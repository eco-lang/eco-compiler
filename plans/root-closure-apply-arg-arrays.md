# Plan: Root Closure-Apply Arg Arrays via Stack Root Ranges

## Goal

Close the remaining GC visibility holes in the closure-apply runtime path.
Compiled code (and runtime callers) hand `uint64_t*` arg arrays — often
`alloca`'d — into runtime helpers that may trigger GC. The arrays' `HPointer`
contents must be in-place evacuated when GC runs inside those helpers.

The runtime already exposes the stack-root-range API (and uses it correctly
inside `eco_closure_call_saturated` for `combined_args`). This plan extends
that pattern to the remaining entrypoints:

- `eco_apply_closure` (args)
- `eco_apply_segmentation_unknown` (typed_args / boxed_args, branch-dependent)
- `eco_pap_extend` (args)
- (Optional) debug helpers `eco_dbg_print*`

## Files Touched

- `runtime/src/allocator/RuntimeExports.cpp` — body changes only; no header
  signature changes, no ABI changes.

## Steps

### Step 1 — Add small mask helpers

In an anonymous namespace near the top of `RuntimeExports.cpp` (or near the
existing stack-range helpers), add:

```cpp
static inline uint64_t hptr_mask_all(size_t count);     // (1<<count)-1, count<=64 safe
static inline uint64_t hptr_mask_clamp(uint64_t raw, size_t count);
```

These centralize the `(1ULL << n) - 1` pattern and avoid UB at `count == 64`.

### Step 2 — Wrap `eco_apply_closure` (RuntimeExports.cpp:889)

- Save range point at function entry (after the early `nullptr` return).
- Assert `max_values <= 63` (matches the 6-bit closure header field).
- If `num_args > 0`, push a stack range for `args` with mask
  `hptr_mask_all(num_args)` (all entries in `eco_apply_closure` are
  HPointer-encoded `!eco.value`).
- Capture the result into a local, restore the range point at exit.
- All three branches (saturated, under, over) are protected by a single
  push covering `args`. The over-saturated recursive call will push its own
  range for `args + remaining`; that overlap is harmless.

### Step 3 — Wrap `eco_apply_segmentation_unknown` (RuntimeExports.cpp:915)

After the existing closure header DIAG block, save the range point.

- Under-saturated branch (`num_args < remaining`):
  - `typed_args` is mixed unboxed/boxed; `unboxed_bitmap` bit `i = 1` means
    `typed_args[i]` is an unboxed primitive.
  - Push range over `typed_args` with mask
    `hptr_mask_clamp(~unboxed_bitmap, num_args)`. Skip push if the mask is 0.

- Saturated / over-saturated branch:
  - `boxed_args` entries are all HPointer-encoded `!eco.value`.
  - Push range over `boxed_args` with `hptr_mask_all(num_args)`.

Capture the result into a local, restore the range point at exit.

### Step 4 — Wrap `eco_pap_extend` (RuntimeExports.cpp:954)

This is the highest-leverage fix because `Allocator::instance().allocate()`
on line 979 may trigger GC while `args[]` is still being read on line 1005.

- Save range point at function entry (after early returns).
- Before the `allocate(...)` call, if `num_newargs > 0`, push a range over
  `args` with mask `hptr_mask_clamp(~new_unboxed_bitmap, num_newargs)`.
- The existing `old_closure` re-resolve via `hpointerToPtr(closure_hptr)`
  after `allocate` is preserved (the closure itself is rooted via
  `closure_hptr` semantics, not via the args buffer).
- Capture result, restore range point at exit.

Subtlety: `args[i].i` is being stored into `new_closure->values[]` which is
freshly allocated and not yet GC-visible. Since we re-resolve `old_closure`
post-allocate (already in code) and we now root `args` across the alloc,
the copy loop reads forwarded pointers correctly.

### Step 5 — (Optional) Debug helpers

`eco_dbg_print` / `eco_dbg_print_typed` take `uint64_t*` arrays and may
allocate transitively when formatting values. Defer unless we observe
crashes in a debug-printing path; document the invariant in a code comment
("callers must root the array, OR debug helper will push its own range").

### Step 6 — Build & test

```
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

Then re-run the Stage-7 self-compile reproducer from `bootstrap-fails.md`
and confirm:
- DIAG[STORE_BAD_VAL] no longer fires for `Custom`/RBNode.LEFT writes
  with stale HPointers.
- The previously-reported GC crash is gone.

## Non-Goals

- No changes to `RuntimeExports.h` or the C ABI.
- No changes to the MLIR-side statepoint/stackmap pipeline.
- No inlining of `papExtend` in LLVM (orthogonal in-flight work).
- No removal of the existing range push inside `eco_closure_call_saturated`.

## Risks / Edge Cases

- **Range stack overflow**: `RootSet::stack_root_ranges` is a
  `std::vector<StackRootRange>` with no fixed cap; push/pop is
  `vector::push_back` / `resize`. Per-frame push is the supported pattern
  (already used by `eco_closure_call_saturated`). The only hard limit is
  per-range: `eco_gc_push_stack_range` asserts `count <= 64`.
- **`max_values <= 63`** is already a closure header invariant; assert it
  rather than silently mis-masking.
- **Overlapping ranges** are safe. Both `NurserySpace::minorGC` and
  `ThreadLocalHeap::collectRoots` walk `getStackRootRanges()` and treat
  `base[i]` as the authoritative slot. Forwarding is idempotent — after
  the first evacuation, a forward header at the old location makes
  subsequent `evacuate(base[i], …)` calls follow the forward. So
  `args` ⊕ `combined_args` overlap (in `eco_apply_closure` →
  `eco_closure_call_saturated`) is just slightly redundant.
- **Unboxed primitives misclassified as pointers**: avoided by using
  `~unboxed_bitmap` masks where the bitmap is available; never use an
  all-ones mask on `typed_args` with unboxed mixed in.
- **`new_unboxed_bitmap` reliability** (for Step 4): MLIR-side codegen
  computes the bitmap from SSA operand types in both `generateGenericApply`
  and `applyByStages`, and the "PAP bitmaps limited to 52 bits" invariant
  test verifies popcount matches the unboxed-typed-operand count. There is
  no hand-written C++ caller that passes a fabricated bitmap. Treat the
  bitmap as authoritative.

---

## Step 7 — Targeted runtime regression test (new)

There is no existing runtime GC stress test for `eco_pap_extend` /
`eco_apply_*`; the existing PAP-bitmap tests (`UnboxedBitmapTest.elm`)
are MLIR-level invariants, not GC tests. Add a small C++ test that:

- Constructs a closure and a stack arg array containing HPointers.
- Forces a minor GC inside `eco_pap_extend` (e.g. by pre-filling the
  nursery near its limit, or via a debug hook that triggers GC on the
  next allocation).
- Verifies the resulting closure's `values[]` hold forwarded pointers
  (i.e. point into oldgen, not into the now-evacuated nursery slot).
- Repeats analogous coverage for `eco_apply_closure` and
  `eco_apply_segmentation_unknown` (under-saturated and saturated
  branches, mixed unboxed/boxed `typed_args`).

Place under `runtime/test/` next to existing allocator/GC tests. The
test directly covers the class of bug from `heap-invariant-bug.md` and
the Failure #2 path in `bootstrap-fails.md`, neither of which currently
has runtime-level regression coverage.
