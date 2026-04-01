# Elm-Test Failures Report (2026-04-01)

**Run**: 12202 passed, 8 failed (seed 1537112672, fuzz 1)

---

## Failure Group 1: CGEN_056 — Saturated PapExtend Result Type (1 test)

**Test**: "Composition operators and staged case passes saturated papExtend result type invariant"

**Elm source** (`SourceIR/CompositionOpCases.elm`):
```elm
-- ComposeR (>>) two functions
testValue : Int
testValue =
    let
        composed = (\x -> x + 1) >> (\x -> x * 2)
    in
    composed 9
```

**Why it fails**: The `>>` operator (`Basics_composeR`) has return type `i64` in MLIR, but when the two PAP args are supplied via a saturated `eco.papExtend`, the result type is `!eco.value`. The invariant requires the saturated papExtend result type to match the target function's return type. Here, `Basics_composeR_$_3` returns `i64` but the papExtend produces `!eco.value`. The composeR function returns a *function* (the composed pipeline), which at the ABI level is `!eco.value`, but the stub's `function_type` says `i64` — a mismatch between the staged return type and the ABI representation.

---

## Failure Group 2: Array Type Variable Scoping (2 tests) — DEEP INVESTIGATION

**Tests**: "Array type variable scoping case branch types match" (MONO_018) and "Array type variable scoping has closure types matching spec keys" (MONO_025)

### Violations

**MONO_018 violation 1** — inside the `helper` closure's case expression:
```
resultType: MList (JsArray [MVar (Id 29)])
inline type: MList (JsArray [JsArray [JsArray [MVar (Id 29)]]])
```
Expected `List (JsArray a)`, got `List (JsArray (JsArray (JsArray a)))` — **2 extra JsArray layers**

**MONO_018 violation 2** — in the outer `sliceLeft` case:
```
resultType: MCustom "Array" [MVar (Id 29)]
inline type: MCustom "Array" [MRecord {nodeList: List (Node {record...}), nodeListSize: Int, tail: JsArray {record...}}]
```
Expected `Array a`, got `Array (Builder (Builder a))` — **2 extra Builder layers**

**MONO_025 violation** — for `slice` SpecId 4:
```
closure body type: Array ≠ key result type: Array
```

### Source Code

`SourceIR/ArrayCases.elm` — the `sliceLeft` function (SpecId 4):
```elm
sliceLeft : Int -> Array a -> Array a
sliceLeft from ((Array_elm_builtin len _ tree tail) as array) =
    if from == 0 then array
    else if from >= tailIndex len then
        Array_elm_builtin (len - from) shiftStep JsArray.empty <|
            JsArray.slice (from - tailIndex len) (JsArray.length tail) tail
    else
        let
            helper node acc = case node of          -- ← violation 1 is HERE
                SubTree subTree -> JsArray.foldr helper acc subTree
                Leaf leaf -> leaf :: acc
            leafNodes = JsArray.foldr helper [ tail ] tree
            skipNodes = from // branchFactor
            nodesToInsert = List.drop skipNodes leafNodes
        in
        case nodesToInsert of                       -- ← violation 2 is HERE
            [] -> empty
            head :: rest ->
                let firstSlice = from - (skipNodes * branchFactor)
                    initialBuilder = { tail = JsArray.slice firstSlice (JsArray.length head) head
                                     , nodeList = [], nodeListSize = 0 }
                in List.foldl appendHelpBuilder initialBuilder rest |> builderToArray True
```

Key types:
```elm
type Array a = Array_elm_builtin Int Int (Tree a) (JsArray a)
type Node a  = SubTree (Tree a) | Leaf (JsArray a)
type alias Tree a    = JsArray (Node a)       -- mutually recursive with Node
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }
```

### Pipeline Context

The test goes through the **full compiler pipeline**: Source AST → Canonicalization → Type Checking → PostSolve → TypedOptimize → AssignMVarIds → Monomorphization. The type checker infers correct types. The bug is in the monomorphizer.

`sliceLeft` is specialized at a polymorphic type (`a = MVar 29` — still a free type variable because `testValue = sliceLeft 0 empty` where `empty` is polymorphic).

### Evidence Gathered

#### 1. Scheme caching creates MVarId collisions

**File**: `Specialize.elm:71-91` — `getOrBuildSchemeInfo` caches schemes keyed by global name:
```elm
getOrBuildSchemeInfo funcCanType maybeGlobal state =
    case maybeGlobal of
        Just global ->
            case Data.Map.get TOpt.toComparableGlobal global accum.schemeCache of
                Just info -> ( info, state )   -- ← returns CACHED scheme, ignores funcCanType
                Nothing -> ...build and cache...
```

The scheme is built from `funcCanType` (the caller's instantiated type for the callee). After type checking + `AssignMVarIds`, `funcCanType` contains MVarIds from the **caller's SchemeEnv**. When the scheme is cached and reused at different call sites, the cached MVarIds may collide with the current call site's substitution.

**File**: `AssignMVarIds.elm` — each definition gets a **fresh SchemeEnv**, but the type checker may share type variables between the function parameter and the callee's instantiation. For `JsArray.foldr` called within `sliceLeft`, the type checker resolves `foldr`'s type variables to expressions involving `sliceLeft`'s `a`, so the cached scheme uses MVarId 29 (= `sliceLeft`'s `a`).

#### 2. `callResultMonoType` fallback uses contaminated `callSubst`

**File**: `Specialize.elm:3340-3350`:
```elm
callResultMonoType mvarEnv callerSubst callSubst canType =
    let
        fromCaller = applySubst mvarEnv callerSubst canType
    in
    if Mono.containsAnyMVar fromCaller then
        applySubst mvarEnv callSubst canType    -- ← FALLBACK: uses callSubst
    else
        fromCaller
```

When the caller's substitution maps `a → MVar 29` (polymorphic specialization), the result always contains MVars, triggering the fallback. The fallback applies `callSubst` (which includes the caller's substitution **extended** by callee unification) to `canType`.

**File**: `Specialize.elm:1224`:
```elm
( callSubst, funcMonoTypeRaw, _ ) =
    TypeSubst.unifyCallSiteDirect state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes subst
                                                                                                        ^^^^
                                                                              -- baseSubst = caller's subst!
```

`unifyCallSiteDirect` starts from the **caller's substitution** as `baseSubst`. Any mutations during unification propagate into `callSubst`.

#### 3. ROOT CAUSE: `unifyMonoMono` uses `insertBinding` without occurs check

**File**: `TypeSubst.elm:400-436`:
```elm
unifyMonoMono env m1 m2 subst =
    case ( m1, m2 ) of
        ( Mono.MVar mvarId _, _ ) ->
            insertBinding env mvarId m2 subst      -- ← NO occurs check!
        ...
```

**File**: `TypeSubst.elm:241-247` — `insertBinding` just normalizes and inserts:
```elm
insertBinding env mvarId ty subst =
    let (normalizedTy, subst1, env1) = normalizeMonoType env subst ty
    in (Dict.insert (Id.toComparable mvarId) normalizedTy subst1, env1)
```

Compare with `insertBindingSafe` (`TypeSubst.elm:967`), which **does** have an occurs check:
```elm
insertBindingSafe env targetId monoType subst =
    case normalizeAndOccursCheck env targetId subst monoType of
        Nothing -> ( subst, env )    -- occurs check failed, skip
        Just ( normalizedTy, subst1, env1 ) -> ( Dict.insert ... )
```

**The critical interaction** (`TypeSubst.elm:270-277`):
```elm
( Can.TVar mvarId, _ ) ->
    case Dict.get (Id.toComparable mvarId) subst of
        Just existingMono ->
            let (substWithTransitives, env1) =
                    unifyMonoMono env existingMono monoType subst     -- step A
            in
            insertBindingSafe env1 mvarId monoType substWithTransitives  -- step B
```

When MVarId 29 is already bound to `MVar 29` (self-referential, from polymorphic specialization `a → MVar 29`):

- **Step A**: `unifyMonoMono env (MVar 29) concreteType subst`
  - Matches `(MVar mvarId, _)` with mvarId=29
  - Calls `insertBinding env 29 concreteType subst` — **NO occurs check**
  - If `concreteType` contains `MVar 29` (e.g., `Node (MVar 29)`), this creates a **cyclic binding**: `29 → Node (MVar 29)`
  - Returns the contaminated substitution

- **Step B**: `insertBindingSafe env1 29 concreteType substWithTransitives`
  - Occurs check detects 29 in concreteType → **skips its own insert**
  - But **does NOT undo** the `insertBinding` from step A!
  - Returns `substWithTransitives` which still has `29 → Node (MVar 29)` (or whatever `concreteType` was)

The contaminated substitution then propagates through the rest of the unification.

#### 4. How contamination causes the specific type nesting

When the scheme for `JsArray.foldr` has `schemeResultType = List (JsArray (TVar 29))`:

If during `unifyArgTypesZip`, MVarId 29 gets contaminated (bound to a compound type involving `MVar 29`), then `applySubst substAfterArgs schemeResultType` would:
- Resolve `TVar 29` → the contaminated binding
- `resolveMonoVars` follows one level of self-reference (cycle detection stops further expansion)
- Produces a type with ONE extra level of nesting per contamination

For **violation 1**: The `JsArray.foldr helper acc subTree` call produces `List (JsArray (JsArray (JsArray (MVar 29))))` — suggesting MVarId 29 was bound to something like `JsArray (JsArray (MVar 29))` through two rounds of contamination in the argument unification.

For **violation 2**: The downstream `builderToArray True (foldl_result)` produces `Array (Builder (Builder (MVar 29)))` — the same self-referential substitution pattern but through the Builder record type.

Both violations show exactly **2 extra layers** of wrapping, consistent with the contamination propagating through the scheme's multi-argument unification.

### Root Cause Summary

The root cause is `unifyMonoMono` at `TypeSubst.elm:410-411` using `insertBinding` (no occurs check) instead of `insertBindingSafe`. When:

1. A specialization is polymorphic (`a → MVar 29`), creating a self-referential substitution entry `29 → MVar 29`
2. A cached scheme has type variables with MVarId 29 (from the same caller context)
3. `unifyCallSiteDirect` uses the caller's substitution as `baseSubst`
4. `unifyHelp` for `TVar 29` finds the existing binding `MVar 29` and calls `unifyMonoMono`
5. `unifyMonoMono` matches `(MVar 29, concreteType)` and calls `insertBinding` — creating a cyclic binding **without occurs check**
6. The cyclic binding contaminates subsequent type resolutions

### Proposed Fix

Replace `insertBinding` with `insertBindingSafe` in `unifyMonoMono` at `TypeSubst.elm:408,411,414`:

```elm
unifyMonoMono env m1 m2 subst =
    case ( m1, m2 ) of
        ( Mono.MVar mvarId1 _, Mono.MVar mvarId2 _ ) ->
            if Id.toComparable mvarId1 == Id.toComparable mvarId2 then
                ( subst, env )
            else
                insertBindingSafe env mvarId1 m2 subst   -- was: insertBinding

        ( Mono.MVar mvarId _, _ ) ->
            insertBindingSafe env mvarId m2 subst         -- was: insertBinding

        ( _, Mono.MVar mvarId _ ) ->
            insertBindingSafe env mvarId m1 subst         -- was: insertBinding
        ...
```

This would prevent cyclic bindings from being created during the transitive unification step, while `insertBindingSafe` in step B of `unifyHelp` would correctly skip the binding when the occurs check fails.

**Alternative fix**: Instead of (or in addition to) fixing `unifyMonoMono`, ensure `callResultMonoType` does not fall back to `callSubst` when the self-referential substitution pattern `a → MVar a` is the only source of MVars. The fallback to `callSubst` is unnecessary when `fromCaller` only contains the *same* MVars that were in the original polymorphic specialization.

---

## Failure Group 3: GOPT_013 — CallInfo `initialRemaining` exceeds `totalArity` (5 tests)

All 5 failures show the same pattern: `initialRemaining` exceeds `totalArity` in CallInfo.

### 3a. "Case returns lambda, then apply"
```elm
type Op = Add | Sub
getOp : Op -> Int -> Int -> Int
getOp op = case op of
    Add -> \a b -> a + b
    Sub -> \a b -> a - b
testValue : Int
testValue = (getOp Add) 3 4
```
**Violation**: `initialRemaining=3 exceeds totalArity=1 (stageArities=[1])`

### 3b. "1.2 identicalCurried11" (JoinpointABI)
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a -> \b -> a + b
    _ -> \a -> \b -> a - b
testValue : Int
testValue = (caseFunc 0 5) 3
```
**Violation**: `initialRemaining=3 exceeds totalArity=2 (stageArities=[1,1])`

### 3c. "Hetero closure: boxed vs unboxed capture"
```elm
type Shape = Circle | Square
shapeBonus : Shape -> Int -> Int
shapeBonus shape x = case shape of
    Circle -> x + 10
    Square -> x + 20
addN : Int -> Int -> Int
addN n x = n + x
testValue : Int
testValue = let f = if True then shapeBonus Circle else addN 5 in f 3
```
**Violation**: `initialRemaining=2 exceeds totalArity=1 (stageArities=[1])`

### 3d. "filterMap"
```elm
filterMap : (a -> Maybe b) -> List a -> List b
filterMap f xs = foldr (maybeCons f) [] xs
testValue : List Int
testValue = filterMap (\x -> Just x) [1, 2]
```
**Violation**: `initialRemaining=3 exceeds totalArity=1 (stageArities=[1])`

### 3e. "partial application of map"
```elm
map : (a -> b) -> List a -> List b
map f xs = case xs of
    [] -> []
    x :: rest -> f x :: map f rest
testValue : (List Int, List String)
testValue = let mapAddOne = map addOne
                mapId = map (\s -> s)
            in (mapAddOne [1, 2], mapId ["a", "b"])
```
**Violation**: `initialRemaining=2 exceeds totalArity=1 (stageArities=[1])`

**Why they all fail**: The GlobalOpt pass computes `initialRemaining` from the function's *logical* arity (total number of parameters in the Elm type signature), but `totalArity` is computed from `stageArities` which reflects the *staged/segmented* ABI (how the function is actually chunked into stages after currying analysis). When a function like `getOp` has 3 logical params but stage segmentation is `[1]` (only the first stage with 1 param, returning a closure for the rest), `initialRemaining=3` exceeds `totalArity=1`. The GOPT_013 invariant requires `initialRemaining ≤ totalArity`, meaning `initialRemaining` should be capped at or computed from the staged arity, not the full logical arity.
