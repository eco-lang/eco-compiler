# Analysis of `Basics.abs` Test Failures

## Test Cases

**IntAbsTest.elm:**
```elm
abs 5    -- should be: Int -> Int
abs -5   -- should be: Int -> Int
abs 0    -- should be: Int -> Int
```

**FloatAbsTest.elm:**
```elm
abs 3.14   -- should be: Float -> Float
abs -3.14  -- should be: Float -> Float
abs 0.0    -- should be: Float -> Float
```

## Source Definition

```elm
-- From elm/core Basics.elm line 580
abs : number -> number
abs n = if lt n 0 then -n else n
```

Where `lt : comparable -> comparable -> Bool`.

---

## Compiler Flow Analysis

### Phase 1: Type Checking

For `abs 5` (IntAbs):
- `5` is an Int literal → type `Int`
- `abs` is called with Int → specialized to `abs : Int -> Int`
- Inside `abs`, `n : number` → `number = Int`
- `0` literal → type `number` (constrained type variable)

For `abs 3.14` (FloatAbs):
- `3.14` is a Float literal → type `Float`
- `abs` is called with Float → specialized to `abs : Float -> Float`
- Inside `abs`, `n : number` → `number = Float`
- `0` literal → type `number` (constrained type variable, should resolve to Float)

### Phase 2: Typed Optimization (Expression.elm)

**BUG #1 LOCATION: `/work/compiler/src/Compiler/Optimize/Typed/Expression.elm:156-160`**

```elm
Can.Int int ->
    Names.pure (TOpt.Int region int ((Can.TType ModuleName.basics "Int" [])))

Can.Float float ->
    Names.pure (TOpt.Float region float ((Can.TType ModuleName.basics "Float" [])))
```

**Problem:** The optimizer **ignores** the inferred type (`tipe` parameter) and **hardcodes** the type as `Int` for all integer literals and `Float` for all float literals.

**Effect on `abs` body:**
- The `0` in `if lt n 0` gets type `TType Basics "Int" []` **regardless** of whether `abs` is being used with Int or Float
- The actual polymorphic type `number` is discarded

Compare with `List` which correctly uses `tipe`:
```elm
Can.List entries ->
    Names.registerKernel Name.list (TOpt.List region optEntries tipe)  -- Correct!
```

### Phase 3: Monomorphization (Monomorphize.elm)

**BUG #2 LOCATION: `/work/compiler/src/Compiler/Generate/Monomorphize.elm:761-765`**

```elm
TOpt.Int _ value _ ->
    ( Mono.MonoLiteral (Mono.LInt value) Mono.MInt, state )

TOpt.Float _ value _ ->
    ( Mono.MonoLiteral (Mono.LFloat value) Mono.MFloat, state )
```

**Problem:** The monomorphizer **ignores** the type annotation (third parameter `_`) and always produces `MInt` for integer literals and `MFloat` for float literals. It should apply the substitution like it does for variables:

```elm
TOpt.VarLocal name canType ->
    let
        monoType = applySubst subst canType  -- Correctly applies substitution!
    in
    ( Mono.MonoVarLocal name monoType, state )
```

**Effect on `abs : Float -> Float`:**
- When specializing `abs` for Float, `n` correctly gets type `MFloat`
- But `0` in `lt n 0` gets type `MInt` (hardcoded)
- The call `lt n 0` is monomorphized with argument types `[MFloat, MInt]`
- This requests a specialization of `lt : (Float, Int) -> Bool` which is invalid

### Phase 4: MLIR Generation

**IntAbs MLIR Output (lines 34-45):**
```mlir
func.func @Basics_abs_$_1 (%n: i64):
    %1 = arith.constant 0 : i64
    %2 = eco.int.lt(%n, %1) : (i64, i64) -> i1
    %4 = scf.if(%2) ...  <-- ERROR: scf.if can't be lowered
```
- Types are consistent (i64 throughout)
- But `scf.if` operation isn't being lowered to LLVM IR

**FloatAbs MLIR Output (lines 34-45):**
```mlir
func.func @Basics_abs_$_1 (%n: f64):
    %1 = arith.constant 0 : i64          <-- WRONG: Should be 0.0 : f64
    %2 = eco.call(%n, %1) @Basics_lt_$_5  <-- Passes (f64, i64)
```

And `Basics_lt_$_5` is defined as:
```mlir
func.func @Basics_lt_$_5 (%arg0: i64, %arg1: i64):  <-- Expects (i64, i64)!
```

**Error:** `'llvm.call' op operand type mismatch for operand 0: 'f64' != 'i64'`

---

## Summary of Issues

| Bug | Location | Description |
|-----|----------|-------------|
| #1 | `Expression.elm:156-160` | Optimizer discards polymorphic type for Int/Float literals, hardcodes concrete types |
| #2 | `Monomorphize.elm:761-765` | Monomorphizer ignores type annotation, always produces `MInt`/`MFloat` |
| #3 | (secondary) | `scf.if` not lowering to LLVM for Int case |

## Root Cause

The fundamental issue is that **numeric literals lose their polymorphic type information** during optimization. When `abs : number -> number` contains the literal `0`, that `0` should have type `number` so it can be specialized to either `Int` or `Float` during monomorphization.

Instead:
1. The optimizer replaces `number` with hardcoded `Int`
2. The monomorphizer doesn't even check the type annotation

This causes incorrect MLIR generation where:
- Float-specialized `abs` tries to compare `f64` with `i64`
- The `lt` function gets specialized with mismatched types
