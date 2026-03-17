# Error 2: `eco.papExtend` remaining_arity wrong (12 errors)

## Root Cause

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`, two interacting issues:

### Issue 1: Closure parameters not registered in `varSourceArity` (line ~1149-1157)

In `annotateExprCalls`, when processing a `MonoClosure`, the closure body is recursed with the **same** `env` without adding the closure's parameters to `env.varSourceArity`:

```elm
Mono.MonoClosure info body closureType ->
    let
        newCaptures =
            List.map (\( n, e, t ) -> ( n, recurse e, t )) info.captures
        newBody =
            recurse body  -- uses same env, params NOT registered
    in
    Mono.MonoClosure { info | captures = newCaptures } newBody closureType
```

### Issue 2: Fallback uses total arity instead of first-stage arity (line ~1494-1497)

When `sourceArityForExpr` returns `Nothing` (because the variable is a closure parameter not in `varSourceArity`), `sourceArityForCallee` falls back to `countTotalArityFromType`, which sums ALL stage arities:

```elm
sourceArityForCallee graph env funcExpr =
    case sourceArityForExpr graph env funcExpr of
        Just arity -> arity
        Nothing ->
            countTotalArityFromType (Mono.typeOf funcExpr)
```

For a multi-stage type like `MFunction [Int] (MFunction [Int] Int)` (stage arities `[1, 1]`), `countTotalArityFromType` returns **2**, but the actual source arity for the first stage is **1**.

### How the two issues combine

1. A function is defined with an explicit return lambda: `curried x = \y -> x + y`, producing multi-stage type with stage arities `[1, 1]`.
2. This is passed to a higher-order function: `applyPartial f a = f a`.
3. Inside `applyPartial`'s closure body, `f` is a closure parameter NOT registered in `varSourceArity`.
4. `sourceArityForCallee` falls back to `countTotalArityFromType` = **2** instead of **1**.
5. `initialRemaining = 2` propagates to `remaining_arity` on `eco.papExtend`.

## MLIR Evidence

Sub-pattern A (7 errors): `remaining_arity = 4` but computed = 2
```mlir
%1 = "eco.papCreate"() {arity = 2, function = @Pretty_append_$_115, num_captured = 0, ...}
%3 = "eco.papCreate"(%1) {arity = 3, function = @Basics_Extra_lambda_30379$clo, num_captured = 1, ...}
%4 = "eco.papExtend"(%3, %arg0) {remaining_arity = 4}   // ERROR: should be 1
```

Sub-pattern B (5 errors): `remaining_arity = 2` but computed = 1
```mlir
%8 = "eco.papCreate"(%1, %2) {arity = 3, function = @List_lambda_31356$clo, num_captured = 2, ...}
%9 = "eco.papExtend"(%8, %arg0) {remaining_arity = 2}   // ERROR: should be 0
```

## Failing Test

`test/elm/src/PapExtendArityTest.elm` — **FAILS** with SIGABRT (runtime assertion on arity mismatch)

## Fix Direction

Either:
- **Option A:** Register closure params in `varSourceArity` using first-stage arity from their type
- **Option B:** Change the fallback in `sourceArityForCallee` to use first-stage arity instead of total arity for `StageCurried` callees
