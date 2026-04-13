# GC-Safe Closure Wrappers

## Problem

Closure wrapper functions (`__closure_wrapper_*`) generated in `getOrCreateWrapper()` 
(EcoToLLVMClosures.cpp:203-442) are not GC-safe. They contain calls that can trigger GC:
- The target Elm function call (line 388)
- `eco_alloc_int/float/char` for result boxing (lines 402-414, 421-430)

But they emit **no `__eco_safepoint_marker` calls**, so StatepointConversion never wraps
these calls in `gc.statepoint`. This means HPointer values loaded from the args array 
are invisible to GC — if GC triggers during the target call or boxing allocation, those
HPointers become stale.

**Note:** The GC strategy attribute (`"statepoint-example"`) is already applied to wrappers
by the post-conversion walk at EcoToLLVM.cpp:349-352. The only missing piece is safepoint 
markers inside the wrapper body.

## Files to Modify

| File | Change |
|------|--------|
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Add safepoint markers in `getOrCreateWrapper` |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | Add `emitWrapperSafepointMarker` helper declaration |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | Implement helper |
| `runtime/src/allocator/RuntimeExports.h` | Document `eco_resolve_hptr` non-allocating invariant |
| `runtime/src/allocator/RuntimeExports.cpp` | Optional: debug assert in `eco_resolve_hptr` |
| `runtime/src/allocator/Allocator.hpp` | Optional: `NoGCGuard` RAII helper (debug only) |

---

## Step-by-step Plan

### Step 1: Add `emitWrapperSafepointMarker` helper

**Why a new helper?** The existing `emitSafepointMarker` (EcoToLLVMRuntime.cpp:594) requires 
`ConversionPatternRewriter &` and `Operation *op`. Inside `getOrCreateWrapper`, we have a 
`PatternRewriter &` and no source op (we're building a new function body). A simpler helper 
that takes `OpBuilder &` and `Location` avoids coupling to the conversion framework.

**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h`

Declare in `namespace eco::detail`:
```cpp
/// Emit __eco_safepoint_marker in a wrapper function body.
/// liveRoots: i64 SSA values representing HPointers that must survive GC.
void emitWrapperSafepointMarker(
    mlir::OpBuilder &builder,
    const EcoRuntime &runtime,
    mlir::Location loc,
    mlir::ValueRange liveRoots);
```

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` (near line 622, after `emitSafepointMarker`)

Implementation — mirrors `emitSafepointMarker` but uses `OpBuilder`:
```cpp
void eco::detail::emitWrapperSafepointMarker(
    OpBuilder &builder,
    const EcoRuntime &runtime,
    Location loc,
    ValueRange liveRoots) {

    if (liveRoots.empty()) return;

    auto *ctx = builder.getContext();
    auto gcPtrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);

    SmallVector<Value, 4> gcPtrs;
    for (auto val : liveRoots) {
        auto ptr = builder.create<LLVM::IntToPtrOp>(loc, gcPtrTy, val);
        gcPtrs.push_back(ptr);
    }

    runtime.getOrCreateSafepointMarker(builder);

    auto voidTy = LLVM::LLVMVoidType::get(ctx);
    auto markerFuncTy = LLVM::LLVMFunctionType::get(voidTy, {}, /*isVarArg=*/true);

    builder.create<LLVM::CallOp>(
        loc, markerFuncTy,
        FlatSymbolRefAttr::get(ctx, "__eco_safepoint_marker"),
        gcPtrs);
}
```

### Step 2: Track live HPointer roots in `getOrCreateWrapper`

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`  
**Function:** `getOrCreateWrapper` (lines 203-442)

After line 316 (`Value argsArray = ...`), add:
```cpp
SmallVector<Value, 8> liveRoots;
```

In the arg-loading loop (lines 333-383), after loading each `argI64` at line 336,
add all loaded HPointers to `liveRoots` unconditionally:
```cpp
liveRoots.push_back(argI64);
```

**Rationale:** Only `!eco.value` args are strictly live HPointers across the target call
(primitive args are fully unboxed before the call and dead after). However, including 
primitive-arg HPointers is conservative and safe — the only cost is slightly larger 
stackmaps. This keeps the logic simple and avoids subtle bugs if the unboxing order 
ever changes.

### Step 3: Emit safepoint marker before target function call

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`  
**Location:** Before line 388 (the `CallOp` to the target function)

Insert:
```cpp
emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);
```

The existing call at line 388 (`rewriter.create<LLVM::CallOp>(...)`) stays as-is.
StatepointConversion's `findTargetCall` (StatepointConversion.cpp:149) will find this 
call immediately after the marker and wrap it in `gc.statepoint`.

### Step 4: Emit safepoint markers before boxing allocation calls

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`  
**Locations:** Before each `eco_alloc_*` call in the result-boxing section (lines 400-434)

Before each boxing `CallOp`, emit a safepoint marker with the full `liveRoots`:
```cpp
emitWrapperSafepointMarker(rewriter, runtime, loc, liveRoots);
```

There are 5 boxing call sites:
1. Line 403: `eco_alloc_int` (Int result with origType)
2. Line 408: `eco_alloc_float` (Float result with origType)  
3. Line 414: `eco_alloc_char` (Char result with origType)
4. Line 422: `eco_alloc_float` (fallback, no origType)
5. Line 429: `eco_alloc_char` (fallback, no origType)

**Rationale:** Boxing calls are GC-capable (they call `Allocator::allocate`). While 
the arg HPointers have been consumed by the target call, the closure and other args 
in the wrapper frame are still live. Passing the full `liveRoots` is conservative but 
correct — StatepointConversion will generate relocates for any roots it sees, and 
the cost of slightly larger stackmaps is negligible compared to the safety guarantee.

### Step 5: Audit for other wrapper-like generators

**Action:** Search for other code paths that generate LLVM IR functions directly 
(bypassing Eco IR) and call into Elm code or GC-capable runtime functions without 
going through `emitSafepointMarker` / EcoGCPrepare.

Grep for:
- `getOrCreate*Wrapper` / "trampoline" / "thunk" helpers in `EcoToLLVM*.cpp`
- Any pass that creates `LLVM::LLVMFuncOp` and then emits calls to Elm functions or 
  `eco_alloc_*` without safepoint markers

`PapCreateOpLowering`, `PapExtendOpLowering`, etc. already use `emitSafepointMarker` — 
this step is looking for additional ad-hoc LLVM function generators with the same gap.

### Step 6: Document `eco_resolve_hptr` non-allocating invariant

**File:** `runtime/src/allocator/RuntimeExports.h` (near line 407)

Add documentation comment:
```cpp
/// Convert an HPointer-encoded uint64_t to a raw heap pointer.
///
/// GC INVARIANT: This function MUST NOT allocate or trigger GC.
/// Closure wrappers call eco_resolve_hptr without safepoint markers,
/// relying on it being non-allocating. Any allocation here would
/// require adding safepoints around all ~17k wrapper resolve calls.
extern "C" void* eco_resolve_hptr(uint64_t hptr);
```

### Step 7: Audit `eco_apply_closure` over-saturation path

**File:** `runtime/src/allocator/RuntimeExports.cpp` (lines 874-879)

Audit whether the `intermediate` HPointer returned from `eco_closure_call_saturated` 
is safe from GC before the recursive `eco_apply_closure` call. Specifically check:
- Does `eco_apply_closure` entry perform any allocation, GC poll, or call to 
  GC-capable functions before handling `closure_hptr`?
- Could a safepoint poll at function entry invalidate `intermediate`?

If the gap is unsafe, either root the intermediate HPointer before the recursive call 
or enforce a "no GC here" invariant with a guard.

### Step 8: Optional `NoGCGuard` RAII helper (debug only)

**File:** `runtime/src/allocator/Allocator.hpp`

Add debug-only `NoGCGuard` class and `noGCDepth_` counter to Allocator:
```cpp
#if ECO_DEBUG_GC
class NoGCGuard {
public:
    NoGCGuard();
    ~NoGCGuard();
};
#endif
```

Apply in `eco_apply_closure` over-saturation path and `eco_resolve_hptr` to guard 
no-GC assumptions at runtime in debug builds.

**This step is lowest priority** and can be deferred. It requires introducing the 
`ECO_DEBUG_GC` macro and plumbing it through the build system (CMake).

---

## Verification

After implementing Steps 1-4:

1. **Build:** `cmake --build build --target full`
2. **Check stackmaps:** Verify `__closure_wrapper_*` functions appear in `.llvm_stackmaps` 
   (can dump with `llvm-readobj --stackmap`)
3. **Run E2E tests:** `TEST_FILTER=elm cmake --build build --target full` — no regressions
4. **GC stress test (if available):** Trigger GC inside a shallow Elm function called via 
   a wrapper and verify wrapper frame roots are scanned

---

## Resolved Questions

### Q1: Is a safepoint marker with 0 live roots valid?
**Resolved:** At the LLVM level, a `gc.statepoint` with an empty `gc-live` set is valid.
For correctness, if there are truly no live HPointers across the call, skipping the marker 
is fine. In wrappers, boxing calls DO have live HPointers (closure/args in the wrapper 
frame), so `liveRoots.empty()` should not be true if wired correctly. No need to change 
the early-return behavior in `emitSafepointMarker`.

### Q2: Are primitive-parameter HPointers truly dead before the target call?
**Resolved:** Yes. All primitive arg unboxing happens in the loop before the target call,
and the wrapper re-boxes from the primitive result, not from the original HPointer. Only 
`!eco.value` args are live HPointers across the target call. Including primitive-arg 
HPointers in `liveRoots` is conservative but safe; the main cost is slightly larger stackmaps.

### Q3: Does `getOrCreateSafepointMarker` work with `PatternRewriter &`?
**Resolved:** Yes. It takes `OpBuilder &`, and `PatternRewriter` is a subclass of `OpBuilder`.

### Q4: Will StatepointConversion handle wrappers correctly?
**Resolved:** Yes, provided wrappers contain `__eco_safepoint_marker` calls and are marked 
with `"statepoint-example"` GC attribute. Wrappers already get the GC attribute from the 
post-conversion walk at EcoToLLVM.cpp:349-352. No changes needed in StatepointConversion.

### Q5: Does `ECO_DEBUG_GC` exist as a build macro?
**Resolved:** Not blocking for core fix (Steps 1-4). If it doesn't exist, it can be 
introduced via CMake for Steps 7-8. Deferred.

### Q6: Are there other wrapper-like generators besides `getOrCreateWrapper`?
**Resolved:** Added as Step 5 (audit). Any code that generates LLVM IR functions directly 
and calls into Elm code or GC-capable runtime functions must be audited the same way. 
`PapCreateOpLowering`, `PapExtendOpLowering`, etc. already use `emitSafepointMarker`.

### Q7: Over-saturation in `eco_apply_closure` — is the gap truly safe?
**Resolved:** Needs real code audit (Step 7). Safe only if there is no GC opportunity 
between `eco_closure_call_saturated` return and the recursive `eco_apply_closure` 
handling of `closure_hptr`. If `eco_apply_closure` entry does NOT perform any allocation, 
GC poll, or GC-capable call before handling the first argument, the gap is OK. If there 
is (or might later be) such work, the gap is unsafe and needs either rooting the 
intermediate HPointer or a `NoGCGuard`.

### Q8: Should boxing use fast-alloc variants?
**Resolved:** Not as the primary correctness mechanism. Even if fast-alloc boxing 
eliminates GC at boxing sites, safepoints are still needed around the target Elm function 
call. Relying on "fast alloc never GC" is fragile — if someone later introduces a slow 
path or GC check, wrappers silently become unsafe. Implement safepoints for wrappers 
(covers both target call and boxing), then consider fast-alloc boxing as an optional 
optimization later.
