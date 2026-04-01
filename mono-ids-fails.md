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

### MLIR Evidence

The test failure message:
```
ComposeR (>>) two functions: Saturated eco.papExtend result type !eco.value
does not match func.func @Basics_composeR_$_3 return type i64
```

Generated MLIR for `testValue`:
```mlir
-- composeR stub: only 2 params, returns i64
"func.func"() ({
    ^bb0(%arg0: !eco.value, %arg1: !eco.value):
      %2 = "arith.constant"() {value = 0 : i64} : () -> i64
      "eco.return"(%2) : (i64) -> ()
}) {function_type = (!eco.value, !eco.value) -> (i64), sym_name = "Basics_composeR_$_3"}

-- testValue body:
%0 = "eco.papCreate"() {arity = 1, function = @Test_lambda_1, ...}           -- \x -> x*2
%1 = "eco.papCreate"() {arity = 1, function = @Test_lambda_0, ...}           -- \x -> x+1
%5 = "eco.papCreate"() {arity = 2, function = @Basics_composeR_$_3, ...}     -- composeR, arity=2
%2 = "eco.papExtend"(%5, %1, %0) {remaining_arity = 2} : (...) -> !eco.value -- SATURATED: 2 args, arity 2
%7 = "arith.constant"() {value = 9 : i64} : () -> i64
%8 = "eco.papExtend"(%2, %7) {_call_kind = "segmentation_unknown"} : (...) -> !eco.value
%9 = "eco.unbox"(%8) : (!eco.value) -> i64
```

**Key observations:**
1. `@Basics_composeR_$_3` has signature `(!eco.value, !eco.value) -> i64` — **only 2 params**, returns `i64`
2. `papCreate` for composeR has `arity = 2` (not 3)
3. `papExtend(%5, %1, %0)` applies 2 args to arity-2 PAP → **falsely detected as saturated** (remaining = 0)
4. But its result type is `!eco.value` (a function/closure), not `i64`
5. **CGEN_056 violation**: saturated papExtend result `!eco.value` ≠ func.func return `i64`

### What the MLIR Should Look Like

`composeR` is defined as `composeR f g x = g (f x)` with type `(a→b) → (b→c) → a → c` — a **3-argument** function. Specialized with `a=Int, b=Int, c=Int`, the full ABI signature should be `(!eco.value, !eco.value, i64) → i64`:

```mlir
-- CORRECT: 3-param signature
{function_type = (!eco.value, !eco.value, i64) -> (i64), sym_name = "Basics_composeR_$_3"}

%5 = "eco.papCreate"() {arity = 3, function = @Basics_composeR_$_3, ...}     -- arity=3
%2 = "eco.papExtend"(%5, %1, %0) {remaining_arity = 3} : (...) -> !eco.value -- NOT saturated: 3-2=1 remaining
%8 = "eco.papExtend"(%2, %7) {remaining_arity = 1} : (...) -> i64            -- SATURATED: 1-1=0, result=i64 ✓
```

### Root Cause: Same `buildCurriedFuncType` Truncation as Group 3

The `>>` binop desugars to `Call (VarGlobal composeR) [f, g]` with 2 args (`LocalOpt/Typed/Expression.elm:432`). The monomorphizer processes this via the `VarGlobal` case (`Specialize.elm:1214-1247`):

```elm
( schemeInfo, state1a ) =
    getOrBuildSchemeInfo funcCanType (Just global) state1          -- schemeArgTypes = [(a→b), (b→c), a] (3 params)
( callSubst, funcMonoTypeRaw, _ ) =
    TypeSubst.unifyCallSiteDirect ... schemeInfo.argTypes ... argTypes subst  -- argTypes = [f, g] (2 supplied)
```

Then `unifyCallSiteDirect` calls `buildCurriedFuncType` (`TypeSubst.elm:949-956`):

```elm
buildCurriedFuncType schemeArgs resolvedArgs resultMono =
    case ( schemeArgs, resolvedArgs ) of
        ( _ :: schemeRest, arg :: argRest ) ->
            Mono.MFunction [ arg ] (buildCurriedFuncType schemeRest argRest resultMono)
        _ ->
            resultMono   -- ← resolvedArgs exhausted after 2 iterations, returns MInt
```

**Trace for `composeR f g`:**
- `schemeArgs = [(a→b), (b→c), a]`, `resolvedArgs = [!eco.value, !eco.value]`, `resultMono = MInt`
- iter 1: `MFunction [!eco.value] (…)`
- iter 2: `MFunction [!eco.value] (…)` — `resolvedArgs` now empty
- iter 3: catch-all → returns `MInt`
- **Result: `MFunction [!eco.value] (MFunction [!eco.value] MInt)`** — only 2 params, **missing the 3rd param `a` (Int)**

This truncated type is stored in the `MonoVarGlobal` and used to enqueue the specialization:
```elm
( specId, newState ) = enqueueSpec monoGlobal funcMonoType Nothing state2  -- truncated!
monoFunc = Mono.MonoVarGlobal funcRegion specId funcMonoType               -- truncated!
```

### How the Truncated Type Cascades to CGEN_056

1. **Node creation**: The monomorphizer creates a `MonoExtern` node for `composeR` at specId=3 with the truncated 2-param type.

2. **Kernel stub in MLIR** (`Expr.elm:680-709`): `generateVarKernel` derives the func.func signature from the mono type:
   ```elm
   arity = Types.countTotalArity monoType          -- = 2 (from truncated type)
   ( paramTypes, resultType ) = Types.flattenFunctionType monoType  -- = ([!eco.value, !eco.value], i64)
   ```
   Creates `func.func @Basics_composeR_$_3(!eco.value, !eco.value) → i64`

3. **papCreate**: `arity = 2` (from the 2-param type)

4. **papExtend with 2 args**: remaining\_arity = 2, applying 2 args → remaining = 0 → **falsely detected as saturated**

5. **Mismatch**: The call `composeR f g` semantically returns `Int → Int` (a function = `!eco.value` at ABI level). But func.func says the return type is `i64`. The test catches this: `!eco.value ≠ i64`.

### Why This Doesn't Trigger GOPT_013

`composeR` resolves to a `MonoExtern` node. `callModelForExpr` (`MonoGlobalOptimize.elm:1433-1434`) returns `FlattenedExternal` for `MonoExtern` nodes. The GOPT_013 check skips `FlattenedExternal` calls entirely (`CallInfoComplete.elm:173-175`). The CGEN_056 check operates at the MLIR level and catches the mismatch that GOPT_013 cannot see.

### Relationship to Group 3

**This is the same root cause as Group 3.** Both failures stem from `buildCurriedFuncType` (`TypeSubst.elm:949-956`) truncating the function type to only include stages for supplied arguments. The manifestation differs:

| | Group 3 (GOPT_013) | Group 1 (CGEN_056) |
|---|---|---|
| **Affected functions** | User-defined (MonoDefine) | Kernel (MonoExtern) |
| **Call model** | StageCurried | FlattenedExternal |
| **Detection level** | GlobalOpt pass | MLIR generation |
| **Symptom** | `initialRemaining > totalArity` | papExtend result type ≠ func.func return type |
| **Root cause** | `buildCurriedFuncType` truncation | Same |

### Proposed Fix

The same fix proposed for Group 3 — modifying `unifyCallSiteDirect` (`TypeSubst.elm:909-927`) to resolve ALL scheme arg types through the substitution, not just the supplied ones — would fix Group 1 as well. With the correct full type `MFunction [!eco.value, !eco.value, i64] MInt`:

1. `func.func @Basics_composeR_$_3(!eco.value, !eco.value, i64) → i64` — correct 3-param signature
2. `papCreate(arity=3)` — correct arity
3. `papExtend` with 2 args: remaining = 3−2 = 1 → **not saturated** → result = `!eco.value` ✓
4. `papExtend` with 1 arg (9): remaining = 1−1 = 0 → **saturated** → result = `i64` → matches func.func ✓

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

### Debug Evidence

Instrumented `checkGopt013` to print the `funcExpr` at each violating call site:

| Test | func type in MonoVarGlobal | nargs | initialRemaining | stageArities | totalArity |
|------|---------------------------|-------|-----------------|-------------|-----------|
| Case returns lambda | `MFunction [Op] MInt` | 1 | 3 | [1] | 1 |
| identicalCurried11 | `MFunction [MInt] (MFunction [MInt] MInt)` | 2 | 3 | [1,1] | 2 |
| Hetero closure | `MFunction [Shape] MInt` | 1 | 2 | [1] | 1 |
| filterMap | `MFunction [(Int→Maybe Int)] (MList MInt)` | 1 | 3 | [1] | 1 |
| partial app of map | `MFunction [(Int→Int)] (MList MInt)` | 1 | 2 | [1] | 1 |

**Key observation**: In every case, the `MonoVarGlobal` type only contains stages for the args **supplied at the call site**, not the full function type. The remaining stages are truncated, and `resultMono` is the **final** result type (after all params), not the intermediate result.

### Pipeline Context

The test goes through the full compiler pipeline: Source AST → Canonicalization → Type Checking → PostSolve → TypedOptimize → MonoInlineSimplify → Monomorphization → GlobalOptimize.

Nested calls are NOT flattened at any stage. `callExpr (callExpr (varExpr "getOp") [ctorExpr "Add"]) [intExpr 3, intExpr 4]` remains as nested `MonoCall` nodes through the entire pipeline.

### Root Cause: `buildCurriedFuncType` produces truncated function types

**File**: `compiler/src/Compiler/Monomorphize/TypeSubst.elm:909-927`

`unifyCallSiteDirect` computes `funcMonoType` (the type stored in `MonoVarGlobal`) via `buildCurriedFuncType`:

```elm
-- Line 916-917: resolvedArgs only contains SUPPLIED args
resolvedArgs =
    List.map (resolveMonoVars env1 substAfterArgs) argMonoTypes

-- Line 920-921: resultMono is the FINAL result type (after ALL params)
( resultMono, env2 ) =
    applySubst env1 substAfterArgs schemeResultType

-- Line 924-925: funcMonoType is TRUNCATED
funcMonoType =
    buildCurriedFuncType schemeArgTypes resolvedArgs resultMono
```

**File**: `TypeSubst.elm:949-956`

```elm
buildCurriedFuncType schemeArgs resolvedArgs resultMono =
    case ( schemeArgs, resolvedArgs ) of
        ( _ :: schemeRest, arg :: argRest ) ->
            Mono.MFunction [ arg ] (buildCurriedFuncType schemeRest argRest resultMono)
        _ ->
            resultMono    -- ← when resolvedArgs runs out, returns FINAL result, losing remaining stages
```

**What happens**: `resolvedArgs` is built from `argMonoTypes` (the actual args at the call site). When a function with N total params is called with M < N args, `resolvedArgs` has M elements. `buildCurriedFuncType` zips `schemeArgs` (N elements) with `resolvedArgs` (M elements). After M iterations, `resolvedArgs` is exhausted, and the catch-all returns `resultMono` — the **final** result type (e.g., `MInt`), not the intermediate type that should include the remaining N−M function stages.

### Concrete Trace: `getOp Add`

`getOp : Op -> Int -> Int -> Int`, called with 1 arg (`Add`):

1. `buildSchemeInfo(Op -> Int -> Int -> Int)` → `schemeArgTypes = [Op, Int, Int]`, `schemeResultType = Int`
2. `argMonoTypes = [Op_mono]` (just 1 arg)
3. `unifyArgTypesZip([Op, Int, Int], [Op_mono], subst)` → unifies only first pair, stops
4. `resolvedArgs = [Op_mono]` (1 element)
5. `resultMono = applySubst(Int) = MInt`
6. `buildCurriedFuncType([Op, Int, Int], [Op_mono], MInt)`:
   - iter 1: `MFunction [Op_mono] (buildCurriedFuncType([Int, Int], [], MInt))`
   - iter 2: `resolvedArgs=[]` → returns `MInt`
   - **Result**: `MFunction [Op] MInt` — **WRONG**, should be `MFunction [Op] (MFunction [Int] (MFunction [Int] MInt))`
7. `MonoVarGlobal specId=4 (MFunction [Op] MInt)` — truncated type stored

### How the truncated type creates the GOPT_013 violation

After the staging rewriter (Phase 2 of GlobalOpt), `getOp`'s **node** is modified:
- The Rewriter's `wrapClosureToCanonical` flattens the closure: `params = [(op, Op), (a, Int), (b, Int)]` (3 params)
- The node type is updated via `Mono.typeOf newExpr` at `Rewriter.elm:143` → becomes `MFunction [Op, Int, Int] MInt`

But the `MonoVarGlobal` at the **call site** still carries the original truncated type `MFunction [Op] MInt` — the rewriter's catch-all at `Rewriter.elm:411` (`_ -> (expr, ctx0)`) passes `MonoVarGlobal` through unchanged.

Then `annotateCallStaging` (Phase 5, `MonoGlobalOptimize.elm:1887-2015`) computes:
- `stageArities = collectStageArities(MFunction [Op] MInt) = [1]` → `totalArity = 1` (from the stale VarGlobal type)
- `sourceArityForExpr(VarGlobal specId=4)` → looks up **node** specId=4 → closure has 3 params → `Just 3` (from the actual rewritten node)
- `initialRemaining = sourceArity = 3`
- **GOPT_013 VIOLATION**: `3 > 1`

### Why all 5 tests fail the same way

Every failing test has the same pattern: a **partial call** (fewer args than total params) to a multi-param function. `buildCurriedFuncType` truncates the type to only cover supplied args, and the staging rewriter later expands the closure to the full arity without updating the stale `MonoVarGlobal` types at call sites.

| Test | Function | Total params | Args supplied | Type stages produced | Correct stages |
|------|----------|-------------|---------------|---------------------|----------------|
| 3a | getOp | 3 | 1 | [1] | [1,1,1] |
| 3b | caseFunc | 3 | 2 | [1,1] | [1,1,1] |
| 3c | shapeBonus | 2 | 1 | [1] | [1,1] |
| 3d | foldr/maybeCons | 3 | 1 | [1] | [1,1,1] |
| 3e | map | 2 | 1 | [1] | [1,1] |

### Proposed Fix

Fix `unifyCallSiteDirect` (`TypeSubst.elm:909-927`) to resolve ALL scheme arg types through the substitution, not just the supplied ones:

```elm
unifyCallSiteDirect env schemeArgTypes schemeResultType argMonoTypes baseSubst =
    let
        ( substAfterArgs, env1 ) =
            unifyArgTypesZip env schemeArgTypes argMonoTypes baseSubst

        -- Resolve supplied arg types through substitution
        resolvedSuppliedArgs =
            List.map (resolveMonoVars env1 substAfterArgs) argMonoTypes

        -- Resolve REMAINING scheme arg types through substitution
        remainingSchemeArgs =
            List.drop (List.length argMonoTypes) schemeArgTypes

        ( resolvedRemainingArgs, env2 ) =
            List.foldl
                (\canArg ( accArgs, accEnv ) ->
                    let ( monoArg, envN ) = applySubst accEnv substAfterArgs canArg
                    in ( accArgs ++ [ monoArg ], envN )
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

This ensures the `MonoVarGlobal` carries the **full** function type (`MFunction [Op] (MFunction [Int] (MFunction [Int] MInt))`) regardless of how many args are supplied at any particular call site. The staging rewriter's type changes then stay consistent with the call site types.
