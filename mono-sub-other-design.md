Below is a concrete design you can hand to an engineer. It assumes the current codebase as you described (State.elm, TypeSubst.elm, Specialize.elm, etc.) and focuses on eliminating “callSubst / InstSubst pollution” by making the roles **type‑checked** and by changing how instantiation flows.
I’ll go file‑by‑file, describing:
- What to add/change
- The exact code (or representative patterns) to insert
- Why the change is needed
---
## 0. Target invariants

After this change, the following should be enforced by the types and code structure:
1. **Two distinct substitution roles**
   ```elm
   type CallerSubst = CallerSubst Substitution
   type InstSubst   = InstSubst Substitution
   ```

   - `CallerSubst` = the environment for specializing a definition (a function / let‑bound def).
   - `InstSubst` = the per‑call instantiation of a callee’s scheme variables.
2. **Discipline:**

   - Every **def body** is only ever specialized under a `CallerSubst` built from its **own canonical type** via `unify`/`unifyExtend`.
   - Every **call** creates a fresh `InstSubst` from `Dict.empty` for that callee’s scheme vars.
   - `InstSubst` is never threaded into `specializeExpr` (or other “caller environment” functions).
   - When a call context constrains a non‑local / local‑multi callee, we:
     1. Compute the callee’s `MonoType` via `InstSubst`.
     2. Fold that back into the callee’s *canonical* type using `unifyExtend` **onto a CallerSubst**.
     3. Use this enriched `CallerSubst` to specialize the callee’s body.

This is exactly what prevents “substitution contamination.”
---
## 1. `State.elm`: define `CallerSubst` / `InstSubst` and helpers

File: `compiler/src/Compiler/Monomorphize/State.elm`
### 1.1. Keep existing Substitution

You already have:
```elm
type alias Substitution =
    Dict Int Mono.MonoType
```

Leave that as is; it’s the raw representation.
### 1.2. Add new wrapper types

Right after `Substitution` (around line 172–173 in your table), define:
```elm
-- New typed roles for substitutions

type CallerSubst
    = CallerSubst Substitution


type InstSubst
    = InstSubst Substitution
```
### 1.3. Basic constructors / accessors

Still in `State.elm`, add:
```elm
emptyCallerSubst : CallerSubst
emptyCallerSubst =
    CallerSubst Dict.empty


emptyInstSubst : InstSubst
emptyInstSubst =
    InstSubst Dict.empty


fromCallerSubst : CallerSubst -> Substitution
fromCallerSubst (CallerSubst subst) =
    subst


fromInstSubst : InstSubst -> Substitution
fromInstSubst (InstSubst subst) =
    subst


mapCallerSubst : (Substitution -> Substitution) -> CallerSubst -> CallerSubst
mapCallerSubst f (CallerSubst subst) =
    CallerSubst (f subst)


mapInstSubst : (Substitution -> Substitution) -> InstSubst -> InstSubst
mapInstSubst f (InstSubst subst) =
    InstSubst (f subst)
```

You can add more helpers later, but these are enough to bridge to `TypeSubst` functions that operate on raw `Substitution`.
### 1.4. Update `SpecAccum` / `LocalMultiState` fields

Wherever you have fields that currently store a `Substitution` *as the environment for a def*, change them to `CallerSubst`.
For example, if `LocalMultiState` (or similar) has:
```elm
type alias LocalInstanceInfo =
    { monoType : Mono.MonoType
    , subst : Substitution
    , ...
    }
```

change it to:
```elm
type alias LocalInstanceInfo =
    { monoType : Mono.MonoType
    , subst : CallerSubst
    , ...
    }
```

This ensures local multi‑def instances are recorded with the correct role.
Don’t change low‑level solver/monomorphizer state that conceptually works on generic substitutions (e.g. `MVarEnv.constraints`); those remain `Substitution` or `Dict Int Mono.MonoType`.
### 1.5. Exports

Expose the new types and helpers from `State.elm`:
```elm
module Compiler.Monomorphize.State
    exposing
        ( MVarId
        , MVarEnv
        , Substitution
        , CallerSubst(..)
        , InstSubst(..)
        , emptyCallerSubst
        , emptyInstSubst
        , fromCallerSubst
        , fromInstSubst
        , mapCallerSubst
        , mapInstSubst
        , ...
        )
```
---
## 2. `TypeSubst.elm`: keep generic, but fix call‑site helpers

File: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`
The core unification/apply functions should remain generic over plain `Substitution`. We simply adjust the specialized call‑site helpers that were mixing roles.
### 2.1. Leave `unify`, `unifyExtend`, `applySubst` unchanged

Keep:
```elm
unify : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> ( Substitution, MVarEnv )

unifyExtend : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )

applySubst : MVarEnv -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
```

These are low‑level; they don’t know about Caller vs Inst.
### 2.2. Change `unifyCallSiteDirect` to be pure instantiation

Current signature (per your report):
```elm
unifyCallSiteDirect :
    MVarEnv ->
    List (Can.Type MVarId) ->
    Can.Type MVarId ->
    List Mono.MonoType ->
    Substitution ->
    ( Substitution, Mono.MonoType, MVarEnv )
```

Change to:
```elm
unifyCallSiteDirect :
    MVarEnv ->
    List (Can.Type MVarId) ->
    Can.Type MVarId ->
    List Mono.MonoType ->
    ( Substitution, Mono.MonoType, MVarEnv )
```

Implementation change: start from `Dict.empty` instead of a `baseSubst`:
```elm
unifyCallSiteDirect env schemeArgTypes schemeResultType argMonoTypes =
    let
        baseInstSubst : Substitution
        baseInstSubst =
            Dict.empty

        ( substAfterArgs, env1 ) =
            unifyArgTypesZip env schemeArgTypes argMonoTypes baseInstSubst

        resolvedSuppliedArgs =
            List.map (resolveMonoVars env1 substAfterArgs) argMonoTypes

        remainingSchemeArgs =
            List.drop (List.length argMonoTypes) schemeArgTypes

        ( resolvedRemainingArgs, env2 ) =
            List.foldl
                (\canArg ( accArgs, accEnv ) ->
                    let
                        ( monoArg, envN ) =
                            applySubst accEnv substAfterArgs canArg
                    in
                    ( accArgs ++ [ monoArg ], envN )
                )
                ( [], env1 )
                remainingSchemeArgs

        resolvedAllArgs =
            resolvedSuppliedArgs ++ resolvedRemainingArgs

        ( resultMono, env3 ) =
            applySubst env2 substAfterArgs schemeResultType

        funcMonoType =
            buildCurriedFuncType schemeArgTypes resolvedAllArgs resultMono
    in
    ( substAfterArgs, funcMonoType, env3 )
```

This `Substitution` is **by design** an InstSubst, but to keep `TypeSubst` generic we leave its type as raw `Substitution`. The wrapper type is applied in `Specialize.elm`.
### 2.3. Change `unifyArgsOnly` to be pure instantiation

Current signature:
```elm
unifyArgsOnly :
    MVarEnv -> Can.Type MVarId -> List Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
```

Change to:
```elm
unifyArgsOnly :
    MVarEnv -> Can.Type MVarId -> List Mono.MonoType -> ( Substitution, MVarEnv )
```

Implementation:
```elm
unifyArgsOnly env canFuncType argTypes =
    let
        baseInstSubst : Substitution
        baseInstSubst =
            Dict.empty
    in
    case ( canFuncType, argTypes ) of
        ( _, [] ) ->
            ( baseInstSubst, env )

        ( Can.TLambda from _, [ singleArg ] ) ->
            unifyHelp env from singleArg baseInstSubst

        ( Can.TLambda from to, arg0 :: rest ) ->
            let
                ( subst1, env1 ) =
                    unifyHelp env from arg0 baseInstSubst
            in
            -- recursively unify remaining args, but still only within instantiation scope
            let
                unifyRemaining ( s, e ) monoArg canT =
                    unifyHelp e canT monoArg s

                ( substFinal, envFinal ) =
                    List.foldl
                        (\monoArg ( s, e ) ->
                            case to of
                                Can.TLambda fromNext toNext ->
                                    unifyRemaining ( s, e ) monoArg fromNext

                                _ ->
                                    ( s, e )
                        )
                        ( subst1, env1 )
                        rest
            in
            ( substFinal, envFinal )

        _ ->
            ( baseInstSubst, env )
```

(You may want to simplify this further based on your actual lambda shape, but the key is: it never starts from callerSubst.)
Callers in `Specialize.elm` will wrap this `Substitution` into an `InstSubst`.
---
## 3. `Specialize.elm`: thread CallerSubst vs InstSubst correctly

This is where most of the work happens.
### 3.1. Imports

At the top of `Specialize.elm`, import the new types and helpers:
```elm
import Compiler.Monomorphize.State
    exposing
        ( MVarId
        , MVarEnv
        , Substitution
        , CallerSubst(..)
        , InstSubst(..)
        , emptyCallerSubst
        , emptyInstSubst
        , fromCallerSubst
        , fromInstSubst
        , mapCallerSubst
        , mapInstSubst
        , ...
        )
```
### 3.2. Change core specialization signatures to use `CallerSubst`

Update all functions that represent “current caller environment” to take `CallerSubst` instead of `Substitution`. For example:
```elm
specializeExpr : TOpt.Expr -> CallerSubst -> MonoState -> ( Mono.Expr, MonoState )

specializeDef : TOpt.Def -> CallerSubst -> MonoState -> ( Mono.Def, MonoState )

specializeFunc : ... -> CallerSubst -> ...  -- where appropriate

specializeLambda : ... -> CallerSubst -> ...

specializeValueDefs : List ... -> CallerSubst -> ...

specializeExprs : List TOpt.Expr -> CallerSubst -> MonoState -> ...

specializeBranches : ... -> CallerSubst -> ...

specializeNamedExprs : ... -> CallerSubst -> ...

specializeDestructor : ... -> CallerSubst -> ...

getOrCreateLocalInstance : Name.Name -> Mono.MonoType -> CallerSubst -> MonoState -> ...

updateLocalMultiStack : ... -> CallerSubst -> ... -> ...
```

In each case, the body will start with:
```elm
specializeExpr expr callerSubst state =
    let
        subst =
            fromCallerSubst callerSubst
    in
    ...
```

and when you produce an updated substitution (via `unifyExtend`, etc.) you rewrap it back into `CallerSubst` using `CallerSubst newSubst`.
### 3.3. Entry point: `specializeNode` should create a `CallerSubst`

In `specializeNode` (the entry for monomorphizing a node):
Current pattern (schematically):
```elm
( subst0, mvarEnv1 ) =
    TypeSubst.unify mvarEnv canType requestedMonoType

( subst1, mvarEnv2 ) =
    TypeSubst.unifyExtend mvarEnv1 exprType requestedMonoType subst0

-- later
( monoExpr, state2 ) =
    specializeExpr expr subst1 state1
```

Change to:
```elm
( subst0, mvarEnv1 ) =
    TypeSubst.unify mvarEnv canType requestedMonoType

( subst1, mvarEnv2 ) =
    TypeSubst.unifyExtend mvarEnv1 exprType requestedMonoType subst0

callerSubst : CallerSubst
callerSubst =
    CallerSubst subst1

state1a =
    { state1 | ctx = { state1.ctx | mvarEnv = mvarEnv2 } }

( monoExpr, state2 ) =
    specializeExpr expr callerSubst state1a
```

This is now the only place you create a `CallerSubst` “from scratch” (modulo lets/unifyExtend).
### 3.4. Let‑bindings: use `CallerSubst` for enrichment

Wherever you currently do:
```elm
( enrichedSubst, mvarEnv1 ) =
    TypeSubst.unifyExtend mvarEnv defCanType defMonoType subst

-- then recursive specializeExpr ... enrichedSubst ...
```

rewrite as:
```elm
let
    subst0 =
        fromCallerSubst callerSubst

    ( enrichedSubstRaw, mvarEnv1 ) =
        TypeSubst.unifyExtend mvarEnv defCanType defMonoType subst0

    enrichedCallerSubst =
        CallerSubst enrichedSubstRaw

    state1a =
        { state1 | ctx = { state1.ctx | mvarEnv = mvarEnv1 } }
in
( monoBody, state2 ) =
    specializeExpr body enrichedCallerSubst state1a
```

Apply this pattern in:
- Let function defs (single and multi),
- Let non‑fn defs (value‑multi and others),
- Any other place you enrich the environment via a definition’s type (`defCanType`).
### 3.5. Change `callResultMonoType` to use wrappers and prefer InstSubst

Current (per your report):
```elm
callResultMonoType : MVarEnv -> Substitution -> Substitution -> Can.Type MVarId -> Mono.MonoType
callResultMonoType mvarEnv callerSubst callSubst canType =
    let
        fromCaller =
            Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst mvarEnv callerSubst canType))
    in
    if Mono.containsAnyMVar fromCaller then
        Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst mvarEnv callSubst canType))
    else
        fromCaller
```

Change signature:
```elm
callResultMonoType : MVarEnv -> CallerSubst -> InstSubst -> Can.Type MVarId -> Mono.MonoType
```

and implementation:
```elm
callResultMonoType mvarEnv callerSubst instSubst canType =
    let
        callerDict =
            fromCallerSubst callerSubst

        instDict =
            fromInstSubst instSubst

        fromInst =
            Mono.forceCNumberToInt
                (Tuple.first (TypeSubst.applySubst mvarEnv instDict canType))
    in
    if Mono.containsAnyMVar fromInst then
        -- Fallback: try caller environment (useful for non-polymorphic cases)
        let
            fromCaller =
                Mono.forceCNumberToInt
                    (Tuple.first (TypeSubst.applySubst mvarEnv callerDict canType))
        in
        fromCaller
    else
        fromInst
```

This makes InstSubst the primary source of the result type, which is what you want for higher‑order cases like `Maybe.map`.
### 3.6. Call branches: VarGlobal / VarKernel / VarDebug
#### VarGlobal

Simplified original structure:
```elm
( schemeInfo, state1a ) =
    getOrBuildSchemeInfo funcCanType (Just global) state1

( callSubst, funcMonoTypeRaw, mvarEnv1 ) =
    TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv
        schemeInfo.argTypes schemeInfo.resultType argTypes subst

funcMonoType = forceCNumberToInt funcMonoTypeRaw
paramTypes   = extractParamTypes funcMonoType

( monoArgs, state2 ) =
    resolveProcessedArgs processedArgs paramTypes callSubst state1a

resultMonoType =
    callResultMonoType mvarEnv1 subst callSubst canType
```

Replace with:
```elm
let
    subst =
        fromCallerSubst callerSubst

    ( schemeInfo, state1a ) =
        getOrBuildSchemeInfo funcCanType (Just global) state1

    ( instSubstRaw, funcMonoTypeRaw, mvarEnv1 ) =
        TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv
            schemeInfo.argTypes schemeInfo.resultType argTypes

    instSubst : InstSubst
    instSubst =
        InstSubst instSubstRaw

    funcMonoType =
        Mono.forceCNumberToInt funcMonoTypeRaw

    paramTypes =
        extractParamTypes funcMonoType

    -- note: still using callerSubst here
    ( monoArgs, state2 ) =
        resolveProcessedArgs processedArgs paramTypes callerSubst state1a

    resultMonoType =
        callResultMonoType mvarEnv1 callerSubst instSubst canType
in
    -- enqueueSpec etc. using funcMonoType, monoArgs, resultMonoType
```

Key: `resolveProcessedArgs` takes `CallerSubst`, `callResultMonoType` gets both roles.
#### VarKernel / VarDebug

Use `InstSubst` in `deriveKernelAbiType` but keep `CallerSubst` for args:
```elm
let
    subst =
        fromCallerSubst callerSubst

    ( schemeInfo, state1a ) =
        getOrBuildSchemeInfo funcCanType (Just global) state1

    ( instSubstRaw, _, mvarEnv1 ) =
        TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv
            schemeInfo.argTypes schemeInfo.resultType argTypes

    instSubst : InstSubst
    instSubst =
        InstSubst instSubstRaw

    funcMonoType =
        deriveKernelAbiType state1a.ctx.mvarEnv kernelId funcCanType instSubst

    paramTypes =
        extractParamTypes funcMonoType

    ( monoArgs, state2 ) =
        resolveProcessedArgs processedArgs paramTypes callerSubst state1a

    resultMonoType =
        callResultMonoType mvarEnv1 callerSubst instSubst canType
in
    ...
```

You’ll adjust `deriveKernelAbiType` in §3.9 to accept an `InstSubst`.
### 3.7. Local multi‑target calls

Current pattern:
```elm
( callSubst, mvarEnv1 ) =
    TypeSubst.unifyArgsOnly state1a.ctx.mvarEnv funcCanType argTypes subst

( funcMonoType, mvarEnv2 ) =
    TypeSubst.applySubst mvarEnv1 callSubst funcCanType

paramTypes =
    extractParamTypes funcMonoType

( monoArgs, state2 ) =
    resolveProcessedArgs processedArgs paramTypes callSubst state1a

-- getOrCreateLocalInstance name funcMonoType callSubst ...
```

New pattern:
```elm
let
    subst =
        fromCallerSubst callerSubst

    ( instSubstRaw, mvarEnv1 ) =
        TypeSubst.unifyArgsOnly state1a.ctx.mvarEnv funcCanType argTypes

    instSubst : InstSubst
    instSubst =
        InstSubst instSubstRaw

    ( funcMonoType, mvarEnv2 ) =
        TypeSubst.applySubst mvarEnv1 instSubstRaw funcCanType

    paramTypes =
        extractParamTypes funcMonoType

    -- 1) Enrich callerSubst with the knowledge that funcCanType ~ funcMonoType
    ( enrichedSubstRaw, mvarEnv3 ) =
        TypeSubst.unifyExtend mvarEnv2 funcCanType funcMonoType subst

    enrichedCallerSubst : CallerSubst
    enrichedCallerSubst =
        CallerSubst enrichedSubstRaw

    state1b =
        { state1a | ctx = { state1a.ctx | mvarEnv = mvarEnv3 } }

    -- 2) Use enrichedCallerSubst to process arguments
    ( monoArgs, state2 ) =
        resolveProcessedArgs processedArgs paramTypes enrichedCallerSubst state1b

    -- 3) Use enrichedCallerSubst as the stored instance env for the local multi
    ( chosenName, state3 ) =
        getOrCreateLocalInstance name funcMonoType enrichedCallerSubst state2

    resultMonoType =
        callResultMonoType mvarEnv3 enrichedCallerSubst instSubst canType
in
    ...
```

Now:
- Instantiation (`instSubst`) is only used for: deriving `funcMonoType` and the call’s result.
- Local instance specialization always runs under a `CallerSubst` (`enrichedCallerSubst`), never under `InstSubst`.
### 3.8. Non‑local fallback calls: remove `InstSubst` pollution

Currently you have the only place where `callSubst` is used as environment:
```elm
( callSubst, funcMonoTypeRaw, mvarEnv1 ) =
    TypeSubst.unifyCallSiteDirect ... subst

...

( monoFunc, state3 ) =
    specializeExpr func callSubst state2
```

Replace with:
```elm
let
    subst =
        fromCallerSubst callerSubst

    ( schemeInfo, state1a ) =
        getOrBuildSchemeInfo funcCanType Nothing state1

    ( instSubstRaw, funcMonoTypeRaw, mvarEnv1 ) =
        TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv
            schemeInfo.argTypes schemeInfo.resultType argTypes

    instSubst : InstSubst
    instSubst =
        InstSubst instSubstRaw

    funcMonoType =
        Mono.forceCNumberToInt funcMonoTypeRaw

    paramTypes =
        extractParamTypes funcMonoType

    -- Use callerSubst to resolve args (not instSubst)
    ( monoArgs, state2 ) =
        resolveProcessedArgs processedArgs paramTypes callerSubst state1a

    -- Now reconcile funcCanType with funcMonoType to enrich callerSubst
    ( enrichedSubstRaw, mvarEnv2 ) =
        TypeSubst.unifyExtend mvarEnv1 funcCanType funcMonoType subst

    enrichedCallerSubst : CallerSubst
    enrichedCallerSubst =
        CallerSubst enrichedSubstRaw

    state2a =
        { state2 | ctx = { state2.ctx | mvarEnv = mvarEnv2 } }

    -- Specialize func under enrichedCallerSubst, not instSubst
    ( monoFunc, state3 ) =
        specializeExpr func enrichedCallerSubst state2a

    resultMonoType =
        callResultMonoType mvarEnv2 enrichedCallerSubst instSubst canType
in
    ...
```

This removes the only direct contamination: `InstSubst` never flows into `specializeExpr`.
### 3.9. `resolveProcessedArgs` and `resolveProcessedArg` use `CallerSubst`

Change their signatures:
```elm
resolveProcessedArgs
    : List ProcessedArg -> List Mono.MonoType -> CallerSubst -> MonoState
    -> ( List Mono.Expr, MonoState )

resolveProcessedArg
    : ProcessedArg -> Maybe Mono.MonoType -> CallerSubst -> MonoState
    -> ( Mono.Expr, MonoState )
```

Inside, you typically do:
```elm
resolveProcessedArg processed maybeParamType callerSubst state =
    let
        subst =
            fromCallerSubst callerSubst
    in
    case processed of
        PendingGlobal savedExpr savedSubst canType ->
            ...
```
#### `PendingGlobal` branch

Ensure it enriches the **saved caller substitution**, not something else:
```elm
PendingGlobal savedExpr savedCallerSubst canType ->
    let
        savedSubst =
            fromCallerSubst savedCallerSubst

        refinedSubstRaw =
            case maybeParamType of
                Just paramType ->
                    Tuple.first
                        (TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType savedSubst)

                Nothing ->
                    savedSubst

        refinedCallerSubst =
            CallerSubst refinedSubstRaw
    in
    specializeExpr savedExpr refinedCallerSubst state
```
#### `LocalFunArg` branch

This represents passing a local function value. It should also use `CallerSubst`:
```elm
LocalFunArg name canType ->
    case maybeParamType of
        Just paramType ->
            if isFunctionType paramType then
                let
                    subst0 =
                        fromCallerSubst callerSubst

                    ( refinedSubstRaw, mvarEnv1 ) =
                        TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType subst0

                    refinedCallerSubst =
                        CallerSubst refinedSubstRaw

                    ( funcMonoType, _ ) =
                        TypeSubst.applySubst mvarEnv1 refinedSubstRaw canType

                    -- use refinedCallerSubst & funcMonoType for local multi, if needed
                in
                ...

            else
                -- treat as plain value: applySubst with callerSubst
                let
                    subst0 =
                        fromCallerSubst callerSubst

                    ( monoType, _ ) =
                        TypeSubst.applySubst state.ctx.mvarEnv subst0 canType
                in
                ...
        Nothing ->
            -- same as “not function” case: applySubst with callerSubst
            ...
```

The main point: this code *never* deals in `InstSubst`; it’s always about the current caller environment.
### 3.10. `deriveKernelAbiType`: accept `InstSubst` when called from calls

Signature today (per your table) is roughly:
```elm
deriveKernelAbiType : MVarEnv -> (String, String) -> Can.Type MVarId -> Substitution -> Mono.MonoType
```

Change to:
```elm
deriveKernelAbiType : MVarEnv -> (String, String) -> Can.Type MVarId -> InstSubst -> Mono.MonoType
```

Implementation:
```elm
deriveKernelAbiType mvarEnv kernelId canFuncType instSubst =
    let
        instDict =
            fromInstSubst instSubst

        monoAfterSubst =
            Mono.forceCNumberToInt
                (Tuple.first (TypeSubst.applySubst mvarEnv instDict canFuncType))

        mode =
            deriveKernelAbiMode kernelId canFuncType mvarEnv
    in
    case mode of
        NumberBoxed ->
            if isFullyMonomorphic monoAfterSubst then
                monoAfterSubst
            else
                canTypeToMonoType_numberBoxed canFuncType

        UseSubstitution ->
            monoAfterSubst

        PreserveVars ->
            if containerSpecialized && isFullyMonomorphic monoAfterSubst then
                monoAfterSubst
            else
                canTypeToMonoType_preserveVars canFuncType
```

Then:
- In `Call -> VarKernel` / `VarDebug` branches, pass in the `InstSubst`.
- In any other usages that conceptually use callerSubst (e.g. standalone kernel refs), add a small adapter:
  ```elm
  deriveKernelAbiTypeFromCaller : MVarEnv -> (String, String) -> Can.Type MVarId -> CallerSubst -> Mono.MonoType
  deriveKernelAbiTypeFromCaller mvarEnv kernelId canFuncType callerSubst =
      let
          instSubst =
              InstSubst (fromCallerSubst callerSubst)
      in
      deriveKernelAbiType mvarEnv kernelId canFuncType instSubst
  ```

  and use that where appropriate.
---
## 4. Transitional / mechanical notes

1. **Compilation strategy**

   - First introduce the new types and helpers in `State.elm`.
   - Then update `Specialize.elm` function signatures to use `CallerSubst`, and insert `fromCallerSubst`/`CallerSubst` wrappers as needed without changing logic.
   - Then change `unifyCallSiteDirect` / `unifyArgsOnly` signatures in `TypeSubst.elm` and update all call sites to adapt them into `InstSubst`.
   - Finally, update `callResultMonoType`, call branches, `resolveProcessedArgs`, `resolveProcessedArg`, and `deriveKernelAbiType`.
2. **Renaming locals**

   - For clarity, always name variables:

     ```elm
     callerSubst : CallerSubst
     instSubst   : InstSubst
     subst       : Substitution  -- only as an unwrapped local
     ```

   - Remove or rename old `callSubst` variables; reserve that name for `InstSubst` *inside* a call branch if you like, but be consistent.

3. **Assertions / debug checks**

   You can add optional debug helpers (guarded by a flag) to assert invariants:
   ```elm
   assertInstSubstNotUsedAsCaller : InstSubst -> a
   assertInstSubstNotUsedAsCaller _ =
       Debug.crash "InstSubst must not be passed as CallerSubst"
   ```

   and temporarily sprinkle them where you’re unsure, to catch any remaining misuse.
---
## 5. What this fixes, explicitly

With this design in place:
- **Scheme instantiation** is always done in a clean, per‑call `InstSubst` coming from `Dict.empty`.
- **Caller environments** (`CallerSubst`) are only enriched via canonical types of the defs they own (through `unify`/`unifyExtend`), never by binding scheme variables directly.
- Non‑local and local‑multi calls no longer run their bodies under a polluted `InstSubst`; instead, they get a properly reconciled `CallerSubst` that matches their own canonical type.
- `callResultMonoType` bases the result on the InstSubst, so higher‑order return types like `b` in `Maybe.map : (a -> b) -> Maybe a -> Maybe b` are resolved per call context, rather than being accidentally collapsed to `a`.

That combination should eliminate the whole “callSubst pollution / substitution contamination” class, while your existing (or planned) scheme freshening keeps the scheme cache itself safe with respect to MVarId collisions.
