# MonoDirect Fixes 1–5 — Implementation Plan

## Scope

Implement five fixes in MonoDirect's solver-directed monomorphization:

1. **Fix 1**: CEcoValue type refinement — use `Mono.typeOf` on specialized children to sharpen types that still contain `MVar _ CEcoValue`
2. **Fix 2**: Two-phase accessor & number-boxed kernel specialization
3. **Fix 3**: VarEnv save/reset across `if` branches
4. **Fix 4**: Function-cycle handling
5. **Fix 5**: Local multi-specialization wiring

All changes stay within MonoDirect's design (solver-driven, no `fillUnconstrainedCEcoWithErased`, no early `MErased` insertion).

---

## Files to modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/MonoDirect/Specialize.elm` | Fixes 1, 2, 3, 4, 5 |
| `compiler/src/Compiler/MonoDirect/State.elm` | Fixes 2, 5 |

---

## Fix 3: VarEnv save/reset in `specializeBranches`

**Simplest fix, do first.**

### What

`specializeBranches` (line 845) threads `MonoDirectState` straight through the branch list without resetting `varEnv` between branches. Bindings from earlier branches leak into later ones.

`specializeDecider` (line 862) and `specializeJumps` (line 920) already save/restore `varEnv`. This fix makes `specializeBranches` consistent.

### Implementation

**File:** `Specialize.elm`, lines 845-859

Save `varEnv` before the fold and reset it at the start of each branch iteration:

```elm
specializeBranches view snapshot branches state0 =
    let
        savedVarEnv = state0.varEnv
    in
    List.foldl
        (\( cond, thenExpr ) ( acc, s ) ->
            let
                sWithReset = { s | varEnv = savedVarEnv }
                ( monoCond, s1 ) = specializeExpr view snapshot cond sWithReset
                ( monoThen, s2 ) = specializeExpr view snapshot thenExpr s1
            in
            ( acc ++ [ ( monoCond, monoThen ) ], s2 )
        )
        ( [], state0 )
        branches
```

### Verification

Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — three-way-if / control-flow comparison tests should improve.

---

## Fix 1: CEcoValue type refinement (no early MErased)

### What

MonoDirect currently uses `resolveType view meta` (which calls `view.monoTypeOf tvar`) for all expression types. This correctly never produces `MErased` — unconstrained CEcoValue TVars stay as `MVar name CEcoValue`, and the post-hoc erasure pass in `assembleRawGraph` handles conversion later.

However, MonoDirect has **no** `containsCEcoMVar`-based refinement. The standard monomorphizer checks whether a resolved type still contains `MVar _ CEcoValue` and, when it does, sharpens the type using `Mono.typeOf` on already-specialized child expressions. MonoDirect skips this entirely, which means types that *could* be concrete (e.g., `MList (MVar "a" CEcoValue)` when the list contains `MInt` elements) stay imprecise.

### Design principles

1. **Never** insert `MErased` during specialization. No `fillUnconstrainedCEcoWithErased`, no `eraseCEcoVarsToErased` calls in Specialize.elm.
2. **Do** sharpen types using `Mono.typeOf` on specialized children when `resolveType` returns a type containing `MVar _ CEcoValue`.
3. Leave genuinely unconstrained `MVar _ CEcoValue` alone — the existing `assembleRawGraph` post-hoc erasure handles them.

### Current state verified

- `view.monoTypeOf` in `SolverSnapshot.elm` (line 237) calls `TypeSubst.canTypeToMonoType Dict.empty`, which maps `TVar` with CEcoValue constraint to `MVar name CEcoValue` (line 705-707 in TypeSubst.elm). It **never** produces `MErased`. This is correct.
- `resolveType` (line 207) crashes if `monoTypeOf` returns `MErased`, enforcing the invariant.
- `assembleRawGraph` (line 316 in Monomorphize.elm) applies three-way CEco erasure after the graph is built: `patchNodeTypesCEcoToErased`, `patchInternalExprCEcoToErased`, and `patchNodeTypesToErased`.
- MonoDirect currently has **zero** uses of `Mono.containsCEcoMVar` — no refinement logic exists.

### Implementation

Add `containsCEcoMVar`-guarded refinement to the expression constructors where the standard monomorphizer does it. In each case, when `resolveType view meta` returns a type with CEcoValue vars, prefer the more concrete type derived from specialized children. When children don't provide a more concrete type, keep the original (CEcoValue vars will be erased later in `assembleRawGraph`).

#### Step 1a: List refinement

**File:** `Specialize.elm`, `TOpt.List` case (currently lines 372-380)

Current:
```elm
TOpt.List region items meta ->
    let
        monoType = resolveType view meta
        ( monoItems, state1 ) = specializeExprs view snapshot items state
    in
    ( Mono.MonoList region monoItems monoType, state1 )
```

Change to:
```elm
TOpt.List region items meta ->
    let
        monoType0 = resolveType view meta
        ( monoItems, state1 ) = specializeExprs view snapshot items state
        monoType =
            if Mono.containsCEcoMVar monoType0 then
                case monoItems of
                    first :: _ ->
                        Mono.MList (Mono.typeOf first)
                    [] ->
                        monoType0  -- keep CEco var; post-hoc erasure handles it
            else
                monoType0
    in
    ( Mono.MonoList region monoItems monoType, state1 )
```

#### Step 1b: If refinement

**File:** `Specialize.elm`, `TOpt.If` case (currently lines 404-416)

Current:
```elm
TOpt.If branches final meta ->
    let
        monoType = resolveType view meta
        ( monoBranches, state1 ) = specializeBranches view snapshot branches state
        ( monoFinal, state2 ) = specializeExpr view snapshot final state1
    in
    ( Mono.MonoIf monoBranches monoFinal monoType, state2 )
```

Change to:
```elm
TOpt.If branches final meta ->
    let
        monoType0 = resolveType view meta
        ( monoBranches, state1 ) = specializeBranches view snapshot branches state
        ( monoFinal, state2 ) = specializeExpr view snapshot final state1
        monoType =
            if Mono.containsCEcoMVar monoType0 then
                Mono.typeOf monoFinal
            else
                monoType0
    in
    ( Mono.MonoIf monoBranches monoFinal monoType, state2 )
```

#### Step 1c: Let refinement (value defs)

**File:** `Specialize.elm`, `specializeLet`, `TOpt.Def` non-function case (currently lines 697-714)

The current code already uses `Mono.typeOf monoDefExpr` for `defMonoType` and inserts that into VarEnv (line 703-706). This is correct. However, the **result type** of the `MonoLet` node uses `monoType` from `resolveType view meta` (line 694), which could still contain CEcoValue vars even when the body's type is concrete.

Change the final result type:
```elm
-- Current: ( Mono.MonoLet monoDef monoBody monoType, state3 )
-- Change to:
let
    letResultType =
        if Mono.containsCEcoMVar monoType then
            Mono.typeOf monoBody
        else
            monoType
in
( Mono.MonoLet monoDef monoBody letResultType, state3 )
```

#### Step 1d: Let refinement (TailDef)

**File:** `Specialize.elm`, `specializeLet`, `TOpt.TailDef` case (lines 716-756)

Same pattern — the outer `monoType` from `resolveType view meta` might contain CEcoValue vars. Refine from body:
```elm
let
    letResultType =
        if Mono.containsCEcoMVar monoType then
            Mono.typeOf monoBody
        else
            monoType
in
( Mono.MonoLet monoDef monoBody letResultType, state6 )
```

#### Step 1e: Destruct refinement

**File:** `Specialize.elm`, `TOpt.Destruct` case (currently lines 418-435)

The current code:
```elm
TOpt.Destruct destructor expr meta ->
    let
        monoType = resolveType view meta
        monoDestructor = specializeDestructor view state.varEnv state.globalTypeEnv destructor
        ( monoExpr, state1 ) = specializeExpr view snapshot expr state
        destructName = ...
        state2 = { state1 | varEnv = State.insertVar destructName destructPathType state1.varEnv }
    in
    ( Mono.MonoDestruct monoDestructor monoExpr monoType, state2 )
```

The bound variable (`destructName`) type is derived from the destructor path type. The expression type used for VarEnv should come from the specialized destructor, not from a raw canonical conversion. This is already mostly correct, but ensure the overall `monoType` also benefits:

```elm
let
    resultType =
        if Mono.containsCEcoMVar monoType then
            Mono.typeOf monoExpr
        else
            monoType
in
( Mono.MonoDestruct monoDestructor monoExpr resultType, state2 )
```

#### Step 1f: Case refinement

**File:** `Specialize.elm`, `TOpt.Case` case (currently lines 436-460)

Add inference from specialized jumps/decider when the canonical result type has CEcoValue vars:

```elm
TOpt.Case name1 name2 decider jumps meta ->
    let
        monoType0 = resolveType view meta
        ...
        ( monoDecider, state1 ) = specializeDecider view snapshot decider state
        ( monoJumps, state2 ) = specializeJumps view snapshot jumps state1

        monoType =
            if Mono.containsCEcoMVar monoType0 then
                inferCaseType monoJumps monoDecider monoType0
            else
                monoType0
    in
    ( Mono.MonoCase name1 name2 monoDecider monoJumps monoType, state2 )
```

Add an `inferCaseType` helper that picks the first concrete branch type:
```elm
inferCaseType :
    List ( Int, Mono.MonoExpr )
    -> Mono.Decider Mono.MonoChoice
    -> Mono.MonoType
    -> Mono.MonoType
inferCaseType jumps decider fallback =
    case jumps of
        ( _, expr ) :: _ ->
            Mono.typeOf expr
        [] ->
            case firstLeafType decider of
                Just t -> t
                Nothing -> fallback

firstLeafType : Mono.Decider Mono.MonoChoice -> Maybe Mono.MonoType
firstLeafType decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) -> Just (Mono.typeOf expr)
        Mono.Chain _ success _ -> firstLeafType success
        Mono.FanOut _ tests _ ->
            case tests of
                ( _, sub ) :: _ -> firstLeafType sub
                [] -> Nothing
        _ -> Nothing
```

#### Step 1g: Record-related refinement

Records (`TOpt.Record`, `TOpt.TrackedRecord`, `TOpt.Update`) typically have fully-resolved types from the solver since record fields are concrete. No special refinement needed — `resolveType view meta` should give a concrete `MRecord` already. Skip these unless tests show otherwise.

#### Step 1h: Tuple refinement

Tuples are similar to records — `resolveType view meta` should produce concrete types. However, if needed:

```elm
TOpt.Tuple region a b rest meta ->
    let
        monoType0 = resolveType view meta
        ( monoA, state1 ) = specializeExpr view snapshot a state
        ( monoB, state2 ) = specializeExpr view snapshot b state1
        ( monoRest, state3 ) = specializeExprs view snapshot rest state2
        monoType =
            if Mono.containsCEcoMVar monoType0 then
                Mono.MTuple (List.map Mono.typeOf (monoA :: monoB :: monoRest))
            else
                monoType0
    in
    ( Mono.MonoTupleCreate region (monoA :: monoB :: monoRest) monoType, state3 )
```

#### Step 1i: No changes to `SolverSnapshot.elm`

`monoTypeOf` already satisfies the contract:
- Reflects solver constraints via `Type.toCanTypeBatch`
- Never returns `MErased` (unconstrained CEcoValue → `MVar name CEcoValue`)
- CNumber defaults to `MInt` when unresolved

No changes needed to `buildLocalView` or `SolverSnapshot.elm`.

#### Step 1j: Remaining `TypeSubst.applySubst` in MonoDirect

Two uses remain in `Specialize.elm` (lines 1160 and 1197), both in `computeCustomFieldType` and `computeUnboxResultType`. These are **not** expression-layer typing — they compute field types from the `GlobalTypeEnv` union definitions using a substitution map built from `MCustom` type args. This is correct and necessary (the solver doesn't track individual constructor field types). No change needed.

### Summary of Fix 1 changes

| Location | Change |
|----------|--------|
| `TOpt.List` | Sharpen to `MList (typeOf first)` when CEco vars present |
| `TOpt.If` | Use `typeOf monoFinal` when CEco vars present |
| `TOpt.Let` (Def, TailDef) | Use `typeOf monoBody` for let result type when CEco vars present |
| `TOpt.Destruct` | Use `typeOf monoExpr` when CEco vars present |
| `TOpt.Case` | Add `inferCaseType` helper; use branch type when CEco vars present |
| `TOpt.Tuple` | Use `MTuple (map typeOf children)` when CEco vars present |
| `SolverSnapshot.elm` | No changes needed |

---

## Fix 4: Function-cycle handling in `specializeCycle`

### What

`specializeCycle` (line 763) ignores `funcDefs` entirely — only value defs are specialized into `MonoCycle`. Recursive function parameters are never bound in `VarEnv`, causing "Root variable not found" crashes.

### Design decision (Q1 resolved)

**Do NOT put function defs into `MonoCycle`.** `MonoCycle` is strictly for value-only cycles. When a `TOpt.Cycle` has function defs, the standard monomorphizer (`specializeFunctionCycle`, line 858) creates *separate* `MonoNode`s for each function (via the registry and worklist), never wrapping them in `MonoCycle`.

MonoDirect should mirror this: when `funcDefs` is non-empty, emit each function as a separate `MonoNode` keyed by its `SpecId` in the registry, and return the requested function's node as the result.

### Implementation

**File:** `Specialize.elm`

#### Step 4a: Add `specializeFuncDefInCycle` helper

Place after `specializeCycle` (line 782). This mirrors the standard monomorphizer's `specializeFuncDefInCycle` (line 959) but uses solver-driven types:

```elm
specializeFuncDefInCycle :
    LocalView -> SolverSnapshot -> TOpt.Def -> MonoDirectState
    -> ( Mono.MonoNode, MonoDirectState )
```

- `TOpt.TailDef`: Resolve func type via `resolveType view`, flatten to get param types, push VarEnv frame, bind params, specialize body, pop frame. Return `Mono.MonoTailFunc monoParams monoBody monoFuncType`.
- `TOpt.Def`: Specialize the expression, return `Mono.MonoDefine monoExpr (Mono.typeOf monoExpr)`.

Note: Returns `Mono.MonoNode` (not `MonoDef`) — these are top-level registry entries like `MonoTailFunc` / `MonoDefine`, matching the standard monomorphizer.

#### Step 4b: Add `specializeFunc` helper

Mirrors the standard monomorphizer's `specializeFunc` (line 904). For each funcDef in the cycle:

1. Get the function's name and canonical type
2. Compute `monoTypeFromDef` via `resolveType view` using the shared `LocalView`
3. For the requested function, use `requestedMonoType` as the spec key; for siblings, use `monoTypeFromDef`
4. Call `Registry.getOrCreateSpecId` to get a `SpecId`
5. If the specId isn't already in the accumulated nodes dict, call `specializeFuncDefInCycle` and insert the resulting node

```elm
specializeFunc :
    IO.Canonical -> Name -> Mono.MonoType -> LocalView -> SolverSnapshot
    -> TOpt.Def -> ( Dict Int Mono.MonoNode, MonoDirectState )
    -> ( Dict Int Mono.MonoNode, MonoDirectState )
```

#### Step 4c: Update `specializeCycle`

Replace the body (lines 763-782) with a dispatch:

```elm
specializeCycle snapshot names valueDefs funcDefs requestedMonoType state =
    case ( List.isEmpty funcDefs, state.currentGlobal ) of
        ( True, _ ) ->
            -- Value-only cycle: existing behavior
            SolverSnapshot.withLocalUnification snapshot [] []
                (\view -> ... specialize valueDefs, return MonoCycle ...)

        ( False, Nothing ) ->
            -- No currentGlobal context: can't register function nodes
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            -- Function cycle: emit separate nodes per function
            SolverSnapshot.withLocalUnification snapshot [] []
                (\view ->
                    let
                        ( newNodes, stateAfter ) =
                            List.foldl
                                (specializeFunc requestedCanonical requestedName
                                    requestedMonoType view snapshot)
                                ( state.nodes, state )
                                funcDefs

                        requestedGlobal = Mono.Global requestedCanonical requestedName
                        ( requestedSpecId, _ ) =
                            Registry.getOrCreateSpecId requestedGlobal
                                requestedMonoType Nothing stateAfter.registry
                    in
                    case Dict.get requestedSpecId newNodes of
                        Just requestedNode ->
                            ( requestedNode
                            , { stateAfter | nodes = newNodes }
                            )
                        Nothing ->
                            ( Mono.MonoExtern requestedMonoType
                            , { stateAfter | nodes = newNodes }
                            )
                )

        ( False, Just (Mono.Accessor _) ) ->
            ( Mono.MonoExtern requestedMonoType, state )
```

#### Step 4d: Pre-bind function names in VarEnv (Q4 resolved: yes)

Inside the function-cycle path, before specializing any bodies, resolve each funcDef's type and insert into VarEnv so mutual recursion works. This happens as a pre-pass before the `List.foldl` over `specializeFunc`.

### Verification

Function-cycle tests and "Root variable not found" crashes should be resolved.

---

## Fix 2: Two-phase accessor & number-boxed kernel specialization

### What

Currently `specializeCall` (line 558) specializes all arguments eagerly via `specializeExprs`. Accessors and number-boxed kernels as arguments need deferred specialization to see fully-resolved types from the callee's parameter signature.

### Design decisions resolved

- **Q2 (Accessors):** Use `enqueueSpec` with `Mono.Accessor` virtual globals, matching the standard monomorphizer. Do NOT build inline closures. MonoDirect already does this for standalone accessors (line 483-494).
- **Q3 (Parameter types):** `finishProcessedArgs` receives *callee parameter types* (from `Closure.flattenFunctionType funcMonoType`), NOT argument types. This is required for accessor resolution — the accessor needs the callee's expected record type.
- **Q6 (TrackedVarLocal):** Handle both `VarLocal` and `TrackedVarLocal` for `LocalFunArg` detection, mirroring the standard monomorphizer.

### Implementation

#### Step 2a: Add `ProcessedArg` type

**File:** `Specialize.elm`, near the top after imports (around line 32)

```elm
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type
    | PendingKernel A.Region String String TOpt.Meta  -- carries full Meta for tvar
    | LocalFunArg Name Can.Type
```

Note: `PendingKernel` stores full `TOpt.Meta` (not just `Can.Type`) because `deriveKernelAbiTypeDirect` requires `meta.tvar` (crashes on `Nothing` at line 1262).

#### Step 2b: Add `isLocalMultiTarget` to State.elm

**File:** `State.elm`

```elm
isLocalMultiTarget : Name -> MonoDirectState -> Bool
isLocalMultiTarget name state =
    List.any (\ls -> ls.defName == name) state.localMulti
```

Add to the `exposing` list in the module header.

#### Step 2c: Add `processCallArgs`

**File:** `Specialize.elm`

Walks call arguments and classifies them. Uses solver-driven types (NOT `TypeSubst`):

```elm
processCallArgs :
    LocalView -> SolverSnapshot -> List TOpt.Expr -> MonoDirectState
    -> ( List ProcessedArg, List Mono.MonoType, MonoDirectState )
processCallArgs view snapshot args state0 =
    List.foldr
        (\arg ( accArgs, accTypes, st ) ->
            case arg of
                TOpt.Accessor region fieldName accessorMeta ->
                    -- Defer: use resolveType for preliminary type reasoning only
                    let monoType = resolveType view accessorMeta
                    in
                    ( PendingAccessor region fieldName accessorMeta.tipe :: accArgs
                    , monoType :: accTypes, st )

                TOpt.VarKernel region home name kernelMeta ->
                    case KernelAbi.deriveKernelAbiMode ( home, name ) kernelMeta.tipe of
                        KernelAbi.NumberBoxed ->
                            let monoType = resolveType view kernelMeta
                            in
                            ( PendingKernel region home name kernelMeta :: accArgs
                            , monoType :: accTypes, st )
                        _ ->
                            -- Non-number-boxed: specialize immediately
                            let ( monoExpr, st1 ) = specializeExpr view snapshot arg st
                            in
                            ( ResolvedArg monoExpr :: accArgs
                            , Mono.typeOf monoExpr :: accTypes, st1 )

                TOpt.VarLocal name localMeta ->
                    if State.isLocalMultiTarget name st then
                        let monoType = resolveType view localMeta
                        in
                        ( LocalFunArg name localMeta.tipe :: accArgs
                        , monoType :: accTypes, st )
                    else
                        let ( monoExpr, st1 ) = specializeExpr view snapshot arg st
                        in
                        ( ResolvedArg monoExpr :: accArgs
                        , Mono.typeOf monoExpr :: accTypes, st1 )

                TOpt.TrackedVarLocal _ name trackedMeta ->
                    if State.isLocalMultiTarget name st then
                        let monoType = resolveType view trackedMeta
                        in
                        ( LocalFunArg name trackedMeta.tipe :: accArgs
                        , monoType :: accTypes, st )
                    else
                        let ( monoExpr, st1 ) = specializeExpr view snapshot arg st
                        in
                        ( ResolvedArg monoExpr :: accArgs
                        , Mono.typeOf monoExpr :: accTypes, st1 )

                _ ->
                    let ( monoExpr, st1 ) = specializeExpr view snapshot arg st
                    in
                    ( ResolvedArg monoExpr :: accArgs
                    , Mono.typeOf monoExpr :: accTypes, st1 )
        )
        ( [], [], state0 )
        args
```

Note: uses `List.foldr` (not `foldl`) to match the standard monomorphizer and preserve argument order without reversal.

#### Step 2d: Add `finishProcessedArgs`

**File:** `Specialize.elm`

Resolves deferred args using the callee's parameter types:

```elm
finishProcessedArgs :
    LocalView -> List ProcessedArg -> List Mono.MonoType -> MonoDirectState
    -> ( List Mono.MonoExpr, MonoDirectState )
finishProcessedArgs view processedArgs paramTypes state0 =
    let
        step processedArg ( acc, st, remainingParams ) =
            let
                ( maybeParam, rest ) =
                    case remainingParams of
                        p :: ps -> ( Just p, ps )
                        []      -> ( Nothing, [] )
                ( monoExpr, st1 ) =
                    finishProcessedArg view processedArg maybeParam st
            in
            ( monoExpr :: acc, st1, rest )

        ( revArgs, finalState, _ ) =
            List.foldl step ( [], state0, paramTypes ) processedArgs
    in
    ( List.reverse revArgs, finalState )
```

#### Step 2e: Add `finishProcessedArg` (single-arg resolver)

```elm
finishProcessedArg :
    LocalView -> ProcessedArg -> Maybe Mono.MonoType -> MonoDirectState
    -> ( Mono.MonoExpr, MonoDirectState )
finishProcessedArg view processedArg maybeParamType state =
    case processedArg of
        ResolvedArg monoExpr ->
            ( monoExpr, state )

        PendingAccessor region fieldName _ ->
            -- Use callee's parameter type to derive accessor's record layout
            case maybeParamType of
                Just (Mono.MFunction [ Mono.MRecord fields ] _) ->
                    resolveAccessor region fieldName fields state

                Just (Mono.MRecord fields) ->
                    resolveAccessor region fieldName fields state

                _ ->
                    Utils.Crash.crash
                        ("MonoDirect.finishProcessedArg: Accessor ."
                            ++ fieldName
                            ++ " did not receive record parameter type")

        PendingKernel region home name kernelMeta ->
            -- kernelMeta carries the full TOpt.Meta including tvar
            let
                kernelMonoType =
                    deriveKernelAbiTypeDirect ( home, name ) kernelMeta view
            in
            ( Mono.MonoVarKernel region home name kernelMonoType, state )

        LocalFunArg name _ ->
            -- Placeholder: full wiring in Fix 5
            case maybeParamType of
                Just paramType ->
                    ( Mono.MonoVarLocal name paramType, state )
                Nothing ->
                    Utils.Crash.crash
                        ("MonoDirect.finishProcessedArg: LocalFunArg "
                            ++ name ++ " with no parameter type")
```

**`resolveAccessor` helper** (mirrors standard monomorphizer's accessor path):
```elm
resolveAccessor : A.Region -> Name -> Dict Name Mono.MonoType -> MonoDirectState
    -> ( Mono.MonoExpr, MonoDirectState )
resolveAccessor region fieldName fields state =
    let
        fieldType = case Dict.get fieldName fields of
            Just ft -> ft
            Nothing -> Utils.Crash.crash ("MonoDirect: field '" ++ fieldName ++ "' not in record")
        recordType = Mono.MRecord fields
        accessorMonoType = Mono.MFunction [ recordType ] fieldType
        accessorGlobal = Mono.Accessor fieldName
        ( specId, state1 ) = enqueueSpec accessorGlobal accessorMonoType Nothing state
    in
    ( Mono.MonoVarGlobal region specId accessorMonoType, state1 )
```

#### Step 2f: Update `specializeCall` to use two-phase processing

Replace `specializeCall` (line 558-619):

```elm
specializeCall view snapshot region func args meta state =
    let
        resultType = resolveType view meta

        -- Phase 1: classify args, deferring accessors/kernels/local-multi
        ( processedArgs, argTypes, state1 ) =
            processCallArgs view snapshot args state
    in
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            let
                funcMonoType = ... -- same as current (resolveType or buildCurriedFuncType)
                ( paramTypes, _ ) = Closure.flattenFunctionType funcMonoType
                monoGlobal = toptGlobalToMono global
                ( specId, state2 ) = enqueueSpec monoGlobal funcMonoType Nothing state1
                monoFunc = Mono.MonoVarGlobal funcRegion specId funcMonoType

                -- Phase 2: resolve deferred args using callee param types
                ( monoArgs, state3 ) =
                    finishProcessedArgs view processedArgs paramTypes state2
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )

        TOpt.VarKernel funcRegion home name funcMeta ->
            let
                funcMonoType = deriveKernelAbiTypeDirect ( home, name ) funcMeta view
                ( paramTypes, _ ) = Closure.flattenFunctionType funcMonoType
                monoFunc = Mono.MonoVarKernel funcRegion home name funcMonoType
                ( monoArgs, state2 ) =
                    finishProcessedArgs view processedArgs paramTypes state1
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )

        TOpt.VarDebug funcRegion name home _ funcMeta ->
            let
                funcMonoType = deriveKernelAbiTypeDirect ( "Debug", name ) funcMeta view
                ( paramTypes, _ ) = Closure.flattenFunctionType funcMonoType
                monoFunc = Mono.MonoVarKernel funcRegion "Debug" name funcMonoType
                ( monoArgs, state2 ) =
                    finishProcessedArgs view processedArgs paramTypes state1
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state2 )

        TOpt.VarLocal name funcMeta ->
            -- Check for local-multi target at call site
            if State.isLocalMultiTarget name state1 then
                let
                    funcMonoType = resolveType view funcMeta
                    ( paramTypes, _ ) = Closure.flattenFunctionType funcMonoType
                    ( freshName, state2 ) =
                        State.getOrCreateLocalInstance name funcMonoType state1
                    monoFunc = Mono.MonoVarLocal freshName funcMonoType
                    ( monoArgs, state3 ) =
                        finishProcessedArgs view processedArgs paramTypes state2
                in
                ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )
            else
                let
                    ( monoFunc, state2 ) = specializeExpr view snapshot func state1
                    funcMonoType = Mono.typeOf monoFunc
                    ( paramTypes, _ ) = Closure.flattenFunctionType funcMonoType
                    ( monoArgs, state3 ) =
                        finishProcessedArgs view processedArgs paramTypes state2
                in
                ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )

        _ ->
            let
                ( monoFunc, state2 ) = specializeExpr view snapshot func state1
                funcMonoType = Mono.typeOf monoFunc
                ( paramTypes, _ ) = Closure.flattenFunctionType funcMonoType
                ( monoArgs, state3 ) =
                    finishProcessedArgs view processedArgs paramTypes state2
            in
            ( Mono.MonoCall region monoFunc monoArgs resultType Mono.defaultCallInfo, state3 )
```

Note: The `VarLocal` callee case handles local-multi targets directly at the call site (Fix 5 wiring).

---

## Fix 5: Local multi-specialization wiring

### What

Enable demand-driven multi-specialization of polymorphic let-bound functions. When `let f x = ...` is used at multiple concrete types in the body, emit separate specialized instances.

### Design decisions resolved

- **Q5 (No tvar on TOpt.Def):** Drive local multi-specialization purely off call-site types from `resolveType view meta`. For each discovered instance `{ freshName, monoType }`, re-specialize `defExpr` by pushing a VarEnv frame with param types derived from `Closure.flattenFunctionType info.monoType`. No solver tvar on the Def is needed — the call-site types fully determine parameter bindings.
- **Q8 (No subst field):** `LocalInstanceInfo` keeps only `{ freshName, monoType }`. No `subst : Substitution` field — MonoDirect doesn't use TypeSubst.

### Implementation

#### Step 5a: Add `getOrCreateLocalInstance` and `updateLocalMultiStack` to State.elm

**File:** `State.elm`

```elm
getOrCreateLocalInstance :
    Name -> Mono.MonoType -> MonoDirectState -> ( Name, MonoDirectState )
getOrCreateLocalInstance defName funcMonoType state =
    let
        key = Mono.toComparableMonoType funcMonoType
        ( updatedStack, freshName ) =
            updateLocalMultiStack defName key funcMonoType state.localMulti
    in
    ( freshName, { state | localMulti = updatedStack } )


updateLocalMultiStack :
    Name -> List String -> Mono.MonoType -> List LocalMultiState
    -> ( List LocalMultiState, Name )
updateLocalMultiStack defName key funcMonoType stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("MonoDirect.State.updateLocalMultiStack: defName not found: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Dict.get key entry.instances of
                    Just info ->
                        ( stack, info.freshName )

                    Nothing ->
                        let
                            freshIndex = Dict.size entry.instances
                            freshName =
                                if freshIndex == 0 then defName
                                else defName ++ "$" ++ String.fromInt freshIndex
                            newInfo = { freshName = freshName, monoType = funcMonoType }
                            newEntry = { entry | instances = Dict.insert key newInfo entry.instances }
                        in
                        ( newEntry :: rest, freshName )

            else
                let ( updatedRest, freshName ) =
                        updateLocalMultiStack defName key funcMonoType rest
                in
                ( entry :: updatedRest, freshName )
```

Add to the module `exposing` list: `isLocalMultiTarget`, `getOrCreateLocalInstance`.

#### Step 5b: Update `specializeLet` for function def multi-specialization

**File:** `Specialize.elm`, replace the `TOpt.Def` branch (lines 697-714)

For `TOpt.Def` when `defCanType` is `Can.TLambda _ _`:

```elm
TOpt.Def defRegion defName defExpr defCanType ->
    case defCanType of
        Can.TLambda _ _ ->
            -- Function def: demand-driven local multi-specialization
            let
                newEntry = { defName = defName, instances = Dict.empty }
                stateForBody = { state | localMulti = newEntry :: state.localMulti }

                -- Specialize body first to discover call-site instances
                ( monoBody, stateAfterBody ) =
                    specializeExpr view snapshot body stateForBody
            in
            case stateAfterBody.localMulti of
                topEntry :: restOfStack ->
                    if Dict.isEmpty topEntry.instances then
                        -- No calls recorded: single-instance fallback
                        let
                            ( monoDefExpr, state1 ) =
                                specializeExpr view snapshot defExpr
                                    { stateAfterBody | localMulti = restOfStack }
                            defMonoType = Mono.typeOf monoDefExpr
                            state2 = { state1 | varEnv = State.insertVar defName defMonoType state1.varEnv }
                            -- Re-specialize body with defName bound
                            ( monoBody2, state3 ) = specializeExpr view snapshot body state2
                            monoDef = Mono.MonoDef defName monoDefExpr
                            letResultType =
                                if Mono.containsCEcoMVar monoType then
                                    Mono.typeOf monoBody2
                                else
                                    monoType
                        in
                        ( Mono.MonoLet monoDef monoBody2 letResultType, state3 )

                    else
                        -- Multiple instances discovered from call sites
                        let
                            instancesList = Dict.values topEntry.instances
                            statePopped = { stateAfterBody | localMulti = restOfStack }

                            -- For each instance: re-specialize defExpr with param
                            -- types derived from instance.monoType
                            ( instanceDefs, stateWithDefs ) =
                                List.foldl
                                    (\info ( defsAcc, stAcc ) ->
                                        let
                                            ( monoDef, st1 ) =
                                                specializeDefForInstance view snapshot
                                                    defName defExpr info stAcc
                                        in
                                        ( monoDef :: defsAcc, st1 )
                                    )
                                    ( [], statePopped )
                                    instancesList

                            -- Register all instance names in VarEnv
                            stateWithVars =
                                List.foldl
                                    (\info st ->
                                        { st | varEnv =
                                            State.insertVar info.freshName info.monoType st.varEnv
                                        }
                                    )
                                    stateWithDefs
                                    instancesList

                            -- Build nested MonoLet chain wrapping monoBody
                            finalExpr =
                                List.foldl
                                    (\def_ accBody ->
                                        Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                                    )
                                    monoBody
                                    instanceDefs
                        in
                        ( finalExpr, stateWithVars )

                [] ->
                    Utils.Crash.crash
                        "MonoDirect.specializeLet: localMulti stack underflow"

        _ ->
            -- Non-function def: original behavior with Fix 1 refinement
            let
                ( monoDefExpr, state1 ) = specializeExpr view snapshot defExpr state
                defMonoType = Mono.typeOf monoDefExpr
                state2 = { state1 | varEnv = State.insertVar defName defMonoType state1.varEnv }
                ( monoBody, state3 ) = specializeExpr view snapshot body state2
                monoDef = Mono.MonoDef defName monoDefExpr
                letResultType =
                    if Mono.containsCEcoMVar monoType then
                        Mono.typeOf monoBody
                    else
                        monoType
            in
            ( Mono.MonoLet monoDef monoBody letResultType, state3 )
```

#### Step 5c: Add `specializeDefForInstance` helper

Re-specializes `defExpr` with parameter types derived from an instance's `monoType`:

```elm
specializeDefForInstance :
    LocalView -> SolverSnapshot -> Name -> TOpt.Expr
    -> State.LocalInstanceInfo -> MonoDirectState
    -> ( Mono.MonoDef, MonoDirectState )
specializeDefForInstance view snapshot defName defExpr info state =
    let
        ( paramTypes, _ ) = Closure.flattenFunctionType info.monoType
    in
    case defExpr of
        TOpt.Function params body funcMeta ->
            -- Push frame, bind params with instance-derived types, specialize body
            let
                monoParams =
                    List.map2 (\( name, _ ) pt -> ( name, pt )) params
                        (padOrTruncate paramTypes (List.length params))
                state1 = { state | varEnv = State.pushFrame state.varEnv }
                state2 = List.foldl
                    (\( n, t ) s -> { s | varEnv = State.insertVar n t s.varEnv })
                    state1 monoParams
                ( monoBody, state3 ) = specializeExpr view snapshot body state2
                state4 = { state3 | varEnv = State.popFrame state3.varEnv }
            in
            ( Mono.MonoDef info.freshName
                (Mono.MonoClosure
                    { lambdaId = Mono.AnonymousLambda state.currentModule state.lambdaCounter
                    , captures = []
                    , params = monoParams
                    , closureKind = Nothing
                    , captureAbi = Nothing
                    }
                    monoBody
                    info.monoType
                )
            , { state4 | lambdaCounter = state4.lambdaCounter + 1 }
            )

        TOpt.TrackedFunction params body funcMeta ->
            -- Same as Function but with located params (A.At _ name)
            let
                unlocatedParams =
                    List.map (\( A.At _ name, tipe ) -> ( name, tipe )) params
                monoParams =
                    List.map2 (\( name, _ ) pt -> ( name, pt )) unlocatedParams
                        (padOrTruncate paramTypes (List.length unlocatedParams))
                state1 = { state | varEnv = State.pushFrame state.varEnv }
                state2 = List.foldl
                    (\( n, t ) s -> { s | varEnv = State.insertVar n t s.varEnv })
                    state1 monoParams
                ( monoBody, state3 ) = specializeExpr view snapshot body state2
                state4 = { state3 | varEnv = State.popFrame state3.varEnv }
            in
            ( Mono.MonoDef info.freshName
                (Mono.MonoClosure
                    { lambdaId = Mono.AnonymousLambda state.currentModule state.lambdaCounter
                    , captures = []
                    , params = monoParams
                    , closureKind = Nothing
                    , captureAbi = Nothing
                    }
                    monoBody
                    info.monoType
                )
            , { state4 | lambdaCounter = state4.lambdaCounter + 1 }
            )

        _ ->
            -- Not a lambda: specialize as-is (shouldn't happen for TLambda canType)
            let ( monoExpr, state1 ) = specializeExpr view snapshot defExpr state
            in ( Mono.MonoDef info.freshName monoExpr, state1 )
```

**Key insight (Q5 resolved):** We don't need a solver tvar on the Def. We re-specialize the function body by:
1. Flattening the instance's concrete `monoType` to get parameter types
2. Pushing those parameter types into VarEnv under the lambda's parameter names
3. Running `specializeExpr` on the lambda body — the solver view resolves internal types, and VarEnv provides the parameter types

This works because MonoDirect's `specializeExpr` for `VarLocal` (line 280) checks VarEnv first, falling back to `resolveType view meta` only when VarEnv has no binding.

#### Step 5d: Wire local-multi at direct call sites (already covered in Fix 2)

The `VarLocal` callee case in `specializeCall` (step 2f above) already calls `getOrCreateLocalInstance` when `isLocalMultiTarget` is true.

#### Step 5e: Wire local-multi at direct var references

**File:** `Specialize.elm`, `specializeExpr`'s `TOpt.VarLocal` case (line 280)

When a local-multi target is referenced as a value (not a call), record the instance:

```elm
TOpt.VarLocal name meta ->
    let
        monoType =
            case State.lookupVar name state.varEnv of
                Just t -> t
                Nothing -> resolveType view meta
    in
    if State.isLocalMultiTarget name state then
        let
            ( freshName, state1 ) =
                State.getOrCreateLocalInstance name monoType state
        in
        ( Mono.MonoVarLocal freshName monoType, state1 )
    else
        ( Mono.MonoVarLocal name monoType, state )
```

Same for `TrackedVarLocal` (line 292).

---

## Implementation Order

1. **Fix 3** — VarEnv in branches (self-contained, ~15 lines changed)
2. **Fix 1** — CEcoValue refinement (~60 lines: add `containsCEcoMVar` checks + `inferCaseType` helper)
3. **Fix 4** — Function cycles (~100 lines new, needs `Registry` import)
4. **Fix 2** — Two-phase args (~200 lines new: `ProcessedArg`, `processCallArgs`, `finishProcessedArgs`, `specializeCall` rewrite)
5. **Fix 5** — Local multi (~150 lines new: `getOrCreateLocalInstance` in State, `specializeLet` rewrite, `specializeDefForInstance`, VarLocal wiring)

### Verification after each fix

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

After all fixes:
```bash
cmake --build build --target check
```

---

## Resolved Questions Summary

| Q | Resolution |
|---|-----------|
| Q1 | Don't put func defs in `MonoCycle`. Emit separate `MonoNode`s via registry, matching `specializeFunctionCycle`. |
| Q2 | Use `enqueueSpec` + `Mono.Accessor` globals, NOT inline closures. |
| Q3 | `finishProcessedArgs` receives callee parameter types from `Closure.flattenFunctionType`. |
| Q4 | Yes, pre-bind function names in VarEnv before specializing cycle bodies. |
| Q5 | Re-specialize by pushing instance param types into VarEnv; no solver tvar needed on Def. |
| Q6 | Handle both `VarLocal` and `TrackedVarLocal` for `LocalFunArg`. |
| Q7 | `MonoDirectComparisonTest.elm` + `MonoDirectTest.elm` + invariant suites. |
| Q8 | Drop `subst` from `LocalInstanceInfo`. Keep `{ freshName, monoType }` only. |
