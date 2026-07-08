# String Rope Representation Theory

## Overview

*(Apr 27, 2026)*

`String` is the only Elm value with three concrete heap representations. The compiler still emits a single string allocation primitive (`Tag_String`, the flat UTF-16 leaf), but the runtime can rewrite a leaf into a **slice** (a structural view over a leaf) or a **rope** (a binary concat tree) when string operations would otherwise duplicate data. The representation is opaque to user code and to the compiler; only `Elm::StringOps` (and the small set of UTF-8 helpers it permits) ever inspects the tag.

The driving constraints are:

1. Repeated `++` should not be `O(n²)` for long strings. Ropes give amortised `O(log n)` concat.
2. `slice`, `trim*`, `dropLeft`/`dropRight`, `left`, `right` must not copy a 16-bit buffer when the result is a substring of an existing leaf. Slices share the source buffer.
3. Above a documented threshold, structural forms collapse back to a flat leaf so kernel hot paths and UTF-8 encoding stay on a single contiguous buffer.
4. The compiler/MLIR is not aware of ropes or slices: every `eco_alloc_string*` and `Eco_StringLiteralOp` produces a `Tag_String` leaf. Structural forms are produced and consumed entirely inside the runtime.

The heap layout, GC tracing, and `StringOps` API for these three forms are governed by **HEAP_025** in `design_docs/invariants.csv`.

## The Three Tags

```cpp
struct ElmString {                  // Tag_String — flat UTF-16 leaf
    Header header;                  // header.size = code-unit count
    u16 chars[];                    // flexible array; byte size varies
};

struct ALIGN(8) ElmStringSlice {    // Tag_StringSlice — view over a leaf
    Header header;                  // header.size = slice length (code units)
    HPointer base;                  // points to a Tag_String leaf (canonicalised
                                    // — never to another slice or rope)
    u32 offset;                     // starting index in base->chars[]
    u32 _padding;                   // reserved for future flags (e.g. all-ASCII)
};

struct ALIGN(8) ElmStringRope {     // Tag_StringRope — concat tree node
    Header header;                  // header.size = total length
    HPointer left;                  // any string tag
    HPointer right;                 // any string tag
    u32 height;                     // 1 + max(leftHeight, rightHeight); leaves & slices = 0
    u32 leafCount;                  // sum of leaves visible through this subtree
};
```

Both `Tag_StringRope` and `Tag_StringSlice` sit in the `Tag` enum **before** `Tag_Forward` so the "Forward must be last" invariant is preserved. `Tag_String`'s numeric value is unchanged because MLIR/LLVM lowering bakes it into header construction; new tags were appended without renumbering existing tags.

### Why `header.size` Always Means "Logical UTF-16 Length"

For all three forms `header.size` is the logical code-unit count visible to Elm. This deviates from the byte-count convention some other variable-size objects use, but it is the only choice that keeps `length`, `charAt`, slice arithmetic, and rope `leafCount`/`height` accounting consistent. Byte size is variable only for `Tag_String`; rope and slice are fixed-size objects, with explicit `case Tag_StringRope: size = sizeof(ElmStringRope);` / `case Tag_StringSlice: size = sizeof(ElmStringSlice);` arms in `getObjectSize`.

### `header.unboxed` Is Always 0

Rope and slice fields are pure `HPointer`s; there is no per-slot kind bitmap to consult. `unboxed` is set to 0 at construction and never read by GC for these tags. This is a documented contract (HEAP_025); GC code consults `unboxed` only for Cons / Tuple2 / Tuple3 / ElmArray / Custom / Record / DynRecord / Closure.

## Empty-String Canonicalisation

`Const_EmptyString` is one of the seven embedded `HPointer` constants (`HEAP_010`/`REP_CONSTANT_001`). Every constructor short-circuits length-zero results to it:

- `makeLeafFromBuffer(_, 0)` → `alloc::emptyString()`
- `makeSlice(_, _, 0)` → `alloc::emptyString()`
- `makeRope(left, right)`: empty child → return the other; both empty → empty constant
- `flattenToLeaf(empty | len==0)` → `alloc::emptyString()`

This preserves `REP_CONSTANT_001` (constants are never heap-allocated) and avoids the well-known 8-byte-vs-forward-pointer corruption that would arise from allocating a zero-length leaf into a heap cell that GC later overwrites with a 16-byte forwarding pointer.

## Construction Boundaries

| Path | Result | Notes |
|---|---|---|
| MLIR / `eco_alloc_string*` / `Eco_StringLiteralOp` / `Eco_AllocateStringOp` | leaf only | Compiler-emitted; no rope/slice produced |
| `alloc::allocString` (`HeapHelpers.hpp`) | leaf only | Used by C++ kernels and `StringOps` for short results |
| `StringOps::makeLeafFromBuffer` | leaf | Wrapper that canonicalises empty |
| `StringOps::makeSlice(base, off, len)` | slice or empty | `base` must be a leaf; constructor asserts via offset arithmetic |
| `StringOps::makeRope(left, right)` | rope or one child unchanged | Computes `height` / `leafCount` from children before allocating |

Per **CGEN_039** the compiler may not introduce `Tag_StringRope` / `Tag_StringSlice` allocations directly — they exist only inside `StringOps` and through the kernel `String` module that delegates to `StringOps`.

## Tag-Dispatched Access

`StringOps` exposes a small helper layer that hides the three tags:

```cpp
isLeaf(o)       // alloc::getTag(o) == Tag_String
isSlice(o)      // alloc::getTag(o) == Tag_StringSlice
isRope(o)       // alloc::getTag(o) == Tag_StringRope
rawLen(o)       // Header*->size, valid for all three
heightOf(o)     // 0 for leaf and slice, stored for rope
leafCountOf(o)  // 1 for leaf and slice, stored for rope
```

The two canonical readers are `charAt` and `toStdU16String`:

- **`charAt(str, i)`** is implemented as an iterative loop, not recursion. A leaf reads `chars[i]`; a slice resolves its base and reads `chars[offset + i]`; a rope reads its left subtree's `header.size`, and either descends into the left subtree (if `i < leftLen`) or shifts `i -= leftLen` and descends right. The iterative form means a deep rope cannot blow the C stack.
- **`toStdU16String(str)`** materialises the contents into a contiguous `std::u16string`, pre-sized from `header.size`. It uses an explicit DFS stack (visit-right-then-left so left is popped first) so deep ropes don't recurse on the C stack. This is the canonical interop path for kernel C++ and for UTF-8 encoding (`elm_utf8_width` / `elm_utf8_copy`).

Neither function allocates on the Elm heap, so callers don't need to root inputs across them.

## Heuristics

```cpp
namespace detail {
    constexpr size_t FLATTEN_LIMIT     = 32 * 1024;        // ~64 KiB UTF-16
    // Rope rebalance heuristics — only consulted when ropes exist.
    constexpr u32 MAX_HEIGHT       = 32;
    constexpr u32 LEAFCOUNT_LIMIT  = 64;
    constexpr u32 MIN_LEAF_SIZE    = 128;
}

// Tiny-slice cutoff is a runtime-tunable HeapConfig field, not a compile-time
// constant. Default 128 UTF-16 code units (was 8 KiB before May 22, 2026 —
// most slices in practice are short, and a 8 KiB cap was forcing avoidable
// leaf copies).
//
//   AllocatorCommon.hpp:  STRING_TINY_SLICE_LIMIT = 128
//                         HeapConfig::string_tiny_slice_limit (instance field)
//   StringOps.cpp:        slice_len <= allocator.getConfig()
//                                              .string_tiny_slice_limit
//   heap-config.json:     "string_tiny_slice_limit": <bytes>
//   eco-config.json:      flows through into HeapConfig at startup

enum class FlattenReason {
    Structural,    // ad-hoc concat / slice cleanup
    Equality,      // about to compare; flatten so memcmp wins
    Utf8Encode,    // UTF-8 width/copy needs contiguous buffer
    RandomAccess,  // ensureFlat() — caller will index in a tight loop
    Transform,     // toUpper / toLower / reverse / repeat / map / filter
};
```

`maybeFlattenOrRebalance(s, reason)` is the single decision point:

- `Const_EmptyString` and leaves pass through unchanged.
- If `header.size <= FLATTEN_LIMIT`, call `flattenToLeaf` and return a fresh leaf.
- Otherwise return `s` unchanged. For ropes with `reason == Structural`, this is also where the future rebalancer would fire when `height > MAX_HEIGHT` or `leafCount > LEAFCOUNT_LIMIT && avgLeaf < MIN_LEAF_SIZE`. Today only a `// TODO: rebalance` is recorded — the heuristics are observed but no rotation runs.

`ensureFlat(s)` is `maybeFlattenOrRebalance(s, RandomAccess)`. Hot kernel loops that need direct `chars[i]` access call `ensureFlat` once and then walk the leaf, paying one allocation rather than per-character tag dispatch.

## Operation-by-Operation Summary

### `slice(str, start, end)`

| Input shape | Result shape |
|---|---|
| Whole-string range | original `HPointer` (no copy) |
| `len ≤ string_tiny_slice_limit` *(runtime tunable, default 128 UTF-16 code units)* | flat leaf (avoids slice metadata for short ranges) |
| Large range over a leaf | new `Tag_StringSlice` over the source |
| Large range over a slice | new slice with `offset = parent.offset + start` (slice-of-slice collapses) |
| Range over a rope, fully in left/right child | recurse into that child |
| Range over a rope, spanning both children | rope of (slice over left tail) and (slice over right head) |

Slice-of-slice and rope-of-slice collapse at construction time (no unbounded slice chains, no rope-of-rope-of-rope created by repeated trims).

### `append(a, b)`

- `total ≤ FLATTEN_LIMIT`: snapshot via `toStdU16String`, allocate a fresh leaf, `memcpy` both halves. Keeps the simple memcpy fast path for everyday string building.
- `total > FLATTEN_LIMIT`: build a `Tag_StringRope` joining the two `HPointer`s. Both operands are wrapped as `HPointer`s before the rope allocation so they survive the `allocate()` call.

### `concat(stringList)` / `join(sep, stringList)`

Two-pass: first walk computes total length; second walk produces the result.

- `total ≤ FLATTEN_LIMIT`: allocate a single flat leaf, copy each element via `toStdU16String` (so slice/rope inputs work transparently).
- `total > FLATTEN_LIMIT`: collect element `HPointer`s into a `std::vector` (caller-rooted) and call `buildBalancedRope`.

`buildBalancedRope` uses an explicit merge stack: each new element is pushed; whenever `top.size() ≤ second.size()`, the two are merged via `makeRope` and pushed back. This avoids the degenerate `O(n²)` left-leaning shape of naive `((((a++b)++c)++d)…)` accumulation while still being a single linear pass.

### Transforms (`toUpper`, `toLower`, `reverse`, `repeat`, `padLeft/Right`, `map`, `filter`, `cons`)

All snapshot via `toStdU16String` first, then run their existing leaf-based loop. The result is always a flat leaf in the current implementation. For ropes / slices below `FLATTEN_LIMIT` this is essentially `flatten-then-existing-loop`; above the limit, the snapshot still happens (bounded by the rope size) — streaming variants are deferred follow-ups.

### `equal(a, b)` / `compare(a, b)`

- Pure leaf+leaf: `memcmp(chars, chars, len * 2)` — the original fast path is unchanged.
- Mixed shapes with `max(len) ≤ FLATTEN_LIMIT`: snapshot both via `toStdU16String`, then `memcmp`. The snapshot allocations are on the C stack, not the Elm heap.
- Mixed shapes with `max(len) > FLATTEN_LIMIT`: bounded-memory walk via `charAt(a, i)` vs `charAt(b, i)`. `// TODO: streaming compare` is recorded for follow-up.

`compare` follows the same three-tier shape and additionally returns the tie-breaker `static_cast<int>(ha->size) - static_cast<int>(hb->size)` when one string is a prefix of the other.

### Search (`contains`, `startsWith`, `endsWith`, `indexes`)

All implemented via `charAt`, so they transparently handle every tag without flattening. Allocation-free for haystack and needle inputs.

## GC Integration

The new tags participate in tracing, evacuation, and old-gen mark/fixup like any container with `HPointer` fields:

| Site | What it does for the new tags |
|---|---|
| `getObjectSize` | `Tag_StringSlice` → `sizeof(ElmStringSlice)`; `Tag_StringRope` → `sizeof(ElmStringRope)`. `Tag_String` byte-size formula unchanged. |
| Nursery evacuation (`NurserySpace.cpp`) | Slice forwards `base`. Rope forwards `left` and `right`. Same dispatch as Cons. |
| Nursery post-copy scan | Slice/rope cases enqueue children for further scanning. |
| Old-gen mark (`OldGenSpace.cpp`) | Marker pushes `base` for slices; `left` and `right` for ropes. Per-block mark bitmaps record liveness. |
| Old-gen fixup | Pointer-fixup updates `base` / `left` / `right` after compaction. |
| `initHeaderForTag` | No-op for slice/rope — constructors set `header.size` explicitly; `_padding`/`height`/`leafCount` are written by the constructor. |

`HeapHelpers::isString(p)` accepts all three tags. `HeapHelpers::stringLength(p)` reads `header.size` for any string tag. `HeapHelpers::stringData(p)` keeps its leaf-only contract (asserts `getTag == Tag_String`); call sites that previously read `chars[]` for any string have been migrated to `StringOps::charAt` / `toStdU16String` / `ensureFlat`.

## Rooting Discipline

`makeSlice`, `makeRope`, `flattenToLeaf`, `ensureFlat`, `slice`, `append`, `concat`, `join`, and `buildBalancedRope` allocate. Callers must root every `HPointer` they hold across these calls; resolved `void*`s are unsafe across `Allocator::allocate()` because GC may relocate the underlying object.

The `StringOps` constructors take `HPointer` arguments (not `void*`) for exactly this reason and use `Elm::StackRootGuard` internally to keep their inputs reachable across the alloc. `slice` and `buildBalancedRope` use guards explicitly. The general rule is consistent with the rest of the runtime: if a kernel helper allocates, it is the caller's responsibility to ensure live `HPointer`s appear in `RootSet::stack_root_ranges` before the call.

## Boundary with Kernel C++

Per **BFOPS_032** and **HEAP_025**, the only layout-aware code for `String` is `Elm::StringOps` plus the UTF-8 helpers `elm_utf8_width` / `elm_utf8_copy`. Every other kernel C++ file (`elm-kernel-cpp/src/{core, parser, json, bytes, url, http, regex, virtual-dom}/...`, `eco-kernel-cpp/src/eco/...`) reads strings through:

- `Elm::StringOps::length(void*)`
- `Elm::StringOps::charAt(void*, i64)`
- `Elm::StringOps::toStdString(void*)` / `toStdU16String(void*)`
- `Elm::StringOps::ensureFlat(HPointer)` for hot paths that must walk `chars[]` directly

The kernel `String` module (`elm-kernel-cpp/src/core/String.{hpp,cpp,StringExports.cpp}`) is a thin wrapper that delegates each kernel string operation to `Elm::StringOps`. The C ABI signatures are unchanged so JIT resolution and BF dialect lowering are unaffected.

UTF-8 helpers materialise via `toStdU16String` once and then reuse the existing UTF-8 encode loop. This keeps UTF-8 logic centralised in one place and means rope/slice support drops out for free at this layer.

Debug printers (`print_string_content`, `print_string`, `eco_crash`, `print_value`'s `Tag_String` branch, `print_label`) all route through `Elm::StringOps::toStdString` and accept any string tag via `isString`.

## Compiler Side: Documentation Only

There are no Elm-side or MLIR-side code changes for ropes/slices. The contracts are:

- `Eco_StringLiteralOp` and `Eco_AllocateStringOp` always produce `Tag_String` leaves.
- `eco_alloc_string`, `eco_alloc_string_literal`, `eco_alloc_string_fast`, `eco_alloc_string_slow`, `eco_init_string_at` all produce leaves.
- `String` runtime layout is opaque to the compiler. The MLIR pipeline does not pattern-match on rope/slice tags.

The plan that drove this work documents the compiler's contract in `Compiler/Generate/MLIR/Context.elm` and `KernelAbi.elm`, but no semantic changes were required.

## Invariants

- **HEAP_001** — every heap object starts with an 8-byte `Header`. `ElmStringSlice` and `ElmStringRope` both lead with one.
- **HEAP_010 / REP_CONSTANT_001** — `Const_EmptyString` is never heap-allocated. Every constructor short-circuits empty results to it.
- **HEAP_025** *(added Apr 27, 2026)* — strings exist as `Tag_String` / `Tag_StringRope` / `Tag_StringSlice`; `header.size` is logical UTF-16 length for all three; compiler/MLIR allocates only leaves; structure access goes through `StringOps` or `elm_utf8_*`. See `design_docs/invariants.csv`.
- **REP_HEAP_001/002** — heap-field representation is layout-driven. Rope and slice fields are pure boxed `HPointer`s; their `header.unboxed` is always 0 and is never read by GC.
- **BFOPS_032** — runtime helpers are the only layout-aware code for `String`. Strengthened by this change: kernel code now goes through `StringOps` rather than reading `chars[]` directly.
- **CGEN_039 / CGEN_019** — MLIR codegen never emits `Tag_StringRope` / `Tag_StringSlice` allocations. Verified by inspection of `Compiler/Generate/MLIR/Ops.elm` and the lowering passes.

## Open Items / Future Work

- **Real rope rebalancing.** `maybeFlattenOrRebalance` records the trigger conditions (`MAX_HEIGHT`, `LEAFCOUNT_LIMIT`, `MIN_LEAF_SIZE`) but does not rotate. Pathological deep ropes from sustained left-leaning concat are bounded by `FLATTEN_LIMIT` (small ropes flatten; large ones stay tall but no worse than today's `O(n²)` flat copy cost would have been).
- **Streaming `equal` / `compare`.** Above `FLATTEN_LIMIT` the comparison falls back to per-character `charAt`. A streaming pair-walk that avoids the per-character tag dispatch is on the follow-up list.
- **Streaming UTF-8.** `elm_utf8_width` / `elm_utf8_copy` materialise the full string before encoding. Option B from the design plan — true streaming encode via per-leaf segments — is a follow-up.
- **All-ASCII bit in `ElmStringSlice`.** The `_padding` field is reserved for a future flag that could enable byte-level fast paths for ASCII-only ranges.
- **Char iterators / cursor types** for rope traversal in user-facing kernel code, replacing `charAt` indexing in inner loops.

## UTF-8 (all-ASCII) Forms

*(added Jul 8, 2026 — see **HEAP_032** and
`plans/utf8-string-representation.md`)*

Two further forms hold **pure-ASCII** content as UTF-8 bytes (1 byte per
logical UTF-16 unit), enabling zero-copy between `Bytes` and `String`:

```cpp
struct ALIGN(8) ElmStringUtf8View {   // Tag_StringUtf8View — zero-copy byte view
    Header header;                    // header.size = UTF-16 unit count == byteLen
    HPointer base;                    // -> Tag_ByteBuffer | Tag_LargeByteHeader
                                      //    | Tag_StringUtf8Leaf (never a slice/view)
    u32 offset;                       // byte offset into base's payload
    u32 byteLen;                      // == header.size (all-ASCII invariant)
};
struct ALIGN(8) ElmStringUtf8Leaf {   // Tag_StringUtf8Leaf — inline ASCII bytes
    Header header;                    // header.size = byte count == unit count
    u8 bytes[];
};
```

**Why all-ASCII.** Restricting to bytes `< 0x80` makes `unit index == byte
offset`, so `length`/`slice`/`charAt` stay O(1) and correct with no index
translation; no code point spans units; no lone surrogate is representable;
and `equal`/`compare` reduce to `memcmp` (byte order == UTF-16 unit order for
ASCII). Non-ASCII content always stays in the UTF-16 forms — byte-for-byte
behavioural compatibility. The all-ASCII invariant is asserted under
`ECO_HEAP_VALIDATE`.

**Creation is gated** (valid + all-ASCII only), at exactly: `Bytes.Decode.string`
(`read_string` via `Elm::Utf8::scan`; `>= utf8_view_min_len` bytes → view,
shorter → leaf), `StringOps::makeUtf8View`/`makeUtf8LeafFromBytes` (slice/uncons
of an existing UTF-8 form; `fromInt`/`fromFloat`), and
`eco_alloc_string_literal_utf8` (ASCII string literals + string-`case`
patterns, emitted by the compiler as `[N x i8]` globals and interned).
`HeapConfig::utf8_strings_enabled = false` rolls everything back to UTF-16.

**GC** treats `Tag_StringUtf8View` exactly like `Tag_StringSlice` (trace the
single boxed `base`; fixed-size `getObjectSize`) and `Tag_StringUtf8Leaf` like
`Tag_String` (pointer-free, footprint from `header.size`). A view's `base`
points at a `Tag_LargeByteHeader`'s *header* (not its pinned body), matching
slice-of-large.

**Operation handling.** `StringOps` reads UTF-8 payloads via `isUtf8` /
`utf8Bytes`; `forEachSegmentEx` fires a `u8` callback for UTF-8 segments with
stable pointers (so `equal`/`compare` can collect mixed-width segments safely),
while the u16-only `forEachSegment` wrapper widens through a transient buffer
for consume-immediately callers. `ensureFlat` widens a UTF-8 form to a UTF-16
leaf unconditionally (parser and other `chars[]` consumers; the parser also has
a direct byte fast path). `getStringWidth`/`elm_utf8_width` are O(1)
(`header.size`) and `Encode.string`/`elm_utf8_copy` are a `memcpy` for UTF-8
inputs.

## See Also

- `runtime/src/allocator/Heap.hpp` — `Tag` enum, `ElmString` / `ElmStringSlice` / `ElmStringRope` structs, `HeapValue` union
- `runtime/src/allocator/StringOps.hpp` / `StringOps.cpp` — public API and tag-dispatched implementations
- `runtime/src/allocator/HeapHelpers.hpp` — `isString`, `stringLength`, `stringData`
- `runtime/src/allocator/AllocatorCommon.hpp` — `getObjectSize`
- `runtime/src/allocator/NurserySpace.cpp`, `OldGenSpace.cpp` — GC tracing
- `runtime/src/allocator/ElmBytesRuntime.cpp` — `elm_utf8_width` / `elm_utf8_copy`
- `plans/string-rope-slice-representation.md` — original design plan and resolved questions
- `design_docs/invariants.csv` — HEAP_025
- [heap_representation_theory.md](heap_representation_theory.md) — broader heap model
- [kernel_abi_theory.md](kernel_abi_theory.md) — kernel C++ ABI rules including BFOPS_032
