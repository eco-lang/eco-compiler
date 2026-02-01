# Plan: Join-Point Staged-Currying for MonoCase ABI Consistency

## Overview

This plan implements a **join-point staged-currying algorithm** for `MonoCase` expressions that ensures MONO_018 compliance: all case branches must have exactly the same `MonoType` as the `MonoCase` result type. When branches return function values with different staging (segmentation), this algorithm selects a canonical ABI and wraps mismatched branches.

### Prerequisites

This plan assumes the staged-currying work from `mono-still-curried-implementation.md` is complete:
- `MFunction args ret` represents "one stage"; nested `MFunction` encodes real staging
- `Types.decomposeFunctionType` gives `(flatArgs, finalRet)` across all stages

### Goal and Cost Model

At a `case` join point, branches may produce function values with different **staging** but the same Elm type. Each branch has some `MonoType`:

```
Ti = MFunction [stageArgs_i,1] (MFunction [stageArgs_i,2] ... (MFunction [stageArgs_i,k] R) ...)
```

All branches share the same flattened signature `A1 -> ... -> AN -> R`.

**Canonical ABI Selection:**
- Choose `S = [m1, ..., mk]` with `m1 + ... + mk = N`
- Stage 1 takes `m1` args, stage 2 takes `m2`, etc.

**Cost Model:**
- If a branch's segmentation equals `S`: cost 0 (reuse as-is)
- Otherwise: cost 1 (insert one wrapper)

**Optimization Objective (lexicographic):**
1. Minimize number of wrappers
2. Subject to (1), minimize number of stages (prefer flatter)

### Performance Note

Join-point ABI normalization may allocate wrapper closures when branches return differently-staged functions. This is rare and limited to higher-order code where case analysis produces a function value.

In the worst case where every branch stages differently, the algorithm picks one existing segmentation and wraps n-1 branches. This is acceptable because:
- Cases returning function values are relatively uncommon
- Different staging shapes within such cases are even rarer (due to `specializeLambda` flattening)
- Wrapper cost is one closure allocation per branch at that join point
- A future Mono-IR simplifier pass could eliminate trivial wrappers (similar to `MonoInlineSimplify`)

---

## Step-by-Step Implementation

### Step 1: Add Segmentation Utilities to Types.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Types.elm`

> **Note on imports:** This module is imported as `Types` throughout the monomorphization code (e.g., `import Compiler.Generate.MLIR.Types as Types` in `TypeSubst.elm`, `Functions.elm`, `Expr.elm`). The new helpers go here to be reusable for both monomorphization and MLIR codegen.

#### 1.1 Add `segmentLengths` function

Add after `decomposeFunctionType` (after line 324):

```elm
{-| Extract the staging pattern (segment lengths) from a function type.
    For `MFunction [A,B] (MFunction [C,D] R)` returns `[2, 2]`.
    For `MFunction [A,B,C,D] R` returns `[4]`.
    For non-function types returns `[]`.
-}
segmentLengths : Mono.MonoType -> List Int
segmentLengths monoType =
    let
        go t acc =
            case t of
                Mono.MFunction stageArgs stageRet ->
                    go stageRet (List.length stageArgs :: acc)

                _ ->
                    List.reverse acc
    in
    go monoType []
```

**Explanation:** This function walks the nested `MFunction` structure and collects the number of arguments at each stage. The result is a list of segment lengths that fully describes the staging pattern.

#### 1.2 Add type alias for Segmentation

Add after the new function:

```elm
{-| A Segmentation is a list of stage arities: [m1, m2, ...] means
    stage 1 takes m1 args, stage 2 takes m2 args, etc.
-}
type alias Segmentation =
    List Int
```

#### 1.3 Add `chooseCanonicalSegmentation` function

```elm
{-| Choose the canonical ABI segmentation for a join point.
    Given leaf function types from case branches:
    1. Pick the segmentation that appears most often (minimize wrappers)
    2. Among ties, pick the one with fewest stages (prefer flatter)

    Returns (canonicalSegmentation, flatArgs, flatRet).
-}
chooseCanonicalSegmentation : List Mono.MonoType -> ( Segmentation, List Mono.MonoType, Mono.MonoType )
chooseCanonicalSegmentation leafTypes =
    case leafTypes of
        [] ->
            -- Should not happen for well-formed MonoCase
            ( [], [], Mono.MUnit )

        firstType :: _ ->
            let
                -- Shared flattened signature (all branches must agree)
                ( flatArgs, flatRet ) =
                    decomposeFunctionType firstType

                -- Count how often each segmentation occurs
                countSegmentations : List Mono.MonoType -> Dict (List Int) (List Int) Int
                countSegmentations types =
                    List.foldl
                        (\t freqDict ->
                            let
                                seg =
                                    segmentLengths t

                                current =
                                    Dict.get identity seg freqDict |> Maybe.withDefault 0
                            in
                            Dict.insert identity seg (current + 1) freqDict
                        )
                        Dict.empty
                        types

                freqDict =
                    countSegmentations leafTypes

                -- Find maximum count
                maxCount =
                    Dict.foldl identity (\_ count acc -> max count acc) 0 freqDict

                -- All segmentations that hit maxCount
                bestSegs =
                    Dict.foldl identity
                        (\seg count acc ->
                            if count == maxCount then
                                seg :: acc
                            else
                                acc
                        )
                        []
                        freqDict

                -- Among them, prefer fewest stages (most flat)
                canonicalSeg =
                    case List.sortBy List.length bestSegs of
                        shortest :: _ ->
                            shortest

                        [] ->
                            -- Fallback: use first type's segmentation
                            segmentLengths firstType
            in
            ( canonicalSeg, flatArgs, flatRet )
```

**Explanation:** This implements the cost-model optimization. We count segment frequencies, find the maximum, filter to best candidates, then sort by length (fewest stages) and take the first.

> **Note on Dict API:** The project uses `elm-explorations/dict` which takes a key comparison function as its first argument. `Dict.get identity key dict` and `Dict.insert identity key value dict` is the standard pattern throughout the codebase.

#### 1.4 Add `buildSegmentedFunctionType` function

```elm
{-| Rebuild a nested MFunction from flat args and a segmentation.
    buildSegmentedFunctionType [A,B,C,D] R [2,2] = MFunction [A,B] (MFunction [C,D] R)
    buildSegmentedFunctionType [A,B,C,D] R [4] = MFunction [A,B,C,D] R
-}
buildSegmentedFunctionType : List Mono.MonoType -> Mono.MonoType -> Segmentation -> Mono.MonoType
buildSegmentedFunctionType flatArgs finalRet seg =
    let
        -- Split flatArgs according to seg = [m1, m2, ...]
        splitBySegments : List Mono.MonoType -> Segmentation -> List (List Mono.MonoType)
        splitBySegments remaining segLengths =
            case segLengths of
                [] ->
                    []

                m :: rest ->
                    let
                        ( now, later ) =
                            ( List.take m remaining, List.drop m remaining )
                    in
                    now :: splitBySegments later rest

        stageArgsLists =
            splitBySegments flatArgs seg
    in
    -- Build nested MFunction from inside out
    List.foldr
        (\stageArgs acc -> Mono.MFunction stageArgs acc)
        finalRet
        stageArgsLists
```

**Explanation:** This reconstructs a nested `MFunction` structure from a flat argument list and a segmentation pattern. It's used to build the canonical ABI type.

#### 1.5 Update module exports

**Line 6** - add to exports:

```elm
    , segmentLengths, chooseCanonicalSegmentation, buildSegmentedFunctionType
```

The full export line should become:
```elm
    , stageParamTypes, stageArity, stageReturnType, decomposeFunctionType
    , segmentLengths, chooseCanonicalSegmentation, buildSegmentedFunctionType
    , isEcoValueType
```

---

### Step 2: Add ABI Wrapper Builder to Closure.elm

**File:** `compiler/src/Compiler/Generate/Monomorphize/Closure.elm`

> **Note on imports:** This module imports `Compiler.Reporting.Annotation as A` for source location tracking. Regions (`A.Region`) are propagated into transformed code to preserve source locations for error reporting.

#### 2.1 Add `buildNestedCalls` helper

Add after `makeGeneralClosure` (after line 220):

```elm
{-| Build nested calls that apply all params to a callee, respecting the callee's staging.

    Given calleeType with segmentation [2,3] and params [a,b,c,d,e]:
    - First call: callee(a,b) -> intermediate1
    - Second call: intermediate1(c,d,e) -> result

    This follows MONO_016: never pass more args to a stage than it accepts.

    The region parameter (A.Region from Compiler.Reporting.Annotation) is propagated
    to generated MonoCall nodes for source location tracking in error messages.
-}
buildNestedCalls : A.Region -> Mono.MonoExpr -> List ( Name, Mono.MonoType ) -> Mono.MonoExpr
buildNestedCalls region calleeExpr params =
    let
        calleeType =
            Mono.typeOf calleeExpr

        srcSeg =
            Types.segmentLengths calleeType

        -- Convert params to expressions
        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        -- Build calls stage by stage
        buildCalls : Mono.MonoExpr -> List Mono.MonoExpr -> List Int -> Mono.MonoExpr
        buildCalls currentCallee remainingArgs segLengths =
            case ( segLengths, remainingArgs ) of
                ( [], _ ) ->
                    -- No more stages; return current callee (which should be the final result)
                    currentCallee

                ( m :: restSeg, _ ) ->
                    let
                        ( nowArgs, laterArgs ) =
                            ( List.take m remainingArgs, List.drop m remainingArgs )

                        currentCalleeType =
                            Mono.typeOf currentCallee

                        resultType =
                            Types.stageReturnType currentCalleeType

                        callExpr =
                            Mono.MonoCall region currentCallee nowArgs resultType
                    in
                    buildCalls callExpr laterArgs restSeg
    in
    buildCalls calleeExpr paramExprs srcSeg
```

**Explanation:** This function generates the nested call structure required by MONO_016. It takes arguments in chunks matching the callee's staging, using intermediate results as callees for subsequent stages. This is the same nested-call logic used for other MONO_016 wrappers.

#### 2.2 Add `buildAbiWrapper` function

```elm
{-| Build a closure that wraps a function expression to adapt its ABI.

    Given:
    - targetType: the desired ABI type (e.g., MFunction [A,B,C,D] R)
    - calleeExpr: the expression to wrap (e.g., has type MFunction [A] (MFunction [B,C,D] R))

    Returns a closure with targetType that calls calleeExpr using nested calls.

    If the segmentations already match, returns the callee unchanged.

    The wrapper is built entirely in Mono:
    - Fresh lambdaId from state
    - Params = flat argument list for canonical ABI
    - Body = nested MonoCalls respecting callee's staging (MONO_016)
    - Captures = computeClosureCaptures params body
-}
buildAbiWrapper :
    Mono.MonoType
    -> Mono.MonoExpr
    -> State.MonoState
    -> ( Mono.MonoExpr, State.MonoState )
buildAbiWrapper targetType calleeExpr state =
    let
        srcType =
            Mono.typeOf calleeExpr

        targetSeg =
            Types.segmentLengths targetType

        srcSeg =
            Types.segmentLengths srcType
    in
    if targetSeg == srcSeg then
        -- Segmentations match; no wrapper needed
        ( calleeExpr, state )

    else
        let
            -- Flatten to get all arg types
            ( flatArgs, _ ) =
                Types.decomposeFunctionType targetType

            -- Fresh params for the wrapper
            params =
                freshParams flatArgs

            -- Build the wrapper body: nested calls to calleeExpr
            -- Propagate the callee's source region for error reporting
            region =
                extractRegion calleeExpr

            bodyExpr =
                buildNestedCalls region calleeExpr params

            -- Create anonymous lambda ID
            lambdaId =
                Mono.AnonymousLambda state.currentModule state.lambdaCounter

            stateWithLambda =
                { state | lambdaCounter = state.lambdaCounter + 1 }

            -- Compute captures (calleeExpr may reference outer variables)
            captures =
                computeClosureCaptures params bodyExpr

            closureInfo =
                { lambdaId = lambdaId
                , captures = captures
                , params = params
                }

            closureExpr =
                Mono.MonoClosure closureInfo bodyExpr targetType
        in
        ( closureExpr, stateWithLambda )
```

**Explanation:** This is the main wrapper generator. It checks if wrapping is needed (by comparing segmentations), and if so, builds a `MonoClosure` that adapts the ABI. The closure has parameters matching the target segmentation and a body that calls the original function using nested calls matching its source segmentation.

#### 2.3 Update module exports

Add to the module's exposing list:
```elm
    , buildAbiWrapper
```

---

### Step 3: Add Leaf Collection and Rewriting to Specialize.elm

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

#### 3.1 Add required imports

Add/confirm in the imports section (around line 15):

```elm
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Monomorphize.Closure as Closure
```

#### 3.2 Add `collectCaseLeafFunctions` function

Add near the end of the file (before the last helper functions, around line 2000):

```elm
{-| Collect MonoTypes of all function-typed leaf expressions in a MonoCase.
    Returns empty list if no branches return functions.
-}
collectCaseLeafFunctions :
    Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> List Mono.MonoType
collectCaseLeafFunctions monoDecider monoJumps =
    let
        jumpDict =
            Dict.fromList identity monoJumps

        -- Collect from inline leaves and resolved jumps
        collectFromDecider : Mono.Decider Mono.MonoChoice -> List Mono.MonoType -> List Mono.MonoType
        collectFromDecider dec acc =
            case dec of
                Mono.Leaf choice ->
                    case choice of
                        Mono.Inline expr ->
                            let
                                t =
                                    Mono.typeOf expr
                            in
                            case t of
                                Mono.MFunction _ _ ->
                                    t :: acc

                                _ ->
                                    acc

                        Mono.Jump idx ->
                            case Dict.get identity idx jumpDict of
                                Just jumpExpr ->
                                    let
                                        t =
                                            Mono.typeOf jumpExpr
                                    in
                                    case t of
                                        Mono.MFunction _ _ ->
                                            t :: acc

                                        _ ->
                                            acc

                                Nothing ->
                                    acc

                Mono.Chain _ success failure ->
                    collectFromDecider success (collectFromDecider failure acc)

                Mono.FanOut _ edges fallback ->
                    let
                        accAfterEdges =
                            List.foldl
                                (\( _, d ) a -> collectFromDecider d a)
                                acc
                                edges
                    in
                    collectFromDecider fallback accAfterEdges
    in
    collectFromDecider monoDecider []
```

**Explanation:** This traverses the decision tree and jump table, collecting the types of all function-valued leaves. Non-function results are ignored since staging is irrelevant for them.

#### 3.3 Add `rewriteCaseLeavesToAbi` function

```elm
{-| Rewrite all function-typed leaves in a MonoCase to use the canonical ABI type.
    Non-function leaves are left unchanged.

    State is threaded in a deterministic order (depth-first, left-to-right) to ensure
    lambdaCounter monotonically increases and each wrapper gets a unique LambdaId.
-}
rewriteCaseLeavesToAbi :
    Mono.MonoType
    -> Types.Segmentation
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> State.MonoState
    -> ( Mono.Decider Mono.MonoChoice, List ( Int, Mono.MonoExpr ), State.MonoState )
rewriteCaseLeavesToAbi targetType targetSeg monoDecider monoJumps state0 =
    let
        -- Rewrite a single expression if it's a function
        rewriteExpr : Mono.MonoExpr -> State.MonoState -> ( Mono.MonoExpr, State.MonoState )
        rewriteExpr expr st =
            case Mono.typeOf expr of
                Mono.MFunction _ _ ->
                    if Types.segmentLengths (Mono.typeOf expr) == targetSeg then
                        ( expr, st )
                    else
                        Closure.buildAbiWrapper targetType expr st

                _ ->
                    ( expr, st )

        -- Rewrite the decider tree (depth-first, left-to-right)
        rewriteDecider : Mono.Decider Mono.MonoChoice -> State.MonoState -> ( Mono.Decider Mono.MonoChoice, State.MonoState )
        rewriteDecider dec st =
            case dec of
                Mono.Leaf choice ->
                    case choice of
                        Mono.Inline expr ->
                            let
                                ( newExpr, st1 ) =
                                    rewriteExpr expr st
                            in
                            ( Mono.Leaf (Mono.Inline newExpr), st1 )

                        Mono.Jump _ ->
                            -- Jumps are rewritten via monoJumps, not here
                            ( dec, st )

                Mono.Chain testChain success failure ->
                    let
                        ( newSuccess, st1 ) =
                            rewriteDecider success st

                        ( newFailure, st2 ) =
                            rewriteDecider failure st1
                    in
                    ( Mono.Chain testChain newSuccess newFailure, st2 )

                Mono.FanOut path edges fallback ->
                    let
                        -- Process edges left-to-right (foldl), threading state forward
                        ( newEdgesReversed, st1 ) =
                            List.foldl
                                (\( test, d ) ( accEdges, accSt ) ->
                                    let
                                        ( newD, newSt ) =
                                            rewriteDecider d accSt
                                    in
                                    ( ( test, newD ) :: accEdges, newSt )
                                )
                                ( [], st )
                                edges

                        newEdges =
                            List.reverse newEdgesReversed

                        ( newFallback, st2 ) =
                            rewriteDecider fallback st1
                    in
                    ( Mono.FanOut path newEdges newFallback, st2 )

        -- Rewrite jump table (in index order)
        rewriteJumps : List ( Int, Mono.MonoExpr ) -> State.MonoState -> ( List ( Int, Mono.MonoExpr ), State.MonoState )
        rewriteJumps jumps st =
            let
                ( reversedJumps, finalSt ) =
                    List.foldl
                        (\( idx, expr ) ( accJumps, accSt ) ->
                            let
                                ( newExpr, newSt ) =
                                    rewriteExpr expr accSt
                            in
                            ( ( idx, newExpr ) :: accJumps, newSt )
                        )
                        ( [], st )
                        jumps
            in
            ( List.reverse reversedJumps, finalSt )

        ( newDecider, state1 ) =
            rewriteDecider monoDecider state0

        ( newJumps, state2 ) =
            rewriteJumps monoJumps state1
    in
    ( newDecider, newJumps, state2 )
```

**Explanation:** This traverses the decision tree and jump table, wrapping any function-typed expressions whose segmentation doesn't match the target. The state is threaded through in a deterministic order (depth-first, left-to-right) to ensure `lambdaCounter` monotonically increases.

---

### Step 4: Modify the TOpt.Case Branch in specializeExpr

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

> **Note:** The sanity check uses `Utils.Crash.crash` which is the standard crash utility in this codebase.

#### 4.1 Replace the existing TOpt.Case branch

**Current code (lines 1175-1191):**
```elm
        TOpt.Case label root decider jumps canType ->
            let
                monoType =
                    TypeSubst.applySubst subst canType

                initialVarTypes =
                    state.varTypes

                ( monoDecider, state1 ) =
                    specializeDecider decider subst state

                state1WithResetVarTypes =
                    { state1 | varTypes = initialVarTypes }

                ( monoJumps, state2 ) =
                    specializeJumps jumps subst state1WithResetVarTypes
            in
            ( Mono.MonoCase label root monoDecider monoJumps monoType, state2 )
```

**Replace with:**
```elm
        TOpt.Case label root decider jumps canType ->
            let
                -- Type from canonical (used as fallback for non-function results)
                monoTypeFromCan =
                    TypeSubst.applySubst subst canType

                initialVarTypes =
                    state.varTypes

                ( monoDecider0, state1 ) =
                    specializeDecider decider subst state

                state1WithResetVarTypes =
                    { state1 | varTypes = initialVarTypes }

                ( monoJumps0, state2 ) =
                    specializeJumps jumps subst state1WithResetVarTypes

                -- Gather function-typed leaf results
                leafFuncTypes =
                    collectCaseLeafFunctions monoDecider0 monoJumps0
            in
            case ( leafFuncTypes, monoTypeFromCan ) of
                ( [], Mono.MFunction _ _ ) ->
                    -- Sanity check: canonical says function, but no function-typed leaves
                    -- This indicates a bug in earlier phases
                    Utils.Crash.crash
                        ("MonoCase has function result type but no function-typed leaves. "
                            ++ "monoTypeFromCan = "
                            ++ Debug.toString monoTypeFromCan
                        )

                ( [], _ ) ->
                    -- Case returns non-function; use canonical type directly
                    ( Mono.MonoCase label root monoDecider0 monoJumps0 monoTypeFromCan, state2 )

                ( _ :: _, _ ) ->
                    -- Case returns function; choose canonical ABI and coerce branches
                    let
                        ( canonicalSeg, flatArgs, flatRet ) =
                            Types.chooseCanonicalSegmentation leafFuncTypes

                        canonicalType =
                            Types.buildSegmentedFunctionType flatArgs flatRet canonicalSeg

                        ( monoDecider1, monoJumps1, state3 ) =
                            rewriteCaseLeavesToAbi canonicalType canonicalSeg monoDecider0 monoJumps0 state2
                    in
                    ( Mono.MonoCase label root monoDecider1 monoJumps1 canonicalType, state3 )
```

**Explanation:** The key changes:
1. We first specialize the decider and jumps as before
2. We collect all function-typed leaf results
3. **Sanity check:** If `monoTypeFromCan` is a function but `leafFuncTypes` is empty, crash with an internal error (this indicates a bug in earlier phases)
4. If no functions and non-function canonical type: use the original type (unchanged behavior)
5. If functions exist:
   - Choose the canonical segmentation (most common, prefer flatter)
   - Build the canonical ABI type
   - Rewrite all leaves to use that ABI (wrapping as needed)
   - Use the canonical type as the MonoCase result type

This ensures MONO_018 holds by construction: all leaves are either already of the canonical type or wrapped to become so.

---

### Step 5: Update Invariant Documentation

**File:** `design_docs/invariants.csv`

The MONO_018 invariant (line 139) already states:
```
MONO_018;Monomorphization;Types;enforced;Every MonoCase jump branch expression and every Inline leaf in the decider must have the same MonoType as the MonoCase resultType ensuring case expressions are well typed;Compiler.Generate.Monomorphize
```

Update the source reference to reflect the new implementation location:
```
MONO_018;Monomorphization;Types;enforced;Every MonoCase jump branch expression and every Inline leaf in the decider must have the same MonoType as the MonoCase resultType ensuring case expressions are well typed;Compiler.Generate.Monomorphize.Specialize (rewriteCaseLeavesToAbi)
```

---

## Summary of Code Changes

| # | File | Change Type | Description |
|---|------|-------------|-------------|
| 1 | `compiler/src/Compiler/Generate/MLIR/Types.elm` | Add function | `segmentLengths : MonoType -> List Int` |
| 2 | `compiler/src/Compiler/Generate/MLIR/Types.elm` | Add type | `type alias Segmentation = List Int` |
| 3 | `compiler/src/Compiler/Generate/MLIR/Types.elm` | Add function | `chooseCanonicalSegmentation : List MonoType -> (Segmentation, List MonoType, MonoType)` |
| 4 | `compiler/src/Compiler/Generate/MLIR/Types.elm` | Add function | `buildSegmentedFunctionType : List MonoType -> MonoType -> Segmentation -> MonoType` |
| 5 | `compiler/src/Compiler/Generate/MLIR/Types.elm` | Modify | Update module exports |
| 6 | `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` | Add function | `buildNestedCalls : Region -> MonoExpr -> List (Name, MonoType) -> MonoExpr` |
| 7 | `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` | Add function | `buildAbiWrapper : MonoType -> MonoExpr -> MonoState -> (MonoExpr, MonoState)` |
| 8 | `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` | Modify | Update module exports |
| 9 | `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Add import | `import Compiler.Generate.MLIR.Types as Types` |
| 10 | `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Add function | `collectCaseLeafFunctions : Decider MonoChoice -> List (Int, MonoExpr) -> List MonoType` |
| 11 | `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Add function | `rewriteCaseLeavesToAbi : MonoType -> Segmentation -> Decider -> List (Int, MonoExpr) -> MonoState -> (Decider, List (Int, MonoExpr), MonoState)` |
| 12 | `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Modify | Replace `TOpt.Case` branch in `specializeExpr` with join-point ABI logic |
| 13 | `design_docs/invariants.csv` | Modify | Update MONO_018 source reference |

---

## Testing Strategy

Add these targeted tests on top of existing MONO_018 coverage:

### Test 1: All branches identical staging (no wrappers)

```elm
module JoinPoint.IdenticalStaging exposing (select)

select : Bool -> (Int -> Int)
select b =
    case b of
        True  -> \x -> x + 1
        False -> \x -> x + 2
```

**Expected:**
- All leaves and MonoCase result type share the same `MFunction [MInt] MInt`
- No extra `MonoClosure` wrappers beyond the lambdas themselves
- `lambdaCounter` doesn't grow unexpectedly

### Test 2: Two different stagings, majority wins

```elm
module JoinPoint.MajorityWins exposing (select)

type Selector = A | B | C

select : Selector -> Int -> Int -> Int
select sel =
    case sel of
        A -> \x -> \y -> x + y      -- seg [1,1]
        B -> \x y -> x + y          -- seg [2]
        C -> \x y -> x - y          -- seg [2]
```

**Expected:**
- Canonical segmentation is `[2]` (two branches use `[2]`)
- A's branch gets a wrapper; B and C don't
- `MonoCase.resultType = MFunction [Int, Int] Int`
- MONO_018 passes

### Test 3: Tie-break on flattest

```elm
module JoinPoint.TieBreak exposing (select)

type Selector = A | B | C

select : Selector -> Int -> Int -> Int -> Int
select sel =
    case sel of
        A -> \x -> \y -> \z -> x + y + z   -- seg [1,1,1]
        B -> \x y -> \z -> x + y + z       -- seg [2,1]
        C -> \x y z -> x + y + z           -- seg [3]
```

**Expected:**
- All have frequency 1 (tie)
- Choose flattest: `[3]`
- A and B get wrappers; C doesn't
- Validates "we're willing to wrap everyone when no segmentation has strictly more users"

### Test 4: Nested case returning functions

```elm
module JoinPoint.Nested exposing (select)

select : Bool -> Bool -> (Int -> Int)
select a b =
    case a of
        True ->
            case b of
                True  -> \x -> x + 1
                False -> \x -> x + 2
        False ->
            \x -> x + 3
```

**Expected:**
- Nested case structure is handled correctly
- All leaves get consistent ABI

### How to add these tests

Add as new modules in `test/Elm/JoinPoint/` and include them in the elm-test suite. The existing `MonoCaseBranchResultTypeTest` framework can validate MONO_018 compliance after monomorphization.

---

## Verification

After implementation:

1. **MONO_018 tests should pass**: `MonoCaseBranchResultTypeTest` and related tests should now succeed for cases where branches return differently staged lambdas.

2. **MONO_016 remains valid**: ABI wrappers use `buildNestedCalls`, which respects the callee's staging (no `MonoCall` passes more args than the callee's first stage accepts).

3. **Existing tests remain passing**: Non-function case branches are unchanged; function branches with matching staging are unchanged.

4. **Run test suite**:
   ```bash
   cd compiler && npx elm-test-rs --fuzz 1
   cmake --build build --target check
   ```

---

## Future Extensions

This algorithm can be extended to `If` and `Let` expressions if they exhibit similar join-point staging issues. The core logic (`collectLeafFunctions`, `chooseCanonicalSegmentation`, `rewriteLeavesToAbi`) is factored to be reusable.
