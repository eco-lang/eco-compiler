# Plan: Canonicalize Tail-Func Parameter Types in Staging Rewriter

## Problem

After the staging solver canonicalizes function segmentations, **tail-func parameter types are not rewritten**. The `params` list in `MonoTailFunc` retains original curried types (e.g., `MFunction [Int] (MFunction [Int] Int)`) even when the solver chose a flat segmentation `[2]`. Since `MonoVarLocal Name MonoType` stores its type inline, body references to those parameters also retain stale types.

This causes `firstStageArityFromType` (the fallback in `sourceArityForCallee`) to return wrong arities for function-typed parameters, leading to incorrect `papExtend.remaining_arity` values (CGEN_052/CGEN_056 failures).

## Design Decisions (resolved)

### `MonoVarLocal` carries independent types → single-pass with `OverrideEnv`

`MonoVarLocal Name MonoType` stores the type inline — it does NOT reference the `params` list dynamically. Rewriting `params` alone is insufficient. We must also update every `MonoVarLocal` reference in the body.

**Decision:** Thread a per-scope `OverrideEnv` (`Dict Name MonoType`) through the existing `rewriteExpr` walk. This avoids a second pass and keeps all staging canonicalization logic in one place. The binding structure is non-trivial (`MonoLet`, `MonoClosure`, `MonoTailDef`) and is already understood in the existing walk — a separate post-pass would duplicate that binding logic.

### Scope shadowing — which binding forms shadow?

Within a `MonoTailFunc` body, only these expression-level binding forms can shadow a parameter name:

1. **`MonoClosure` params** — `closureInfo.params` bind in the closure body. Remove those names from `OverrideEnv` when entering the closure body.
2. **`MonoLet` with `MonoDef name bound`** — `name` binds in the let body. Remove from `OverrideEnv` when entering the let body.
3. **`MonoLet` with `MonoTailDef name params bound`** — `name` and each param name bind in `bound`, and `name` binds in the let body. Remove all from `OverrideEnv` in their respective scopes.

`MonoCase` and `MonoDestruct` do NOT introduce new `MonoVarLocal` names and need no special shadowing treatment.

### Closure body descent — must rewrite inside closures

We **must** descend into closure bodies and also rewrite capture expressions:

- A nested closure might reference an outer function-typed parameter:
  ```elm
  tail f x =
      let g = \y -> f x y
      in ...
  ```
  Here `f` is a `MonoVarLocal` inside `g`'s body that needs the canonical type.

- Captures are explicit in `ClosureInfo.captures` as `(Name, MonoExpr, Bool)`. The capture expression is typically `MonoVarLocal name actualType` — this must also be rewritten.

**Rule:** Descend into closure bodies with `OverrideEnv` minus the closure's own param names. Rewrite capture expressions with the current `OverrideEnv`.

### Closure parameters — deferred (future scope)

`GraphBuilder` currently only registers `SlotParam` for `MonoTailFunc`, not for `MonoClosure`. The immediate bug involves tail-func parameters and their uses (including inside nested closures and captures). Closure parameter canonicalization is an orthogonal enhancement for later.

### `remainingStageArities` — use tail of `stageAritiesFull`

After canonicalization, parameters are NOT guaranteed to be single-stage. The solver can choose any segmentation per equivalence class. The fallback for unknown callees (parameters) should use `tail stageAritiesFull` instead of `[]`:

- Single-stage `[2]` → remaining `[]` (correct: no further stages)
- Multi-stage `[1,1]` → remaining `[1]` (correct: one more stage of arity 1)

---

## Steps

### Step 1: Extend imports in Rewriter.elm

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm` (lines 21-22)

Add `SlotId(..)` and `slotIdToKey` to existing imports:

```elm
import Compiler.GlobalOpt.Staging.Types exposing (ProducerId(..), SlotId(..), ProducerInfo, Segmentation, StagingSolution)
import Compiler.GlobalOpt.Staging.UnionFind exposing (producerIdToKey, slotIdToKey)
```

### Step 2: Define `OverrideEnv` type alias

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`

Add near `RewriteCtx`:

```elm
type alias OverrideEnv =
    Dict Name Mono.MonoType
```

### Step 3: Add `canonicalSegForParam` helper

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`

Add near other helpers:

```elm
{-| Look up the canonical segmentation for a function parameter slot. -}
canonicalSegForParam : StagingSolution -> Int -> Int -> Maybe Segmentation
canonicalSegForParam solution funcNodeId paramIndex =
    let
        slotKey =
            slotIdToKey (SlotParam funcNodeId paramIndex)
    in
    Dict.get slotKey solution.slotClass
        |> Maybe.andThen (\classId -> Array.get classId solution.classSeg)
        |> Maybe.andThen identity
```

### Step 4: Add `rewriteTailFuncParams` function

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`

Returns both the new params list and an `OverrideEnv` of changed types:

```elm
{-| Rewrite function-typed parameter types based on canonical segmentation.
    Returns (newParams, overrideEnv) where overrideEnv maps changed param names
    to their canonical types.
-}
rewriteTailFuncParams :
    StagingSolution
    -> Int
    -> List ( Name, Mono.MonoType )
    -> ( List ( Name, Mono.MonoType ), OverrideEnv )
rewriteTailFuncParams solution funcNodeId params =
    List.indexedMap
        (\index ( name, paramType ) ->
            case paramType of
                Mono.MFunction _ _ ->
                    case canonicalSegForParam solution funcNodeId index of
                        Just seg ->
                            let
                                ( flatArgs, flatRet ) =
                                    Mono.decomposeFunctionType paramType

                                newParamType =
                                    buildSegmentedFunctionType seg flatArgs flatRet
                            in
                            ( ( name, newParamType ), Just ( name, newParamType ) )

                        Nothing ->
                            ( ( name, paramType ), Nothing )

                _ ->
                    ( ( name, paramType ), Nothing )
        )
        params
        |> List.unzip
        |> Tuple.mapSecond (List.filterMap identity >> Dict.fromList)
```

### Step 5: Add `OverrideEnv` parameter to `rewriteExpr` and all helpers

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`

Change signature of `rewriteExpr`:

```elm
rewriteExpr :
    StagingSolution
    -> ProducerInfo
    -> OverrideEnv
    -> Mono.MonoExpr
    -> RewriteCtx
    -> ( Mono.MonoExpr, RewriteCtx )
```

Add `MonoVarLocal` case (currently falls through to `_ ->` catch-all):

```elm
Mono.MonoVarLocal name _ ->
    case Dict.get name overrides of
        Just newTy ->
            ( Mono.MonoVarLocal name newTy, ctx0 )

        Nothing ->
            ( expr, ctx0 )
```

**Scope-aware changes within `rewriteExpr`:**

For `MonoClosure`:
```elm
Mono.MonoClosure closureInfo body monoType ->
    let
        -- Rewrite capture expressions with current overrides
        newCaptures =
            List.map
                (\( capName, capExpr, flag ) ->
                    case capExpr of
                        Mono.MonoVarLocal varName _ ->
                            case Dict.get varName overrides of
                                Just newTy ->
                                    ( capName, Mono.MonoVarLocal varName newTy, flag )

                                Nothing ->
                                    ( capName, capExpr, flag )

                        _ ->
                            ( capName, capExpr, flag )
                )
                closureInfo.captures

        -- Remove closure params from overrides for body descent
        paramNames =
            List.map Tuple.first closureInfo.params

        childOverrides =
            List.foldl Dict.remove overrides paramNames

        ( newBody, ctx1 ) =
            rewriteExpr solution producerInfo childOverrides body ctx0

        -- ... rest of existing closure logic (GOPT_001, wrapping, etc.)
        -- but use { closureInfo | captures = newCaptures }
    in
    ...
```

For `MonoLet`:
```elm
Mono.MonoLet def body monoType ->
    let
        ( newDef, ctx1 ) =
            rewriteDef solution producerInfo overrides def ctx0

        -- Shadow the def's name in the body
        defName =
            case newDef of
                Mono.MonoDef name _ -> name
                Mono.MonoTailDef name _ _ -> name

        bodyOverrides =
            Dict.remove defName overrides

        ( newBody, ctx2 ) =
            rewriteExpr solution producerInfo bodyOverrides body ctx1
    in
    ( Mono.MonoLet newDef newBody monoType, ctx2 )
```

**Also update `rewriteDef` signature** to accept `OverrideEnv`:

```elm
rewriteDef solution producerInfo overrides def ctx0 =
    case def of
        Mono.MonoDef name bound ->
            let
                ( newBound, ctx1 ) =
                    rewriteExpr solution producerInfo overrides bound ctx0
            in
            ( Mono.MonoDef name newBound, ctx1 )

        Mono.MonoTailDef name params bound ->
            let
                -- Remove local taildef params from overrides
                paramNames =
                    List.map Tuple.first params

                overridesWithoutParams =
                    List.foldl Dict.remove overrides paramNames

                ( newBound, ctx1 ) =
                    rewriteExpr solution producerInfo overridesWithoutParams bound ctx0
            in
            ( Mono.MonoTailDef name params newBound, ctx1 )
```

**Also update `rewriteDecider` and `rewriteChoice`** to accept and forward `OverrideEnv`.

### Step 6: Update `rewriteNode` to compute and pass `OverrideEnv`

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm` (lines 104-135)

For `MonoTailFunc`:
```elm
Mono.MonoTailFunc params body monoType ->
    let
        pid =
            ProducerTailFunc nodeId

        key =
            producerIdToKey pid

        maybeClassId =
            Dict.get key solution.producerClass

        -- Rewrite function-typed parameter types based on canonical segmentation
        ( newParams, paramOverrides ) =
            rewriteTailFuncParams solution nodeId params

        -- Rewrite body with param type overrides threaded through
        ( newBody, ctx1 ) =
            rewriteExpr solution producerInfo paramOverrides body ctx0

        -- GOPT_001: Always compute canonical type for the function itself
        paramCount =
            List.length newParams

        canonType =
            flattenTypeToArity paramCount monoType
    in
    case maybeClassId of
        Nothing ->
            ( Mono.MonoTailFunc newParams newBody canonType, ctx1 )

        Just _ ->
            ( Mono.MonoTailFunc newParams newBody canonType, ctx1 )
```

For all other node types (`MonoDefine`, `MonoCycle`, etc.), pass `Dict.empty` as `OverrideEnv`.

### Step 7: Fix `remainingStageArities` fallback for unknown callees

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` (~line 1830 in `computeCallInfo`)

Change:
```elm
Nothing ->
    []
```
To:
```elm
Nothing ->
    case stageAritiesFull of
        _ :: rest ->
            rest

        [] ->
            []
```

### Step 8: Validate with existing tests

```bash
# E2E tests (backend + runtime)
cmake --build build --target check

# Front-end tests
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

### Step 9: Add targeted test (recommended)

**File:** `compiler/tests/TestLogic/GlobalOpt/ParamStagingCanonicalizationTest.elm` (new)

Test that constructs a `MonoTailFunc` with a curried function-typed parameter, runs `applyStagingSolution`, and asserts:
1. The parameter type in the rewritten `params` list matches the canonical segmentation from `SlotParam`
2. `MonoVarLocal` references in the body carry the updated canonical type
3. Capture expressions in nested closures carry the updated canonical type

Implement as a test helper `validateClosureStaging` that:
- For each tail-func param slot with a class, checks `segmentLengths(paramType) == canonicalSeg`
- For each `MonoVarLocal` referencing that param name in the body, checks it has the matching `MonoType`

---

## Execution order

1. Steps 1-2 (imports + type alias)
2. Steps 3-4 (helpers: `canonicalSegForParam`, `rewriteTailFuncParams`)
3. Step 5 (thread `OverrideEnv` through `rewriteExpr`, `rewriteDef`, `rewriteDecider`, `rewriteChoice` — scope-aware)
4. Step 6 (hook `rewriteNode` for `MonoTailFunc`, pass `Dict.empty` elsewhere)
5. Step 7 (`remainingStageArities` fix in `MonoGlobalOptimize.elm`)
6. Step 8 (run tests)
7. Step 9 (targeted test)

---

## Files modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm` | Import `SlotId`/`slotIdToKey`; add `OverrideEnv` alias, `canonicalSegForParam`, `rewriteTailFuncParams`; thread `OverrideEnv` through `rewriteExpr`/`rewriteDef`/`rewriteDecider`/`rewriteChoice` with scope-aware shadowing; update `rewriteNode` `MonoTailFunc` branch; rewrite closure captures |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Fix `remainingStageArities` fallback to use `tail stageAritiesFull` for unknown callees |

## Files NOT modified (confirmed sufficient as-is)

| File | Reason |
|------|--------|
| `Staging/Types.elm` | `SlotParam Int Int` already defined in `SlotId` |
| `Staging/UnionFind.elm` | `slotIdToKey` already defined and handles `SlotParam` |
| `Staging/GraphBuilder.elm` | Already registers `SlotParam` nodes for tail-func function-typed params |
| `Staging/Solver.elm` | Already computes `slotClass` + `classSeg` for all nodes including `SlotParam` |

---

## How this fixes papExtend arity

After this change, the call chain works correctly:

1. **Parameter types are canonical.** For a param `f` with solver-chosen segmentation `[2]`, its type becomes `MFunction [Int, Int] Int` instead of `MFunction [Int] (MFunction [Int] Int)`.

2. **All `MonoVarLocal "f"` in the body carry the canonical type.** The `OverrideEnv` ensures this, including inside nested closures and captures.

3. **`sourceArityForCallee` returns correct arity.** For unknown callees (parameters), `firstStageArityFromType (Mono.typeOf funcExpr)` now reads the canonical first-stage arity (`2`), not the stale curried arity (`1`).

4. **`computeCallInfo` computes correct `initialRemaining`.** Since `sourceArity = 2`, `initialRemaining = 2`, matching the actual PAP's remaining arity.

5. **`remainingStageArities` uses `tail stageAritiesFull`.** For single-stage `[2]` → `[]`; for multi-stage `[1,1]` → `[1]`. Both are correct.

6. **`applyByStages` emits `papExtend` with correct `remaining_arity`.** The `remaining_arity` attribute matches the true PAP remaining arity, satisfying CGEN_052 and preventing runtime assertion failures in `eco_closure_call_saturated`.
