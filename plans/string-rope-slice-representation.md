# String: Flat Leaves + Ropes + Slices + Opportunistic Flattening

## Goal

Replace the current "all `String` heap objects are flat `Tag_String` leaves" representation with a tagged-tree representation of three kinds:

- **Leaf**: `Tag_String` — flat UTF-16 buffer (the existing `ElmString`)
- **Rope** (`Tag_StringRope`): concat-tree node with two `HPointer` children
- **Slice** (`Tag_StringSlice`): structural view with `(base, offset, length)`

`String` operations build ropes/slices for sharing and amortized concat, and **opportunistically flatten** under documented heuristics (size, height, leaf count, leaf-density, and operation-specific reasons).

The compiler / MLIR continues to allocate **only** flat leaves (`Tag_String`); ropes and slices arise only at runtime inside `StringOps` and the kernel libraries. This isolates the representation change to:

1. Heap layout & GC (new tags + tracing).
2. `StringOps` core (tag-dispatched accessors + new constructors + heuristics).
3. Kernel C++ modules currently casting `void* → ElmString*` (must go through `StringOps` instead).
4. Runtime debug/printing helpers (similarly).
5. UTF-8 helpers (`elm_utf8_width`/`elm_utf8_copy`) which today read `chars[]` directly.

---

## Current State (verified against the tree)

- `Tag` enum in `runtime/src/allocator/Heap.hpp:65-86` has 18 tags; `TAG_BITS = 5` gives a budget of 32. Adding two new tags is well within budget. `Tag_Forward` is documented as "must be last"; new tags must be added **before** `Tag_Forward` (and before `Tag_Free`, the sweep free-cell marker).
- `ElmString` (`Heap.hpp:219-223`) is `Header + u16 chars[]`. `HeapValue` union (`Heap.hpp:406-424`) lists it.
- `getObjectSize` (`AllocatorCommon.hpp:61-138`) has a `Tag_String` branch returning `sizeof(ElmString) + hdr->size * sizeof(u16)`.
- `initHeaderForTag` (`ThreadLocalHeap.cpp:52-79`) recovers `hdr->size` (code units) for `Tag_String` from the byte size.
- GC scan/mark sites:
  - Nursery copy: `NurserySpace.cpp:633-779` (object-kind dispatch in evacuation), `NurserySpace.cpp:1137-1267` (post-copy scan; the comment at 1267 explicitly assumes `Tag_String` has no children).
  - Old gen mark: `OldGenSpace.cpp:982-1061`. Old gen fixup: `OldGenSpace.cpp:2545-2619`.
- `HeapHelpers.hpp:447-458, 1159-1161` — `stringLength`, `stringData`, `isString` all assume `Tag_String`.
- `StringOps.hpp/cpp` — every operation casts `void* → ElmString*` and reads `chars[i]` / `header.size` directly.
- Allocations producing strings:
  - `eco_alloc_string`, `eco_alloc_string_literal`, `eco_alloc_string_fast`, `eco_alloc_string_slow`, `eco_init_string_at` (`RuntimeExports.cpp:303-863`) — keep as **leaf-only**.
  - `alloc::allocString` (in `HeapHelpers.hpp` used throughout `StringOps.cpp`) — keep as **leaf-only**.
- UTF-8 helpers `elm_utf8_width`/`elm_utf8_copy` (`ElmBytesRuntime.cpp:103-200`) iterate `s->chars` directly. **Invariant `BFOPS_032` requires all `String` structure access to go through `elm_utf8_*`** — so these become a primary representation-aware boundary alongside `StringOps`.
- 17 kernel/runtime `.cpp/.hpp` files reference `ElmString`/`Tag_String` directly outside StringOps.

---

## Phasing (resolved)

Per Q1, the work is split into two phases. Each phase is independently shippable.

- **Phase 1 — Slices only.** Adds `Tag_StringSlice`, the `ElmStringSlice` struct, GC tracing for the `base` field, slice-aware accessors in `StringOps`, and rewrites `slice`/`trim*`/`drop*`/`left`/`right` to build slices instead of copies. `append`/`concat`/`join` remain flat. All kernel/runtime printer migration to `StringOps` happens here, since it's required to read slices safely.
- **Phase 2 — Ropes.** Adds `Tag_StringRope`, the `ElmStringRope` struct, GC tracing for `left`/`right`, rope-aware `charAt`, rewrites `append`/`concat`/`join` to build ropes with `FLATTEN_LIMIT` heuristics, and updates `equal`/`compare`/`elm_utf8_*`/transforming ops to handle rope inputs (flatten-then-existing-loop semantics).

The numbered steps below are written for the **combined** plan; phase tags `[P1]`, `[P2]`, or `[P1+P2]` mark which phase each sub-step belongs to. Implement Phase 1 to completion (build, tests, e2e) before starting Phase 2.

---

## Step-by-Step Implementation Plan

The plan is staged so each step can build, run, and pass tests before moving on. The bulk of the change is concentrated in steps 2–5.

### Step 1 — Heap & GC: add tags, structs, sizes, tracing

**Files:** `runtime/src/allocator/Heap.hpp`, `AllocatorCommon.hpp`, `ThreadLocalHeap.cpp`, `NurserySpace.cpp`, `OldGenSpace.cpp`, `TypeInfo.hpp`.

1. **Tags.**
   - `[P1]` Add `Tag_StringSlice` to the `Tag` enum, placed **before** `Tag_Forward` (which is documented as "must be last"). `Tag_String` keeps its current numeric value — this matters because lowering bakes `Tag_String` into header construction.
   - `[P2]` Add `Tag_StringRope` immediately before `Tag_StringSlice` (or after, either is fine — both are added before `Tag_Forward`).
2. **Structs.**
   - `[P1]` Add `ElmStringSlice` (header + `HPointer base`, `u32 offset`, `u32 _padding`), `ALIGN(8)`. `_padding = 0` for now, reserved for future flags.
   - `[P2]` Add `ElmStringRope` (header + `HPointer left`, `HPointer right`, `u32 height`, `u32 leafCount`), `ALIGN(8)`.
   - Document that `header.size = logical UTF-16 length` for **all** string tags. The byte size is variable only for `Tag_String`; rope/slice are fixed-size objects (per Q3).
3. **HeapValue union.** `[P1]` add `ElmStringSlice stringSlice;`; `[P2]` add `ElmStringRope stringRope;`.
4. **`getObjectSize`.** `[P1]` add `case Tag_StringSlice: size = sizeof(ElmStringSlice);`. `[P2]` add `case Tag_StringRope: size = sizeof(ElmStringRope);`. The existing `Tag_String` byte-size formula stays unchanged. The `Tag_Forward` arm is independent and is not affected (per Q10).
5. **`initHeaderForTag`.** No-op for the new tags; the constructors will set `header.size` explicitly. Add a comment to that effect.
6. **GC tracing.**
   - `[P1]` Nursery: in the post-copy scan switch (`NurserySpace.cpp:1137-1267`) add a case for `Tag_StringSlice` that forwards `base`. The evacuation dispatch (`NurserySpace.cpp:633-779`) is field-by-field for container types; the slice's `base` is a fully boxed `HPointer`, so it fits the same pattern as e.g. `Tag_Cons`.
   - `[P1]` Old gen mark: `OldGenSpace.cpp:982-1061` — add slice children traversal so the marker enqueues `base`.
   - `[P1]` Old gen fixup: `OldGenSpace.cpp:2545-2619` — pointer-fixup for `base`.
   - `[P2]` Repeat the same three sites for `Tag_StringRope`, forwarding `left` and `right`.
7. **TypeInfo.hpp.** If it carries per-tag type info (string-related descriptors), extend it consistently. P1 adds slice; P2 adds rope.
8. **`unboxed` field policy.** Per Q4: rope/slice nodes have only fully-boxed `HPointer` fields; we set `header.unboxed = 0` and never read it for these tags. No GC code reads `unboxed` for strings today (it is only consulted for Cons/Tuple/Array). Document this in the struct comment.
9. **Sanity.** Add a debug-only assert that `_padding` in `ElmStringSlice` is zero on read.

After step 1: code builds, runs as before. No rope/slice is ever produced yet, so behavior is unchanged.

### Step 2 — `StringOps` core: tag-aware accessors and constructors

**Files:** `runtime/src/allocator/StringOps.hpp`, `StringOps.cpp`, `HeapHelpers.hpp`.

1. **Helpers in StringOps.**
   - `[P1]` `isLeaf(void*)`, `isSlice(void*)`, `rawLen(void*)` (returns `header.size` for any string tag).
   - `[P2]` Add `isRope(void*)`, `heightOf(void*)` (1 for leaf, stored for rope, recurses through slice base), `leafCountOf(void*)` (1 for leaf, stored for rope, delegates through slice).
2. **Generic access.**
   - `[P1]` `length(void*)` → `rawLen(...)`.
   - `[P1]` `charAt(void*, i64 idx)` becomes a tag dispatch:
     - leaf: `s->chars[idx]`,
     - slice: recurse into base at `idx + offset`.
   - `[P2]` Add the rope arm to `charAt`: recurse left/right based on `leftLen` (read from `left`'s header). The rope path **resolves child `HPointer`s through the allocator**; since `charAt` itself does not allocate, this is GC-safe.
3. **Constructors (in `.cpp`).**
   - `[P1]` `makeSlice(HPointer base, u32 offset, u32 len)` → allocates `ElmStringSlice` with `Tag_StringSlice`. `base` must be rooted by the caller (`StackRootGuard` pattern, per Q6). Empty-canonicalization (per Q5): if `len == 0`, return `alloc::emptyString()`; never allocate.
   - `[P1]` `makeLeafFromBuffer(const u16*, u32 len)` → wraps `alloc::allocString`. If `len == 0`, return `alloc::emptyString()` (per Q11, never allocate a zero-length leaf).
   - `[P2]` `makeRope(HPointer left, HPointer right, u32 totalLen, u32 leftHeight, u32 rightHeight, u32 leftLeaves, u32 rightLeaves)` → allocates `ElmStringRope` with `Tag_StringRope`. Both children must be already rooted by the caller. Empty-canonicalization (per Q5): if either child is the empty constant or has `len == 0`, return the other child directly; if both empty, return `alloc::emptyString()`.
4. **`HeapHelpers.hpp` updates.**
   - `[P1]` `isString(void*)`: accept `Tag_String` and `Tag_StringSlice`. `[P2]` extend to `Tag_StringRope`.
   - `[P1]` `stringLength(void*)`: read `header.size` for any string tag.
   - `[P1]` `stringData(void*)`: keep semantics — only valid for leaf — and `assert(getTag == Tag_String)`. Callers that previously passed any "string" must move to `StringOps::charAt`/`toStdU16String` or first flatten. Optionally mark `[[deprecated]]` during the migration to surface remaining direct uses at compile time.
5. **Configuration constants.** `[P1]` add to anonymous namespace in `StringOps.cpp`:
   - `FLATTEN_LIMIT = 32 * 1024` UTF-16 code units (~64 KiB).
   - `[P2]` `MAX_HEIGHT = 32`, `LEAFCOUNT_LIMIT = 64`, `MIN_LEAF_SIZE = 128`, `TARGET_LEAF_SIZE = 512` (rope rebalance heuristics; only consulted by `maybeFlattenOrRebalance` once ropes exist).
   - `[P1]` `enum class FlattenReason { Structural, Equality, Utf8Encode, RandomAccess, Transform }`.
6. **`flattenToLeaf(HPointer)`.** `[P1]` allocates a fresh leaf of `len` units, fills via `charAt`. Roots the input string with `StackRootGuard` across the allocation. Returns the new leaf's `HPointer`. For empty input, returns `alloc::emptyString()` (never allocates a zero-length leaf, per Q11).
7. **`maybeFlattenOrRebalance(HPointer, FlattenReason)`.**
   - `[P1]` shipping behavior: if already leaf or empty constant, return as-is; else if `len <= FLATTEN_LIMIT`, `flattenToLeaf`; else return as-is. (No rope structural cases yet.)
   - `[P2]` add the rope arm: if `len > FLATTEN_LIMIT` and `Structural` and (`height > MAX_HEIGHT` or `(leafCount > LEAFCOUNT_LIMIT && len/leafCount < MIN_LEAF_SIZE)`), emit a `// TODO: rebalance` and return rope unchanged. Per Q9, full rebalancing is deferred.
8. **`toStdU16String`/`toStdString`.** `[P1]` make tag-aware via `charAt`/length walk so they handle slices. These are the canonical interop path for kernel C++. `[P2]` no further change — they already iterate by `length`/`charAt`.

### Step 3 — `StringOps` operations: append, slice, transform, equality

After step 2, individual ops can be migrated incrementally; the migration order is chosen so each commit is testable.

1. **`slice(void*, i64 start, i64 end)`. `[P1]`**
   - Whole-string slice: return the existing `HPointer` (no copy).
   - Tiny slice (`len ≤ FLATTEN_LIMIT/4`): flatten directly into a leaf (avoids slice metadata bloat for small ranges).
   - Leaf input: build a `Tag_StringSlice` directly over the leaf base.
   - Slice-of-slice: collapse to a single slice over the deepest non-slice base by adding offsets (avoids unbounded slice chains).
   - `[P2]` Rope input: implement `sliceRope(HPointer root, u32 start, u32 len)` in `.cpp` — walk by child lengths, cut at the boundary, rebuild a rope-of-slices for the trimmed parts, sharing fully-included subtrees.
2. **`left/right/dropLeft/dropRight/trim*`. `[P1]`** Today these all delegate to `slice` — no further change required after step 3.1.
3. **`append(void*, void*)`.**
   - `[P1]` Two leaves with `total ≤ FLATTEN_LIMIT`: keep current `memcpy` fast path.
   - `[P1]` Two leaves with `total > FLATTEN_LIMIT`: keep current memcpy until P2 (rare in current usage).
   - `[P1]` One side is a slice: flatten the slice via `flattenToLeaf` first, then memcpy. Acceptable in P1 since slices only flow into `append` from user code that previously copied anyway.
   - `[P2]` General path: `makeRope` over the two `HPointer`s, then `maybeFlattenOrRebalance(rope, Structural)`. Root both operands across allocation.
4. **`concat(stringList)` / `join(sep, stringList)`.**
   - `[P1]` Existing flat-allocation path stays as-is, but the per-element traversal must use `StringOps::length`/`charAt` (or flatten slice inputs first) to handle slice inputs correctly.
   - `[P2]` If `total > FLATTEN_LIMIT`: build a balanced rope by repeatedly appending list elements and applying `maybeFlattenOrRebalance` at the end. Avoid `O(n²)` left-leaning concatenation by using an explicit balanced-merge stack.
5. **Transforms (`toUpper`, `toLower`, `reverse`, `repeat`, `cons`, `padLeft`, `padRight`, `map`, `filter`, `foldl`, `foldr`). `[P1]` for slice handling, `[P2]` for rope handling.**
   - `[P1]` If input is a slice: flatten to leaf via `maybeFlattenOrRebalance(..., FlattenReason::Transform)`, then run existing leaf-based loop. Existing leaf path is unchanged.
   - `[P2]` Same flatten-then-existing-loop strategy if input is a rope under `FLATTEN_LIMIT`. Larger-rope streaming traversal is a follow-up (per Q7/Q8 — out of scope here).
6. **Searching / equality.** Per Q7:
   - `[P1]` `equal`/`compare`: if either side is a slice, flatten via `maybeFlattenOrRebalance(..., Equality)` then `memcmp`. Pure leaf+leaf path is unchanged.
   - `[P2]` Add the rope arms to the same flatten-then-`memcmp` paths, gated on `len ≤ FLATTEN_LIMIT`. For `len > FLATTEN_LIMIT`, fall back to a character-by-character traversal over `charAt` (no extra flattening, bounded peak memory). Add `// TODO: streaming compare` for follow-up.
   - `[P1+P2]` `contains/startsWith/endsWith/indexes/split`: flatten haystack and needle under `Equality` semantics. Streaming versions are out of scope for both phases.
7. **`uncons` / `cons`.**
   - `[P1]` `uncons(str)` already calls `slice(str, 1, len)` — automatically benefits from slice sharing.
   - `[P1]` `cons(c, str)` keeps the leaf allocation path; if `str` is a slice, flatten first.
   - `[P2]` `cons` for large `str`: switch to building a 2-leaf rope: `[c] ++ str`.

### Step 4 — Runtime exports & UTF-8 helpers

**Files:** `runtime/src/allocator/RuntimeExports.cpp`, `ElmBytesRuntime.cpp`, `ElmBytesRuntime.h`, `BytesOps.cpp/.hpp`, `platform/PlatformRuntime.cpp`.

1. **Allocation exports remain leaf-only.** `[P1]` `eco_alloc_string`, `eco_alloc_string_literal`, `eco_alloc_string_fast`, `eco_alloc_string_slow`, `eco_init_string_at` continue to allocate `Tag_String`. Add a comment: "Compiler-emitted allocation exports always produce flat `Tag_String` leaves. Slice (P1) and rope (P2) nodes are produced only by `StringOps`/kernel string operations."
2. **Debug/print paths.** `[P1]` `print_string_content`, `print_string`, `eco_crash`, `print_value` (`Tag_String` branch around `RuntimeExports.cpp:1887`), `print_label`, and the diagnostic at `RuntimeExports.cpp:1420` all assume leaf strings. Re-route them through `Elm::StringOps::toStdString(void*)` / `charAt` + `length`. Extend the `Tag_String` switch arms to also accept `Tag_StringSlice` (and `[P2]` `Tag_StringRope`) using `StringOps::toStdString`. The single tag check at `RuntimeExports.cpp:2028` must become an `isString(...)` call. **All printer migration must happen in P1** — once any slice exists in the heap, the old `Tag_String`-only printers are unsafe.
3. **`elm_utf8_width` / `elm_utf8_copy` (`ElmBytesRuntime.cpp:103-200`).** Per Q8: **Option A confirmed** for both phases.
   - `[P1]` Update both functions to handle slices: rather than read `s->chars` directly, call `Elm::StringOps::toStdU16String(...)` once to materialize a contiguous buffer, then run the existing UTF-8 loop. (Alternative for slices specifically: flatten via `flattenToLeaf` then run existing loop on the leaf — pick whichever is simpler in code.)
   - `[P2]` No change required to the implementation — `toStdU16String` already handles ropes via `charAt` after step 2.8.
   - Streaming UTF-8 (Option B) is a follow-up for both phases.
4. **`elm_utf8_decode`** and any reverse path build new `Tag_String` leaves — no change needed.
5. **`BytesOps`/`ElmBytesRuntime`** UTF-8 encode side: route through `StringOps::toStdU16String`/`toStdString` rather than direct `ElmString*` access. No changes to byte buffers themselves.

**Note:** All of step 5 must land in `[P1]` for the same safety reason as step 4.2: kernel modules accepting any `String` argument may receive a slice once `slice/trim*/drop*` are migrated. Late P2 rope changes don't require additional kernel work because the kernel boundaries already go through `StringOps` after P1.

### Step 5 — Kernel C++ modules: drop direct `ElmString` casts

**Files (17):**
`elm-kernel-cpp/src/{core/{String.hpp,String.cpp,StringExports.cpp,Utils.cpp,DebugExports.cpp},parser/ParserExports.cpp,json/JsonExports.cpp,bytes/{Bytes.cpp,BytesExports.cpp},url/{Url.hpp,Url.cpp,UrlExports.cpp},http/HttpExports.cpp,regex/{Regex.cpp,RegexExports.cpp},virtual-dom/{VirtualDom.cpp,VirtualDomExports.cpp}}`,
`eco-kernel-cpp/src/eco/{KernelHelpers.hpp,Http.cpp}`.

**Rule:** Kernel C++ never reads `s->chars[i]` or `s->header.size` directly. All access goes through:

- `Elm::StringOps::length(void*)`
- `Elm::StringOps::charAt(void*, i64)`
- `Elm::StringOps::toStdString(void*)` and `toStdU16String(void*)`
- New helper `Elm::StringOps::ensureFlat(HPointer)` returning a leaf `HPointer` for the rare site that legitimately needs random access (e.g. parser hot loops). **`ensureFlat` may allocate**, so the caller must root inputs.

Migration tactic per file: add the include, replace local `elmStringToStd`-style helpers with one-line wrappers (or delete them and update callers). Keep public C ABI signatures unchanged so the JIT side and BF dialect lowering are unaffected.

`elm-kernel-cpp/src/core/String.{hpp,cpp,StringExports.cpp}` is largely a thin wrapper around `Elm::StringOps`; for each kernel `String` op (length/append/join/slice/split/lines/words/reverse/foldl/foldr), delegate to the corresponding `Elm::StringOps` function with no manual `ElmString` casting.

`ParserExports.cpp` is the heaviest consumer: it currently casts inputs to `ElmString*` and indexes per character. The simplest correct approach is `auto data = Elm::StringOps::toStdU16String(ptr);` once at function entry; if profiling shows it's hot, switch that single function to `ensureFlat` + a direct `chars[]` walk (still a leaf, so no regression in allocation count).

### Step 6 — Compiler & MLIR

**Files:** `compiler/src/Compiler/Generate/MLIR/*`, `runtime/src/codegen/Ops.td`, `runtime/src/codegen/Passes/Eco{ToLLVMTypes,ToLLVMHeap,ToLLVMControlFlow,ToLLVMRuntime,GCPrepare}.cpp`.

`[P1+P2]` No code changes. Only documentation:

- `Ops.td:858-900` (`Eco_StringLiteralOp`) and `:1217-1240` (`Eco_AllocateStringOp`): clarify in the description block that these always produce `Tag_String` leaves; runtime ops may transform results into ropes/slices.
- `Compiler/Generate/MLIR/Context.elm` and `KernelAbi.elm` comments referring to `String` runtime layout: note that the runtime representation is opaque (leaf/rope/slice).

`CGEN_039` already states allocation ops are introduced only by lowering — no semantic change.

### Step 7 — Tests

**Files:** `test/allocator/{StringOpsTest.cpp,RuntimeExportsTest.cpp,AllocatorCommonTest.cpp,HeapHelpersTest.cpp,GCPressureTest.cpp,BytesOpsTest.cpp,HeapGenerators.cpp}`.

1. **Existing leaf assertions.** Where tests check `getTag(s) == Tag_String` for leaves, leave them alone. Where tests assume "strings have no children", replace with "leaves have no children, ropes/slices have stable children".
2. **New tag tests.**
   - `getObjectSize(rope) == sizeof(ElmStringRope)`, ditto slice.
   - `initHeaderForTag` on rope/slice does not corrupt fields.
   - GC scan/mark/fixup follow rope `left`/`right` and slice `base` correctly under nursery copy and old-gen mark/fixup. Use `HeapGenerators` to construct random rope structures.
3. **`StringOps` behavioral tests.**
   - Long `++` chain: assert structural correctness via `toStdU16String` and approximate height bound.
   - `slice` on a leaf returns a `Tag_StringSlice` (no buffer copy) when above the tiny-slice threshold; assert the slice's `base` equals the original.
   - `slice` of `slice` collapses to a single slice over the deepest leaf (or stays as a rope-of-slice — document and test the chosen behavior).
   - `toUpper`/`toLower`/`reverse`/`repeat` on a rope produce a leaf result when input was below `FLATTEN_LIMIT`; produce another rope/leaf otherwise — document and test.
   - `equal`/`compare` on two equal strings of mixed representation return true.
   - `elm_utf8_width`/`elm_utf8_copy` on a rope produce identical bytes to the same string flattened first.
4. **Round-trip property.** For random strings, `toStdU16String(buildAsLeaf) == toStdU16String(buildAsRope) == toStdU16String(buildAsSlice)`.
5. **GC pressure.** A test that builds a deep rope and triggers minor + major GCs without crashing or losing characters.
6. **E2E.** Run `cmake --build build --target full` and the elm-test-rs front-end test suite. Watch for regressions in `String` ops, parser-heavy tests, JSON, URL.

---

## Test / Validation Strategy

For each step, run:

```bash
cmake --build build --target check 2>&1 | tee /tmp/test_output.txt
```

(or `--target full` if any compiler-side comments in step 6 trigger MLIR regen — which they shouldn't).

For step 5 in particular, run a parser-heavy elm-test-rs subset to catch any regression in `ParserExports.cpp`.

---

## Invariants to Maintain

- **HEAP_001** — every heap object begins with an 8-byte `Header`; both new structs do.
- **HEAP_010 / REP_CONSTANT_001** — `Const_EmptyString` is never heap-allocated; all rope/slice paths must early-out on it.
- **REP_HEAP_001/002** — heap-field representation is layout-driven; rope/slice fields are pure boxed `HPointer`s, so the existing 2-bit-per-slot rules don't apply (no unboxed kinds in these new objects). The header's `unboxed` field must be **0** for ropes and slices.
- **BFOPS_032** — runtime helpers are the only layout-aware code for `String`. After this change, `elm_utf8_*` and the StringOps dispatch are the only places that read string layout; kernel code goes through them. This invariant becomes **tighter** with this change, not weaker.
- **CGEN_039 / CGEN_019** — MLIR codegen never directly emits `Tag_StringRope` or `Tag_StringSlice` allocations; only `Tag_String` via `Eco_StringLiteralOp`/`Eco_AllocateStringOp`. Verified by inspection.

A new invariant to add (text for `design_docs/invariants.csv`):

> `HEAP_xxx;Runtime_Heap;StringRepresentation;documented;String values are heap-represented in three forms: Tag_String (flat UTF-16 leaf), Tag_StringRope (binary concat tree with HPointer left/right children), and Tag_StringSlice (view with HPointer base + offset + length). For all three, header.size = logical UTF-16 length. Compiler/MLIR allocation paths produce only Tag_String leaves; rope/slice nodes are produced only by runtime String operations. All structure access outside StringOps and elm_utf8_* must go through Elm::StringOps APIs;Heap.hpp|StringOps.cpp`

---

## Resolved Decisions

All previously open questions have been resolved. Recorded here for the implementer.

### Q1 — Scope: phased.

**Resolved: ship slices first (P1), then ropes (P2).** There is no existing rope infrastructure to break, slicing already funnels through a single `StringOps::slice`, and `Tag_Slice` was already a documented future hook. P1 is a much smaller diff and removes the slice/trim/drop copy on its own.

### Q2 — Tag enum ordering.

**Resolved: keep `Tag_String` at its current numeric value; add new tags before `Tag_Forward`.** `Tag_String` is baked into header construction during MLIR/LLVM lowering and is on-disk-equivalent for compiled binaries / caches. `Tag_Forward` is documented as "must be last" but its specific integer value isn't load-bearing — only the enum name is used. Shifting `Tag_Forward` by 1 (P1) or 2 (P2) is fine.

### Q3 — `header.size` semantics.

**Resolved: `header.size = logical UTF-16 length` for all string tags.** Byte size is variable only for `Tag_String` (`sizeof(ElmString) + hdr->size * sizeof(u16)`); rope/slice are fixed-size, with explicit `getObjectSize` cases. Consistent with how `Tag_ByteBuffer`/`Tag_Array` already work.

### Q4 — `unboxed` field policy.

**Resolved: `header.unboxed = 0` for ropes and slices; nothing reads it.** GC consults `unboxed` only for Cons/Tuple/Array (per the `Heap.hpp` comment and `ListOps`).

### Q5 — Empty constant canonicalization.

**Resolved: canonicalize at every constructor and at `flattenToLeaf`.**
- `makeSlice(..., len=0)` → `alloc::emptyString()`.
- `makeRope(left, right)`: empty child → return other; both empty → empty constant.
- `flattenToLeaf` of empty / `len == 0` → `alloc::emptyString()`, never allocate.

Preserves the "constants never heap-allocated" invariant (`REP_CONSTANT_001` / `HEAP_010`) and avoids the 8-byte vs forward-pointer corruption from `Heap.hpp:212-214`.

### Q6 — Rooting discipline.

**Resolved: caller-side rooting via `StackRootGuard`.** Both `makeRope` and `makeSlice` allocate; callers must root all `HPointer` arguments across the call, matching the pattern used by `cons`, `tuple2`, `listFromPointers`. Documented in constructor comments. The contract is enforced by code review + GC-stress tests.

### Q7 — Equality / compare strategy.

**Resolved: flatten-then-memcmp under `FLATTEN_LIMIT`, char-by-char above.**
- Pure leaf+leaf: existing `memcmp` path unchanged.
- Mixed/slice (P1) or mixed/rope (P2) with `len ≤ FLATTEN_LIMIT`: flatten via `maybeFlattenOrRebalance(..., Equality)`, then `memcmp`.
- `len > FLATTEN_LIMIT`: character-by-character traversal over `charAt`, no extra flattening, bounded peak memory. `// TODO: streaming compare` for follow-up.

### Q8 — UTF-8 helpers.

**Resolved: Option A.** `elm_utf8_width`/`elm_utf8_copy` materialize via `StringOps::toStdU16String` (or flatten then leaf walk) and reuse the existing UTF-8 encode loop. Centralizes UTF-8 logic in one place. Streaming variant (Option B) is a follow-up.

### Q9 — Rebalancing.

**Resolved: deferred.** First cut only flattens; `maybeFlattenOrRebalance` emits a `// TODO: rebalance` when `len > FLATTEN_LIMIT && height > MAX_HEIGHT`. `FLATTEN_LIMIT` + `MAX_HEIGHT` keep small/medium ropes balanced; pathological large `++` chains stay tall but no worse than today's `O(n²)` flat copy. Add proper rebalancing when profiles show it.

### Q10 — `getObjectSize` and `Tag_Forward`.

**Resolved: independent.** `getObjectSize` already has a dedicated `case Tag_Forward: size = sizeof(Forward);` arm that is unaffected by adding rope/slice cases. The GC consults the original tag *before* overwriting the header with `Tag_Forward`. No additional work.

### Q11 — Zero-length leaves.

**Resolved: never allocate.** All construction paths that could produce `len == 0` short-circuit to `alloc::emptyString()` (per Q5). `equal`/`compare` therefore see only the embedded empty constant or non-empty leaf/slice/rope nodes — they never need to reason about heap zero-length leaves.

### Q12 — Test generators.

**Resolved: add slice/rope generators.** `[P1]` `genSlice(...)` for random ranges over a generated leaf in `HeapGenerators.cpp`. `[P2]` `genRope(...)` for random ropes of bounded depth.

### Assumption A1 — Tag bit budget.

Adding 2 tags keeps total ≤ 20, well under the 32-tag cap of `TAG_BITS = 5`.

### Assumption A2 — Allocation exports are immutable.

`eco_alloc_string*` exports keep producing `Tag_String` leaves. The compiler/MLIR is not changed to ever produce ropes or slices. Verified by reading `RuntimeExports.cpp` and confirming no other path allocates with `Tag_String`/`Tag_StringSlice`/`Tag_StringRope` outside `StringOps`.

### Assumption A3 — `_padding` in slice is unused initially.

The 4-byte `_padding` in `ElmStringSlice` is reserved for future flags (e.g. an "all-ASCII" bit). For now we set it to 0 and assert on read in debug.

### Assumption A4 — Heap snapshot/dump compatibility.

If any external on-disk heap-snapshot format serializes raw tag integers, it must learn the new tags. A `grep` for snapshot/serialization code did not surface anything load-bearing; confirm before shipping each phase.

---

## Risks

1. **Use-after-GC in StringOps.** Any code path that holds a `void*` across an allocation breaks. The current `StringOps` is mostly safe because flat ops compute everything before allocating. Rope/slice operations allocate during their work — every such site needs `StackRootGuard`. **Mitigation:** code review specifically targeting "did we root before `allocate`?" plus GC-stress tests.
2. **Kernel C++ misses.** 17 files casting `ElmString*` directly. A single missed site that reads `chars[i]` on a non-leaf will read the rope/slice fields as if they were code units. **Mitigation:** after step 5, search `grep -rn 'static_cast<ElmString\*>' elm-kernel-cpp eco-kernel-cpp` and confirm all hits are inside helper wrappers calling `assert(isLeaf(...))` or via `ensureFlat`. Optionally land a `[[deprecated]]` on `stringData` to surface remaining direct uses at compile time during the migration.
3. **Deep ropes during tests.** Without rebalancing, a stress test that does 100K appends might OOM on rope nodes faster than it would on a flat string. Pick test sizes to keep this in check.
4. **Performance regressions.** Making `charAt` rope-aware adds a tag dispatch on every character read — measurable in tight inner loops. Hot loops in kernel code should use `ensureFlat` (one allocation, then leaf indexing) rather than per-char `charAt`.
5. **`Tag_String` semantics drift.** Future code might assume `isString(x)` implies `chars[]` is valid. The renamed `stringData` (assert-on-leaf) catches this; the migration off `stringData` is mandatory in step 2.

---

## Out of Scope (Follow-ups)

- Real rope rebalancing (e.g. AVL or weight-balanced).
- Streaming `equal`/`compare` over ropes (replaces the char-by-char fallback above `FLATTEN_LIMIT`).
- Streaming `elm_utf8_width`/`elm_utf8_copy` (Option B in Q8).
- An "all-ASCII" bit in `ElmStringSlice` to enable byte-level fast paths.
- Char iterators / cursor types for rope traversal in user-facing kernel code.

(Note: slice-of-slice canonicalization is now done at construction in step 3.1, not deferred.)

---

## Checkpoint Order

### Phase 1 (slices)

1. **Step 1 [P1]** — `Tag_StringSlice`, struct, union entry, `getObjectSize`/`initHeaderForTag`, GC tracing for `base`. Green build, no slice produced yet.
2. **Step 2 [P1]** — slice-aware accessors, `makeSlice`, `flattenToLeaf`, `FLATTEN_LIMIT`, `HeapHelpers` updates with leaf-only `stringData` + assert. Green build, slices not yet produced.
3. **Step 4.2 [P1]** — debug printers route through `StringOps::toStdString` and accept slice tags. Catches print-path regressions before any slice reaches them.
4. **Step 3.1 [P1]** — rewrite `slice` to build `Tag_StringSlice`. From here, slices flow through the system. Run full e2e.
5. **Step 3.2 [P1]** — `left/right/dropLeft/dropRight/trim*` automatically benefit (no code change beyond what step 3.1 enables).
6. **Step 3.3, 3.4, 3.5, 3.6, 3.7 [P1]** — slice-aware paths in `append`/`concat`/`join`/transforms/`equal`/`compare`/`cons`/`uncons` (mostly: flatten-then-existing-loop when input is a slice).
7. **Step 4.3 [P1]** — `elm_utf8_width`/`elm_utf8_copy` via `toStdU16String`.
8. **Step 5 [P1]** — kernel C++ migration to `StringOps`, file by file; e2e after each.
9. **Step 6 [P1]** — doc-only updates.
10. **Step 7 [P1]** — slice generators in `HeapGenerators`, slice tests, GC pressure tests, full e2e.

**End of Phase 1:** ship.

### Phase 2 (ropes)

11. **Step 1 [P2]** — `Tag_StringRope`, struct, union entry, sizes, GC tracing for `left`/`right`. Green build, no rope produced yet.
12. **Step 2 [P2]** — rope arms in helpers (`isRope`, `heightOf`, `leafCountOf`), `charAt` rope dispatch, `makeRope`, rope structural cases in `maybeFlattenOrRebalance`.
13. **Step 3.3, 3.4 [P2]** — `append`/`concat`/`join` build ropes when total exceeds `FLATTEN_LIMIT`.
14. **Step 3.5, 3.6, 3.7 [P2]** — rope arms in transforms, `equal`/`compare` (with char-by-char fallback above `FLATTEN_LIMIT`), `cons`.
15. **Step 4 [P2]** — verify printers + UTF-8 helpers work on ropes (mostly free thanks to `toStdU16String`/`charAt`).
16. **Step 5 [P2]** — verify kernel C++ paths work on ropes (mostly free).
17. **Step 7 [P2]** — rope generators, rope tests, deep-rope GC pressure, full e2e.

**End of Phase 2:** ship.

---

## Stop here for /pqn — no implementation yet.

All open questions from the initial /pqn pass have been resolved (see "Resolved Decisions" above). Phase 1 is ready to start when authorized.
