# Plan: Monomorphic Global Fast Path in Classic Monomorphizer

## Goal

Skip `SchemeInfo` construction/caching and `unifyCallSiteDirect` for top-level user functions whose scheme has **zero generalized type variables**. These functions have exactly one MonoType; the scheme machinery adds overhead without value.

## Context

- **File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`
- **Location:** `specializeExpr`, `TOpt.Call` → `TOpt.VarGlobal` branch (lines 1470-1518)
- The existing path always calls `getOrBuildSchemeInfo` + `unifyCallSiteDirect`, even for monomorphic globals where there are no type variables to unify.

## What stays the same

- Monomorphic globals still get a `SpecKey`/`SpecId` and `MonoNode` via the worklist.
- `enqueueSpec`, `resolveProcessedArgs`, `callResultMonoType`, `forceCNumberToInt` all still called.
- Polymorphic globals, kernels, ctors, local multi-specialization: **completely unchanged**.

## Steps

### Step 1: Add `isMonomorphicGlobal` helper

**File:** `Specialize.elm`, near `lookupFreeVars` (line ~155)

Add:
```elm
{-| Return True if a top-level global function has an explicit annotation with
no generalized type variables (i.e. freeVars = {} in Can.Forall freeVars annType).

Only returns True when we have a confirmed Can.Forall entry with empty freeVars.
Returns False for globals with no annotation entry (Nothing case) — those must
go through the SchemeInfo path since funcMeta.tipe may contain unresolved TVars.
-}
isMonomorphicGlobal : TOpt.Global -> MonoState -> Bool
isMonomorphicGlobal global state =
    case Data.Map.get TOpt.toComparableGlobal global state.ctx.annotations of
        Just (Can.Forall freeVars _) ->
            Dict.isEmpty freeVars

        Nothing ->
            False
```

Does **not** delegate to `lookupFreeVars` because `lookupFreeVars` returns `Dict.empty` for the `Nothing` case, which would incorrectly classify unannotated globals as monomorphic.

### Step 2: Add monomorphic branch in `TOpt.VarGlobal` call handling

**File:** `Specialize.elm`, lines 1470-1518

Replace the existing `TOpt.VarGlobal` case with a guarded version:

```elm
TOpt.VarGlobal funcRegion global funcMeta ->
    let
        isMonoGlobal =
            isMonomorphicGlobal global state1r

        funcCanType : Can.Type MVarId
        funcCanType =
            case Data.Map.get TOpt.toComparableGlobal global state1r.ctx.annotations of
                Just (Can.Forall _ annType) ->
                    annType
                Nothing ->
                    funcMeta.tipe
    in
    if isMonoGlobal then
        -- MONOMORPHIC FAST PATH: no SchemeInfo, no unifyCallSiteDirect.
        -- The annotation has zero generalized vars, so canTypeToMonoType with
        -- substForCall is sufficient to derive the single funcMonoType.
        let
            ( funcMonoTypeRaw, mvarEnv2 ) =
                TypeSubst.canTypeToMonoType state1r.ctx.mvarEnv substForCall funcCanType

            funcMonoType =
                Mono.forceCNumberToInt funcMonoTypeRaw

            state1m =
                let ctx = state1r.ctx
                in { state1r | ctx = { ctx | mvarEnv = mvarEnv2 } }

            paramTypes =
                TypeSubst.extractParamTypes funcMonoType

            ( monoArgs, state2 ) =
                resolveProcessedArgs processedArgs paramTypes substForCall state1m

            resultMonoType =
                callResultMonoType
                    state2.ctx.mvarEnv
                    (state2.ctx.currentFreeVars)
                    substForCall
                    canType

            monoGlobal =
                toptGlobalToMono global

            ( specId, newState ) =
                enqueueSpec monoGlobal funcMonoType Nothing state2

            monoFunc =
                Mono.MonoVarGlobal funcRegion specId funcMonoType
        in
        ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
        , newState
        )
    else
        -- EXISTING POLYMORPHIC PATH (unchanged)
        let
            ( schemeInfo, state1a ) =
                getOrBuildSchemeInfo funcCanType (Just global) state1r

            ( callSubst, funcMonoTypeRaw, _ ) =
                TypeSubst.unifyCallSiteDirect
                    state1a.ctx.mvarEnv
                    schemeInfo.argTypes
                    schemeInfo.resultType
                    argTypes
                    substForCall

            funcMonoType =
                Mono.forceCNumberToInt funcMonoTypeRaw

            paramTypes =
                TypeSubst.extractParamTypes funcMonoType

            ( monoArgs, state2 ) =
                resolveProcessedArgs processedArgs paramTypes callSubst state1a

            resultMonoType =
                callResultMonoType
                    state2.ctx.mvarEnv
                    (state2.ctx.currentFreeVars)
                    callSubst
                    canType

            monoGlobal =
                toptGlobalToMono global

            ( specId, newState ) =
                enqueueSpec monoGlobal funcMonoType Nothing state2

            monoFunc =
                Mono.MonoVarGlobal funcRegion specId funcMonoType
        in
        ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
        , newState
        )
```

Key differences from original design document:
- `canTypeToMonoType` called with **three** args: `mvarEnv`, `substForCall`, `funcCanType`
- `isMonomorphicGlobal` returns `False` for `Nothing` annotation entries (not `True`)

### Step 3: Build and run E2E tests

```bash
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

Verify zero regressions. No new tests needed — this is a pure performance optimization that must produce identical MonoNodes.

### Step 4: Run frontend tests

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

## Resolved Questions

### Q1: `canTypeToMonoType` arity (RESOLVED)

The signature is `MVarEnv -> Substitution -> Can.Type MVarId -> (MonoType, MVarEnv)`. The fast path passes `substForCall` as the substitution — the caller's refined substitution from `refineSubstFromArgExprs`. This resolves any MVarIds in the annotation type bound by the caller's context. The original design document incorrectly showed a 2-arg call.

### Q2: Stray unbound MVarIds in monomorphic annotations (RESOLVED — safe)

`AssignMVarIds` rewrites all scheme roots using solver roots. If a global's scheme has `freeVars = {}`, all MVarIds in `annType` are fixed by the solver, not generalized. They are concrete under `canTypeToMonoType` + the caller's `substForCall`.

If such an MVarId were truly unbound, it would already be a latent bug in the existing scheme path (where `buildSchemeInfo.collectMVarIds` would collect it and `unifyCallSiteDirect` would attempt to bind it). The fast path doesn't introduce new failure modes here.

**Optional defensive assert** (can add if desired):
```elm
if Mono.containsAnyMVar funcMonoType then
    Utils.Crash.crash "monomorphic fast path: annotation produced MonoType with MVar"
```

### Q3: `callSubst == substForCall` for monomorphic case (RESOLVED — proven)

`unifyCallSiteDirect` only adds bindings for scheme MVarIds by unifying `schemeArgTypes` with `argMonoTypes`. If the scheme has no MVarIds, `unifyArgTypesZip` can't introduce new mappings — it returns the original substitution unchanged. So `callSubst` is exactly `substForCall` when there are no generalized vars.

### Q4: `Nothing` annotation entry (RESOLVED — guard against it)

`lookupFreeVars` returns `Dict.empty` for `Nothing`, which would incorrectly classify unannotated globals as monomorphic. Fixed by making `isMonomorphicGlobal` check for an explicit `Just (Can.Forall freeVars _)` with `Dict.isEmpty freeVars`, returning `False` for `Nothing`. This preserves existing SchemeInfo-path behavior for unannotated globals.

### Q5: Debug tracing (RESOLVED — skip)

No tracing. E2E tests via `cmake --build build --target full` are the validation mechanism.
