# Plan: Fix lowerGenericApply to Use Original Types for Boxing Decisions

## Problem

`lowerGenericApply` in `EcoToLLVMClosures.cpp` boxes new args based on **post-conversion LLVM types**. After LLVM type conversion, both `!eco.value` (HPointer) and `Int` become `i64`. The code cannot distinguish them and blindly calls `eco_alloc_int` on every `i64`, **double-boxing** `!eco.value` HPointers.

The evaluator wrapper then unboxes the double-boxed value, extracting the original HPointer's raw bits and misinterpreting them — producing garbage values or crashes.

## Evidence

`ListFoldlTest`: `concat` uses `foldl` with `(++)` callback. All args are `!eco.value` (strings). The LLVM lowering boxes them via `eco_alloc_int` because they're `i64` at LLVM level. The wrapper passes them through (origType is `!eco.value`), but the values are now boxed ElmInt objects containing HPointer bits → output is `8` instead of `"cba"`.

## Root Cause

Line 863-888 of `EcoToLLVMClosures.cpp` (`lowerGenericApply`):
```cpp
if (auto intTy = dyn_cast<IntegerType>(arg.getType())) {
    if (intTy.getWidth() == 64) {
        // Int (i64): box via eco_alloc_int  ← WRONG: also matches !eco.value
```

`arg.getType()` is the post-conversion LLVM type from `adaptor.getNewargs()`. Both `!eco.value` and `Int` are `i64`.

## Fix

Use `op.getNewargs()` (pre-conversion MLIR types) instead of `adaptor.getNewargs()` LLVM types for boxing decisions. This is the same pattern used by the typed path in `emitInlineClosureCall` (line 707-723).

### Single change in `lowerGenericApply`

**Before the loop**, extract original types:
```cpp
SmallVector<Type> origNewArgTypes;
for (auto arg : op.getNewargs()) {
    origNewArgTypes.push_back(arg.getType());
}
```

**Inside the loop**, replace LLVM-type dispatch with original-type dispatch:
```cpp
Type origType = (i < origNewArgTypes.size()) ? origNewArgTypes[i] : Type();

if (origType && isa<eco::ValueType>(origType)) {
    // !eco.value → already HPointer, ptrtoint to i64
    if (isa<LLVM::LLVMPointerType>(arg.getType()))
        arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
} else if (origType && origType.isInteger(64)) {
    // Int → eco_alloc_int
} else if (origType && origType.isF64()) {
    // Float → eco_alloc_float
} else if (origType && isa<IntegerType>(origType) && width < 64) {
    // Char → eco_alloc_char
} else {
    // Fallback: ptrtoint if ptr
}
```

### Files changed

| File | Change |
|------|--------|
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | `lowerGenericApply`: use `op.getNewargs()` original types for boxing decisions |

No other files need changes.
