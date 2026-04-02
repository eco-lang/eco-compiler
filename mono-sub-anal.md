# Monomorphizer Substitution Analysis — Full Report

All references are to `/work/compiler/src/Compiler/Monomorphize/` unless noted.

---

## Q1: `callResultMonoType` — Implementation & Call Sites

**File:** `Specialize.elm:3355–3371`

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

**Call sites** (all pass `subst` as `callerSubst`, `callSubst` as `callSubst`):

| Line | Branch | Context |
|------|--------|---------|
| 1257 | `VarGlobal` | `callSubst` from `unifyCallSiteDirect`; `funcMonoType = forceCNumberToInt funcMonoTypeRaw`; paramTypes extracted; `resolveProcessedArgs` uses `callSubst` |
| 1293 | `VarKernel` | `callSubst` from `unifyCallSiteDirect`; `funcMonoType = deriveKernelAbiType ... callSubst` |
| 1323 | `VarDebug` | identical pattern to VarKernel |
| 1374 | Local multi-target (`Just name`) | `callSubst` from `unifyArgsOnly`; `funcMonoType = applySubst ... callSubst funcCanType` |
| 1405 | Non-local fallback (`Nothing`) | `callSubst` from `unifyCallSiteDirect`; then `specializeExpr func callSubst state2` |

---

## Q2: `callerSubst` and `callSubst` in Specialize.elm

### `callerSubst`
Appears **only** as a parameter name in `callResultMonoType` (line 3362). Nowhere else.

### `callSubst` — all enclosing function bodies

**1. `getOrCreateLocalInstance` (163–186):** Takes `callSubst` as parameter, passes it to `updateLocalMultiStack` which stores it in `newInfo.subst`.

**2. `updateLocalMultiStack` (191–241):** Takes `callSubst` as parameter, stores it as `{ subst = callSubst }` in the instance info.

**3–7. Five local let-bindings in `specializeExpr`'s `TOpt.Call` handler:**

| Line | How computed | Where used |
|------|-------------|------------|
| 1244 | `unifyCallSiteDirect ... subst` | `resolveProcessedArgs` (1254), `callResultMonoType` (1257) |
| 1279 | `unifyCallSiteDirect ... subst` | `deriveKernelAbiType` (1284), `resolveProcessedArgs` (1290), `callResultMonoType` (1293) |
| 1309 | `unifyCallSiteDirect ... subst` | `deriveKernelAbiType` (1314), `resolveProcessedArgs` (1320), `callResultMonoType` (1323) |
| 1361 | `unifyArgsOnly ... subst` | `applySubst` (1365), `resolveProcessedArgs` (1371), `callResultMonoType` (1374), `getOrCreateLocalInstance` (1377) |
| 1392 | `unifyCallSiteDirect ... subst` | `resolveProcessedArgs` (1402), `callResultMonoType` (1405), **`specializeExpr func callSubst`** (1408) |

**8. `deriveKernelAbiType` (3503–3554):** Takes `callSubst` as parameter, applies it via `applySubst mvarEnv callSubst canFuncType`.

**9. `callResultMonoType` (3361):** Takes `callSubst` as parameter, used as fallback at line 3368.

---

## Q3: `applySubst`, `applySubstList`, `applySubstLambdaChain`

### `applySubst` — `TypeSubst.elm:581–724`

```elm
applySubst : MVarEnv -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
applySubst env subst canType =
    case canType of
        Can.TVar mvarId ->
            case Dict.get (Id.toComparable mvarId) subst of
                Just monoType -> ( resolveMonoVars env subst monoType, env )
                Nothing ->
                    case State.lookupConstraint mvarId env |> Maybe.withDefault Mono.CEcoValue of
                        Mono.CNumber -> ( Mono.MInt, env )
                        Mono.CEcoValue -> ( Mono.MVar mvarId constraint, env )
        Can.TLambda from to -> applySubstLambdaChain env subst [ from ] to
        Can.TType canonical name args -> -- handles Int/Float/Bool/Char/String/List/Custom
        Can.TRecord fields maybeExtension -> -- handles record extension via subst lookup
        Can.TTuple a b rest -> applySubstList env subst (a :: b :: rest)
        Can.TUnit -> ( Mono.MUnit, env )
        Can.TAlias _ _ _ (Can.Filled inner) -> applySubst env subst inner
        Can.TAlias _ _ args (Can.Holey inner) -> -- builds newSubst from alias params, then recurses
```

### `applySubstList` — `TypeSubst.elm:727–740`

```elm
applySubstList : MVarEnv -> Substitution -> List (Can.Type MVarId) -> ( List Mono.MonoType, MVarEnv )
applySubstList env subst types =
    List.foldl (\t ( acc, e ) -> let ( monoT, e1 ) = applySubst e subst t in ( acc ++ [ monoT ], e1 )) ( [], env ) types
```

### `applySubstLambdaChain` — `TypeSubst.elm:743–765`

```elm
applySubstLambdaChain : MVarEnv -> Substitution -> List (Can.Type MVarId) -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
applySubstLambdaChain env subst argsAcc to =
    case to of
        Can.TLambda from innerTo -> applySubstLambdaChain env subst (from :: argsAcc) innerTo
        _ ->
            let ( resultMono, env1 ) = applySubst env subst to in
            List.foldl (\argType ( acc, e ) -> let ( monoArg, e1 ) = applySubst e subst argType in ( Mono.MFunction [ monoArg ] acc, e1 ))
                ( resultMono, env1 ) argsAcc
```

### External call sites of `TypeSubst.applySubst` — substitution argument names

| Lines | Subst arg | Context |
|-------|-----------|---------|
| 461, 613, 641, 1003, 1018, 1028, 1048, 1068, 1075, 1078, 1081, 1084, 1106, 1113, 1135, 1151, 1187, 1420, 1447, 1472, 1526, 1649, 1709, 1745, 1859, 1908, 1946, 1991, 2012, 2048, 2098, 2139, 2185, 2298, 2314, 2339, 2364, 2389, 2550, 2558, 2784 | `subst` | Caller's current subst |
| 490, 2530 | `refinedSubst` | Enriched from `unifyExtend` |
| 850 | `sharedSubst` | From `unify` on cycle type |
| 946 | `augmentedSubst` | Enriched from `foldl unifyExtend` over params |
| 2028 | `enrichedSubst` | From `unifyExtend` of def type |
| 2995, 3062 | `typeVarSubst` | Ctor type variable substitution |
| 1365 | `callSubst` | In local multi-target branch |
| 3365 | `callerSubst` | In `callResultMonoType` preferred path |
| 3368 | `callSubst` | In `callResultMonoType` fallback path |
| 3509 | `callSubst` | In `deriveKernelAbiType` |
| 629 | `(Tuple.first (TypeSubst.unify ...))` | Inline unify result |
| Analysis.elm:470 | `subst` | Analysis context |

---

## Q4: `unify`, `unifyExtend`, `unifyArgsOnly`, `unifyHelp`

### `unify` — `TypeSubst.elm:250–254`
```elm
unify : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> ( Substitution, MVarEnv )
unify env canType monoType = unifyHelp env canType monoType Dict.empty
```

### `unifyExtend` — `TypeSubst.elm:257–262`
```elm
unifyExtend : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyExtend env canType monoType baseSubst = unifyHelp env canType monoType baseSubst
```

### `unifyArgsOnly` — `TypeSubst.elm:439–460`
```elm
unifyArgsOnly : MVarEnv -> Can.Type MVarId -> List Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )
unifyArgsOnly env canFuncType argTypes subst =
    case ( canFuncType, argTypes ) of
        ( _, [] ) -> ( subst, env )
        ( Can.TLambda from _, [ singleArg ] ) -> unifyHelp env from singleArg subst
        ( Can.TLambda from to, arg0 :: rest ) ->
            let ( subst1, env1 ) = unifyHelp env from arg0 subst
            in unifyArgsOnly env1 to rest subst1
        _ -> ( subst, env )
```

### `unifyHelp` — `TypeSubst.elm:265–390`
Handles: `TVar` (insert binding or reconcile existing), `TType<>MInt/MFloat/MBool/MChar/MString` (identity), `TLambda<>MFunction` (peel args), `TType<>MCustom/MList` (recurse on type args), `TRecord<>MRecord` (field-by-field + extension var), `TTuple<>MTuple`, `TAlias` (unwrap).

### Call sites

**`unify`** (8 sites, all in `Specialize.elm`): lines 569, 593, 610, 629, 638, 692, 706, 787 — all pass `(mvarEnv, canType, requestedMonoType)`, result used as initial `subst` in `specializeNode` or `specializeForType`.

**`unifyExtend`** (17 sites, all in `Specialize.elm`): lines 469, 576, 596, 923, 1540, 1591, 1660, 1756, 1800, 1873, 2025, 2077, 2118, 2161, 2499, 2526, 2756 — extends an existing `subst` with new (canType, monoType) bindings.

**`unifyArgsOnly`** (1 site): line 1362 — local multi-target Call branch.

---

## Q5: All Functions Taking `Substitution` Parameter

| Line | Function | Signature (abbreviated) |
|------|----------|------------------------|
| 163 | `getOrCreateLocalInstance` | `Name -> MonoType -> Substitution -> MonoState -> (Name, MonoState)` |
| 191 | `updateLocalMultiStack` | `Name -> String -> MonoType -> Substitution -> List LocalMultiState -> (List LocalMultiState, Name)` |
| 445 | `specializeLambda` | `Expr -> Can.Type -> Substitution -> MonoState -> (MonoExpr, MonoState)` |
| 830 | `specializeFunc` | `Canonical -> Name -> MonoType -> Substitution -> Def -> (...) -> (...)` |
| 885 | `specializeFuncDefInCycle` | `Substitution -> Def -> MonoState -> (MonoNode, MonoState)` |
| 957 | `specializeValueDefs` | `List (Name, Expr) -> Substitution -> MonoState -> (List (Name, MonoExpr), MonoState)` |
| 985 | `specializeExpr` | `Expr -> Substitution -> MonoState -> (MonoExpr, MonoState)` |
| 2249 | `specializeExprs` | `List Expr -> Substitution -> MonoState -> (List MonoExpr, MonoState)` |
| 2276 | `processCallArgs` | `List Expr -> Substitution -> MonoState -> (List ProcessedArg, List MonoType, MonoState)` |
| 2289 | `processCallArg` | `Substitution -> Expr -> (...) -> (...)` |
| 2424 | `resolveProcessedArg` | `ProcessedArg -> Maybe MonoType -> Substitution -> MonoState -> (MonoExpr, MonoState)` |
| 2565 | `resolveProcessedArgs` | `List ProcessedArg -> List MonoType -> Substitution -> MonoState -> (List MonoExpr, MonoState)` |
| 2596 | `specializeNamedExprs` | `List (Name, Expr) -> Substitution -> MonoState -> (List (Name, MonoExpr), MonoState)` |
| 2620 | `specializeBranches` | `List (Expr, Expr) -> Substitution -> MonoState -> (List (MonoExpr, MonoExpr), MonoState)` |
| 2724 | `specializeDef` | `Def -> Substitution -> MonoState -> (MonoDef, MonoState)` |
| 2777 | `specializeDestructor` | `Destructor -> Substitution -> MVarEnv -> VarEnv -> ... -> MonoDestructor` |
| 3196 | `specializeDecider` | `Name -> Decider Choice -> Substitution -> MonoState -> (Decider MonoChoice, MonoState)` |
| 3263 | `specializeChoice` | `Choice -> Substitution -> MonoState -> (MonoChoice, MonoState)` |
| 3277 | `specializeEdges` | `Name -> List (Test, Decider Choice) -> Substitution -> MonoState -> (...)` |
| 3308 | `specializeJumps` | `List (Int, Expr) -> Substitution -> MonoState -> (List (Int, MonoExpr), MonoState)` |
| 3361 | `callResultMonoType` | `MVarEnv -> Substitution -> Substitution -> Can.Type -> MonoType` |
| 3376 | `specializeArg` | `MVarEnv -> Substitution -> (Located Name, Can.Type) -> (Name, MonoType)` |
| 3503 | `deriveKernelAbiType` | `MVarEnv -> (String,String) -> Can.Type -> Substitution -> MonoType` |

---

## Q6: Substitution Threading in Main Functions

### `specializeNode` (560–712)

**Does not receive** `subst`. Creates it from scratch via `unify(canType, requestedMonoType)`, optionally enriches with `unifyExtend(exprType, requestedMonoType, subst0)`, then passes to `specializeExpr`.

### `specializeDef` (2724–2774)

- `Def`: passes `subst` unchanged to `specializeExpr`.
- `TailDef`: builds `augmentedSubst` by `foldl unifyExtend` over each param's `(canType, monoType)`, passes `augmentedSubst` to body's `specializeExpr`.

### `specializeExpr` (985–2203) — key substitution-modifying branches

| Branch | How `subst` is modified for recursive calls |
|--------|---------------------------------------------|
| Literals, VarLocal, VarGlobal, VarEnum, List, Tuple | `subst` passed unchanged |
| `Call` -> VarGlobal/VarKernel/VarDebug | `callSubst` computed via `unifyCallSiteDirect`; passed to `resolveProcessedArgs` and `callResultMonoType`; **not** to recursive `specializeExpr` |
| `Call` -> local multi-target | `callSubst` computed via `unifyArgsOnly`; passed to `resolveProcessedArgs`, `callResultMonoType`, `getOrCreateLocalInstance` |
| `Call` -> non-local fallback | `callSubst` via `unifyCallSiteDirect`; **passed to `specializeExpr func callSubst`** (line 1408) — **the only place `callSubst` replaces `subst` in a recursive specializeExpr call** |
| `Let` (function def) | Body first specialized with `subst`. Then per-instance: `mergedSubst = unifyExtend(defCanType, info.monoType, subst)`. `specializeDef` gets `mergedSubst`. If no instances + MVars: `enrichedSubst = unifyExtend(defCanType, defMonoType, subst)`; body re-specialized with `enrichedSubst`. |
| `Let` (non-function) | `specializeDef` gets `subst`. If MVars remain: `enrichedSubst = unifyExtend(...)`, body re-specialized with `enrichedSubst`. |
| `Access` (record field) | If value-multi: `enrichedSubst = unifyExtend(...)`. Otherwise `subst` unchanged. |
| `Update` / `Record` | Per-field `refinedSubst` via `unifyExtend` for field expressions. |

---

## Q7: `unifyCallSiteDirect` — `TypeSubst.elm:1036–1080`

```elm
unifyCallSiteDirect :
    MVarEnv -> List (Can.Type MVarId) -> Can.Type MVarId -> List Mono.MonoType -> Substitution
    -> ( Substitution, Mono.MonoType, MVarEnv )
unifyCallSiteDirect env schemeArgTypes schemeResultType argMonoTypes baseSubst =
    let
        ( substAfterArgs, env1 ) =
            unifyArgTypesZip env schemeArgTypes argMonoTypes baseSubst
        resolvedSuppliedArgs = List.map (resolveMonoVars env1 substAfterArgs) argMonoTypes
        remainingSchemeArgs = List.drop (List.length argMonoTypes) schemeArgTypes
        ( resolvedRemainingArgs, env2 ) =
            List.foldl (\canArg (accArgs, accEnv) ->
                let (monoArg, envN) = applySubst accEnv substAfterArgs canArg
                in (accArgs ++ [monoArg], envN))
                ([], env1) remainingSchemeArgs
        resolvedAllArgs = resolvedSuppliedArgs ++ resolvedRemainingArgs
        ( resultMono, env3 ) = applySubst env2 substAfterArgs schemeResultType
        funcMonoType = buildCurriedFuncType schemeArgTypes resolvedAllArgs resultMono
    in
    ( substAfterArgs, funcMonoType, env3 )
```

**All 4 call sites** (identical argument pattern):

| Line | Branch | baseSubst |
|------|--------|-----------|
| 1245 | VarGlobal | `subst` |
| 1280 | VarKernel | `subst` |
| 1310 | VarDebug | `subst` |
| 1393 | Non-local fallback | `subst` |

All pass: `state1a.ctx.mvarEnv`, `schemeInfo.argTypes`, `schemeInfo.resultType`, `argTypes`, `subst`.

---

## Q8: Where `callSubst` Replaces the Caller's `subst`

**Only one place** passes `callSubst` as the `subst` argument to a recursive `specializeExpr`:

**Line 1408** — non-local fallback Call branch:
```elm
( monoFunc, state3 ) =
    specializeExpr func callSubst state2
```

All other uses of `callSubst` are to helper functions (`resolveProcessedArgs`, `callResultMonoType`, `deriveKernelAbiType`, `getOrCreateLocalInstance`, `applySubst`), never to `specializeExpr` for subexpressions.

---

## Q9: `containsAnyMVar` Usage and callerSubst vs callSubst Decision

**21 occurrences**, 5 patterns:

| Pattern | Lines | Logic |
|---------|-------|-------|
| List element type inference | 1194 | If `MList monoType0` has MVars, infer from first element's concrete type |
| TailCall result | 1428 | If result has MVars, look up tail-called function's registered type |
| If/Destruct/Case result | 1458, 1930, 1971 | If result has MVars, infer from specialized branch body |
| Let def type enrichment | 1529, 1539, 1558, 1566, 1652, 1659, 1676, 1684, 1748, 1755, 1772, 1780, 1863, 1872, 1893 | If `defMonoType0` has MVars: (a) use `monoDefExprType` for concrete type, (b) compute `enrichedSubst`, (c) re-specialize body |
| **callerSubst vs callSubst** | **3367** | **`callResultMonoType`: if `applySubst callerSubst` leaves MVars, fall back to `applySubst callSubst`** |

The line 3367 decision is the **sole** point where the choice between caller and call-site substitution is made:
```elm
if Mono.containsAnyMVar fromCaller then
    Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst mvarEnv callSubst canType))
else
    fromCaller
```

---

## Q10: `extractParamTypes` — `TypeSubst.elm:468–475`

```elm
extractParamTypes : Mono.MonoType -> List Mono.MonoType
extractParamTypes monoType =
    case monoType of
        Mono.MFunction argTypes returnType -> argTypes ++ extractParamTypes returnType
        _ -> []
```

**5 call sites** (all in `specializeExpr`'s Call handler), each feeding `resolveProcessedArgs`:

| Line | How `funcMonoType` was derived |
|------|-------------------------------|
| 1251 | `forceCNumberToInt funcMonoTypeRaw` (from `unifyCallSiteDirect`) |
| 1287 | `deriveKernelAbiType ... callSubst` |
| 1317 | `deriveKernelAbiType ... callSubst` |
| 1368 | `applySubst ... callSubst funcCanType` |
| 1399 | `forceCNumberToInt funcMonoTypeRaw` (from `unifyCallSiteDirect`) |

---

## Q11: `Maybe.map` in TOpt IR

`Maybe.map` is **not** hardcoded in the compiler. It comes from the `elm/core` package, compiled normally through Canonicalize -> Type Inference -> TypedOptimize, serialized into `typed-artifacts.dat`.

**Canonical type:** `(a -> b) -> Maybe a -> Maybe b`

**Body (Elm source):**
```elm
map f maybe = case maybe of Just value -> Just (f value); Nothing -> Nothing
```

This becomes a `TOpt.Define` wrapping a `TOpt.Function` with params `[f, maybe]` and a `TOpt.Case` body matching on `maybe`. The monomorphizer encounters it as a `VarGlobal` call target and processes it via the standard `specializeNode` -> `specializeExpr` pipeline.

**Critical for the FloatSpecialValuesTest bug:** When `Maybe.map (\x -> x == posInf) decoded`, the scheme unification should resolve `a = Float` and `b = Bool`. The bug is that the result `b` gets resolved to `Float` instead of `Bool`, causing the `eco.unbox` to treat a Bool embedded constant as f64 -> SIGSEGV.

---

## Q12: `VarGlobal` / `VarKernel` / `VarDebug` Call Branches

### VarGlobal (1234–1268)
```
callSubst = unifyCallSiteDirect(schemeInfo.argTypes, schemeInfo.resultType, argTypes, subst)
funcMonoType = forceCNumberToInt(funcMonoTypeRaw)  -- from unifyCallSiteDirect
paramTypes = extractParamTypes(funcMonoType)
monoArgs = resolveProcessedArgs(processedArgs, paramTypes, callSubst)
resultMonoType = callResultMonoType(mvarEnv, subst, callSubst, canType)
specId = enqueueSpec(monoGlobal, funcMonoType)
```

### VarKernel (1270–1298)
```
callSubst = unifyCallSiteDirect(...)  -- funcMonoType discarded
funcMonoType = deriveKernelAbiType(kernelId, funcCanType, callSubst)  -- ABI-aware
paramTypes = extractParamTypes(funcMonoType)
monoArgs = resolveProcessedArgs(processedArgs, paramTypes, callSubst)
resultMonoType = callResultMonoType(mvarEnv, subst, callSubst, canType)
```

### VarDebug (1300–1328)
Identical to VarKernel except `kernelId = ("Debug", name)`.

### Local multi-target (1356–1384)
```
callSubst = unifyArgsOnly(funcCanType, argTypes, subst)  -- NOTE: not unifyCallSiteDirect
funcMonoType = applySubst(callSubst, funcCanType)
```

### Non-local fallback (1386–1412)
Same as VarGlobal, plus **`specializeExpr func callSubst state2`** at line 1408.

---

## Q13: `PendingGlobal` and `LocalFunArg` Handling

### Creation

**`PendingGlobal`** (2382–2405): Created when a `VarGlobal` argument's type `containsCEcoMVar`. Stores the original `(expr, subst, canType)`.

**`LocalFunArg`** (2331–2343, 2356–2369): Created when a `VarLocal`/`TrackedVarLocal` argument is a `localMultiTarget`. Stores `(name, canType)`.

### Resolution (in `resolveProcessedArg`, 2424–2560)

**`PendingGlobal`** (2492–2504):
```elm
refinedSubst = case maybeParamType of
    Just paramType -> unifyExtend(canType, paramType, savedSubst)
    Nothing -> savedSubst
specializeExpr savedExpr refinedSubst state
```
Uses the **saved caller subst** (`savedSubst`), enriched with the parameter type hint.

**`LocalFunArg`** (2517–2560):
```elm
-- When paramType is MFunction:
refinedSubst = unifyExtend(canType, paramType, subst)  -- NOTE: uses callSubst (the subst parameter)
funcMonoType = applySubst(refinedSubst, canType)
-- Then getOrCreateLocalInstance if multi-target

-- When paramType is not MFunction, or Nothing:
monoType = applySubst(subst, canType)  -- uses callSubst directly
```

**Key difference:** `PendingGlobal` enriches the **saved caller subst**. `LocalFunArg` enriches the **call-site subst** (the `subst` parameter of `resolveProcessedArgs`, which is `callSubst` from the caller).

---

## Q14: `monoDefExprType`, `typeContainsLambda`, `hasCEcoTVar`

### `monoDefExprType` (3341–3352)
Extracts the MonoType from a specialized def. For `MonoDef`: `typeOf monoExpr`. For `MonoTailDef`: rebuilds `MFunction` chain from args + body type.

**Called at:** 1530, 1653, 1749, 1864 — always as fallback when `applySubst subst defCanType` still has MVars.

### `typeContainsLambda` (250–276)
Returns `True` if any `TLambda` exists in the type tree.

### `hasCEcoTVar` (280–290)
Returns `True` if the type has any type variable with constraint != `CNumber`.

**Combined in `shouldUseValueMulti` (296–298):**
```elm
shouldUseValueMulti mvarEnv defCanType =
    typeContainsLambda defCanType && hasCEcoTVar mvarEnv defCanType
```
Triggers value-multi specialization (multiple monomorphic instances for different types) only when the type contains lambdas AND has unconstrained type vars.

---

## Q15: Specialization Entry Points — `subst` Initialization

### `specializeNode` (560–712)
Creates `subst` from scratch: `subst0 = unify(canType, requestedMonoType)`, then `subst = unifyExtend(exprType, requestedMonoType, subst0)`. Passes `subst` to `specializeExpr`.

### `specializeDef` (2724–2774)
Receives `subst` as parameter. `Def`: passes through. `TailDef`: augments via `foldl unifyExtend` over params.

### `specializeExpr` (985+)
Receives `subst` as parameter, never creates from scratch. Threads through, enriching at let-bindings and record fields.

---

## Q16: `canTypeToMonoType` Call Sites

| File | Line | Subst | Context |
|------|------|-------|---------|
| TypeSubst.elm | 771–773 | (alias for `applySubst`) | Definition |
| Monomorphize.elm | 157 | `Dict.empty` | Main entry, main type |
| Monomorphize.elm | 519 | `subst` param | Wrapper for general use |
| SolverSnapshot.elm | 270 | `substDict` | Solver snapshot |
| Specialize.elm | 3534 | (none — `canTypeToMonoType_numberBoxed`) | `deriveKernelAbiType` NumberBoxed fallback |
| Specialize.elm | 3554 | (none — `canTypeToMonoType_preserveVars`) | `deriveKernelAbiType` PreserveVars fallback |

---

## Q17: `deriveKernelAbiType` and `deriveKernelAbiMode`

### `deriveKernelAbiType` (Specialize.elm:3503–3554)
```elm
deriveKernelAbiType mvarEnv kernelId canFuncType callSubst =
    let monoAfterSubst = forceCNumberToInt (applySubst mvarEnv callSubst canFuncType)
        mode = deriveKernelAbiMode kernelId canFuncType mvarEnv
    in case mode of
        NumberBoxed -> if isFullyMonomorphic monoAfterSubst then monoAfterSubst
                       else canTypeToMonoType_numberBoxed(canFuncType)
        UseSubstitution -> monoAfterSubst
        PreserveVars -> if containerSpecialized && isFullyMonomorphic then monoAfterSubst
                        else canTypeToMonoType_preserveVars(canFuncType)
```

### `deriveKernelAbiMode` (KernelAbi.elm:89–117)
Checks: monomorphic? -> `UseSubstitution`. Has number vars + in numberBoxedKernels? -> `NumberBoxed`. Otherwise -> `PreserveVars`.

**Call sites of `deriveKernelAbiType`:**

| Line | Subst passed | Context |
|------|-------------|---------|
| 1167 | `subst` (caller's) | standalone `VarDebug` |
| 1177 | `subst` (caller's) | standalone `VarKernel` |
| 1284 | `callSubst` | `Call` -> `VarKernel` |
| 1314 | `callSubst` | `Call` -> `VarDebug` |
| 2513 | `subst` (resolution's) | `PendingKernel` resolution |

---

## Q18: `SchemeInfo` Field Usage

Only **two fields** are accessed: `schemeInfo.argTypes` and `schemeInfo.resultType`. Both are passed exclusively to `unifyCallSiteDirect`:

| Line | Branch |
|------|--------|
| 1245 | VarGlobal |
| 1280 | VarKernel |
| 1310 | VarDebug |
| 1393 | Non-local fallback |

Fields `varIds`, `constraints`, `argCount`, `schemeType` are **never accessed** in Specialize.elm.

---

## Q19: `State.insertVar` — MonoType Derivation

| Line | Context | How MonoType was derived |
|------|---------|-------------------------|
| 503 | Lambda params | `applySubst refinedSubst` on each param's canType |
| 913 | TailDef params (cycle) | `specializeArg subst` = `applySubst subst` |
| 1552 | Let function def (single) | `applySubst subst defCanType`, fallback to `monoDefExprType` |
| 1625 | Let function def (multi) | `info.monoType` from `LocalMultiState` instance |
| 1672 | Let non-fn def (single, value-multi) | `applySubst subst defCanType`, fallback to `monoDefExprType` |
| 1720 | Value-multi preliminary | `applySubst subst defCanType` |
| 1768 | Value-multi (single fallback) | Same as 1672 |
| 1833 | Value-multi (multi) | `info.monoType` from instance |
| 1885 | Let non-fn def (else) | `applySubst enrichedSubst defCanType` |
| 1923 | Destructor | From `specializeDestructor` with `subst` |
| 2745 | TailDef params | `specializeArg subst` |

---

## Q20: Combinator Specialization Flow

For `b = s (k s) k` in `CombinatorCConsTest`:

1. **Entry:** `specializeNode "b" (Define expr meta) requestedMonoType state` creates `subst = unify(b_canType, requestedMonoType)`.

2. **Body** is `TOpt.Call s [k_applied_to_s, k]`:
   - `processCallArgs` specializes each argument under `subst`:
     - `(k s)` is itself a `Call` of `k` with `s` -> recursively specialized, producing a mono type for the partial application result
     - `k` is a bare `VarGlobal` -> `applySubst subst k_canType`
   - Collects `argTypes` = `[monoType_of_(k_s), monoType_of_k]`

3. **SchemeInfo for `s`:** `getOrBuildSchemeInfo` freshens `s`'s canonical type `(a->b->c) -> (a->b) -> a -> c` into `(a'->b'->c') -> (a'->b') -> a' -> c'` with `argTypes = [a'->b'->c', a'->b', a']`, `resultType = c'`.

4. **`unifyCallSiteDirect`:** Unifies `a'->b'->c'` with `monoType_of_(k_s)` and `a'->b'` with `monoType_of_k`. The third scheme arg `a'` is unsupplied — resolved through the substitution. Produces `callSubst` mapping `a'`, `b'`, `c'` to concrete types, and `funcMonoType` as the full curried type of the specialized `s`.

5. **The bug:** When `b` is used in `c = s (b b s) (k k)`, the monomorphizer resolves all type variables in `s`'s type (used inside `b`) to `Int` from the outer usage context of `c (::) [2,3] 1`. But `s`'s first parameter in `b = s (k s) k` actually receives functions (not Ints) through the combinator chain. The monomorphizer doesn't distinguish `Int` from `Int->Int` for higher-order parameters because it resolves `b`'s overall type `(Int->Int) -> (Int->Int) -> Int -> Int` uniformly, collapsing the distinction between function-typed and value-typed parameters in the substitution passed to inner combinators.
