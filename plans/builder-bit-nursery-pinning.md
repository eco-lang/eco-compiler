# Builder Bit: Pin In-Construction Objects to Nursery

## Goal

Add a one-bit `builder` flag to the heap `Header` so runtime kernels (notably
`Elm_Kernel_JsArray_indexedMap_Int` and its siblings) can mark an object as
**under construction**. While `builder == 1`, the GC must keep the object in
the nursery: it is fully traced, but it does not age and is never promoted.

This eliminates the Stage-7 corruption class where `JsArray` result arrays are
allocated, written across closure calls, and (on the unlucky GC schedule)
promoted mid-loop — so subsequent slot writes plant nursery HPointers into an
old-gen parent in violation of the "no remembered set / no old→young pointers"
invariant the rest of the GC depends on.

## Decisions (resolved)

- **Bit source**: carve `builder:1` out of `refcount:16` (header doc explicitly
  marks `refcount` as unused). `pin` is not a substitute — `pin` forbids
  relocation, `builder` forbids promotion; they are orthogonal.
- **Promotion condition (canonical)**: `!hdr->pin && !hdr->builder &&
  hdr->age >= config_->promotion_age`. No special-casing between `pin` and
  `builder`.
- **Age semantics for builders**: when `mark_as_builder` is called, the bit
  is set **and** `age` is reset to 0. While `builder == 1`, age is *never*
  incremented. The resulting invariant `builder ⇒ age == 0` is asserted in
  HEAP_VALIDATE builds. After `clear_builder`, the cell ages like a freshly
  allocated object.
- **Default allocator stays plain**: `allocArray` is unchanged. Builder
  semantics are opt-in via a new `allocArrayBuilder`. One-shot allocators
  (`arrayFromPointers`, `unsafeSet`, `push`, `slice`, `appendN`,
  `singleton`) stay on `allocArray` because they don't mutate across GC
  points.
- **Regression gate**: a focused JsArray regression test is the primary,
  deterministic gate; Stage 7 is an *additional* gate when healthy, not
  the sole one.

## Background / grounding

- Existing header layout in `runtime/src/allocator/Heap.hpp:117-127` packs
  `tag:5 / color:2 / pin:1 / age:2 / unboxed:6 / refcount:16 / size:32` into
  exactly 64 bits. `refcount` is documented as unused.
- The nursery promotion decision runs in three places in
  `runtime/src/allocator/NurserySpace.cpp`:
    - `evacuate(HPointer&, OldGenSpace&, ...)` at line 1132 (the main path).
    - `evacuateJitPtr(...)` at line 1286 (raw 64-bit JIT pointer evacuation).
    - The Cons-spine fast path inside `evacuateListSpine` at line 1759.
  All three test `hdr->age >= config_->promotion_age` and copy to old gen, then
  set `new_hdr->age = 0`. The non-promoted branches do `new_hdr->age++`.
- `config_->promotion_age` is configurable in `[1, 3]`
  (`AllocatorCommon.hpp:343,535-542`); the `age` field is 2 bits.
- The "child of promoted parent must already be old enough" invariant is
  asserted at `NurserySpace.cpp:1170-1195` (in_phase3_, ECO_HEAP_VALIDATE).
- `OldGenSpace::markOneObject` at `OldGenSpace.cpp:1814-1854` is the spot
  where, in HEAP_VALIDATE builds, we can cheaply assert that no Black-marked
  old-gen object ever has `builder == 1`.
- `alloc::allocArray` lives at `runtime/src/allocator/HeapHelpers.hpp:919-930`
  and is the single allocator entry used by every JsArray kernel that builds
  a result array in place.
- The actual victim kernel,
  `elm-kernel-cpp/src/core/JsArrayExports.cpp:958-997`
  (`Elm_Kernel_JsArray_indexedMap_Int`), already uses `StackRootGuard` and
  re-resolves `arr` each iteration — it has the rooting story right; what it
  lacks is a way to tell the GC "do not promote this array yet."

## Plan

### Phase 1 — Header change

1. **Edit `runtime/src/allocator/Heap.hpp`** (the `Header` struct, lines
   117-127):
    - Carve `builder:1` out of `refcount:16` → `refcount:15 + builder:1`.
    - Keep the `static_assert(sizeof(Header) == 8)`; it must still hold.
    - Update the surrounding header comment (lines ~97-116) with the builder
      semantics: must live in nursery, fully traced, never aged, never
      promoted, kernels must clear before returning.
2. **Document in `THEORY.md`** under the promotion section: add a paragraph
   describing the builder bit and its interaction with age/promotion. Note the
   invariant that builders must never appear in old gen.
3. **Add invariants to `design_docs/invariants.csv`**: at minimum
   `HEAP_BUILDER_001` (no builder in old gen), `HEAP_BUILDER_002` (builders
   are not aged or promoted while builder==1), `HEAP_BUILDER_003` (kernels
   clear builder before publishing the result).

### Phase 2 — GC honors the builder bit

4. **`NurserySpace::evacuate` (`NurserySpace.cpp:1131-1162`)**: replace the
   promotion test with the canonical condition
   `!hdr->pin && !hdr->builder && hdr->age >= config_->promotion_age`.
   (`pin` is already an existing concept and the test currently does not
   gate on it explicitly — fold it in alongside `builder` so the predicate
   reads cleanly.) The else branch (copy to to_space) must **skip**
   `new_hdr->age++` (line 1205) when `new_hdr->builder == 1` so the
   `builder ⇒ age == 0` invariant holds.
5. **`NurserySpace::evacuateJitPtr` (lines 1285-1313)**: apply the same
   canonical predicate, and the same `age++` skip when `builder == 1`.
6. **`evacuateListSpine` Cons fast path (lines 1759-1780)**: same treatment.
   Cons cells aren't typically marked builder, but the fast path should
   still respect the bit defensively.
7. **`ECO_HEAP_VALIDATE` assertions**:
    - In `NurserySpace::evacuate`, on the to_space branch after the copy:
      assert `!(new_hdr->builder && new_hdr->age != 0)` — the
      `builder ⇒ age == 0` invariant.
    - In `OldGenSpace::markOneObject` (`OldGenSpace.cpp:1814-1854`), at the
      old-gen branch (line 1837+, after `if (!contains(obj)) return false;`):
      assert `!hdr->builder` — a builder ever showing up in old gen is a
      kernel bug.
    - In the existing phase-3 invariant block at `NurserySpace.cpp:1170-1195`:
      add a parallel branch panicking with "builder object would have been
      promoted" if `hdr->builder` is set there (should be unreachable once
      the gate above is in place).

### Phase 3 — Runtime helper API

8. **`runtime/src/allocator/HeapHelpers.hpp`**: add inline helpers next to
   `allocArray` (around line 919):
    - `inline void mark_as_builder(Header* h)` — sets `builder=1` **and**
      `age=0`. Both writes are required to maintain the
      `builder ⇒ age == 0` invariant.
    - `inline void clear_builder(Header* h)` — clears `builder`; leaves
      `age` at 0 so the cell ages from scratch on the next minor GC. In
      `ECO_HEAP_VALIDATE` builds, asserts the object is in nursery (call
      `Allocator::instance().isInNursery(...)`) before clearing.
    - `class BuilderGuard` — RAII type; constructor calls `mark_as_builder`,
      destructor calls `clear_builder` if the bit is still set. Allows
      manual early `clear()` if a kernel wants to release before scope exit.
9. **Allocator opt-in entry**: add
   `inline HPointer allocArrayBuilder(size_t capacity)` adjacent to the
   existing `allocArray` (line 919) that does the same allocation and then
   sets `builder=1` on the returned cell's header. Keep `allocArray`
   unchanged so one-shot allocation sites (`arrayFromPointers`, `unsafeSet`,
   `push`, `slice`, `appendN`, `singleton`) are unaffected.

### Phase 4 — Migrate JsArray kernels

10. Convert each JsArray kernel that allocates a result array up front and
    then mutates it across closure calls (i.e. across GC points) to:
    - allocate via `allocArrayBuilder` instead of `allocArray`,
    - hold a `BuilderGuard` for the body of the loop so the bit is cleared
      automatically on every exit (return, exception, early break),
    - keep the existing `StackRootGuard` + per-iteration `allocator.resolve`
      pattern.
    Concrete sites in `elm-kernel-cpp/src/core/JsArrayExports.cpp`:
    - `Elm_Kernel_JsArray_initialize` (line 422)
    - `Elm_Kernel_JsArray_initialize_Int` (line 929)
    - `Elm_Kernel_JsArray_map` (line 455)
    - `Elm_Kernel_JsArray_indexedMap` (line 507)
    - `Elm_Kernel_JsArray_indexedMap_Int` (line 958)
    - Audit `Elm_Kernel_JsArray_foldl` / `foldr` (line 636-) — if they only
      carry a scalar accumulator and don't mutate a heap array across closure
      calls, no change needed.
    - Audit `Elm_Kernel_JsArray_unsafeSet` / `push` / `appendN` / `slice` —
      these allocate and copy in tight loops without invoking user closures,
      so no GC happens inside the loop. They should *not* need builder.
11. Sweep `runtime/src/allocator/RuntimeExports.cpp:3377` and any other
    callers of `alloc::allocArray` for the same "alloc + mutate across GC
    points" pattern.

### Phase 5 — Audit other in-place builders beyond JsArray

12. Grep the runtime + elm-kernel-cpp tree for the same shape: a container
    allocator (`allocArray`, `allocRecord`, `allocCustom`, anything ending
    in `_alloc`, custom byte buffers) followed by a loop that calls user
    closures or transitively reaches `eco_alloc_with_roots`. Likely
    suspects to check explicitly:
    - JSON decoders (`Json/Decode.elm` runtime side, anywhere that builds
      an array/record incrementally from a parsed input).
    - `Bytes.Encode` / `Bytes.Decode` — incremental byte-buffer builders
      that may allocate and write across GC points if encoders include
      user computations.
    - `String.split` / `String.join` runtime helpers if they preallocate a
      result and fill it.
    - Any fold helpers (List, Dict, Set) that accumulate into a heap
      structure rather than a scalar.
    For each match, decide between:
    - migrate to `alloc*Builder` + `BuilderGuard`, or
    - refactor to scratch buffer + single final allocation.

### Phase 6 — Optional debug exit-validation

13. (HEAP_VALIDATE only) In a common kernel-return helper or at the bottom of
    each migrated JsArray kernel, call a `validate_no_builder_result(HPtr)`
    that resolves and asserts `!hdr->builder`. Cheap last-line-of-defense
    against a forgotten `BuilderGuard` scope.

### Phase 7 — Targeted regression test (primary gate)

14. Add a focused JsArray regression test as the **primary, deterministic**
    gate for this work. The test must:
    - exercise `JsArray.indexedMap` / `JsArray.map` / `JsArray.initialize`
      over a large array (size large enough that multiple minor GCs run
      mid-loop on the default nursery configuration),
    - have the mapping closure allocate heavily (e.g. build a small nested
      record/tuple per call) so the loop reliably triggers minor GCs and
      tries to age/promote the result array,
    - run under `ECO_HEAP_VALIDATE=ON`, with the new HEAP_VALIDATE
      assertions enabled,
    - pass cleanly with no phase-3 promotion-invariant violations and no
      `builder`-related assertion failures.
    Place the test alongside existing JsArray tests so it runs as part of
    the standard E2E target.

### Phase 8 — Verify

15. Run `cmake --build build --target full` (E2E) and the stress-test suite
    with `ECO_HEAP_VALIDATE=ON`. Targets: 1267/1267 E2E and 99/99 stress
    preserved.
16. Confirm the new targeted JsArray regression test passes.
17. **Additional, non-blocking gate**: when Stage 7 is healthy enough to
    run, confirm the
    `Elm_Kernel_JsArray_indexedMap_Int` corruption signature documented in
    Stage 7 logs no longer reproduces. If Stage 7 is blocked by unrelated
    bugs (per project memory), do not gate on it — the targeted test
    above is sufficient evidence.

## Files touched (summary)

- `runtime/src/allocator/Heap.hpp` — header bit + comments.
- `runtime/src/allocator/HeapHelpers.hpp` — `mark_as_builder`,
  `clear_builder`, `BuilderGuard`, `allocArrayBuilder`.
- `runtime/src/allocator/NurserySpace.cpp` — `evacuate`, `evacuateJitPtr`,
  `evacuateListSpine` gates + age skip.
- `runtime/src/allocator/OldGenSpace.cpp` — HEAP_VALIDATE assertion in
  `markOneObject`.
- `elm-kernel-cpp/src/core/JsArrayExports.cpp` — migrate the five typed-
  result kernels listed above.
- `design_docs/theory/THEORY.md`, `design_docs/invariants.csv` — docs.

---

## Remaining minor questions

These don't block starting the work; flag if any change during implementation.

1. **`refcount` clear path**. Nothing currently writes `refcount`, but if any
   future code does `hdr->refcount = N`, it must mask off the new
   `builder` bit. Once `builder` lands, audit any `refcount =` writes that
   appear and either preserve the bit explicitly or convert to a typed
   accessor.
2. **Cons spine fast path completeness**. The plan applies the same
   `!builder` gate to the spine fast path defensively, but no kernel marks
   Cons cells as builders today. If we ever introduce one, decide whether
   the spine path should bail to the slow path on first-builder rather
   than handle each cell individually.
3. **HEAP_VALIDATE-only vs always-on for `markOneObject` assertion**. The
   bit-test is cheap (the header is already in a register at that point),
   so promoting the assertion to always-on is plausible. The plan keeps it
   `ECO_HEAP_VALIDATE`-gated for consistency with the surrounding
   assertions; revisit if production-time guarantees are wanted.