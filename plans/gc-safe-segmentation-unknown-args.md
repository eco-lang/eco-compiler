# GC-Safe Segmentation-Unknown Args Arrays

## Problem

The `lowerSegmentationUnknown` path in `EcoToLLVMClosures.cpp` builds two parallel
args arrays (typed + boxed) for `eco_apply_segmentation_unknown`. The boxed-args
population loop duplicates the same alloca → zero-init → root → box → store pattern
used in `lowerGenericApply`, but is written independently. This creates:

1. **A real GC-safety hole:** The typed-args loop's "unrooted while partially
   populated" window intersects with potential `eco_alloc_char` calls (or any future
   allocating operation). Our Stage-7 investigation traced stale HPointers to exactly
   this family of call paths. Even if the current typed-args loop appears
   non-allocating after recent fixes, the structural pattern — populate first, root
   later — remains fragile: any future change that adds an allocation to the loop
   re-opens the window silently.
2. **Duplicated boxing logic** across `lowerGenericApply` and `lowerSegmentationUnknown`,
   making GC-safety reasoning harder (two places to audit).
3. **Dead `adjustedBitmap`** variable left over from when Char was boxed in the
   typed-args loop.

### Current Code Layout

- **Typed-args loop** (lines 1068-1081): Populates `typedArgsArray` with raw unboxed
  values (ZExt for Char, PtrToInt for HPointers). Currently non-allocating.
  Rooted *after* the loop (lines 1083-1093).
- **Boxed-args loop** (lines 1105-1142): Populates `boxedArgsArray` with all-boxed
  HPointers via `eco_alloc_*` calls with safepoints. Rooted before population
  (lines 1095-1103).
- **Generic-apply path** (lines 1163-1259): Single all-boxed array using
  `emitPushArgsRootRange` — the "gold standard" pattern.
- **Under-saturated papExtend** (lines 1347-1410): Same typed-args pattern
  (non-allocating loop, root after loop).

## Goals

1. **Extract a shared `emitRootedBoxedArgsArray` helper** that encapsulates the
   alloca → zero-init → root-as-all-HPointers → box-and-populate → return pattern.
2. **Refactor `lowerGenericApply`** to use this helper (pure refactor, no behavior change).
3. **Refactor `lowerSegmentationUnknown`** to use this helper for `boxedArgsArray`,
   with explicit per-array push/restore pairs.
4. **Clean up `adjustedBitmap`**: replace with direct use of `newargsBitmap`.
5. **Verify Char is consistently unboxed** in all typed-args loops.
6. **Add MLIR-level invariant check** for segmentation-unknown call sites.

## Non-Goals

- No changes to runtime C++ signatures (`eco_apply_closure`, `eco_apply_segmentation_unknown`, `eco_pap_extend`).
- No changes to how new args are handled for `eco_closure_call_saturated`.
- No changes to wrapper return boxing (`getOrCreateWrapper`).
- No changes to `emitInlineClosureCall` or `emitFastClosureCall` patterns.
- No ParamKind-aware boxing changes (follow-up work; helper uses `origNewArgTypes`).

---

## Resolved Design Decisions

### Root range restore strategy

Each push gets its own explicit restore. The helper returns `savedDepth`; the caller
is responsible for calling `emitRestoreArgsRootRange` with that token. No reliance on
a single outer save/restore to unwind multiple pushes — too easy to get ordering
wrong or double-restore.

In `lowerSegmentationUnknown`, this means TWO restores in reverse push order:
1. `emitRestoreArgsRootRange(boxed.savedDepth)` — pops boxed range
2. `emitRestoreArgsRootRange(typedSavedDepth)` — pops typed range

The current single-restore pattern (line 1153) must be replaced.

### Float bitcast in typed-args

Confirmed consistent with existing design:
- Unboxed Float captures are stored as raw 64-bit payloads (f64 bit pattern) in `Unboxable` slots.
- `eco_pap_extend` treats unboxed slots as 64-bit payloads, not HPointers — just memcpy 8 bytes.
- `buildEvaluatorArgs` + evaluator wrapper interpret the 64-bit payload as f64 for Float params.
- Confirm in code that `eco_pap_extend` doesn't tag or mask unboxed slots.

### ParamKind readiness

Use `origNewArgTypes` now. The helper is local C++; when ParamKind is ready, change
it to take `SmallVector<uint8_t>` without breaking the runtime ABI. Treat ParamKind
as a follow-up refactor.

### Codegen invariant test

Include a minimal MLIR-level check as part of this work (Step 6). It's a small
amount of work and gives a regression trip-wire on exactly the GC-safety pattern
being fixed.

---

## Plan

### Step 1: Define `BoxedArgsResult` struct and `emitRootedBoxedArgsArray` helper

**File:** `EcoToLLVMClosures.cpp`, near the existing `emitPushArgsRootRange` helper (after line 76).

Add a static struct and function:

```cpp
struct BoxedArgsResult {
    Value array;       // i64* alloca
    Value numArgsVal;  // i64 constant (numNewArgs)
    Value savedDepth;  // saved GC range point — caller MUST restore
};
```

`emitRootedBoxedArgsArray` will:
1. Create `AllocaOp` for `numNewArgs` i64 slots.
2. Call `emitPushArgsRootRange` with all-ones HPointer mask — this zero-inits and
   registers the array in one call (the existing helper already does memset + push).
3. Loop over args, boxing based on `origNewArgTypes`:
   - `eco::ValueType` → PtrToInt (already HPointer)
   - `i64` (Int) → safepoint + `eco_alloc_int`
   - `f64` (Float) → safepoint + `eco_alloc_float`
   - `IntegerType` width < 64 (Char) → safepoint + `eco_alloc_char`
   - fallback pointer → PtrToInt
4. Store each boxed value into the array slot.
5. Return `{array, numArgsConst, savedDepth}`.

**Parameters:**
```cpp
static BoxedArgsResult emitRootedBoxedArgsArray(
    ConversionPatternRewriter &rewriter, Location loc,
    const EcoRuntime &runtime,
    ValueRange newargs,
    ArrayRef<Type> origNewArgTypes,
    ValueRange liveRoots,
    Operation *safeOp);
```

**Key design decision:** The helper calls `emitPushArgsRootRange` which already
does zero-init + push. This means we reuse the existing proven pattern exactly,
not a new one. The helper returns `savedDepth`; caller MUST call
`emitRestoreArgsRootRange(savedDepth)` after the runtime call completes.

### Step 2: Refactor `lowerGenericApply` to use the helper

**File:** `EcoToLLVMClosures.cpp`, lines 1163-1259.

Replace:
- Lines 1177-1184 (alloca + `emitPushArgsRootRange`)
- Lines 1189-1193 (origNewArgTypes collection)
- Lines 1195-1244 (boxing loop)

With:
```cpp
SmallVector<Type> origNewArgTypes;
auto origNewargs = op.getNewargs();
for (size_t i = 0; i < newargs.size(); ++i)
    origNewArgTypes.push_back(origNewargs[i].getType());

auto boxed = emitRootedBoxedArgsArray(
    rewriter, loc, runtime, newargs, origNewArgTypes, liveRoots, op);
```

Keep the `eco_apply_closure` call using `boxed.array` and a truncated i32 count.
Restore with `emitRestoreArgsRootRange(rewriter, loc, runtime, boxed.savedDepth)`.

**Validation:** Pure refactor. Generated LLVM IR should be identical.

### Step 3: Refactor `lowerSegmentationUnknown` to use the helper + explicit push/restore pairs

**File:** `EcoToLLVMClosures.cpp`, lines 1021-1157.

The refactored structure becomes:

```
1. Alloca typedArgsArray only (remove boxedArgsArray alloca)
2. Zero-init typedArgsArray only (remove boxedArgsArray memset)
3. Populate typed-args loop (no allocs — unchanged)
4. Save typedSavedDepth via emitPushArgsRootRange for typedArgsArray
   (mask = ~newargsBitmap & countMask)
5. Call emitRootedBoxedArgsArray → boxed
   (helper internally: alloca + zero-init + push root range + populate with boxing)
6. Call eco_apply_segmentation_unknown(closure, typedArgsArray, numArgs, bitmap, boxed.array)
7. emitRestoreArgsRootRange(boxed.savedDepth)   — pops boxed range
8. emitRestoreArgsRootRange(typedSavedDepth)     — pops typed range
```

**Changes from current code:**
- Remove: boxedArgsArray alloca (line 1045), boxedArgsArray memset (line 1053),
  single outer savedRangePoint (line 1058), boxedArgsArray root push (lines 1095-1103),
  entire boxed-args population loop (lines 1105-1142), single restore (line 1153).
- Add: typed-args gets its own `emitPushArgsRootRange` call (replacing the manual
  push at lines 1086-1093) — this also handles its zero-init.
- Add: `emitRootedBoxedArgsArray` call for boxed args.
- Add: two explicit restores in reverse push order.

**Key invariant:** `typedArgsArray` is rooted (step 4) BEFORE `emitRootedBoxedArgsArray`
is called (step 5), because the helper's boxing calls can trigger GC.

**Typed-args alloca + root refactoring detail:** Currently the typed-args array is
alloca'd and memset'd manually (lines 1043-1054), then rooted with a manual push
(lines 1086-1093). We can simplify by using `emitPushArgsRootRange` for the typed
array too — it handles zero-init + push. The typed-args alloca stays separate
(before the population loop), but the zero-init + push moves into the
`emitPushArgsRootRange` call after the loop:

```cpp
// Alloca for typed args
Value typedArgsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsI64);

// Populate typed-args loop (no allocs, no safepoints)
// ... loop stores raw values ...

// Root typed array with correct HPointer mask
uint64_t countMask = (numNewArgs >= 64) ? ~0ULL : ((1ULL << numNewArgs) - 1);
uint64_t typedHPtrMask = ~newargsBitmap & countMask;
Value typedSavedDepth = emitPushArgsRootRange(
    rewriter, loc, runtime, typedArgsArray, numNewArgs, typedHPtrMask);
```

Wait — `emitPushArgsRootRange` does zero-init first, which would overwrite the
values we just stored. So we need to either:
- (a) Zero-init the typed array manually BEFORE the loop, then do a manual push
  (no zero-init) after the loop.
- (b) Split `emitPushArgsRootRange` into separate zero-init and push helpers.

**Decision:** Keep the manual zero-init before the typed-args loop (as today), then
do a manual push after the loop (as today). Don't use `emitPushArgsRootRange` for
the typed array since its built-in zero-init would clobber the populated values.
Only use `emitRootedBoxedArgsArray` (which calls `emitPushArgsRootRange` internally)
for the boxed array, where zero-init happens before population.

Revised structure:
```
1. Alloca typedArgsArray
2. Manual memset zero typedArgsArray
3. Populate typed-args loop (no allocs)
4. Manual push typed root range (no zero-init) → typedSavedDepth
5. emitRootedBoxedArgsArray → boxed (alloca + zero-init + push + populate)
6. Call eco_apply_segmentation_unknown
7. emitRestoreArgsRootRange(boxed.savedDepth)
8. emitRestoreArgsRootRange(typedSavedDepth)
```

For step 4, we need a push-only helper (no zero-init). Extract from
`emitPushArgsRootRange` or just inline the push calls as the current code does
(lines 1086-1093). Since this is only ~6 lines of code, inlining is fine.

Alternatively, add a small `emitPushRootRangeOnly` helper that skips zero-init.

### Step 4: Clean up `adjustedBitmap` in `lowerSegmentationUnknown`

**File:** `EcoToLLVMClosures.cpp`, line 1067.

`adjustedBitmap` is initialized to `newargsBitmap` and never modified. Replace all
uses with `newargsBitmap` and delete the variable.

Affected lines:
- Line 1067: `uint64_t adjustedBitmap = newargsBitmap;` → delete
- Line 1085: `~adjustedBitmap & countMask` → `~newargsBitmap & countMask`
- Line 1147: `adjustedBitmap` in bitmap constant → `newargsBitmap`

### Step 5: Verify Char handling in under-saturated papExtend path

**File:** `EcoToLLVMClosures.cpp`, lines 1347-1410.

Verify that the typed-args loop (lines 1370-1383) treats Char identically to the
segmentation-unknown typed-args loop:
- Char (i16) → ZExt to i64, bitmap bit stays set as unboxed.
- No `eco_alloc_char` call.
- Array rooted after loop with `~newargsBitmap & countMask`.

**Current code confirms this is already correct** (lines 1376-1380). No changes
needed, just document the consistency.

Also verify that `eco_pap_extend` does not tag or mask unboxed slots — it should
just memcpy 8 bytes for unboxed Float/Int/Char payloads.

### Step 6: Add MLIR-level invariant check for segmentation-unknown call sites

Add a minimal verification check that at every `eco_apply_segmentation_unknown` site:

1. The `boxed_args` array is rooted (via GC root range push) and all slots are
   treated as HPointers (all-ones mask for the array's size).
2. The `typed_args` root mask matches `unboxed_bitmap` — only non-unboxed slots
   are marked as HPointers in the mask (i.e., `mask == ~unboxed_bitmap & countMask`).

This provides a regression trip-wire on the GC-safety pattern.

### Step 7: Run tests

1. Build and run full E2E suite:
   ```bash
   cmake --build build --target full
   ```

2. Run compiler front-end tests:
   ```bash
   cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
   ```

3. Optionally inspect generated LLVM IR for a segmentation-unknown call site to
   confirm the expected structure (typed loop has no `eco_alloc_*`, boxed uses
   shared helper, root ranges pushed/popped in correct order).

---

## Key Files

| File | Lines | What |
|------|-------|------|
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | 41-76 | Existing GC root range helpers |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | 1021-1157 | `lowerSegmentationUnknown` |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | 1163-1259 | `lowerGenericApply` |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | 1347-1410 | Under-saturated papExtend |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | 253-255 | GC runtime function getters |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | 414-427 | GC runtime function impls |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | 594-622 | `emitSafepointMarker` |
| `runtime/src/allocator/RuntimeExports.h` | 206, 235 | Runtime C signatures |
| `runtime/src/allocator/RuntimeExports.cpp` | 828-876 | `buildEvaluatorArgs` |

## Assumptions

- `emitPushArgsRootRange` does both zero-init and GC registration, so
  `emitRootedBoxedArgsArray` can delegate to it for the boxed array.
- For the typed array, zero-init must happen before the population loop, so we
  cannot use `emitPushArgsRootRange` (it would clobber stored values). Manual
  memset + manual push is required.
- The `emitSafepointMarker` signature `(Operation*, ConversionPatternRewriter&,
  const EcoRuntime&, ValueRange)` is compatible with the helper's parameters.
- The under-saturated papExtend path (lines 1347-1410) is already consistent with
  the typed-args pattern and needs no functional changes.
