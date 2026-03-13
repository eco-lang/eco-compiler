# Fix MonoDirect VarEnv Crashes (Cat 2) and Currying Mismatches (Cat 3)

## Status: PLAN
## File: `compiler/src/Compiler/MonoDirect/Specialize.elm`

---

## Goal

Fix two categories of MonoDirect failures without touching Category 1 (CEcoValue/MErased erasure):

- **Category 2**: VarEnv crashes in `specializePath` — pattern-match branches leak VarEnv bindings across siblings, causing "Root variable not found" crashes.
- **Category 3a**: Operator/binop function types are flattened to multi-arg `MFunction` instead of curried, causing MonoGraph key mismatches with the original Monomorphize pipeline.

---

## Category 2: VarEnv Save/Restore in Case Specialization

### Problem

`specializeDecider` and `specializeJumps` never snapshot/reset `state.varEnv`. When a decider branch introduces pattern-bound variables into VarEnv, those leak into sibling branches. Later, `specializePath` crashes when it can't find a root variable that should be in scope.

The original `Monomorphize.Specialize` solves this by saving VarEnv before each branching point and restoring it before each sibling branch (lines 2982-3078 of `Compiler/Monomorphize/Specialize.elm`).

### Changes

All changes are in `compiler/src/Compiler/MonoDirect/Specialize.elm`.

#### Change 1: `specializeExpr` — `TOpt.Case` branch (~line 443)

Save VarEnv before the decider, reset before jumps:

```elm
-- BEFORE:
TOpt.Case scrutName label decider jumps meta ->
    let
        monoType =
            resolveType view meta

        ( monoDecider, state1 ) =
            specializeDecider view snapshot decider state

        ( monoJumps, state2 ) =
            specializeJumps view snapshot jumps state1
    in
    ( Mono.MonoCase scrutName label monoDecider monoJumps monoType, state2 )

-- AFTER:
TOpt.Case scrutName label decider jumps meta ->
    let
        monoType =
            resolveType view meta

        savedVarEnv =
            state.varEnv

        ( monoDecider, state1 ) =
            specializeDecider view snapshot decider state

        state1WithResetVarEnv =
            { state1 | varEnv = savedVarEnv }

        ( monoJumps, state2 ) =
            specializeJumps view snapshot jumps state1WithResetVarEnv
    in
    ( Mono.MonoCase scrutName label monoDecider monoJumps monoType, state2 )
```

#### Change 2: `specializeDecider` — `Chain` branch (~line 869)

Save VarEnv, reset before failure branch:

```elm
-- BEFORE:
TOpt.Chain testChain success failure ->
    let
        ( monoSuccess, state1 ) =
            specializeDecider view snapshot success state

        ( monoFailure, state2 ) =
            specializeDecider view snapshot failure state1
    in
    ( Mono.Chain testChain monoSuccess monoFailure, state2 )

-- AFTER:
TOpt.Chain testChain success failure ->
    let
        savedVarEnv =
            state.varEnv

        ( monoSuccess, state1 ) =
            specializeDecider view snapshot success state

        state1WithResetVarEnv =
            { state1 | varEnv = savedVarEnv }

        ( monoFailure, state2 ) =
            specializeDecider view snapshot failure state1WithResetVarEnv
    in
    ( Mono.Chain testChain monoSuccess monoFailure, state2 )
```

#### Change 3: `specializeDecider` — `FanOut` branch (~line 876)

Save VarEnv, reset before each edge and before fallback. Switch edges from `List.foldl`+`++` to `List.foldr`+`::` (matches original `specializeEdges`):

```elm
-- BEFORE:
TOpt.FanOut path tests fallback ->
    let
        ( monoTests, state1 ) =
            List.foldl
                (\( test, subDecider ) ( acc, s ) ->
                    let
                        ( monoSubDecider, s1 ) =
                            specializeDecider view snapshot subDecider s
                    in
                    ( acc ++ [ ( test, monoSubDecider ) ], s1 )
                )
                ( [], state )
                tests

        ( monoFallback, state2 ) =
            specializeDecider view snapshot fallback state1
    in
    ( Mono.FanOut path monoTests monoFallback, state2 )

-- AFTER:
TOpt.FanOut path tests fallback ->
    let
        savedVarEnv =
            state.varEnv

        ( monoTests, state1 ) =
            List.foldr
                (\( test, subDecider ) ( acc, s ) ->
                    let
                        sWithResetVarEnv =
                            { s | varEnv = savedVarEnv }

                        ( monoSubDecider, s1 ) =
                            specializeDecider view snapshot subDecider sWithResetVarEnv
                    in
                    ( ( test, monoSubDecider ) :: acc, s1 )
                )
                ( [], state )
                tests

        state1WithResetVarEnv =
            { state1 | varEnv = savedVarEnv }

        ( monoFallback, state2 ) =
            specializeDecider view snapshot fallback state1WithResetVarEnv
    in
    ( Mono.FanOut path monoTests monoFallback, state2 )
```

#### Change 4: `specializeJumps` (~line 893)

Save VarEnv, reset before each jump body. Switch from `List.foldl`+`++` to `List.foldr`+`::` (matches original):

```elm
-- BEFORE:
specializeJumps view snapshot jumps state =
    List.foldl
        (\( idx, expr ) ( acc, s ) ->
            let
                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr s
            in
            ( acc ++ [ ( idx, monoExpr ) ], s1 )
        )
        ( [], state )
        jumps

-- AFTER:
specializeJumps view snapshot jumps state =
    let
        savedVarEnv =
            state.varEnv
    in
    List.foldr
        (\( idx, expr ) ( acc, s ) ->
            let
                sWithResetVarEnv =
                    { s | varEnv = savedVarEnv }

                ( monoExpr, s1 ) =
                    specializeExpr view snapshot expr sWithResetVarEnv
            in
            ( ( idx, monoExpr ) :: acc, s1 )
        )
        ( [], state )
        jumps
```

---

## Category 3a: Curried Function Types for Synthesized Globals

### Problem

In `specializeCall`, when a `VarGlobal` has `funcMeta.tvar == Nothing` (synthesized references like binops), MonoDirect builds a flat multi-arg function type:

```elm
Mono.MFunction argMonoTypes resultType
-- e.g. MFunction [MInt, MInt] MInt
```

The original Monomorphize produces curried types via `buildCurriedFuncType`:

```elm
MFunction [MInt] (MFunction [MInt] MInt)
```

This violates the invariant that each TLambda becomes a single-arg MFunction, and causes MonoGraph key mismatches.

### Change

#### Change 5a: Add `buildCurriedFuncType` helper (near `specializeCall`, ~line 540)

Local helper that builds a curried function type from argument types and a result type:

```elm
{-| Build a curried function type from argument types and a result type.
Each argument becomes its own single-arg MFunction layer:
  [a, b] -> r  becomes  MFunction [a] (MFunction [b] r)
-}
buildCurriedFuncType : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
buildCurriedFuncType argTypes resultType =
    List.foldr
        (\argTy acc -> Mono.MFunction [ argTy ] acc)
        resultType
        argTypes
```

#### Change 5b: `specializeCall` — `VarGlobal` / `funcMeta.tvar == Nothing` branch (~line 561)

Use the helper to build a curried type instead of a flat one:

```elm
-- BEFORE (lines 561-569):
Nothing ->
    let
        argMonoTypes =
            List.map (\arg -> resolveExprType view arg) args
    in
    Mono.MFunction argMonoTypes resultType

-- AFTER:
Nothing ->
    buildCurriedFuncType
        (List.map Mono.typeOf monoArgs)
        resultType
```

**Notes:**
- Uses `Mono.typeOf monoArgs` (already-specialized expressions) instead of re-resolving from TOpt args.
- `buildCurriedFuncType` is a module-local helper, not exported.

---

## Category 3b: Constructor Spec Keys (Out of Scope)

Ctor node specialization already uses saturated result types as registry keys (via `finalizeSpec` + `Mono.nodeType`). Remaining ctor mismatches are expected to be either:
- Fixed indirectly by the currying fix above (when ctors are used as first-class functions).
- Related to CEcoValue/MErased (Category 1), which is intentionally deferred.

No ctor-specific changes in this plan.

---

## Validation

1. `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — front-end tests pass.
2. Category 2 crashes ("Root variable 'X' not found in VarEnv") should be eliminated.
3. Category 3a operator arity mismatches (`Function{ Int Int -> Int }` vs `Function{ Int -> Function{ Int -> Int } }`) should be eliminated.
4. Remaining test failures should be limited to Category 1 (CEcoValue/MErased) and possibly residual Category 3b ctor issues tied to erasure.

---

## Design Decisions (Resolved)

1. **`List.foldr`+`::` over `List.foldl`+`++`**: Changes 3 and 4 switch FanOut edges and jumps to `List.foldr` with `::` cons, matching the original `specializeEdges`/`specializeJumps` style (O(1) cons vs O(n) append).
2. **Extracted helper**: `buildCurriedFuncType` is defined as a module-local helper near `specializeCall`, not a cross-module API. Keeps scope tight while avoiding inline noise.
