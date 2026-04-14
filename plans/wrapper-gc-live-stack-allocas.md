# Plan: Stack Allocas for Wrapper GC-Live Values

## Context

Closure wrappers (`__closure_wrapper_*`) emit GC-live operands in `gc.statepoint` bundles,
but the final `__LLVM_StackMaps` section contains **0 GC-live stack locations** for wrapper
frames (only 3 Constant locations: CC, Flags, NumDeoptArgs). The root cause: the gc-live
SSA values are the same as the call-argument SSA values, so the register allocator keeps
them in argument registers and never spills. The GC stack walker therefore never updates
wrapper-frame copies of closure HPointers after relocation, leading to stale pointers
(e.g. the `eco_pap_extend: new_n_values (34) exceeds max_values (1)` crash).

**Fix:** Force each gc-live value through a wrapper-local stack alloca so it has a distinct
SSA identity from the call argument, making the backend assign it a stack slot that appears
in the stackmap.

## Files to Modify

- **`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`** — `getOrCreateWrapper()`, lines ~332-342

## Step-by-Step Plan

### Step 1: Add alloca+store+reload for each gc-live root (lines 332-342)

Replace the current pattern at line 342:

```cpp
// CURRENT (line 342):
liveRoots.push_back(argI64);
```

With an alloca-based indirection:

```cpp
// NEW: force gc-live through a distinct stack slot
auto oneConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty,
    rewriter.getI64IntegerAttr(1));
auto rootAlloca = rewriter.create<LLVM::AllocaOp>(
    loc, ptrTy, i64Ty, oneConst);
rewriter.create<LLVM::StoreOp>(loc, argI64, rootAlloca);
auto gcLiveVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, rootAlloca);
liveRoots.push_back(gcLiveVal);
```

**API reference:** existing AllocaOp usage in same file at line 796:
`rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numNewArgsConst)`

**Note:** The `oneConst` can be hoisted outside the loop (single constant reused for all allocas).

### Step 2: No changes to downstream passes

- `emitWrapperSafepointMarker` (EcoToLLVMRuntime.cpp:628-654) — unchanged; still receives
  `ValueRange liveRoots` of i64 values, converts to `ptr addrspace(1)`, calls
  `__eco_safepoint_marker`.
- `convertSafepointMarkers` / `rewriteGCRootsWithAllocas` (StatepointConversion.cpp) —
  unchanged; Phase 2 creates its own allocas for gc.relocate tracking. Our MLIR-level
  allocas are separate and serve a different purpose (preventing register coalescing).

### Step 3: Verify pass ordering is safe

Confirmed pipeline in `eco-boot.cpp`:
1. MLIR passes (EcoToLLVM emits allocas) — line ~258+
2. `translateToLLVMIR()` — line 577
3. `convertSafepointMarkers()` — line 585 (our allocas survive; no LLVM opts yet)
4. LLVM optimization passes — line 599+ (gc.statepoint is already in place)

The alloca survives from step 2 to step 3 because no LLVM optimization runs between
translation and StatepointConversion. By step 4, the gc.statepoint with gc-live bundle
is already emitted, and LLVM opts preserve gc-live semantics.

## What Does NOT Change

- Call argument construction (`callArgs`) — identical, no ABI change
- `emitWrapperSafepointMarker` — unchanged
- `StatepointConversion` — unchanged
- Runtime GC stack walker — unchanged (already handles Indirect stackmap locations)
- `combined_args` root range registration — unchanged (still works as a separate GC root source)

## Verification

### IR-level checks
1. After `translateToLLVMIR`, inspect a `__closure_wrapper_*` function: each gc-live arg
   should flow through `alloca i64` → `store` → `load` → `inttoptr` → marker arg
2. After `convertSafepointMarkers`, wrapper statepoints should still have gc-live operand
   bundles (count should remain ~47k total)

### Stackmap check
3. After AOT compile, dump `__LLVM_StackMaps` and verify wrapper frames now have
   **Indirect** locations (base=RBP, offset=-NN) instead of only 3 Constants

### E2E regression
4. `cmake --build build --target full` — all existing tests pass
5. Re-run the Stage-7 bootstrap that previously crashed with
   `eco_pap_extend: new_n_values (34) exceeds max_values (1)` — confirm crash is gone

## Resolved Questions

### Q1: Will LLVM optimization passes collapse the alloca+store+reload?

**Resolved: Low risk, verify via stackmap inspection.**

At the IR level, `convertSafepointMarkers` runs before optimization passes (eco-boot.cpp:585
vs 599), so `gc.statepoint` and `"gc-live"` bundles are already materialized when opts run.

The critical concern is the **backend** (SelectionDAG + RA + stackmap emission): as long as
the gc-live root is the load from the alloca and that load is directly used in the `"gc-live"`
bundle, LLVM's statepoint lowering must treat it as a live value at the call site and give it
a physical location. Even if IR-level mem2reg/SROA rewrites the pattern, the resulting value
is still SSA-live across the statepoint, so it *must* get a location.

The real risk isn't "alloca disappears" — it's "value ends up register-only again at the
statepoint". Validate by inspecting final stackmaps after the change.

**Fallbacks if wrapper roots still missing in `__LLVM_StackMaps`:**
1. Add an explicit artificial SSA use *after* the statepoint (e.g. store to a dummy global
   or a second alloca) in debug builds, to see if that changes behavior.
2. Last resort: make the load from the alloca `volatile` so the backend is forced to
   materialize it. Sledgehammer — probably won't be needed.

### Q2: Does StatepointConversion Phase 2 interact correctly with our allocas?

**Resolved: Yes, no conflict.**

Phase 2 treats "whatever i64 values appear in the gc-live bundle" as roots to relocate.
It doesn't care whether those came from `combined_args` loads directly or from our extra
alloca+reload. With Option A:

- The gc-live operand is the reloaded value `%gcLiveVal` from our alloca slot.
- Phase 2 inserts a `gc.relocate` for `%gcLiveVal` after the statepoint.
- Stores the relocated value back into its own alloca (per existing pattern).
- Runs mem2reg and produces SSA phis as needed.

Since `gcLiveVal` is an i64 HPointer just like before, and StatepointConversion already
assumes "roots are arbitrary i64 HPointers", this is mechanically identical from its
perspective. The MLIR-level `rootAlloca` is invisible to Phase 2 (it operates on LLVM IR
allocas it creates itself).

**Verification:** Dump one wrapper's IR after StatepointConversion and confirm the
`gc.statepoint`'s `"gc-live"` bundle references the reloaded SSA value, with a
corresponding `gc.relocate`.

### Q3: Should we also handle the result-boxing safepoint markers?

**Resolved: No extra work needed.**

Lines 412-445 emit additional `emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots)`
calls before boxing the result (eco_alloc_int/float/char). These reuse the same `liveRoots`
vector. Once `liveRoots` holds alloca-backed values, *all* wrapper safepoints (including
result-boxing ones) automatically see the updated roots.

**Verification:** Check one wrapper that has both a main evaluator-call safepoint and a
result-boxing safepoint — ensure both statepoints' `"gc-live"` sets use the alloca-backed
SSA values and both have stackmap entries.

### Q4: Impact on code size and stack frame size?

**Resolved: Negligible.**

One i64 alloca per wrapper argument: 8 bytes each on x86-64. Typical wrapper arities are
1-5, so ~8-40 bytes of extra stack per wrapper frame. Even in worst-case arity scenarios
(dozens of args), this is bounded and only affects wrapper frames — not all calls.
