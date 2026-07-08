# UTF-8 (ASCII) String Representation, Zero-Copy Bytes Views, and Literal Interning

*(Plan created Jul 8, 2026. Design rationale: `design_docs/utf8-string-encoding-investigation.md`.
Prior art in-repo: `design_docs/theory/string_rope_representation_theory.md`,
`plans/string-rope-slice-representation.md`, `plans/large-object-split-header-bodies.md`.)*

## 1. Goal and locked decisions

Add a second String storage encoding to the runtime: **pure UTF-8 restricted to
all-ASCII content** (every char is one 8-bit unit == one UTF-16 code unit).
Three deliverables:

1. **`Tag_StringUtf8View`** — a string that is a zero-copy slice onto a Bytes
   buffer, created by `Bytes.Decode.string` for valid all-ASCII input.
2. **`Tag_StringUtf8Leaf`** — an inline-bytes string form, used for interned
   string literals and small ASCII results.
3. **String-literal interning** — `eco_alloc_string_literal` currently
   allocates a fresh old-gen object on *every execution* of the op
   (`RuntimeExports.cpp:414-428`; dropped copies are reclaimed at major GC, so
   this is churn, not a leak — but it is repeated work and old-gen pressure).
   Interning makes each literal allocate once per process.

Locked decisions (design doc §3.4 "Decision", §2, §6):

- **ASCII gate**: a UTF-8 form is created *only* when the content is strictly
  valid UTF-8 **and** all bytes < 0x80. Consequence: `unit index == byte
  offset`, `String.length` = `header.size` as today, no code point can span
  units, no lone-surrogate state is representable, `memcmp` on bytes is exact
  for both `equal` and `compare`. Anything non-ASCII takes today's UTF-16
  paths unchanged — byte-for-byte behavioral compatibility.
- **`header.size` stays the logical UTF-16 unit count** for the new forms
  (HEAP_025 convention). Under the ASCII gate this equals the byte count.
- **No compiler/Elm/MLIR IR changes.** Both new forms are runtime-internal,
  like ropes and slices (CGEN_039 already guarantees codegen emits only
  `Tag_String`-producing ops; literal changes are inside the *lowering pass
  and runtime*, not the IR).
- ASCII-ness is **not** represented in types or Elm-side IRs (design doc §6.3).

## 2. Tag space — verified

`Tag` enum (`runtime/src/allocator/Heap.hpp:76-105`), `TAG_BITS = 5` → 32 max.
Currently 23 tags (`Tag_Int`=0 … `Tag_LargeByteHeader`=20, `Tag_Free`=21,
`Tag_Forward`=22). **9 slots free; we need 2.**

Insert the new tags **after `Tag_LargeByteHeader`, before `Tag_Free`**:

```c
    Tag_LargeByteHeader,   // (unchanged, 20)
    Tag_StringUtf8View,    // 21: ASCII string as byte view: base + byteOffset.
    Tag_StringUtf8Leaf,    // 22: ASCII string with inline u8 bytes[].
    Tag_Free,              // 23 (renumbered from 21)
    Tag_Forward,           // 24 (renumbered from 22) — must stay last.
```

Renumbering `Tag_Free`/`Tag_Forward` is safe: neither appears in generated
code or persisted artifacts (they are allocator/GC-internal); all runtime and
codegen C++ compiles against the same `Heap.hpp`. This mirrors how
rope/slice/large tags were added ("appended without renumbering existing
tags"; `Tag_String`'s value is baked into lowering and must never change).
**Caveat:** requires a full rebuild — use `cmake --build build --target full`,
never trust a stale `build/test/test` binary (see memory: stale front-end).

## 3. New heap structs

Add to `Heap.hpp` next to `elm_string_slice` (~line 386), and add members to
the `HeapValue` union (`Heap.hpp:650-673`):

```c
// ASCII string as a zero-copy view over a byte buffer. 24 bytes.
// header.size = logical UTF-16 unit count == byteLen (ASCII invariant).
// base -> Tag_ByteBuffer | Tag_LargeByteHeader | Tag_StringUtf8Leaf.
// header.unboxed == 0 (base is the only traced field; offset/byteLen scalars).
struct ALIGN(8) elm_string_utf8_view {
    Header header;
    HPointer base;
    u32 offset;    // byte offset into base's payload
    u32 byteLen;   // == header.size under the ASCII gate; kept as a separate
                   // field so a future non-ASCII lift changes policy, not layout
};
typedef struct elm_string_utf8_view ElmStringUtf8View;
static_assert(sizeof(ElmStringUtf8View) == 24, "...");

// ASCII string with inline bytes. header.size = unit count == payload bytes.
struct ALIGN(8) elm_string_utf8_leaf {
    Header header;
    u8 bytes[];    // flexible array; NOT nul-terminated
};
typedef struct elm_string_utf8_leaf ElmStringUtf8Leaf;
```

Hard invariants (assert under `ECO_HEAP_VALIDATE`, document as new
**HEAP_028** in `invariants.csv`):

- Every byte in a UTF-8 form is `< 0x80`; `byteLen == header.size` (view);
  `offset + byteLen <=` base payload length; view base tag is in the allowed
  set above; `header.size > 0` (zero-length canonicalizes to the `Empty`
  constant like every other string form, per REP_CONSTANT_001/003).
- View base points at the `Tag_LargeByteHeader` *header*, never directly at
  its pinned body — same rule and reason as slice-of-large
  (`StringOps.cpp:244-255`: body lifetime is tracked via the header).

## 4. Milestones

Each milestone lands independently with `cmake --build build --target full`
green (currently 1555/1555). Run tests ONCE, tee to `/tmp/test_output.txt`.

---

### M0 — Shared UTF-8 scan/widen helper (no behavior change)

**New file** `runtime/src/allocator/Utf8.hpp` (header-only, no allocator deps):

```cpp
namespace Elm { namespace Utf8 {
struct ScanResult { bool valid; bool ascii; u32 utf16Units; };
// Strict validation + unit count in one pass. Mirror elm_utf8_decode's
// pass 1 EXACTLY (ElmBytesRuntime.cpp:212-250): continuation-byte checks,
// truncation, overlong rejection (cp<0x80 / cp<0x800 / cp<0x10000),
// surrogate range 0xD800-0xDFFF rejection, cp>0x10FFFF rejection.
// ascii == (utf16Units == len) == no byte >= 0x80 was seen.
ScanResult scan(const u8* p, size_t len);
// zext widen: dst[i] = src[i]  (ASCII only; caller guarantees)
void widenAscii(const u8* src, size_t n, u16* dst);
}}
```

**Tests**: new `test/allocator/Utf8Test.cpp` (register in `test/CMakeLists.txt`
beside `StringOpsTest.cpp`). rapidcheck properties: (a) scan of a valid
encoded random code-point sequence returns valid with the correct unit count;
(b) `ascii ⇔ all bytes < 0x80`; fixed vectors: bare continuation byte,
truncated 2/3/4-byte sequences at end, overlong `C0 80` / `E0 80 80` /
`F0 80 80 80`, encoded surrogate `ED A0 80`, `F4 90 80 80` (> U+10FFFF),
boundary code points U+007F/U+0080/U+07FF/U+0800/U+FFFF/U+10000/U+10FFFF.

Do **not** refactor the six existing UTF-8 codec sites in this milestone
(three decode strictness levels exist deliberately; see design doc §1.4 /
Appendix B). New code uses `Utf8::scan`; legacy paths stay byte-identical.

---

### M1 — Heap forms, GC arms, and the StringOps read layer (no creation sites)

After M1 the new tags exist and every String operation handles them, but no
Elm-reachable code path *creates* them — user-visible behavior is unchanged
by construction. Constructed only from C++ tests.

#### 1a. Structs and sizing

- `Heap.hpp`: tags + structs + `HeapValue` union members (§2, §3).
- `AllocatorCommon.hpp getObjectSize` (switch at :204): 
  `Tag_StringUtf8View → sizeof(ElmStringUtf8View)` (fixed, like the
  `Tag_StringSlice` case at :221 — note its HEAP_004 comment: a missing case
  mis-sizes as 8 bytes and corrupts sweep stride);
  `Tag_StringUtf8Leaf → sizeof(ElmStringUtf8Leaf) + hdr->size * sizeof(u8)`.
- `ThreadLocalHeap.cpp initHeaderForTag` (:91): both new tags → `hdr->size = 0`
  with a comment "constructors set header.size explicitly" (same as the
  slice/rope arm). Constructors always overwrite (avoids the ×1-byte rounding
  ambiguity the `Tag_String` derive-then-overwrite pattern already guards).

#### 1b. GC arms — mirror `Tag_StringSlice` / no-child forms exactly

Enumerate every site with `grep -n "Tag_StringSlice" runtime/src/allocator/*.cpp`
and add a matching arm at each. Verified sites:

| Site | View arm | Leaf arm |
|---|---|---|
| `NurserySpace.cpp` evacuate switch (~:1662) | `evacuate(v->base, ...)` | none (falls to default; add to the "no children" comment beside `Tag_String`) |
| `NurserySpace.cpp` debug child validators (~:810 `checkChild`, ~:943 `checkOGChild`) | `checkChild(v->base, "utf8view-base", 0)` | none |
| `OldGenSpace.cpp markChildren` (~:1705) | `markHPointer(v->base)` | none |
| `OldGenSpace.cpp` compaction fixup (~:3955) | `fixHPointer(v->base)` | none |

`header.unboxed` stays 0 for both forms (HEAP_025 pattern — GC never consults
it for string tags).

#### 1c. Constructors (in `StringOps.{hpp,cpp}`)

```cpp
// len==0 -> alloc::emptyString(). Roots `base` across the allocation via
// eco_alloc_with_roots(Tag_StringUtf8View, 24, roots, 1, 0x1) — copy
// makeSlice (StringOps.cpp:20-38) verbatim, then set offset/byteLen.
HPointer makeUtf8View(HPointer base, u32 byteOffset, u32 len);

// len==0 -> empty. If sizeof(ElmStringUtf8Leaf)+len >= large_object_threshold,
// fall back to widening into alloc::allocString (which routes to the existing
// split-header path) — no third split form in v1. Under ECO_HEAP_VALIDATE,
// assert all bytes < 0x80.
HPointer makeUtf8LeafFromBytes(const u8* bytes, u32 len);
```

Base-collapse rule for `makeUtf8View` callers: if the prospective base is a
`Tag_ByteBufferSlice`, collapse to `{slc->base, slc->offset + byteOffset}`
(mirror `makeByteBufferSlice`'s slice-of-slice collapse,
`HeapHelpers.hpp:1650-1654`). A view's base is never a slice.

#### 1d. StringOps read layer

New internal helpers:

```cpp
inline bool isUtf8(void* o);            // either new tag
// Resolves to the contiguous byte payload: leaf -> bytes[]; view -> resolve
// base (through Tag_LargeByteHeader body / Tag_StringUtf8Leaf) + offset.
// No allocation; same safety contract as singleSegmentView.
inline std::pair<const u8*, u32> utf8Bytes(void* o);
```

Then, function by function (all verified against current code):

- **`charAt`** (`StringOps.hpp:282`): add before the rope arm:
  `if utf8 → return (u16)utf8Bytes(str).first[index]`. Also required *inside*
  the rope descent loop? No — the loop re-enters at the top each iteration
  (`str = child; continue`), so the top-level arm covers UTF-8 rope children.
- **`forEachSegment`** (`StringOps.hpp:181`): this is the subtle one. Two of
  its callers (`equal`/`compare`, `StringOps.hpp:1152-1155, 1217-1220`)
  **collect and retain segment pointers after the walk**, so the arm must NOT
  hand out a reused transient widening buffer. Do this instead:
  - Add `forEachSegmentEx(str, u16cb, u8cb)`: identical walk, but UTF-8 forms
    (top-level and as rope children in the DFS loop) fire
    `u8cb(const u8*, u32)` with *stable* payload pointers.
  - Reimplement `forEachSegment(str, cb)` as a wrapper over `...Ex` whose
    `u8cb` widens through a 256-unit stack buffer and invokes `cb` per chunk.
    Document loudly: *chunks passed to `cb` may live in a transient buffer;
    consume immediately, never retain.* Audit of current callers confirms all
    consume immediately **except** `equal`/`compare`: `copyInto` (:266),
    `toUpper`/`toLower`/`reverse`/`repeat`/`padLeft`/`padRight`/`cons` (via
    `copyInto`), `map` (.cpp:773), `filter` (.cpp:791+806),
    `narrowAsciiToStack` (:822), `concat`/`join` copy loops (.cpp:416, 512,
    522), rope-tiny-slice copy (.cpp:221).
- **`equal`** (`StringOps.hpp:1129`) / **`compare`** (:1181): insert explicit
  UTF-8 handling before the collect fallback:
  - both UTF-8 → `memcmp(bytesA, bytesB, min)` (+ length tiebreak for
    compare). Sound because both are ASCII ⇒ byte order == unit order.
  - one UTF-8, other anything → lockstep: `forEachSegmentEx(other, ...)` with
    a running byte cursor over `utf8Bytes(utf8Side)`, comparing
    `(u16)byte vs unit`. No retention, no allocation.
  - With both fast paths in place the collect fallback can no longer receive
    a UTF-8 side; add `assert(!isUtf8(a) && !isUtf8(b))` there.
- **`singleSegmentView`** (:450): return `{nullptr, 0}` for UTF-8 tags
  (callers — `contains`/`startsWith`/`endsWith` — then use `charAt`, which is
  O(1) on UTF-8; byte fast paths are M5).
- **`toStdU16String`** (:1029): top-level UTF-8 arm (widen via
  `Utf8::widenAscii`) + an arm in its rope-DFS loop (:1070-1111).
- **`toStdString`** (.cpp:834): UTF-8 arm first: bytes are ASCII ⇒ valid
  UTF-8 ⇒ `return std::string((const char*)p, n);` — a straight memcpy.
- **`flattenToLeaf`** (.cpp:94): UTF-8 arm → widen into
  `alloc::allocString` (a UTF-16 leaf). **`maybeFlattenOrRebalance`**
  (.cpp:119) / **`ensureFlat`**: UTF-8 → `flattenToLeaf` *unconditionally*
  (no `string_flatten_limit` pass-through: `ensureFlat` consumers like the
  parser cast the result to `ElmString*` via `resolveStringBody`
  (`ParserExports.cpp:38-46`, `HeapHelpers.hpp:1688`) and must get a
  `u16`-walkable leaf). This is correct-but-slow for the parser (transcode
  per primitive); M5 removes the cost. Note in passing: today's code passes
  through slices/ropes larger than `string_flatten_limit`, which the parser
  would mis-cast — a latent pre-existing issue worth a separate look; do not
  replicate it for UTF-8.
- **`slice`** (.cpp:156): UTF-8 arms after the clamp/whole-string checks
  (whole-range early return at .cpp:170 already returns the original ✓):
  - tiny range (≤ `string_tiny_slice_limit`): `makeUtf8LeafFromBytes(p +
    start, slice_len)` — stays ASCII, no widening, mirrors the leaf-copy arm.
  - larger: `makeUtf8View(baseOf(str), offsetOf(str) + start, slice_len)`
    where for a *view* source base/offset collapse (like slice-of-slice,
    .cpp:259-264) and for a *leaf* source `base = wrap(leaf), offset = start`.
- **`uncons`** (.cpp:718): add UTF-8 arm beside the leaf/slice arms: first
  char = `bytes[0]` zext; rest = `makeUtf8View` advanced by 1 (leaf source:
  view over the leaf; view source: offset+1) — preserves the O(n)-total
  fold-with-uncons guarantee the current slice arm exists for.
- **`append`** (:343): no change needed — small totals widen via
  `toStdU16String` (UTF-8 arm ✓); large totals build a rope whose children
  may now be UTF-8 (`makeRope`'s `heightLeafOf` treats any non-rope as
  `{0, 1}` ✓, .cpp:59-69). Same for `concat`/`join` (header.size sums ✓).
- `HeapHelpers.hpp`: `isString` (:1545) — add both tags (this is what routes
  `Utils.cpp` `eq`/`cmp` at :234-240/:427-430 into `StringOps` ✓).
  `stringLength` (:552) works as-is. `stringData` (:564) keeps its
  leaf-only assert — verify via grep that all callers sit behind
  `ensureFlat`/`resolveStringBody` (they do today).
- `StringOps::isLeaf` (:45) stays `Tag_String || Tag_LargeStringHeader`
  (UTF-8 forms are *not* u16-walkable leaves; callers that test `isLeaf` and
  then read `chars[]` — `BytesExports.cpp:223/329`, `filter`'s
  keep-all fast path — correctly fall to general paths).
- Debug printers: `grep -n "Tag_StringSlice" runtime/src/allocator/RuntimeExports.cpp`
  (e.g. the switch near :2477) — add arms that forward to
  `StringOps::toStdString` like the existing string arms.

#### 1e. Tests (all in `test/allocator/`, rapidcheck style per `StringOpsTest.cpp`)

New `Utf8StringTest.cpp`:

- **Differential property**: generate ASCII strings (and lists thereof), build
  each as (a) UTF-16 leaf, (b) UTF-8 leaf, (c) UTF-8 view over a
  `Tag_ByteBuffer`, (d) slice/rope compositions mixing (a)-(c); apply every
  StringOps op (`length, charAt, append, concat, join, slice, left/right/
  drop*, contains, startsWith, endsWith, indexes, split, toList, uncons,
  cons, toUpper/toLower, reverse, trim*, repeat, pad*, toInt, toFloat, map,
  filter, foldl, foldr, equal, compare`) and assert results identical to the
  UTF-16-twin result (via `toStdString`, lengths, and for compare: **sign
  equality across all encoding pairings** — the Dict-order property).
- **Mixed-operand multi-unit property**: extend the generator with a
  *non-ASCII* string source (UTF-16 by construction — the gate forbids UTF-8
  forms for it) drawing from the multi-unit battery of §5a, and exercise
  every **two-operand** op with one ASCII-UTF-8 operand and one non-ASCII
  UTF-16 operand in both orders (`append`, `equal`, `compare`, `contains`,
  `startsWith`, `endsWith`, `indexes`, `split`-separator, `join`-separator)
  plus ropes mixing UTF-8 children with astral-bearing UTF-16 children
  (then `slice`/`charAt`/`toStdU16String` across the child boundary).
  Include UTF-16 operands containing **lone surrogates** (built via
  `slice` mid-pair, as Elm permits) — they must compare/append against
  UTF-8 views exactly as against UTF-16 twins.
- Boundary lengths: 0, 1, `string_tiny_slice_limit` ± 1,
  `MAKE_BYTEBUFFER_SLICE_MIN_LEN` ± 1, `string_flatten_limit` ± 1,
  `large_object_threshold`-crossing leaves (must fall back to UTF-16 split).
- Empty canonicalization: every constructor path with len 0 returns the
  `Empty` constant (bit-compare against `alloc::emptyString()`).
- GC: adapt `GCPressureTest.cpp` patterns — build views over nursery
  ByteBuffers and over `Tag_LargeByteHeader` buffers, force minor + major GCs
  (tiny nursery config), re-verify contents; run under the
  `-DECO_HEAP_VALIDATE=ON` configuration (the technique that caught the
  List.mapN stale-cursor bug).

**Exit**: full suite green; no Elm-visible change.

---

### M2 — `Bytes.Decode.string` goes straight to a zero-copy UTF-8 view

**This is the headline optimization**: decoding an (ASCII) string from Bytes
allocates a single 24-byte `Tag_StringUtf8View` aliasing the source
ByteBuffer's payload — **no payload copy, no transcode**. Today's path does a
count pass + a fresh 2×len UTF-16 allocation + a decode-copy pass; the new
path does one validation scan + 24 bytes.

**File**: `elm-kernel-cpp/src/bytes/Bytes.cpp`, `read_string` (:247-313).
Route coverage (verified): this is the **sole** interpreter entry for
`Bytes.Decode.string` — `Elm_Kernel_Bytes_read_string`
(`BytesExports.cpp:573`) is a thin wrapper over it, and
`BytesOps::decodeUtf8` (`BytesOps.cpp:91`) has no production callers (only
`test/allocator/BytesOpsTest.cpp:698`; leave it and its test alone). The
only other decode route is the *fused* one (`bf.read_utf8` →
`elm_utf8_decode`) — see the note below.

Scope of "zero copy" (matches the locked §3.4 decision): valid **all-ASCII**
payloads ≥ `utf8_view_min_len` get the view; short ASCII gets a UTF-8 leaf
(one copy, still no transcode); valid *non-ASCII* UTF-8 keeps today's
transcode-to-UTF-16 by design (lifting that is design doc §3.4 Choice 2b/3,
tracked under M6); invalid input keeps today's path byte-for-byte.

Current shape (verified): bounds-check → non-validating unit-count pass →
`allocStringBlank` (source rooted via `StackRootRangeGuard`) → non-validating
decode pass. Replace with:

```
bounds-check (unchanged)
scan = Utf8::scan(src, length)               // one pass, strict
if scan.valid && scan.ascii:
    if length >= cfg.utf8_view_min_len:
        base, absOff = collapse(bytes, offset)   // slice -> {slc->base,
                                                 //   slc->offset + offset};
                                                 // buffer/large-header -> {wrap(bytes), offset}
        return readSuccessBoxed(StringOps::makeUtf8View(base, absOff, length),
                                offset + length)
    else:
        return readSuccessBoxed(StringOps::makeUtf8LeafFromBytes(src, length),
                                offset + length)      // copy, but no transcode
else:
    // NON-ASCII or INVALID: run today's two passes verbatim (keep the old
    // count loop; do not reuse scan.utf16Units here). Byte-identical
    // behavior, including the current garbage-units-on-invalid-input
    // semantics and the known read-past-`length` quirk on truncated
    // trailing sequences. Bug-compatibility is the point.
```

- New `HeapConfig` field `utf8_view_min_len` (default 32 — mirrors
  `MAKE_BYTEBUFFER_SLICE_MIN_LEN`, `HeapHelpers.hpp:1639`), added beside
  `string_tiny_slice_limit` (`AllocatorCommon.hpp:335+`) and plumbed through
  `heap-config.json` / `eco-config.json` the same way (grep
  `string_tiny_slice_limit` for the three plumbing sites). **Kill switch**:
  also add `utf8_strings_enabled` (bool, default true) checked at the two
  creation sites — cheap, and makes bisection/rollback a config edit.
- The **fused** decode path (`elm_utf8_decode`, `ElmBytesRuntime.cpp:208`) is
  deliberately unchanged: it receives a raw `const u8*` from BF-lowered code
  with no base HPointer, so it cannot make a view. Fused and interpreted
  decodes may now produce different *representations* of the same string —
  invisible to Elm (BFOPS_018 requires identical *results*, and
  representations are opaque); the differential tests must compare values,
  not forms.
- Rooting: `makeUtf8View` roots `base` internally; `read_string` already
  wraps `bytes` (`srcHP`) — pass that through.

**Tests**:

- E2E Elm module under `test/elm-bytes/` (follow the existing suite layout /
  `plans/string-bytes-testing-gap.md` conventions): decode ASCII, non-ASCII
  (the full §5a multi-unit battery — 2/3/4-byte chars, combining sequences,
  mostly-ASCII payloads with one multi-byte char at first/middle/last
  position), and invalid byte payloads of lengths straddling
  `utf8_view_min_len`, then push each result through the String-op matrix
  comparing against literal-built twins — including `String.length` unit
  counts (`"😀"` → 2) and astral `Encode`/`Decode`/`getStringWidth`
  round-trips per §5a obligations 2-4; `Dict`/`Set` keyed by
  decoded-vs-literal strings (mixing ASCII and astral keys); `case` dispatch
  on decoded strings.
- **Golden capture first**: before flipping this milestone on, record the
  current outputs of the invalid-UTF-8 decode cases as expected values, so
  bug-compatibility is enforced by test rather than by review.
- C++: `read_string` unit test asserting representation (view/leaf/UTF-16) as
  a function of (validity, ascii-ness, length); GC-stress decode loop.

**Exit**: full green including `TEST_FILTER=elm` and `TEST_FILTER=codegen`.

---

### M3 — Literal interning (pointer-keyed, zero codegen changes)

Verified facts this design rests on:

- Both lowering sites call the same runtime symbol with a **unique, stable
  global address per literal**: `StringLiteralOpLowering` passes
  `__eco_str_N` (`EcoToLLVMTypes.cpp:49-102`, pre-created by
  `preMaterializeStringLiterals` :124-158), and the string-case path passes
  `__eco_str_case_<caseId>_<i>` (`EcoToLLVMControlFlow.cpp:360-405`,
  pre-created by `preMaterializeStringCases`). JIT resolves the same symbol
  (`RuntimeSymbols.cpp:54`).
- `RootSet` (per-thread, `RootSet.hpp:22`) has **long-lived roots**:
  `addRoot(HPointer*)` persists across GC cycles — unlike stack root ranges,
  which are frame-disciplined (`restoreStackRangePoint` truncates; never use
  them for persistent registration).
- "Permanent" old-gen allocation (`ThreadLocalHeap.cpp:372-387`) is just a
  direct old-gen allocation: unreachable objects ARE collected at major GC,
  and live ones may be MOVED by compaction. Interned literals therefore need
  root registration for both liveness and fixup.

**Implementation** — entirely inside `RuntimeExports.cpp` (plus a small
header): change `eco_alloc_string_literal(const uint16_t* chars, uint32_t
length)` to intern by `chars` pointer:

```cpp
// Single-threaded by design: literals execute on the Elm mutator thread
// (assert std::this_thread::get_id() == first-caller id under !NDEBUG).
struct LiteralTable {
    std::unordered_map<const void*, HPointer*> byGlobal;
    std::deque<std::array<HPointer, 64>> chunks;  // stable addresses
    size_t nextSlot = 64;                          // forces first chunk
    HPointer* newSlot(RootSet& rs) {
        if (nextSlot == 64) { chunks.emplace_back(); nextSlot = 0; }
        HPointer* slot = &chunks.back()[nextSlot++];
        *slot = HPointer{};        // null until filled
        rs.addRoot(slot);          // long-lived root: liveness + compaction fixup
        return slot;
    }
};
```

`eco_alloc_string_literal`: look up `chars`; hit → return cached bits; miss →
run the existing `allocatePermanent` + memcpy body, store, return. Identical
signature, so **no codegen, no JIT-symbol, and no `.mlir` changes at all**.
Two distinct globals with equal content intern separately — harmless
(conservative), and content-dedup can be a later nicety.

Verification step during implementation: confirm `RootSet::roots` is (a)
traced for liveness in major-GC mark and (b) rewritten by compaction fixup —
grep `getRoots()` consumers in `OldGenSpace.cpp`/`NurserySpace.cpp`. If (b)
turns out not to hold for long-lived roots, pin interned literals instead
(`header.pin = 1` — the compactor skips pinned objects, verified at
`OldGenSpace.cpp:3969-3982`) and keep `addRoot` for liveness only.

**Tests**:

- C++ unit: same `chars` pointer twice → identical HPointer bits; distinct
  pointers → distinct objects; content preserved after forced major GC (and
  after a compaction cycle if the test harness can trigger one).
- E2E memory-stability: an Elm program that evaluates a literal-bearing
  function in a long loop; assert old-gen allocation counters (GCStats) stay
  flat after warm-up rather than growing per iteration.

**Exit**: full green. This milestone is orthogonal to encoding and can land
before or after M1/M2 (it only touches `RuntimeExports.cpp`).

---

### M4 — ASCII literals become UTF-8 leaves

Depends on M1 (leaf form) + M3 (table). The literal is UTF-8 (an MLIR
`StringAttr`) all the way to lowering; today `utf8ToUtf16` transcodes at the
last step (`EcoToLLVMTypes.cpp:80, :139`; `EcoToLLVMControlFlow.cpp:387`).
This milestone *deletes* that transcode for ASCII literals:

1. `preMaterializeStringLiterals` (`EcoToLLVMTypes.cpp:124`): if all bytes of
   `value` are `< 0x80`, emit the global as `[N x i8]` with the raw bytes
   (same `__eco_str_N` name); record ASCII-ness in a side map next to
   `stringLiteralIndexForOp`.
2. `StringLiteralOpLowering`: ASCII → call new
   `eco_alloc_string_literal_utf8(const uint8_t* bytes, uint32_t byteLen)`;
   else existing call. Same split in `preMaterializeStringCases` + the
   case-pattern site (`EcoToLLVMControlFlow.cpp:373-405`).
3. Runtime: `eco_alloc_string_literal_utf8` — interns via the same
   `LiteralTable`; on miss allocates a **permanent `Tag_StringUtf8Leaf`**
   (`allocatePermanent(sizeof(ElmStringUtf8Leaf) + byteLen, Tag_StringUtf8Leaf)`,
   set `header.size = byteLen`, memcpy). Register beside
   `eco_alloc_string_literal` in `RuntimeSymbols.cpp` (:54) and declare in
   the runtime-function factory (`EcoToLLVMRuntime.cpp:223` pattern).
4. `StringOps::fromInt` (:890) / `fromFloat` (:904): output is always ASCII
   (`std::to_chars`, `"NaN"`, `"Infinity"`) — replace the widen-and-
   `allocString` with `makeUtf8LeafFromBytes` on the char buffer directly.
   Leave `fromChar`/`cons`/`fromList` on UTF-16 (Chars can be any u16).
5. Empty literal already short-circuits to the embedded constant in both
   lowering sites — unchanged.

Gate with the M2 `utf8_strings_enabled` config check inside the two runtime
alloc functions (fall back to widening) so a single config flag disables all
UTF-8 creation everywhere.

**Tests**: E2E covering literal-heavy paths — string `case` dispatch where
patterns are ASCII literals and scrutinees arrive from all creation paths
(literal / fromInt / Decode.string view / non-ASCII UTF-16), `++` chains
mixing literal + decoded strings, `Dict` keyed by literals. Differential
suite re-run. Perf sanity vs the `string-perf-16-optimizations` benchmarks.

**Exit**: full green; string perf non-regression.

---

### M5 — Consumer fast paths (semantics-neutral perf)

Each item is small, independent, and testable by the differential suite:

1. **`getStringWidth` O(1)**: UTF-8 arm returning `header.size` in
   `Elm_Kernel_Bytes_getStringWidth` (`BytesExports.cpp:302`),
   `Bytes::getStringWidth` (`Bytes.cpp:74`), and `elm_utf8_width`
   (`ElmBytesRuntime.cpp:112`).
2. **`Encode.string` memcpy**: UTF-8 arm in `writeEncoder`'s `ENC_UTF8` case
   (`BytesExports.cpp:208-262`), `elm_utf8_copy` (`ElmBytesRuntime.cpp:158`),
   and `BytesOps::encodeUtf8` (`BytesOps.cpp:179`). ASCII bytes are already
   the wire encoding — copy `utf8Bytes()` straight into the buffer. The
   fused `bf.width`/`bf.write_utf8` ops call these helpers, so the fused
   encoder speeds up with no compiler change.
3. **Parser byte path** (removes the ensureFlat transcode-per-primitive for
   ASCII sources): extend `resolveString` (`ParserExports.cpp:38`) to return
   `struct { const u16* wide; const u8* narrow; i64 len; }` — leaf/large →
   wide; UTF-8 forms → narrow via `utf8Bytes` (no flatten!); other tags →
   `ensureFlat` as today. Update the primitive loops (`isAsciiCode`,
   `isSubChar`, `isSubString`, `findSubString`, `chompWhile/If`,
   `consumeBase*`, `advancePosition` — enumerate with
   `grep -n "chars\[" ParserExports.cpp`, ~10 loops) to read through a
   2-way inline accessor (`at(i)`), or template the loop bodies on char
   type with a dispatch at each extern entry. `advancePosition`'s
   surrogate-skip (`ParserExports.cpp:56-70`) is a no-op on ASCII — keep it,
   it's already conditional.
4. **Search byte paths** (optional): both-UTF-8 arms in
   `contains`/`startsWith`/`endsWith` using `memcmp`/`std::search` over
   bytes; a `singleSegmentBytes()` helper mirroring `singleSegmentView`.
5. **`split`/`trim*` UTF-8 outputs** (optional): today they widen via
   `toStdU16String` then `slice`/`allocString`. `trim*` already delegate the
   final cut to `slice()` — which after M1 returns UTF-8 sub-views for UTF-8
   inputs automatically ✓; only their scan loop widens (acceptable). `split`
   allocates UTF-16 parts — a byte-path split can return leaf/view parts;
   defer unless profiling asks.

**Exit**: full green; parser/e2e perf spot-checks (a decode-then-parse E2E
case demonstrating no quadratic behavior — e.g. parse a 1 MB decoded ASCII
source and assert wall time in the same order as parsing a literal-built
string).

---

### M6 — Follow-ups (separate plans, out of scope here)

HTTP `expectString` → ByteBuffer + view (`HttpExports.cpp:411-436`); zero-copy
`Encode.encode (Encode.string s)` returning a `Tag_ByteBufferSlice` over a
view's base; UTF-8+UTF-8 append byte-concat; JSON/ports ASCII ingest fast
paths; threading a base HPointer through `bf.read_utf8` for fused zero-copy;
non-ASCII lifts (design doc §3.4 Choices 2b/3); content-dedup of interned
literals; rope-aware streaming for the remaining `toStdU16String` users.

## 5. Validation work (cross-cutting)

### 5a. Multi-unit Unicode battery (shared fixture set)

A single fixture table (define once in `test/allocator/TestHelpers.hpp` or a
sibling, reuse from C++ and mirror in the E2E Elm modules) covering every
class of character that needs **multiple units in UTF-8, UTF-16, or both** —
these are precisely the inputs the ASCII gate must reject and the mixed
semantics must survive:

| Class | Examples | UTF-8 | UTF-16 | Elm `String.length` |
|---|---|---|---|---|
| ASCII boundary | `U+007F` | 1 byte | 1 unit | 1 |
| 2-byte UTF-8 (Latin-1+/non-Latin) | `é U+00E9`, `ß U+00DF`, `ñ U+00F1`, `а U+0430` (Cyrillic) | 2 bytes | 1 unit | 1 |
| 2/3-byte boundary | `U+07FF`, `U+0800` | 2/3 bytes | 1 unit | 1 |
| 3-byte UTF-8 | `中 U+4E2D`, `€ U+20AC`, `か U+304B`, `U+FFFF` | 3 bytes | 1 unit | 1 |
| Astral (4-byte / surrogate pair) | `😀 U+1F600`, `𝕊 U+1D54A`, `U+10000`, `U+10FFFF` | 4 bytes | **2 units** | **2** |
| Combining sequence | `e` + `U+0301` (é decomposed), `👍 U+1F44D` + skin-tone `U+1F3FD` | multi-cp | multi-unit | 2 / 4 |
| Lone surrogates (UTF-16 strings only) | high `U+D800`, low `U+DC00` half via mid-pair `slice` | *unrepresentable* (WTF-8 3-byte on encode) | 1 unit | 1 |
| Surrogate range as bytes (invalid UTF-8) | `ED A0 80` | invalid | — | — |

Obligations, enforced wherever this battery is used:

1. **Gate rejection**: any byte payload containing ≥1 character from the
   first six rows must never yield a UTF-8 heap form — including
   *mostly-ASCII* payloads with a single such char at the first, a middle,
   and the last position (regression guard: the gate is whole-string, not
   prefix-based).
2. **Length semantics preserved**: decoded results report today's UTF-16
   unit counts (`"😀"` → 2, `"中"` → 1, decomposed `é` → 2) — asserted
   against literal-built twins, never against byte counts.
3. **Value identity with today**: decode → every String op → identical
   results to the pre-change goldens (the strings are UTF-16 both before
   and after this work; the assertion is that the new gate/scan code
   changed nothing for them).
4. **Round-trips unchanged**: `Decode.string >> Encode.string` byte-identity
   for astral + combining content, and `getStringWidth` values unchanged
   (guards the M5 arms against disturbing the surrogate-combining paths);
   lone-surrogate strings keep their 3-byte WTF-8 encode behavior.
5. **Order across the astral/BMP boundary**: `compare` sign between strings
   containing `U+E000..U+FFFF` chars and astral chars must match current
   UTF-16 unit order in every representation pairing (the design doc §3.3
   trap — inert under the ASCII gate, but the test pins it down so any
   future non-ASCII lift trips it immediately).

The two questions the user asked, answered as test obligations:

**"Do all String operations behave identically between UTF-8 and UTF-16?"**

- The M1 differential rapidcheck suite is the primary instrument: same
  logical ASCII string in every representation × every StringOps operation ×
  result equality (including `compare` **sign** equality across all pairings
  — this is what protects `Dict`/`Set` and string `case` dispatch).
- E2E Elm differential modules (M2/M4) exercise the same matrix through
  compiled code: kernel dispatch, `Utils.cpp` eq/cmp routing (:234, :427),
  `case_kind="str"` patterns, Json/Debug printing, Bytes round-trips
  (`Decode.string >> Encode.string >> decode` byte-identity).
- Representation-blindness rule for all tests: compare *values*, never forms
  — fused vs interpreted decode legitimately produce different forms (M2).

**"Is a UTF-8 string never created for inputs that would break compatibility?"**

- Creation is centralized in exactly four constructors/call sites after M4:
  `makeUtf8View`, `makeUtf8LeafFromBytes` (both assert ASCII under
  `ECO_HEAP_VALIDATE`), `read_string` (gated by `Utf8::scan` valid+ascii),
  and the two literal alloc functions (gated by the lowering-time ASCII scan
  of a compile-time constant). Negative tests (M0 vectors + M2 goldens +
  the §5a multi-unit battery) cover: non-ASCII valid UTF-8 (2/3/4-byte,
  combining sequences, single multi-byte char embedded in ASCII), every
  invalid-UTF-8 class, truncation at buffer end, and boundary code points —
  each asserting the result is the legacy UTF-16 representation with
  legacy-identical content and legacy unit counts. The literal gate gets the
  same battery as source literals (non-ASCII literals must keep emitting
  `[N x i16]` globals in M4).
- The `ECO_HEAP_VALIDATE` heap-walk arms (M1) make the invariant *enforced at
  runtime* in stress/CI configurations, not just at creation: any UTF-8 heap
  object containing a byte ≥ 0x80, a size/byteLen mismatch, an out-of-range
  view window, or an illegal base tag aborts with a diagnostic.

**Invariants/docs to update when landing** (per CLAUDE.md, read
`design_docs/invariants.csv` before touching representation code):

- `HEAP_025`: six string forms; add the two tags, their `header.size`
  semantics, and the constructor whitelist.
- New `HEAP_028`: UTF-8 forms are strictly-valid all-ASCII; creation gate;
  view base tag set; base-points-at-header rule; zero-length canonicalizes
  to Empty.
- `REP_CONSTANT_003`: add the two tags to the "size == 0 in any string form"
  comparison list.
- `BFOPS_032`: extend the layout-aware whitelist (`StringOps` + `elm_utf8_*`)
  to note the new tags.
- `design_docs/theory/string_rope_representation_theory.md`: add the two
  forms (or a sibling theory doc) + update the operation table.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `forEachSegment` widening chunks retained by a caller | `forEachSegmentEx` two-callback API; the wrapper's transient-buffer contract documented; `equal`/`compare` (the only retaining callers, verified) rewritten onto explicit UTF-8 paths + assert in the fallback |
| Missed per-tag switch arm (GC corruption — HEAP_004 class) | Mechanical enumeration: `grep -n "Tag_StringSlice"` across `runtime/src` and `elm-kernel-cpp/src` and account for every hit in review; `ECO_HEAP_VALIDATE` arms; GC-pressure tests with tiny nursery |
| `ensureFlat` consumers casting to `ElmString*` receive a UTF-8 form | M1 makes `ensureFlat` widen UTF-8 unconditionally; M5 gives the parser a byte path; `resolveStringBody`/`stringData` asserts stay as backstops |
| Interned literals moved by compaction / collected by major GC | `RootSet::addRoot` long-lived roots (liveness + fixup); verification step; fallback to `pin=1` if fixup coverage of long-lived roots proves incomplete |
| Interning table thread-safety | Single Elm mutator thread assumption, asserted; RootSet is per-thread by design (`RootSet.hpp:20`) |
| Behavior drift on invalid UTF-8 decode | Legacy code path kept verbatim for the non-(valid∧ascii) case; goldens captured before M2 |
| `compare` ordering across encodings | ASCII gate makes byte order == unit order; sign-equality property test across all representation pairings |
| Tag renumbering of `Tag_Free`/`Tag_Forward` | Compile-time only (no persisted tag values); full rebuild required — `--target full`, never the stale `build/test/test` |
| Perf regression from extra tag dispatch on hot UTF-16 paths | New arms are added *after* the existing hot cases in each dispatch chain; string perf benchmarks re-run at M4/M5 exits |
| Retention: small view pins a large ByteBuffer | `utf8_view_min_len` floor; same exposure class as existing `ElmStringSlice`/`ByteBufferSlice`; revisit with a copy-out heuristic only if observed |
| Rollback | `utf8_strings_enabled=false` config disables all creation sites; existing forms then never appear (M1 read-layer arms are inert dead code) |

## 7. Suggested landing order

M0 → M1 → M3 → M2 → M4 → M5. (M3 before M2 is deliberate: interning is
encoding-independent, tiny-diff, and de-risks the schedule; M2 and M3 are
independent and can swap.) Each milestone: implement → `cmake --build build
--target full 2>&1 | tee /tmp/test_output.txt` → grep failures → fix → land.
