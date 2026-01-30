# Plan: Fix eco.yield SCF Lowering for Int/Char/String Cases

## Problem Statement

The error `failed to legalize operation 'eco.yield'` occurs for multi-way (>2 alternatives) int/char/string case expressions because:

1. `EcoControlFlowToSCF.cpp` explicitly rejects these cases at line 319:
   ```cpp
   if (isIntegerCase(op) || isCharCase(op) || isStringCase(op))
       return failure();
   ```
2. These rejected cases fall through to `CaseOpLowering` in `EcoToLLVMControlFlow.cpp`
3. `CaseOpLowering` only handles `eco.return` terminators, not `eco.yield`
4. No pattern exists to lower `eco::YieldOp` directly

**Failing tests:** CaseCharTest, CaseIntTest, CaseStringTest, CaseStringEscapeTest, CaseUnicodeCharTest, CaseManyBranchesTest

## Solution Overview

Extend `EcoControlFlowToSCF` to handle int/char/string cases:
- **Char cases:** Use `scf.index_switch` with `arith.index_cast` (sparse values are fine)
- **Int cases:** Use `scf.index_switch` if all tags are non-negative, otherwise use comparison chain
- **String cases:** Use nested `scf.if` comparison chain with equality calls

## Design Decisions

### D1: Char Cases → `scf.index_switch`
`scf.index_switch` does *not* require dense cases; it's an equality dispatch on an `index` selector. Sparse values like 97/101/105 ('a'/'e'/'i') work fine. Insert `arith.index_cast` from `i16` to `index`.

### D2: Int Cases → Conditional
- If all tags are non-negative: use `scf.index_switch` with `arith.index_cast` from `i64` to `index`
- Otherwise: use comparison chain (nested `scf.if`)

### D3: String Cases → Comparison Chain
Lower to nested `scf.if` with string equality comparisons. This keeps "Eco→SCF" as the single place that understands `eco.yield`.

### D4: Joinpoint Restriction → Keep for Now
Keep "don't lower `eco.case` inside joinpoint bodies" as long as joinpoints exist. The longer-term goal is to eliminate joinpoints by generating `scf.while` directly for tail recursion.

## Implementation Steps

### Step 1: Enable Char Cases in `CaseToScfIndexSwitchPattern`

**File:** `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

Modify `CaseToScfIndexSwitchPattern::matchAndRewrite` to allow char cases:

```cpp
// OLD (line 317-320):
if (isIntegerCase(op) || isCharCase(op) || isStringCase(op))
    return failure();

// NEW:
// String cases need comparison chain, not index_switch
if (isStringCase(op))
    return failure();

// Int cases: only use index_switch if all tags are non-negative
if (isIntegerCase(op)) {
    ArrayRef<int64_t> tags = op.getTags();
    for (int64_t tag : tags) {
        if (tag < 0)
            return failure();  // Fall through to comparison chain
    }
}
// Char cases: always OK (codepoints are non-negative)
```

Update the selector computation for char/int:

```cpp
Value indexTag;
if (isCharCase(op)) {
    // Unbox to i16, then cast to index
    auto i16Ty = rewriter.getIntegerType(16);
    auto unboxed = rewriter.create<UnboxOp>(loc, i16Ty, op.getScrutinee());
    indexTag = rewriter.create<arith::IndexCastOp>(loc, rewriter.getIndexType(), unboxed);
} else if (isIntegerCase(op)) {
    // Unbox to i64, then cast to index
    auto i64Ty = rewriter.getI64Type();
    auto unboxed = rewriter.create<UnboxOp>(loc, i64Ty, op.getScrutinee());
    indexTag = rewriter.create<arith::IndexCastOp>(loc, rewriter.getIndexType(), unboxed);
} else {
    // ADT case: extract tag and cast to index
    auto tag = rewriter.create<GetTagOp>(loc, rewriter.getI32Type(), op.getScrutinee());
    indexTag = rewriter.create<arith::IndexCastOp>(loc, rewriter.getIndexType(), tag);
}
```

### Step 2: Add `CaseToScfIfChainPattern` for String and Negative-Int Cases

**File:** `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

Add new pattern for comparison chains:

```cpp
/// Lowers eco.case to nested scf.if chain for string cases and int cases with negative tags.
/// Each alternative (except the last default) becomes an equality comparison.
struct CaseToScfIfChainPattern : public OpRewritePattern<CaseOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(CaseOp op,
                                  PatternRewriter &rewriter) const override {
        auto alts = op.getAlternatives();

        // Need >2 alternatives (2-way handled by CaseToScfIfPattern)
        if (alts.size() <= 2)
            return failure();

        // Only handle string cases OR int cases with negative tags
        bool isStr = isStringCase(op);
        bool isNegativeInt = false;
        if (isIntegerCase(op)) {
            for (int64_t tag : op.getTags()) {
                if (tag < 0) {
                    isNegativeInt = true;
                    break;
                }
            }
        }
        if (!isStr && !isNegativeInt)
            return failure();

        // All alternatives must end with eco.yield
        if (!hasPureYieldAlternatives(op))
            return failure();

        // Skip cases inside joinpoint bodies
        if (op->getParentOfType<JoinpointOp>())
            return failure();

        auto loc = op.getLoc();
        auto resultTypes = getCaseResultTypes(op);

        if (isStr) {
            return lowerStringCaseToIfChain(op, rewriter, loc, resultTypes);
        } else {
            return lowerIntCaseToIfChain(op, rewriter, loc, resultTypes);
        }
    }

private:
    LogicalResult lowerIntCaseToIfChain(CaseOp op, PatternRewriter &rewriter,
                                        Location loc, SmallVector<Type> &resultTypes) const;
    LogicalResult lowerStringCaseToIfChain(CaseOp op, PatternRewriter &rewriter,
                                           Location loc, SmallVector<Type> &resultTypes) const;
};
```

### Step 3: Implement Int Comparison Chain

For int cases with negative tags, build nested `scf.if`:

```cpp
LogicalResult CaseToScfIfChainPattern::lowerIntCaseToIfChain(
    CaseOp op, PatternRewriter &rewriter,
    Location loc, SmallVector<Type> &resultTypes) const {

    auto alts = op.getAlternatives();
    auto tags = op.getTags();
    auto i64Ty = rewriter.getI64Type();

    // Unbox scrutinee
    Value unboxed = rewriter.create<UnboxOp>(loc, i64Ty, op.getScrutinee());

    // Build chain from last to first (last alt is default)
    // Start with default (last alternative)
    size_t numAlts = alts.size();

    // Clone default alternative body with eco.yield -> scf.yield
    // Then wrap each preceding alternative as scf.if(cmp) { alt } else { inner }

    // ... recursive chain building ...

    rewriter.replaceOp(op, chainResult);
    return success();
}
```

### Step 4: Implement String Comparison Chain

For string cases, use equality comparison:

```cpp
LogicalResult CaseToScfIfChainPattern::lowerStringCaseToIfChain(
    CaseOp op, PatternRewriter &rewriter,
    Location loc, SmallVector<Type> &resultTypes) const {

    auto alts = op.getAlternatives();
    auto stringPatternsAttr = op.getStringPatternsAttr();
    if (!stringPatternsAttr)
        return op.emitOpError("string case missing string_patterns attribute");

    Value scrutinee = op.getScrutinee();

    // Build chain: for each pattern, compare and branch
    // Use eco.call @Elm_Kernel_Utils_equal or similar
    // ... chain building similar to int case ...

    rewriter.replaceOp(op, chainResult);
    return success();
}
```

### Step 5: Register New Pattern

**File:** `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`

In `EcoControlFlowToSCFPass::runOnOperation()`:

```cpp
// Add patterns in priority order:
patterns.add<JoinpointToScfWhilePattern>(ctx, /*benefit=*/10);
patterns.add<CaseToScfIfPattern>(ctx, /*benefit=*/5);
patterns.add<CaseToScfIndexSwitchPattern>(ctx, /*benefit=*/5);
patterns.add<CaseToScfIfChainPattern>(ctx, /*benefit=*/4);  // NEW: lower priority
```

### Step 6: Add Safety Net Error for Unlowered YieldOp

**File:** `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`

Add pattern that emits clear error if `eco::YieldOp` survives:

```cpp
struct YieldOpLowering : public OpConversionPattern<YieldOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(YieldOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        return op.emitError("eco.yield should have been lowered by EcoControlFlowToSCF; "
                           "this indicates a missing pattern for the parent eco.case");
    }
};
```

Register in `populateEcoControlFlowPatterns()`.

### Step 7: Add MLIR-Level Tests

**File:** `test/codegen/eco_case_to_scf.mlir` (new)

Add targeted tests for each pattern:

```mlir
// RUN: ecor-opt %s -eco-cf-to-scf | FileCheck %s

// CHECK-LABEL: func @test_bool_case_to_scf_if
// CHECK: scf.if
// CHECK: scf.yield
func @test_bool_case_to_scf_if(%cond: i1) -> !eco.value {
  %result = eco.case %cond [0, 1] -> (!eco.value) {case_kind = "bool"} {
    %false_val = eco.const_false
    eco.yield %false_val : !eco.value
  }, {
    %true_val = eco.const_true
    eco.yield %true_val : !eco.value
  }
  eco.return %result : !eco.value
}

// CHECK-LABEL: func @test_char_case_to_index_switch
// CHECK: arith.index_cast
// CHECK: scf.index_switch
func @test_char_case_to_index_switch(%val: !eco.value) -> !eco.value {
  // case 'a'=97, 'e'=101, 'i'=105, default
  %result = eco.case %val [97, 101, 105, -1] -> (!eco.value) {case_kind = "chr"} {
    // ... alternatives with eco.yield ...
  }
  eco.return %result : !eco.value
}

// CHECK-LABEL: func @test_string_case_to_if_chain
// CHECK: scf.if
// CHECK: scf.if
func @test_string_case_to_if_chain(%val: !eco.value) -> !eco.value {
  %result = eco.case %val [0, 1, 2] -> (!eco.value)
      {case_kind = "str", string_patterns = ["hello", "world"]} {
    // ... alternatives with eco.yield ...
  }
  eco.return %result : !eco.value
}
```

## Testing

After implementation, verify:
```bash
# Targeted tests
TEST_FILTER=CaseChar cmake --build build --target check
TEST_FILTER=CaseInt cmake --build build --target check
TEST_FILTER=CaseString cmake --build build --target check
TEST_FILTER=CaseManyBranches cmake --build build --target check

# Full test suite
TEST_FILTER=elm-core cmake --build build --target check
```

## Files to Modify

1. **`runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`**
   - Modify `CaseToScfIndexSwitchPattern` to allow char cases and non-negative int cases
   - Add selector computation for char/int (unbox + index_cast)
   - Add `CaseToScfIfChainPattern` for string and negative-int cases
   - Register new pattern

2. **`runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp`**
   - Add `YieldOpLowering` safety pattern
   - Register in `populateEcoControlFlowPatterns()`

3. **`test/codegen/eco_case_to_scf.mlir`** (new)
   - Add MLIR-level tests for each lowering pattern

## Complexity Estimate

| Component | Lines |
|-----------|-------|
| Modify `CaseToScfIndexSwitchPattern` for char/int | ~30 |
| `CaseToScfIfChainPattern` structure | ~40 |
| `lowerIntCaseToIfChain` | ~60 |
| `lowerStringCaseToIfChain` | ~80 |
| `YieldOpLowering` safety net | ~15 |
| MLIR tests | ~80 |
| **Total** | **~305 lines** |
