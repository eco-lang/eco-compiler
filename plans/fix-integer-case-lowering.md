# Plan 1 — Fix integer case lowering (`case_kind="int"`) — unboxed scrutinee incorrectly treated as boxed heap value

## Problem

The `eco.case` for `case_kind="int"` receives an **already-unboxed `i64` scrutinee** directly from the Elm compiler. For example, from CaseIntTest.mlir:

```mlir
"func.func"() ({
  ^bb0(%n: i64):          // <-- scrutinee is ALREADY i64, not !eco.value
    ...
    "eco.case"(%n) (...) {_operand_types = [i64], case_kind = "int", tags = array<i64: 1, 2, 0>}
```

But `lowerIntegerOrCharCase` in EcoToLLVMControlFlow.cpp **unconditionally treats the scrutinee as a boxed heap value**:

```cpp
// Current buggy code (lines 108-119):
auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{scrutinee});
Value ptr = resolveCall.getResult();
auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr, ValueRange{offset});
Value unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
```

This calls `resolveHPtr` on a raw integer value (like `1` or `2`), treating it as a heap pointer address, then tries to load memory from that "pointer". This causes **SIGSEGV** at runtime.

## Target behavior

- For `case_kind="int"` with an already-unboxed `i64` scrutinee, use the value directly — do NOT call `resolveHPtr`.
- For `case_kind="chr"` with an already-unboxed `i16` scrutinee, use the value directly.
- Only unbox if the scrutinee is a boxed `!eco.value` (which would be lowered to an i64 heap pointer in LLVM dialect).
- The literal tag values in the `tags` array should be used as switch case values (this part is already correct in the current code).

## Required code changes

### 1A) `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp` — optionally enable SCF lowering for integer cases

The EcoControlFlowToSCF pass currently skips integer cases (lines 351-355):

```cpp
// Integer, char, and string cases don't work well with scf.index_switch.
if (isIntegerCase(op) || isCharCase(op) || isStringCase(op))
    return failure();
```

This is acceptable — integer cases can fall through to CF lowering. However, if SCF lowering is desired for performance, it could be enabled by:

- Casting `i64` scrutinee to `index` type for `scf.index_switch`
- Building case values from the literal tags
- Using the last alternative as default

This is **optional** — the CF lowering path (1B) must work correctly first.

### 1B) `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` — fix `lowerIntegerOrCharCase` to handle unboxed scrutinees

**Where:** `lowerIntegerOrCharCase` function, lines 94-184.

**Change:** Check if the scrutinee is already an integer type before attempting to unbox it.

**Implementation:**

Replace lines 106-124:

```cpp
Value scrutinee = adaptor.getScrutinee();

// Unbox the scrutinee to get the actual integer/char value
// 1. Resolve HPointer to raw pointer
auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{scrutinee});
Value ptr = resolveCall.getResult();

// 2. Offset past header (8 bytes) to get to value field
auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr, ValueRange{offset});

// 3. Load the unboxed value (always i64 for Int, then truncate for Char)
Value unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);

// For char case, truncate to i16
if (!isIntCase) {
    unboxedValue = rewriter.create<LLVM::TruncOp>(loc, i16Ty, unboxedValue);
}
```

With:

```cpp
Value scrutinee = adaptor.getScrutinee();
Value unboxedValue;

// Check if scrutinee is already unboxed (i64 for int, i16 for char)
Type scrutineeType = scrutinee.getType();
if (scrutineeType.isInteger(64)) {
    // Already unboxed i64 - use directly
    unboxedValue = scrutinee;
    // For char case, truncate to i16
    if (!isIntCase) {
        unboxedValue = rewriter.create<LLVM::TruncOp>(loc, i16Ty, unboxedValue);
    }
} else if (scrutineeType.isInteger(16)) {
    // Already unboxed i16 (char) - use directly
    unboxedValue = scrutinee;
    // For int case, extend to i64
    if (isIntCase) {
        unboxedValue = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, unboxedValue);
    }
} else {
    // Boxed eco.value - need to unbox from heap
    // 1. Resolve HPointer to raw pointer
    auto resolveFunc = runtime.getOrCreateResolveHPtr(rewriter);
    auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{scrutinee});
    Value ptr = resolveCall.getResult();

    // 2. Offset past header (8 bytes) to get to value field
    auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
    auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr, ValueRange{offset});

    // 3. Load the unboxed value (always i64 for Int, then truncate for Char)
    unboxedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);

    // For char case, truncate to i16
    if (!isIntCase) {
        unboxedValue = rewriter.create<LLVM::TruncOp>(loc, i16Ty, unboxedValue);
    }
}
```

### 1C) Add/adjust regression tests in `test/codegen/`

Add two tests:
- `test/codegen/eco-case-int-values.mlir`: tags are non-contiguous (e.g. `1, 5, 100`) and verify correct branch.
- `test/codegen/eco-case-int-many-branches.mlir`: 1–7 + default; verify each result.

These prevent regressions.

## Test cases affected

- CaseIntTest.elm (SIGSEGV → should pass)
- CaseManyBranchesTest.elm (wrong output → should pass)
- CaseDefaultTest.elm (currently passes, should continue to pass)
- CaseCharTest.elm (if char scrutinee has similar issue)

## Verification

After applying the fix, run:
```bash
TEST_FILTER=CaseInt cmake --build build --target check
TEST_FILTER=CaseManyBranches cmake --build build --target check
TEST_FILTER=CaseChar cmake --build build --target check
```

All should pass without SIGSEGV or wrong output.
