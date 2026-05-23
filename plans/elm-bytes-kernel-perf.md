# elm/bytes C++ kernel performance plan

Fourteen perf items uncovered while auditing `elm-kernel-cpp/src/bytes/*` and
`runtime/src/allocator/{BytesOps,ElmBytesRuntime}.*`. The audit notes are the
authoritative description of each item; this file lays out an implementation
order, scoping decisions, and acceptance criteria so the changes can land
without breaking the bootstrap or violating any HEAP_* / REP_* invariant.

The shipping order below trades the obvious "biggest impact first" ranking for
"safest first." A regression in items 1, 10, 11, or 14 would corrupt the heap
or generated code and break Stage 7+. The localised items 2–9 / 12 / 13 ship
first so a baseline win is locked in even if a later phase has to be reverted.

## Phase A — localised refactors (no heap-layout / ABI change)

### A1. Item 2 — `BytesOps::slice` direct memcpy
- File: `runtime/src/allocator/BytesOps.hpp:115-129`.
- Replace `std::vector<u8>` round-trip with a Pattern-B allocate-then-memcpy.
  Pre-allocate the destination `Tag_ByteBuffer` of exact size, root the
  source HPointer across the helper call, re-resolve, single memcpy.
- Watch: source may be a `Tag_LargeByteHeader` — re-resolve through
  `resolveByteBufferBody`.

### A2. Item 3 — `BytesOps::append` direct memcpy
- File: `runtime/src/allocator/BytesOps.hpp:365-382`.
- Two HPointer roots (`a`, `b`). Same Pattern-B template. Two memcpys
  directly into the result, no intermediate vector.

### A3. Item 9 — `BytesOps::fromList` two-pass count-then-fill
- File: `runtime/src/allocator/BytesOps.cpp:15-34`.
- First pass: walk the list, count cells. Second pass: allocate buffer of
  exact size, walk again writing bytes. The list is rooted across the
  allocate via Pattern B. No `std::vector` realloc storm, one fewer memcpy.

### A4. Item 4 — `BytesOps::encodeUtf8` / `decodeUtf8` two-pass
- Files: `runtime/src/allocator/BytesOps.cpp:42-108, :111-154`.
- Same template as `Elm_Kernel_Bytes_read_string` (`BytesExports.cpp:599`):
  width-count pass → allocate exact-size heap object → decode/encode pass
  writing directly into the heap object's payload.
- For `encodeUtf8`: source is a `String` (any form) → walk via
  `StringOps::toStdU16String` for the width pass too (this materialises once
  per call instead of once for vector + once for `fromVector`). Pattern B
  roots the string HPointer across the allocate.
- For `decodeUtf8`: source is a `ByteBuffer` (resolveable through the large
  header). Two-pass UTF-8 → UTF-16 width count, allocate `ElmString` of
  exact size, decode into `str->chars`.
- Also rewrite `elm_utf8_decode` in `ElmBytesRuntime.cpp:200-271` the same
  way — same two-copy pattern.

### A5. Item 5 — LOT routing for direct `Tag_ByteBuffer` allocs
- Sites: `BytesExports.cpp:382`, `:568`, `BytesOps.cpp:204`,
  `ElmBytesRuntime.cpp:80`.
- Each site computes `total_size = sizeof(ByteBuffer) + payload` and calls
  `eco_alloc_with_roots(Tag_ByteBuffer, total_size, ...)` regardless of
  size. `allocateSlow` re-checks the threshold but `allocateFast` does not,
  so a 12 KB buffer that fits the bump pointer is allocated as an unsplit
  nursery `Tag_ByteBuffer`. Then minor GC evacuates its full payload on
  every cycle until promoted.
- Fix: at each site, when `total_size >= large_object_threshold`, route
  through `Allocator::allocLargeByteBuffer(data, length)` (or, for
  fill-after-alloc sites, `allocLargeByteBuffer(nullptr, length)` followed
  by a pointer-resolve + memcpy into the body). Below the threshold, keep
  the current fast-path inline allocation.
- The Pattern-B root-set logic must still wrap the helper because
  `allocLargeByteBuffer` calls into the allocator.

### A6. Item 6 — `Bytes::read_string` consolidation
- File: `elm-kernel-cpp/src/bytes/Bytes.cpp:248-272`.
- The export-side `Elm_Kernel_Bytes_read_string`
  (`BytesExports.cpp:579-668`) is the production path: it does
  count-then-fill in one allocation. The `Bytes::read_string` C++ helper
  slices the input ByteBuffer and then `decodeUtf8`s the slice — three
  allocations, two memcpys, all wasted.
- Decision: this helper is in `Elm::Kernel::Bytes::` (used by older paths /
  tests). Replace its body with the same count-then-fill logic the export
  uses; delete the `BytesOps::slice` + `decodeUtf8` dance.

### A7. Item 12 — `read_*` with `memcpy + bswap`
- Files: `BytesExports.cpp:456-555`, `BytesOps.hpp:176-237`,
  `decodeFloat32/64`.
- Replace byte-by-byte shift assembly with `std::memcpy` + `__builtin_bswap{16,32,64}`
  (or `std::byteswap` if available) on host-LE side. Net effect: clearer
  code, vectorisable, and matches the canonical fast idiom.
- For floats: `memcpy` raw bits → optional bswap → `memcpy` into `float`/
  `double`. Strict-aliasing safe.
- Wrap the bswap helpers in a small `static inline` so we keep one
  endianness-handling utility.

### A8. Item 13 — `Bytes::write_bytes` redundancy
- File: `Bytes.cpp:310-314`.
- ByteBuffers are immutable; `BytesOps::fromData` makes a full copy. The
  exported encoder path (`makeEncoderBytes`) wraps the existing pointer.
  Replace `Bytes::write_bytes`'s body with `Allocator::instance().wrap(b)`
  — return the same buffer. Drop the redundant memcpy.
- Once item 1 lands, this becomes truly zero-cost (the buffer is shared by
  reference, not by value); even before then, immutability makes the copy
  redundant.

## Phase B — encoder hot-path micro-perf

### B1/B2 — DEFERRED at implementation time
**What broke:** I initially refactored `writeEncoder` to read the BE flag from
`encoder->values[0].i` and updated the kernel-side constructors
`makeEncoder2_pi/_pf` and `makeEncoderBytes` to stash the unboxed bool / byte
width in that slot. The fix only updated the C++ constructors, not the
Elm-side `Bytes.Encode` module — and production code paths build the encoder
Custom **from the Elm side** (`type Encoder = I16 Endianness Int | …`), with
slot 0 being the boxed Endianness HPointer. `writeEncoder` then read the raw
HPointer bits as an int and always treated multi-byte primitives as BE; this
broke `BytesRoundtripInt16Mixed` / `BytesRoundtripMixedRecord` stress tests.

**Resolution:** revert the read-side of writeEncoder to the original
`encoderIsBigEndian(encoder->values[0].p)` (renamed to `endiannessHPointerToBool`),
keeping the `memcpy + bswap` cleanup from item 12 around it. Constructors and
`encoderSize` ENC_BYTES are also reverted to the Elm-aligned layout. The full
items 7 and 8 win requires editing the Elm-side `Bytes.Encode` module to make
the BE flag and ENC_BYTES width unboxed fields in the constructor itself —
that's a kernel-package change with its own bootstrap implications and is
explicitly deferred until the unboxed-primitive-return-values plan
(`plans/unboxed-primitive-return-values.md`) makes mixed-kind ctor fields
cheap enough to lay down at the Elm boundary.

What did land from this phase: `endiannessHPointerToBool` is still called
exactly once per multi-byte primitive (same cost as before), but the emit
side uses `memcpy + __builtin_bswap{16,32,64}` instead of byte-shift loops.

### B1. Item 7 — hoist endianness in `writeEncoder`
- File: `BytesExports.cpp:112-298`.
- `encoderIsBigEndian(endianness)` calls `Allocator::instance().resolve()`
  for every primitive write. Two ways out:
  1. Pass an explicit `be` bool down `writeEncoder`'s recursion. The flag
     is stable across nested `ENC_SEQ` (encoders mix endiannesses, so the
     flag must come from the current node — but the node's endianness is
     already a single HPointer slot stored in `values[0].p`, so we can
     `resolve` once per node and stash on the stack).
  2. Store the bool directly in the encoder Custom. Already 16 bits of
     `header.unboxed` is unused on encoder Customs — pack `be` into a low
     bit. Cleaner long-term but requires touching every `makeEncoder2_*`
     site.
- Pick (1) for the first pass — simpler diff. Resolve once at the start
  of each primitive's case and assign to a local `bool be`. No structural
  encoder change.

### B2. Item 8 — precompute encoder sizes
- File: `BytesExports.cpp:119-298` (`encoderSize`) plus all `makeEncoder*`.
- `ENC_SEQ` and `ENC_UTF8` already cache their precomputed total in
  `values[0].i`. Extend the same to every encoder node: at construction
  time (`makeEncoder1/2_*`), store the byte width the node will emit.
  `encoderSize` collapses to a single field read for any node.
- Trade-off: the encoder Custom for `ENC_I8/U8` currently has one value
  slot for the integer payload; we'd need a second slot for the size, OR
  fold the size into `header.size` (which currently equals the field
  count — already a near-free repurpose since the writer doesn't consult
  it for these tags). Use the latter: `header.size` on encoder Customs
  becomes the total byte width. The runtime never iterates encoder
  Customs by `header.size` field count, so this is safe.
- Acceptance: `encoderSize` becomes O(1) per call; `Elm_Kernel_Bytes_encode`
  walks the tree exactly once.

## Phase C — architectural

### C1. Item 1 — `Tag_ByteBufferSlice`
This is the biggest single change. It mirrors `Tag_StringSlice` (HEAP_025).

#### Heap-layout additions
- `Heap.hpp`: add `Tag_ByteBufferSlice` to the enum (currently 22 tags,
  5-bit field — plenty of room).
- `Heap.hpp`: add
  ```c
  struct ALIGN(8) elm_bytebuffer_slice {
      Header header;     // header.size = logical byte count
      HPointer base;     // -> Tag_ByteBuffer / Tag_LargeByteHeader body source
      u32 offset;        // start byte index in source
      u32 _padding;
  };
  typedef struct elm_bytebuffer_slice ElmByteBufferSlice;
  static_assert(sizeof(ElmByteBufferSlice) == 16, ...);
  ```
- `header.unboxed = 0` (base is the only HPointer field).
- Slice-of-slice collapses at construction (just like `StringOps::makeSlice`).

#### GC integration
- `NurserySpace.cpp`: add `case Tag_ByteBufferSlice` to evacuate (just
  evacuate `slc->base`) and to both validators (`checkChild`
  walks for nursery + oldgen scans).
- `OldGenSpace.cpp`: add `case Tag_ByteBufferSlice` to `markChildren`
  (mark `slc->base`) and to compactor `fixPointers`.
- `GCStats.cpp`: add `case Tag_ByteBufferSlice: return "ByteBufferSlice"`.

#### Allocator helpers
- `HeapHelpers.hpp`:
  - New `alloc::makeByteBufferSlice(base, offset, len)` that allocates the
    16-byte slice with the standard Pattern-B rooting of `base`.
  - Collapse slice-of-slice at construction (resolve `base`; if it's a
    `Tag_ByteBufferSlice`, take its `base` + adjusted offset).
  - Add `isByteBufferSlice(obj)`; update `isByteBuffer(obj)` to include
    `Tag_ByteBufferSlice` (consumers that care about "is this any byte
    container").
  - New `byteBufferView(obj) -> (const u8* data, size_t length)`:
    handles flat, large header, and slice transparently. Returns a
    pointer-into-payload that is valid until the next allocation that
    might GC.

#### Caller migration
- Hot path consumers stop calling `resolveByteBufferBody` + `bb->bytes`
  pair and instead call `byteBufferView`:
  - `BytesOps.{hpp,cpp}`: `length`, `getAt`, `slice` (produces a slice),
    `append`, `concat`, `equal`, `hash`, `decodeUnsignedInt`,
    `decodeSignedInt`, `decodeFloat32/64`, `decodeUtf8`, `toBase64`,
    `toHex`, `toList`, `toVector`.
  - `BytesExports.cpp`: `resolveByteBuffer` becomes a view-returning
    helper. All `read_*` callers consume `(data, length)` instead of
    `bb->bytes + offset`.
  - `Bytes.cpp`: `read_bytes`, `read_string`, `width`, `write_bytes`.
  - `Utils.cpp` `compare`/`equal` paths for ByteBuffer.
  - `HttpExports.cpp`, `File.cpp`, `NativeDriver.cpp`, `ElmBytesRuntime.cpp`.

#### Producers
- `BytesOps::slice` returns a `Tag_ByteBufferSlice` (no memcpy at all)
  whenever the source is `Tag_ByteBuffer` or `Tag_ByteBufferSlice`. If the
  source is `Tag_LargeByteHeader`, still produce a slice — `base` is the
  large header itself (which transparently resolves through to the body
  via `byteBufferView`).
- `Elm_Kernel_Bytes_read_bytes`: same — produces a slice, not a copy.

#### Cutoff: tiny slices
- For very tiny slices (e.g. < 32 bytes) we may want to flatten to a copy
  rather than a 16-byte slice header — the slice header itself plus the
  indirection cost outweighs the saved copy. Add a `MAKE_SLICE_MIN_LEN`
  threshold (initial 32) tuned by stress tests.
- Mirrors `StringOps::slice` which has the same tiny-path flatten.

#### Invariants
- Add a `HEAP_028` (or extend `HEAP_025`) covering the new
  `Tag_ByteBufferSlice` form, base-resolves-to-`Tag_ByteBuffer` /
  `Tag_LargeByteHeader` rule, and the rule that `byteBufferView` is the
  only legal way to read the payload of a "byte buffer in any form."
- Update `BFOPS_032`: extend list of layout-aware ops to include
  `byteBufferView`.

### C2. Item 10 — streaming `StringOps` visitor for `writeEncoder`
- File: `BytesExports.cpp:252-289` (ENC_UTF8 case), `:329-366`
  (`Elm_Kernel_Bytes_getStringWidth`).
- Add `StringOps::visitU16(str, fn)` that calls `fn(const u16* run,
  size_t len)` for each contiguous run inside any string form (leaf, slice,
  rope). No materialisation. Hot UTF-8 encoders iterate the runs directly.
- Migration: `writeEncoder`'s ENC_UTF8 case becomes a visitor walk;
  `Elm_Kernel_Bytes_getStringWidth` becomes a visitor walk.
- Risk: rope walks must be correct on surrogate pairs that straddle a run
  boundary. The visitor passes a "carry" code unit between calls, or the
  user is responsible for splicing the boundary. Simpler approach: the
  visitor guarantees that ropes' run boundaries do not split surrogate
  pairs — a rope leaf that ends in a high surrogate is followed by a leaf
  that starts with its paired low surrogate (a property of how
  `StringOps::concat` builds ropes, since concat happens at logical
  String boundaries — but a rope built from an arbitrary subsequence of
  inputs can have this property violated). Simplest safe choice: visitor
  passes a high-surrogate carry to the callback's next invocation. The
  UTF-8 emitter buffers one half-pair and resolves it on the next call.

### C3. Item 11 — multi-value return for read helpers
- DEFERRED with rationale. Changing `Elm_Kernel_Bytes_read_i8` etc. to
  return `(i64, i64)` natively requires:
  - Updating the kernel function signature (Elm-side decl + MLIR codegen
    for the call site).
  - Changing the Elm-side decoder combinator from `Tuple2`-destructuring
    to direct multi-value consumption.
  - Verifying every wrapper/PAP path can carry multi-value returns.
- Risk of bootstrap regression is high relative to the saved one Tuple2
  per read. Re-evaluate once `unboxed-primitive-return-values.md` is
  fully landed end-to-end.

### C4. Item 14 — callback variant of `elm_bytebuffer_data`
- File: `ElmBytesRuntime.cpp:93-98`.
- Add `elm_bytebuffer_with_data(HPtr bb, void (*fn)(const u8* data, u32 len,
  void* ctx), void* ctx)`. The runtime resolves and invokes the callback
  while guaranteeing the buffer body is stable (no GC during the call —
  callbacks must not allocate; documented in the header).
- Do NOT migrate existing callers in this change set — they remain on
  `elm_bytebuffer_data` plus inline GC-aware rooting until each consumer
  is audited. The new API is offered for new code only.
- This delivers safety improvement only when callers migrate; the perf
  impact is secondary. Item is "implement the API, document the rule, do
  not migrate."

## Build/test/bootstrap checklist
After each phase:
1. `cmake --build build` — must succeed.
2. `cmake --build build --target full 2>&1 | tee /tmp/e2e.txt` — E2E
   regression suite.
3. `cmake --build build --target stress 2>&1 | tee /tmp/stress.txt` —
   stress suite.
4. After Phase C: `cmake --build build --target eco-compiler-boot`
   (Stage 7a + Stage 7b) — bootstrap must reach the fixed point.

If a phase fails the bootstrap, the diff for that phase is reverted and
re-debugged in isolation before merging downstream phases.

## Out-of-scope
- Bytes decoder ABI changes (item 11).
- StringOps redesign for arbitrary rope visitors beyond UTF-8 walking
  (item 10 specifically).
- Migrating existing `elm_bytebuffer_data` callers to the callback API
  (item 14's scope is API addition only).
