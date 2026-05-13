# Atomic Allocation Helpers for Records, Customs, and Single Closures

## Goal

Make construction of new heap objects atomic at the allocation site for the
three remaining "alloc-then-store-fields" shapes:

- `eco.construct.record`
- `eco.construct.custom`
- `eco.papCreate` (single closure)

After this change, every field/capture word is consumed as a **call argument**
to an allocation helper. There is no `eco_resolve_hptr` + GEP + store sequence
in user IR following these allocations, so no unboxed primitive copied from
heap object A into heap object B can be loaded via a derived pointer that
crosses a statepoint.

Projection (`eco.project.record/custom`, closure capture loads) is **unchanged**:
it remains `resolve + gep + load`. Allocation groups (`eco_gc_alloc_region_*`
+ `eco_init_*_at`) are also unchanged — they're already atomic from user IR's
perspective.

## Background / grounding

### Current shape

Records (`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:618`):
- `emitAllocWithSafepoint(... eco_alloc_record, {fieldCount, bitmap}, liveRoots)`
- Then per-field: `eco_store_record_field{,_i64,_f64}(obj, idx, val)`.

Customs (`EcoToLLVMHeap.cpp:736`):
- `emitAllocWithSafepoint(... eco_alloc_custom, {tag, size, scalarBytes}, liveRoots)`
- Then per-field: `eco_store_field{,_i64,_f64}(obj, idx, val)`.
- If `unboxed_bitmap != 0`: `eco_set_unboxed(obj, bitmap)`.

Single closures (`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:600`):
- `emitSafepointMarker(...)`
- `eco_alloc_closure_k(funcPtr, arity, resultKind)` → closureHPtr
- `eco_resolve_hptr(closureHPtr)` → closurePtr
- Inline `store packedConst at closurePtr+8`
- Inline `store capturedValue[i] at closurePtr + 24 + i*8` for each capture
- Optional self-capture backpatch: `store closureI64 at closurePtr + 24 + i*8`

### Already atomic from user IR

- Tuples (`Tuple2ConstructOpLowering`/`Tuple3ConstructOpLowering`, `EcoToLLVMHeap.cpp:472,506`):
  fields are widened to i64 and passed as call args; no follow-up stores.
- Cons (`ListConstructOpLowering`, around `EcoToLLVMHeap.cpp:309`):
  `eco_alloc_cons(head_i64, tail_hptr, head_kind)` — no follow-up stores.
- String allocation: `eco_alloc_string(length)` — content is filled elsewhere
  (literal data; not from heap projections).
- Closure groups (`PapCreateGroupOpLowering`, `EcoToLLVMClosures.cpp:772`):
  single `eco_alloc_closure_group_slow` call with `captures[]` and
  `crossEdges[]` arrays — already atomic from user IR.
- `eco.allocate_closure` (`AllocateClosureOpLowering`, `EcoToLLVMClosures.cpp:154`):
  zero-capture alloc, no follow-up field stores from projected values.

So only **records, customs, and `papCreate`** need conversion.

### Existing runtime entry points (signatures today)

`runtime/src/allocator/RuntimeExports.h`:

```c
HPtr eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap);
void eco_store_record_field    (HPtr, uint32_t, HPtr);
void eco_store_record_field_i64(HPtr, uint32_t, int64_t);
void eco_store_record_field_f64(HPtr, uint32_t, double);

HPtr eco_alloc_custom(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);
void eco_store_field    (HPtr, uint32_t, HPtr);
void eco_store_field_i64(HPtr, uint32_t, int64_t);
void eco_store_field_f64(HPtr, uint32_t, double);
void eco_set_unboxed(HPtr, uint64_t bitmap);

HPtr eco_alloc_closure  (void *func_ptr, uint32_t num_captures);
HPtr eco_alloc_closure_k(void *func_ptr, uint32_t num_captures, uint8_t result_kind);
```

Notes:
- `eco_alloc_record` and `eco_alloc_custom` have **no callers outside
  generated code** (`grep` over `runtime/` + `elm-kernel-cpp/` confirms only
  codegen/symbol-registration files reference them). They can be changed
  in place.
- `eco_alloc_closure{,_k}` are also used by `AllocateClosureOpLowering`
  (for `eco.allocate_closure`) — that lowering has no follow-up field
  stores from projections, so leaving those entry points alone is correct.
  The atomic closure helper will be a **new** symbol so `eco.allocate_closure`
  is undisturbed.
- The existing `_fast`/`_slow` split (`eco_alloc_record_fast`,
  `eco_alloc_record_slow`, etc.) is consumed by `emitAllocWithSafepoint`
  internally. We need to mirror the new signature on both the fast and slow
  variants where applicable.

### GC-root window on the field/capture array

`PapCreateGroupOpLowering` already demonstrates the pattern we need to copy:
when the capture array contains HPointers, it (`EcoToLLVMClosures.cpp:980-1001`):

1. Zero the alloca with `LLVM::MemsetOp`.
2. `eco_gc_stack_range_point()` → `savedRangeDepth`.
3. `eco_gc_push_stack_range(arrayPtr, count, hpointer_mask)`.
4. Store HPointer/primitive words into the array.
5. Emit the safepoint marker.
6. Call the atomic helper.
7. `eco_gc_restore_stack_range_point(savedRangeDepth)`.

Without this, an HPointer stored into the alloca would not be visible to GC
during the slow allocation path, and the helper would dereference a stale
HPtr after GC moved its target. Records/customs/single-closures need the
same scaffolding when their array contains any HPointer slot.

The HPointer mask is the complement of the kind bitmap (per slot), restricted
to "boxed slot" entries. The kind bitmap is already known at the lowering
site (`op.getUnboxedBitmap()` for records, customs, and papCreate captures
where the typed-newargs wrapper isn't in play; `deriveAllParamKindsBitmap`
result for the wrapper case).

## Plan

### Step 1 — Runtime: new C entry points

All work in `runtime/src/allocator/RuntimeExports.{h,cpp}`.

Naming: introduce **three new `_filled` helpers** plus matching
`_fast`/`_slow` variants. The existing `eco_alloc_record`, `eco_alloc_custom`,
`eco_alloc_closure`, and `eco_alloc_closure_k` symbols stay declared (still
used by `AllocateClosureOpLowering` for `eco.allocate_closure`; the record/
custom names will become orphan after Step 2 and are removed in a follow-up
once we confirm nothing pulls them in).

The new fast helpers must remain `gc-leaf-function` so RS4GC never wraps
them in a statepoint — same invariant as `eco_gc_alloc_region_fast` and
the `eco_init_*_at` family. Document this invariant at the declaration
site: between bump-pointer success and field init there must be no GC,
and the helpers achieve this by never calling anything that could trigger
one.

#### 1a. Records

```c
// Atomic alloc + init. Fields are HPointers (boxed slots) or raw primitive
// bits (unboxed slots) packed as 64-bit words. The slow path uses the
// caller-supplied `fields[]` buffer as the GC root range — the caller is
// responsible for opening the range (eco_gc_push_stack_range) with the
// matching HPointer mask before the call and closing it after.
HPtr eco_alloc_record_filled(
    uint32_t        field_count,
    uint64_t        unboxed_bitmap,   // 2 bits per slot (existing encoding)
    const uint64_t *fields);          // field_count words

HPtr eco_alloc_record_filled_fast(   // gc-leaf
    uint32_t field_count, uint64_t unboxed_bitmap, const uint64_t *fields);

HPtr eco_alloc_record_filled_slow(
    uint32_t field_count, uint64_t unboxed_bitmap, const uint64_t *fields);
```

Implementation notes:
- Size as today: `sizeof(Header) + 8 + field_count * sizeof(Unboxable)`.
- After a slow-path GC, re-read `fields[i]` for boxed slots when copying
  into `rec->values[i]` (the GC may have relocated targets in-place).
- `rec->unboxed = unboxed_bitmap`.

The bump-pointer `_fast` path **must not** itself open a root range — the
caller's range push covers the failed-fast / retry-slow re-read.

#### 1b. Customs

Retain the `scalar_bytes` parameter for parity with `eco_init_custom_at`
even though current call sites always pass `0`. The `fields[]` array
covers only the `field_count` pointer-sized slots; scalar payload bytes
remain managed by the helper itself.

```c
HPtr eco_alloc_custom_filled(
    uint32_t        ctor_id,
    uint32_t        field_count,
    uint32_t        scalar_bytes,
    const uint64_t *fields,           // field_count words
    uint64_t        unboxed_bitmap);

HPtr eco_alloc_custom_filled_fast(   // gc-leaf
    uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes,
    const uint64_t *fields, uint64_t unboxed_bitmap);

HPtr eco_alloc_custom_filled_slow(
    uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes,
    const uint64_t *fields, uint64_t unboxed_bitmap);
```

Implementation notes:
- Size as today: `sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes`.
- `custom->ctor = ctor_id`, `custom->unboxed = unboxed_bitmap` (replaces
  the `eco_set_unboxed` post-step).
- Copy `fields[i]` into `custom->values[i].i` after the (possibly GC'd)
  allocation.

#### 1c. Closures

```c
HPtr eco_alloc_closure_k_filled(
    void           *func_ptr,
    uint32_t        arity,            // max_values
    uint32_t        num_captured,     // n_values
    uint64_t        unboxed_bitmap,   // 50-bit closure-header capture bitmap
    uint8_t         result_kind,      // PK_Boxed/PK_Int/PK_Float/PK_Char
    const uint64_t *captures);        // num_captured words

HPtr eco_alloc_closure_k_filled_fast(   // gc-leaf
    void *func_ptr, uint32_t arity, uint32_t num_captured,
    uint64_t unboxed_bitmap, uint8_t result_kind, const uint64_t *captures);

HPtr eco_alloc_closure_k_filled_slow(
    void *func_ptr, uint32_t arity, uint32_t num_captured,
    uint64_t unboxed_bitmap, uint8_t result_kind, const uint64_t *captures);
```

Implementation notes:
- Size: `sizeof(Header) + 8 + sizeof(EvalFunction) + num_captured * sizeof(Unboxable)`.
- `packed = num_captured | (arity << 6) | (result_kind << 12) | (unboxed_bitmap << 14)`
  written at `ClosurePackedOffset` (offset 8).
- Evaluator pointer at the next slot; capture words at `values[i]`.

**Self-capture backpatch is NOT done here**. The set of self-capture
indices is known statically in the lowering; threading it through the
runtime helper makes the helper opaque for no gain. Self-capture stays
a small post-call `resolve+gep+store` in the lowering (Step 5), which
writes the closure's own HPointer into one of its own slots — a same-
object intra-allocation operation that doesn't reintroduce the bug class
this change targets.

### Step 2 — Codegen: runtime declarations

In `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`, add three families
of `getOrCreate…Filled[Fast|Slow]` helpers mirroring the existing
`AllocRecordFast`/`AllocRecordSlow` etc. style:

- `getOrCreateAllocRecordFilled`     → `(i32, i64, ptr) -> hptr`
- `getOrCreateAllocRecordFilledFast` → same shape, **`gcLeaf=true`**
- `getOrCreateAllocRecordFilledSlow` → same shape
- `getOrCreateAllocCustomFilled`     → `(i32, i32, i32, ptr, i64) -> hptr`
- `getOrCreateAllocCustomFilledFast` → same shape, **`gcLeaf=true`**
- `getOrCreateAllocCustomFilledSlow` → same shape
- `getOrCreateAllocClosureKFilled`     → `(ptr, i32, i32, i64, i8, ptr) -> hptr`
- `getOrCreateAllocClosureKFilledFast` → same shape, **`gcLeaf=true`**
- `getOrCreateAllocClosureKFilledSlow` → same shape

The current `getOrCreateAllocRecord{,Fast,Slow}`, `getOrCreateAllocCustom{,Fast,Slow}`,
`getOrCreateAllocClosure`, `getOrCreateAllocClosureK` declarations remain
in place — `AllocateClosureOpLowering` still uses
`getOrCreateAllocClosure`, and removing the record/custom declarations
can land as a small follow-up after the patterns are migrated.

In `runtime/src/codegen/RuntimeSymbols.cpp`, register all nine new
symbols (`eco_alloc_record_filled{,_fast,_slow}`,
`eco_alloc_custom_filled{,_fast,_slow}`,
`eco_alloc_closure_k_filled{,_fast,_slow}`).

### Step 3 — Lowering: `RecordConstructOpLowering`

`EcoToLLVMHeap.cpp:618` rewrite shape. Allocas stay in the **current
block** (same as `PapCreateGroupOpLowering`); mem2reg + SROA will hoist
them as needed. The GC root range is pushed **from the lowering**, not
from the runtime helper — this mirrors what
`PapCreateGroupOpLowering::matchAndRewrite` already does
(`EcoToLLVMClosures.cpp:980-1001`) and keeps the helper leaf-clean.

1. Compute `fieldWords[i] = widenFieldToI64(fields[i], …)` for each field
   (existing `widenFieldToI64` at `EcoToLLVMHeap.cpp:439` handles HPointer,
   narrow-int → zext, f64 → bitcast).
2. Derive `hptrMask` from `op.getUnboxedBitmap()` (boxed slot ↔ HPointer
   slot). Compute it in C++ (mirror `pointerMaskFromKindBitmap` from
   `RuntimeExports.cpp`). This mask is used **only** for the GC root-range
   push; the helper takes the kind bitmap and recomputes its own internal
   mask if needed.
3. `alloca [fieldCount x i64] fieldsArr` in the current block.
4. If `hptrMask != 0`:
   `LLVM::MemsetOp(fieldsArr, 0, fieldCount*8)`,
   `savedDepth = eco_gc_stack_range_point()`,
   `eco_gc_push_stack_range(fieldsArr, fieldCount, hptrMask)`.
5. Store each `fieldWords[i]` into `fieldsArr[i]`.
6. `emitAllocWithSafepoint(... eco_alloc_record_filled, {countConst,
   bitmapConst, fieldsArr}, liveRoots)`.
   (`emitAllocWithSafepoint` dispatches to the `_fast`/`_slow` filled
   variants under the hood; nothing about its existing fast/slow split
   needs to change beyond the symbol it dispatches to.)
7. If `hptrMask != 0`:
   `eco_gc_restore_stack_range_point(savedDepth)`.
8. `rewriter.replaceOp(op, objHPtr)`.
9. Delete all `storeRecordField*` calls from this pattern.

### Step 4 — Lowering: `CustomConstructOpLowering`

`EcoToLLVMHeap.cpp:736` rewrite — same shape as Step 3:

1. Compute `fieldWords[i]` for each of `op.getSize()` fields.
2. Derive `hptrMask` from `op.getUnboxedBitmap()`.
3. Alloca + (optional) GC-root push (same scaffold as Step 3).
4. Store words into alloca.
5. `emitAllocWithSafepoint(... eco_alloc_custom_filled,
   {tag, size, scalarBytes, fieldsArr, bitmapConst}, liveRoots)`.
   `scalarBytes` is still a constant `0` everywhere it's emitted today;
   we keep it in the call signature for parity with `eco_init_custom_at`
   and to leave the door open to scalar-tail customs.
6. Restore range-point if pushed.
7. `rewriter.replaceOp(op, objHPtr)`.
8. Delete all `storeField*` calls and the `eco_set_unboxed` call.

### Step 5 — Lowering: `PapCreateOpLowering`

`EcoToLLVMClosures.cpp:600` rewrite:

1. Up to and including the `unboxedBitmap` / `closureResultKind` /
   `wrapperFunc` / `funcPtr` computation (lines 615–663) — **unchanged**.
   These derive the bitmap that the closure header will carry, and choose
   the right wrapper function pointer; the logic is independent of how we
   call the allocator. `closureResultKind` continues to come from
   `op.get_resultKind()`.
2. Build `captureWords[i]` from each `captured[i]`, applying the same
   widening as today (narrow int → zext, f64 → bitcast, ptr → `closureStoreValueToI64`).
3. Derive `hptrMask` from the captures portion of `unboxedBitmap` (bits
   `0..2*numCaptured-1`). The 50-bit closure-header `unboxed` field and
   the kind bitmap share the same physical bits but have different
   logical meanings; use a small dedicated helper
   (`deriveCaptureHPtrMask(unboxedBitmap, numCaptured)`) so that
   "which capture slots are HPointers" and "which arg slots are
   HPointers" cannot be conflated. Keep the helper in
   `EcoToLLVMClosures.cpp` (file-scope `static`) until a second caller
   appears.
4. Alloca `[numCaptured x i64] capturesArr` in the current block.
5. If `hptrMask != 0`: zero-memset + `eco_gc_stack_range_point` +
   `eco_gc_push_stack_range(capturesArr, numCaptured, hptrMask)`.
6. Store each `captureWords[i]` into `capturesArr[i]`.
7. `emitSafepointMarker(op, ..., liveRoots)`.
8. Single call:
   ```
   eco_alloc_closure_k_filled(
       funcPtr, arityConst, numCapturedConst,
       bitmapConst, resultKindConst, capturesArr)
   ```
   → `closureHPtr`. (`emitAllocWithSafepoint`-style fast/slow dispatch
   if/when introduced for this helper; the prototype can call the
   unified `eco_alloc_closure_k_filled` and add the split in a
   follow-up commit if profiling needs it.)
9. `eco_gc_restore_stack_range_point(savedDepth)` (if pushed).
10. **Self-capture backpatch** — keep the existing loop, but it now runs
    *after* the atomic alloc. Resolve `closureHPtr` and store
    `closureI64` into each `selfCaptureIdx` slot. This re-introduces a
    `resolve+gep+store` shape, but the stored value is the closure's own
    HPointer (not a value projected from another heap object), so the
    bug class this change targets is not reopened.
11. `rewriter.replaceOp(op, closureHPtr)`.

Delete (in this pattern, not from `EcoToLLVMRuntime.cpp`):
- The `resolveFunc` + `resolveCall` for `closurePtr`.
- The `packedConst` computation/store.
- The per-capture store loop (replaced by the alloca-and-pass approach).

### Step 6 — Lowering: tuples / cons / strings / `papCreateGroup`

No changes required:
- Tuples and cons already pass widened words as call args.
- Strings have no projection-fed init.
- `papCreateGroup` already uses the atomic shape (Step 5 mirrors its
  array-passing pattern).

`AllocateClosureOpLowering` (`EcoToLLVMClosures.cpp:154`) also unchanged —
zero captures, no follow-up stores, still calls `eco_alloc_closure`.

### Step 7 — Allocation groups

No change to `lowerAllocGroups` / `eco_init_record_at` / `eco_init_custom_at`.
Their field/capture words are already passed as call args. The dependent
invariant to check (manually, by IR inspection) is that
`RecordConstructOp` / `CustomConstructOp` / `PapCreateOp` are coalesced
into a region-init shape **before** the patterns in Steps 3–5 run, so
the per-op lowerings only see standalone allocations. This should already
be the case — but worth confirming when wiring the tests in Step 8.

### Step 8 — Tests

1. **MLIR pattern tests** (filecheck-style, against the lowered LLVM IR
   from `--mlir-print-ir-after-all` or an equivalent dump pass on a tiny
   Elm input):

   - After lowering, the bytes from `RecordConstructOpLowering` show
     exactly one allocation call (`eco_alloc_record_fast` / `_slow`) and
     **zero** calls to `eco_store_record_field*`.
   - Same for customs: one alloc call, no `eco_store_field*` / `eco_set_unboxed`.
   - Same for papCreate: one alloc call (`eco_alloc_closure_k_filled_fast`/`_slow`),
     no closure-`resolve`+packed-store, no per-capture stores. The
     self-capture backpatch survives — assert it's the only `eco.resolve`
     in the lowered fragment.

2. **End-to-end E2E** (`cmake --build build --target full`): must still
   pass at the current baseline. Capture pre-change pass count and
   compare.

3. **Stress tests** (`cmake --build build --target full` with stress
   filter): record current 99/99 baseline; expect no regression.

4. **Stage 7** (manual): with this in place, the
   `consumerIdxLocal = consumerIdx + 0` workaround in
   `compiler/.../Generate/MLIR/Expr.elm` (the SSA-anchoring hack inside
   `buildSiblingData`) should be safe to remove. Remove it in a separate
   commit and verify both Stage 2 and Stage 6 binary MLIR converge on
   the previously diverging tests. This is the only Elm-side workaround
   in this area: there are no other "add 0 to pin an SSA value" patterns
   to clean up.

5. **GC stress with HEAP_VALIDATE**: build with `-DHEAP_VALIDATE=ON` (if
   the OldGen diagnostic-loop hang noted in memory has been resolved by
   then) and rerun. Otherwise rely on the existing nursery validator and
   `ECO_GC_DEBUG=1` for one stress pass.

## Decisions (resolved)

The following were initially open; all are now resolved and folded into
the steps above. Kept here as a short audit trail.

1. **Symmetric `_filled` naming** for all three helpers
   (`eco_alloc_record_filled`, `eco_alloc_custom_filled`,
   `eco_alloc_closure_k_filled`) plus matching `_fast`/`_slow` variants.
   The existing `eco_alloc_record` / `eco_alloc_custom` decls in
   `EcoToLLVMRuntime.cpp` become orphan after Step 2 and are removed in
   a follow-up commit; `eco_alloc_closure{,_k}` stay because
   `AllocateClosureOpLowering` still uses them.
2. **GC root range stays in the MLIR→LLVM lowering**, using
   `eco_gc_stack_range_point` / `eco_gc_push_stack_range` /
   `eco_gc_restore_stack_range_point` (mirroring `PapCreateGroupOpLowering`).
   Runtime helpers stay leaf-simple — they don't know which slots are
   HPointers.
3. **Self-capture backpatch stays in the lowering** (Step 5.10).
4. **`_fast` / `_slow` split** is mirrored for all three new helpers.
   `_fast` is `gc-leaf-function`, never wrapped in a statepoint by
   RS4GC, returns `0` on bump-pointer failure. `_slow` opens the
   statepoint window, may GC, always succeeds.
5. **Allocas in the current block** (mirrors `PapCreateGroupOpLowering`,
   `emitRootedBoxedArgsArray`). LLVM mem2reg / SROA flattens these;
   hoisting to entry block is left for a follow-up if profiling shows
   it matters.
6. **Bitmap-width handling**: closure header reserves 50 bits for the
   unboxed mask; the newargs kind bitmap also uses 2 bits per slot and
   can hold up to 25 typed slots in those same 50 bits. The two are
   logically distinct — wrap the conversion in a small helper
   (`deriveCaptureHPtrMask`) so we don't accidentally mix "which capture
   slot is an HPointer" with "which arg slot is an HPointer".
7. **`op.get_resultKind()`** is still the correct accessor (confirmed by
   `PapExtendOp` lowering still calling it).
8. **Only one Elm-side workaround** to remove (`consumerIdxLocal = consumerIdx + 0`
   inside `buildSiblingData`). Structural fixes like the Pattern A Bool
   unbox are legitimate representation work, not workarounds.
9. **`_fast` invariant**: every `_filled_fast` helper must be
   `gc-leaf-function` so no GC can fire between bump-pointer success and
   field init. Document this at the declaration sites.
10. **Customs `scalar_bytes`**: keep the parameter in the new helper for
    parity with `eco_init_custom_at` and forward-compatibility. All
    current call sites pass `0`; the `fields[]` array only covers the
    pointer-sized slots and is unaffected by scalar tails.
