# Eco Arithmetic Operations Plan

## Overview

Implement eco-specific MLIR operations for all Elm arithmetic primitives. These ops work on **unboxed primitives** (i64, f64) and encapsulate Elm's specific arithmetic semantics, making future behavior changes easy.

## Design Principles

1. **All arithmetic through eco ops** - Even standard operations like `add` go through eco ops for consistency and future flexibility
2. **Unboxed primitives** - Ops work on i64/f64, not eco.value; boxing happens at boundaries
3. **Elm semantics baked in** - Division by zero returns 0, modBy uses floored division, etc.
4. **Pure operations** - All arithmetic ops are marked Pure for optimization

## Elm Arithmetic Reference

### Elm's Basics Module Functions

| Elm Function | Type | Elm Semantics |
|--------------|------|---------------|
| `(+)` | `number -> number -> number` | Standard addition |
| `(-)` | `number -> number -> number` | Standard subtraction |
| `(*)` | `number -> number -> number` | Standard multiplication |
| `(/)` | `Float -> Float -> Float` | Float division (IEEE 754) |
| `(//)` | `Int -> Int -> Int` | Integer division, **0 on div-by-zero** |
| `(^)` | `number -> number -> number` | Exponentiation |
| `negate` | `number -> number` | Unary negation |
| `abs` | `number -> number` | Absolute value |
| `modBy` | `Int -> Int -> Int` | Floored (Euclidean) modulo |
| `remainderBy` | `Int -> Int -> Int` | Truncated modulo |
| `toFloat` | `Int -> Float` | Int to Float conversion |
| `round` | `Float -> Int` | Round to nearest |
| `floor` | `Float -> Int` | Round down |
| `ceiling` | `Float -> Int` | Round up |
| `truncate` | `Float -> Int` | Round toward zero |

### Comparison Operations

| Elm Function | Type | Notes |
|--------------|------|-------|
| `(<)` | `comparable -> comparable -> Bool` | Less than |
| `(>)` | `comparable -> comparable -> Bool` | Greater than |
| `(<=)` | `comparable -> comparable -> Bool` | Less or equal |
| `(>=)` | `comparable -> comparable -> Bool` | Greater or equal |
| `max` | `comparable -> comparable -> comparable` | Maximum |
| `min` | `comparable -> comparable -> comparable` | Minimum |

### Bitwise Operations (Bitwise module)

| Elm Function | Type | Notes |
|--------------|------|-------|
| `and` | `Int -> Int -> Int` | Bitwise AND |
| `or` | `Int -> Int -> Int` | Bitwise OR |
| `xor` | `Int -> Int -> Int` | Bitwise XOR |
| `complement` | `Int -> Int` | Bitwise NOT |
| `shiftLeftBy` | `Int -> Int -> Int` | Left shift |
| `shiftRightBy` | `Int -> Int -> Int` | Arithmetic right shift |
| `shiftRightZfBy` | `Int -> Int -> Int` | Logical right shift |

## Phase 1: Core Integer Arithmetic

### Ops.td Additions

```tablegen
//===----------------------------------------------------------------------===//
// Eco Integer Arithmetic Operations
//===----------------------------------------------------------------------===//

def Eco_AddIntOp : Eco_Op<"int.add", [Pure, Commutative]> {
  let summary = "Elm integer addition";
  let description = [{
    Add two 64-bit signed integers. Standard addition semantics.

    Example:
    ```mlir
    %sum = eco.int.add %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_SubIntOp : Eco_Op<"int.sub", [Pure]> {
  let summary = "Elm integer subtraction";
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_MulIntOp : Eco_Op<"int.mul", [Pure, Commutative]> {
  let summary = "Elm integer multiplication";
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_DivIntOp : Eco_Op<"int.div", [Pure]> {
  let summary = "Elm integer division (returns 0 on divide-by-zero)";
  let description = [{
    Integer division with Elm semantics: division by zero returns 0
    instead of throwing an exception.

    Example:
    ```mlir
    %quot = eco.int.div %a, %b : i64  // If b == 0, returns 0
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_ModByOp : Eco_Op<"int.modby", [Pure]> {
  let summary = "Elm modBy (floored/Euclidean modulo)";
  let description = [{
    Floored modulo operation. Result has same sign as modulus.
    Returns 0 if modulus is 0.

    modBy 4 7 = 3
    modBy 4 (-7) = 1  (not -3)
    modBy (-4) 7 = -1 (not 3)

    Example:
    ```mlir
    %rem = eco.int.modby %modulus, %x : i64
    ```
  }];
  let arguments = (ins Eco_Int:$modulus, Eco_Int:$x);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$modulus `,` $x attr-dict `:` type($result)";
}

def Eco_RemainderByOp : Eco_Op<"int.remainderby", [Pure]> {
  let summary = "Elm remainderBy (truncated modulo)";
  let description = [{
    Truncated modulo operation. Result has same sign as dividend.
    Returns 0 if divisor is 0.

    remainderBy 4 7 = 3
    remainderBy 4 (-7) = -3 (not 1)

    Example:
    ```mlir
    %rem = eco.int.remainderby %divisor, %x : i64
    ```
  }];
  let arguments = (ins Eco_Int:$divisor, Eco_Int:$x);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$divisor `,` $x attr-dict `:` type($result)";
}

def Eco_NegateIntOp : Eco_Op<"int.negate", [Pure]> {
  let summary = "Elm integer negation";
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_AbsIntOp : Eco_Op<"int.abs", [Pure]> {
  let summary = "Elm integer absolute value";
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_PowIntOp : Eco_Op<"int.pow", [Pure]> {
  let summary = "Elm integer exponentiation";
  let description = [{
    Integer exponentiation. Returns 0 if exponent is negative
    (since true result would be fractional, breaking Int type).

    Examples:
      2 ^ 3 = 8
      2 ^ 0 = 1
      2 ^ -1 = 0  (mathematically 0.5, but returns 0 to preserve Int type)
  }];
  let arguments = (ins Eco_Int:$base, Eco_Int:$exp);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$base `,` $exp attr-dict `:` type($result)";
}
```

### EcoToLLVM.cpp Lowerings

```cpp
//===----------------------------------------------------------------------===//
// Integer Arithmetic Lowerings
//===----------------------------------------------------------------------===//

struct AddIntOpLowering : public OpConversionPattern<AddIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(AddIntOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        // Direct lowering to LLVM add
        rewriter.replaceOpWithNewOp<LLVM::AddOp>(
            op, adaptor.getLhs(), adaptor.getRhs());
        return success();
    }
};

struct DivIntOpLowering : public OpConversionPattern<DivIntOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(DivIntOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto i64Ty = rewriter.getI64Type();

        Value lhs = adaptor.getLhs();
        Value rhs = adaptor.getRhs();

        // Check for division by zero
        auto zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        auto isZero = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::eq, rhs, zero);

        // Compute division (will only be used if rhs != 0)
        auto divResult = rewriter.create<LLVM::SDivOp>(loc, lhs, rhs);

        // Select: if zero, return 0; else return division result
        rewriter.replaceOpWithNewOp<LLVM::SelectOp>(
            op, isZero, zero, divResult);
        return success();
    }
};

struct ModByOpLowering : public OpConversionPattern<ModByOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(ModByOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto i64Ty = rewriter.getI64Type();

        Value modulus = adaptor.getModulus();
        Value x = adaptor.getX();

        // Check for modulus == 0
        auto zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
        auto isZero = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::eq, modulus, zero);

        // Compute truncated remainder (C/LLVM semantics)
        auto truncRem = rewriter.create<LLVM::SRemOp>(loc, x, modulus);

        // Convert to floored modulo:
        // If rem != 0 && sign(rem) != sign(modulus), add modulus
        auto remIsZero = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::eq, truncRem, zero);
        auto remNeg = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::slt, truncRem, zero);
        auto modNeg = rewriter.create<LLVM::ICmpOp>(
            loc, LLVM::ICmpPredicate::slt, modulus, zero);
        auto signsDiffer = rewriter.create<LLVM::XOrOp>(loc, remNeg, modNeg);
        auto needsAdjust = rewriter.create<LLVM::AndOp>(loc,
            rewriter.create<LLVM::XOrOp>(loc, remIsZero,
                rewriter.create<LLVM::ConstantOp>(loc, rewriter.getI1Type(), 1)),
            signsDiffer);

        auto adjusted = rewriter.create<LLVM::AddOp>(loc, truncRem, modulus);
        auto flooredRem = rewriter.create<LLVM::SelectOp>(
            loc, needsAdjust, adjusted, truncRem);

        // Select: if modulus == 0, return 0; else return floored remainder
        rewriter.replaceOpWithNewOp<LLVM::SelectOp>(
            op, isZero, zero, flooredRem);
        return success();
    }
};
```

## Phase 2: Float Arithmetic

### Ops.td Additions

```tablegen
//===----------------------------------------------------------------------===//
// Eco Float Arithmetic Operations
//===----------------------------------------------------------------------===//

def Eco_AddFloatOp : Eco_Op<"float.add", [Pure, Commutative]> {
  let summary = "Elm float addition";
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_SubFloatOp : Eco_Op<"float.sub", [Pure]> {
  let summary = "Elm float subtraction";
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_MulFloatOp : Eco_Op<"float.mul", [Pure, Commutative]> {
  let summary = "Elm float multiplication";
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_DivFloatOp : Eco_Op<"float.div", [Pure]> {
  let summary = "Elm float division (IEEE 754 semantics)";
  let description = [{
    Float division with IEEE 754 semantics.
    Division by zero returns Infinity or -Infinity.
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_NegateFloatOp : Eco_Op<"float.negate", [Pure]> {
  let summary = "Elm float negation";
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_AbsFloatOp : Eco_Op<"float.abs", [Pure]> {
  let summary = "Elm float absolute value";
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_PowFloatOp : Eco_Op<"float.pow", [Pure]> {
  let summary = "Elm float exponentiation";
  let arguments = (ins Eco_Float:$base, Eco_Float:$exp);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$base `,` $exp attr-dict `:` type($result)";
}

def Eco_SqrtOp : Eco_Op<"float.sqrt", [Pure]> {
  let summary = "Elm square root";
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}
```

## Phase 3: Conversions

### Ops.td Additions

```tablegen
//===----------------------------------------------------------------------===//
// Eco Type Conversion Operations
//===----------------------------------------------------------------------===//

def Eco_IntToFloatOp : Eco_Op<"int.toFloat", [Pure]> {
  let summary = "Convert Int to Float";
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_RoundOp : Eco_Op<"float.round", [Pure]> {
  let summary = "Round Float to nearest Int";
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_FloorOp : Eco_Op<"float.floor", [Pure]> {
  let summary = "Round Float down to Int";
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_CeilingOp : Eco_Op<"float.ceiling", [Pure]> {
  let summary = "Round Float up to Int";
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_TruncateOp : Eco_Op<"float.truncate", [Pure]> {
  let summary = "Truncate Float toward zero to Int";
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}
```

## Phase 4: Comparisons

### Ops.td Additions

```tablegen
//===----------------------------------------------------------------------===//
// Eco Comparison Operations
//===----------------------------------------------------------------------===//

def Eco_CmpIntOp : Eco_Op<"int.cmp", [Pure]> {
  let summary = "Elm integer comparison";
  let arguments = (ins
    Eco_CmpPredicateAttr:$predicate,
    Eco_Int:$lhs,
    Eco_Int:$rhs
  );
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$predicate $lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_CmpFloatOp : Eco_Op<"float.cmp", [Pure]> {
  let summary = "Elm float comparison";
  let arguments = (ins
    Eco_CmpPredicateAttr:$predicate,
    Eco_Float:$lhs,
    Eco_Float:$rhs
  );
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$predicate $lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_MinIntOp : Eco_Op<"int.min", [Pure, Commutative]> {
  let summary = "Elm integer minimum";
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_MaxIntOp : Eco_Op<"int.max", [Pure, Commutative]> {
  let summary = "Elm integer maximum";
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_MinFloatOp : Eco_Op<"float.min", [Pure, Commutative]> {
  let summary = "Elm float minimum";
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_MaxFloatOp : Eco_Op<"float.max", [Pure, Commutative]> {
  let summary = "Elm float maximum";
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

// Comparison predicate enum
def Eco_CmpPredicateAttr : I64EnumAttr<
    "CmpPredicate", "comparison predicate",
    [
      I64EnumAttrCase<"lt", 0>,   // less than
      I64EnumAttrCase<"le", 1>,   // less or equal
      I64EnumAttrCase<"gt", 2>,   // greater than
      I64EnumAttrCase<"ge", 3>,   // greater or equal
      I64EnumAttrCase<"eq", 4>,   // equal
      I64EnumAttrCase<"ne", 5>,   // not equal
    ]> {
  let cppNamespace = "::eco";
}
```

## Phase 5: Bitwise Operations

### Ops.td Additions

```tablegen
//===----------------------------------------------------------------------===//
// Eco Bitwise Operations
//===----------------------------------------------------------------------===//

def Eco_AndOp : Eco_Op<"int.and", [Pure, Commutative]> {
  let summary = "Bitwise AND";
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_OrOp : Eco_Op<"int.or", [Pure, Commutative]> {
  let summary = "Bitwise OR";
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_XorOp : Eco_Op<"int.xor", [Pure, Commutative]> {
  let summary = "Bitwise XOR";
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_ComplementOp : Eco_Op<"int.complement", [Pure]> {
  let summary = "Bitwise NOT (complement)";
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_ShiftLeftOp : Eco_Op<"int.shl", [Pure]> {
  let summary = "Shift left by n bits";
  let arguments = (ins Eco_Int:$amount, Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$amount `,` $value attr-dict `:` type($result)";
}

def Eco_ShiftRightOp : Eco_Op<"int.shr", [Pure]> {
  let summary = "Arithmetic shift right by n bits";
  let arguments = (ins Eco_Int:$amount, Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$amount `,` $value attr-dict `:` type($result)";
}

def Eco_ShiftRightZfOp : Eco_Op<"int.shru", [Pure]> {
  let summary = "Logical shift right by n bits (zero-fill)";
  let arguments = (ins Eco_Int:$amount, Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$amount `,` $value attr-dict `:` type($result)";
}
```

## Implementation Tasks

### Task 1: Add Operations to Ops.td
- [ ] Add integer arithmetic ops (add, sub, mul, div, modby, remainderby, negate, abs, pow)
- [ ] Add float arithmetic ops (add, sub, mul, div, negate, abs, pow, sqrt)
- [ ] Add conversion ops (toFloat, round, floor, ceiling, truncate)
- [ ] Add comparison ops (cmp, min, max)
- [ ] Add bitwise ops (and, or, xor, complement, shl, shr, shru)
- [ ] Add CmpPredicate enum

### Task 2: Implement Lowerings in EcoToLLVM.cpp
- [ ] Integer arithmetic lowerings (simple ops → LLVM, div/mod with zero-check)
- [ ] Float arithmetic lowerings (direct to LLVM FP ops)
- [ ] Conversion lowerings (sitofp, fptosi with rounding modes)
- [ ] Comparison lowerings (icmp, fcmp)
- [ ] Bitwise lowerings (direct to LLVM bit ops)
- [ ] Register all patterns

### Task 3: Add Tests
- [ ] test/codegen/arith_int_basic.mlir - add, sub, mul, negate, abs
- [ ] test/codegen/arith_int_div.mlir - div with zero-check behavior
- [ ] test/codegen/arith_int_mod.mlir - modby vs remainderby semantics
- [ ] test/codegen/arith_float_basic.mlir - float operations
- [ ] test/codegen/arith_conversions.mlir - int/float conversions
- [ ] test/codegen/arith_compare.mlir - comparison operations
- [ ] test/codegen/arith_bitwise.mlir - bitwise operations

### Task 4: Update Compiler Integration
- [ ] Document mapping from Elm Basics functions to eco ops
- [ ] Ensure kernel functions can be recognized as intrinsics

## Example Usage

```mlir
module {
  func.func @example(%a: i64, %b: i64) -> i64 {
    // Integer arithmetic
    %sum = eco.int.add %a, %b : i64
    %diff = eco.int.sub %a, %b : i64
    %prod = eco.int.mul %a, %b : i64
    %quot = eco.int.div %a, %b : i64      // Returns 0 if b == 0
    %mod = eco.int.modby %b, %a : i64     // Floored modulo

    // Float arithmetic
    %af = eco.int.toFloat %a : i64 -> f64
    %bf = eco.int.toFloat %b : i64 -> f64
    %fdiv = eco.float.div %af, %bf : f64  // IEEE 754
    %result = eco.float.round %fdiv : f64 -> i64

    // Comparison
    %lt = eco.int.cmp lt %a, %b : i64     // Returns i1

    return %result : i64
  }
}
```

## Lowering Example: eco.int.div

**Input MLIR:**
```mlir
%result = eco.int.div %a, %b : i64
```

**Lowered LLVM:**
```llvm
%is_zero = icmp eq i64 %b, 0
%div_result = sdiv i64 %a, %b
%result = select i1 %is_zero, i64 0, i64 %div_result
```

## Resolved Design Decisions

1. **Integer overflow**: Allow wrapping (wrong answer preferred over exceptions). Elm conceptually uses arbitrary precision but we're using i64.

2. **NaN handling**: Propagate NaN in the usual IEEE 754 way. No special handling.

3. **Float power of negative base**: `(-2.0) ^ 0.5` returns NaN per IEEE 754 (square root of negative is undefined in reals).

4. **Integer to negative power**: `2 ^ -1` would mathematically be 0.5 (a float), which breaks Elm's Int type. Return **0** (wrong answer but preserves Int type). This handles a known Elm typing bug gracefully.

## Summary

| Category | Ops Count | Notes |
|----------|-----------|-------|
| Integer arithmetic | 9 | add, sub, mul, div, modby, remainderby, negate, abs, pow |
| Float arithmetic | 8 | add, sub, mul, div, negate, abs, pow, sqrt |
| Conversions | 5 | toFloat, round, floor, ceiling, truncate |
| Comparisons | 6 | cmp (int/float), min/max (int/float) |
| Bitwise | 7 | and, or, xor, complement, shl, shr, shru |
| **Total** | **35** | |
