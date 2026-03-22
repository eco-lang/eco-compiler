# Runtime Codegen Efficiency Issues - Thorough Analysis

## Summary
Conducted a comprehensive exploration of `/work/runtime/src/codegen/` focusing on Passes/ directory for MLIR lowering inefficiencies. Found 12+ categories of efficiency issues ranging from hot-path symbol lookups to repeated type conversions.

## Critical Issues Found

### 1. MULTIPLE LOOKUPS PER WRAPPER CREATION (HIGH IMPACT)
**Location:** `EcoToLLVMClosures.cpp:144-240` (getOrCreateWrapper function)
**Issue:** Performs 4 sequential `module.lookupSymbol()` calls for the same function:
- Line 153: `module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)` 
- Line 164: `module.lookupSymbol<LLVM::LLVMFuncOp>(wrapperName)`
- Line 193: `module.lookupSymbol<func::FuncOp>(funcName)`
- Line 193: `module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)` (second time!)
- Line 201: `module.lookupSymbol<func::FuncOp>(funcName)`
- Line 213: `module.lookupSymbol<LLVM::LLVMFuncOp>(funcName)` (third lookup)

**Problem:** Each `lookupSymbol()` is O(n) on module operations. Called once per papCreate operation. With many closures, compounds significantly.
**Fix:** Cache results or use a single lookup with fallback chain.

### 2. REPEATED CONSTANT CREATION IN LOOPS (HIGH IMPACT)
**Location:** `EcoToLLVMClosures.cpp:448-466` (PapCreateOpLowering loop)
**Issue:**
```cpp
for (size_t i = 0; i < captured.size(); ++i) {
    int64_t valueOffset = layout::ClosureValuesOffset + i * layout::PtrSize;
    auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 
        rewriter.getI64IntegerAttr(valueOffset));  // Creates constant every iteration
    auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, 
        closurePtr, ValueRange{offsetConst});
    ...
}
```
**Problem:** Creates LLVM constant operations for offset calculations that could be computed incrementally.
**Impact:** For closures with many captures (10+), creates unnecessary IR ops.

### 3. REPEATED OFFSET CONSTANT PATTERN (MEDIUM-HIGH IMPACT)
**Locations:** Multiple files
- `EcoToLLVMClosures.cpp:514-517` (emitFastClosureCall)
- `EcoToLLVMClosures.cpp:704-706` (emitInlineClosureCall)
- `EcoToLLVMClosures.cpp:472-476` (self-capture loop)

**Issue:** Same pattern repeated:
```cpp
auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 
    rewriter.getI64IntegerAttr(valueOffset));
auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, 
    closurePtr, ValueRange{offsetConst});
Value loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
```
Appears 10+ times across closure lowering code.

### 4. STRING CONCATENATION FOR WRAPPER NAMES (MEDIUM IMPACT)
**Location:** `EcoToLLVMClosures.cpp:161`
```cpp
std::string wrapperName = ("__closure_wrapper_" + funcName).str();
```
**Issue:** Creates std::string temporary via StringRef operator+ and .str() conversion. Called per papCreate. Could use SmallString<64> or direct concatenation.

### 5. REPEATED MODULE WALKS (MEDIUM IMPACT)
**Locations:**
- `EcoToLLVMGlobals.cpp:550` (createGlobalRootInitFunction): `module.walk([&](LLVM::GlobalOp globalOp)`
- `EcoToLLVM.cpp:248` (runOnOperation): `module.walk([&](func::FuncOp funcOp)`
- `JoinpointNormalization.cpp:164` (runOnOperation): `module.walk([&](JoinpointOp op)`
- `CheckEcoClosureCaptures.cpp:47, 92` (two separate walks)
- `UndefinedFunction.cpp:45, 57` (two walks + std::set operations)
- `EcoControlFlowToSCF.cpp:107` (nested walk inside loop)

**Issue:** Each walk is O(n) on module size. Multiple independent walks could be fused.

### 6. NESTED WALKS IN HOT PATH (HIGH IMPACT)
**Location:** `EcoControlFlowToSCF.cpp:105-112` (containsNestedStringCase)
```cpp
bool containsNestedStringCase(CaseOp op) {
    bool found = false;
    op.walk([&](CaseOp nested) {  // Walk entire case op
        if (nested != op && isStringCase(nested))
            found = true;
    });
    return found;
}
```
Called in pattern matching loop (line 163) for every 2-alternative case. Quadratic complexity if not careful.

### 7. TYPE CONVERSION CALLED REPEATEDLY (MEDIUM IMPACT)
**Location:** `EcoToLLVMClosures.cpp:178-190` (getOrCreateWrapper)
```cpp
for (auto paramType : funcType.getInputs()) {
    origParamTypes.push_back(paramType);
    Type convertedType = typeConverter ? 
        typeConverter->convertType(paramType) : paramType;  // Per-param conversion
    targetParamTypes.push_back(convertedType ? convertedType : paramType);
}
```
Type conversion not cached. If many parameters with same type patterns, repeated work.

### 8. REPEATED GEP + LOAD PATTERN IN UNBOXING (MEDIUM IMPACT)
**Locations:** Multiple hot paths
- `EcoToLLVMClosures.cpp:287-292` (wrapper arg unboxing)
- `EcoToLLVMClosures.cpp:295-300` (Float unboxing)
- `EcoToLLVMClosures.cpp:303-308` (Char unboxing)
- `EcoToLLVMClosures.cpp:764-769` (closure call result unboxing)

Pattern repeated 20+ times with identical structure. Could benefit from helper pattern or macro.

### 9. FREQUENT SMALLVECTOR COPIES (MEDIUM IMPACT)
**Location:** `EcoToLLVMClosures.cpp:271` (getOrCreateWrapper)
```cpp
SmallVector<Value> callArgs;
for (int64_t i = 0; i < arity; ++i) {
    ...
    callArgs.push_back(convertedArg);  // No reserve()
}
```
SmallVector with no reserve() means reallocation per push_back if arity > stack size. Should call `.reserve(arity)` beforehand.

Also in `EcoToLLVMClosures.cpp:510-511`:
```cpp
SmallVector<Value> callArgs;
SmallVector<Type> paramTypes;
// ... then populated without reserve
```

### 10. ORIGFUNCTYPES STRINGMAP LOOKUPS IN HOT PATH (MEDIUM IMPACT)
**Location:** `EcoToLLVMClosures.cpp:178`
```cpp
auto origIt = runtime.origFuncTypes.find(funcName);
```
Called once per wrapper creation. StringMap::find is O(1) amortized but with string hashing overhead. Called potentially hundreds of times per module.

### 11. REPEATED PATTERN MATCHER INSTANTIATION (LOW-MEDIUM IMPACT)
**Location:** `EcoToLLVM.cpp` (passWrapper runOnOperation)
Creates pattern matchers for every operation class in patterns.add<>() calls (lines 324-331). These are created per-pass invocation. Could be refactored.

### 12. NO CACHING OF LAYOUT CONSTANTS (LOW IMPACT)
**Throughout:** Files reference `layout::ClosureValuesOffset`, `layout::HeaderSize` etc. as computed constants. Not cached—recomputed at use time (though compiler likely inlines). Not a significant issue but worth noting.

### 13. REPEATED DYNAMIC LEGALITY CHECKS (MEDIUM IMPACT)
**Location:** `EcoToLLVM.cpp:211-219` (CaseOp dynamic legality)
```cpp
target.addDynamicallyLegalOp<CaseOp>([](CaseOp op) {
    if (op->getParentOfType<scf::IfOp>() || 
        op->getParentOfType<scf::IndexSwitchOp>()) {
        return true;
    }
    return false;
});
```
getParentOfType called per-operation per-pattern-match. Could use cached parent walk.

### 14. VECTOR PUSH_BACK IN LOOP WITHOUT RESERVE (MEDIUM IMPACT)
**Location:** `EcoToLLVMGlobals.cpp:554`
```cpp
SmallVector<LLVM::GlobalOp> ecoGlobals;
module.walk([&](LLVM::GlobalOp globalOp) {
    if (...) {
        ecoGlobals.push_back(globalOp);  // No reserve
    }
});
```

## Severity Ranking

1. **CRITICAL:** Multiple lookupSymbol() calls for same symbol (Issue #1)
2. **HIGH:** Repeated constant creation in loops (Issue #2)
3. **HIGH:** Nested walks in hot paths (Issue #6)
4. **MEDIUM-HIGH:** Repeated offset constant pattern (Issue #3)
5. **MEDIUM:** String concatenation overhead (Issue #4)
6. **MEDIUM:** Module walk fusion opportunities (Issue #5)
7. **MEDIUM:** Unboxing pattern repetition (Issue #8)
8. **MEDIUM:** SmallVector without reserve() (Issues #9, #14)
9. **MEDIUM:** StringMap lookups in hot paths (Issue #10)

## Files Most Affected

1. `EcoToLLVMClosures.cpp` - Most efficiency issues (multiple lookup chains, repeated patterns, string concat)
2. `EcoToLLVM.cpp` - Module walks, dynamic legality checks
3. `EcoToLLVMGlobals.cpp` - Module walks, vector allocations
4. `EcoControlFlowToSCF.cpp` - Nested walks in hot path
5. `JoinpointNormalization.cpp` - Multiple walks

## Recommendations for Fixes

1. Cache first lookupSymbol() result and reuse for fallback chain
2. Add SmallString<64> or StringRef builder for wrapper names
3. Fuse multiple module walks into single pass
4. Extract unboxing pattern to helper function
5. Add .reserve() calls before push_back loops
6. Refactor containsNestedStringCase to early-exit without full walk
7. Consider lazy initialization for runtime function declarations
8. Combine dynamic legality checks into single parent walk
