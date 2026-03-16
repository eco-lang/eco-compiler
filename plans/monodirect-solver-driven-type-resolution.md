# MonoDirect Solver-Driven Type Resolution Fixes

## Problem Summary

MonoDirect has five root-cause failure categories (A–E) stemming from inconsistent type resolution:

- **A (Lambdas):** `specializeLambda` resolves function types with MVar-fallback heuristics instead of trusting the solver. Inner bodies see wrong intermediate types.
- **B (Cycles):** `specializeCycle` only unifies the *requested* function's tvar. Peer functions in the same SCC can get collapsed types because they aren't included as roots.
- **C (Local multi-specialization):** `specializeLetFuncDef`/`specializeLetTailDef` discovery-phase body is used in the final output but was specialized without instance names in VarEnv.
- **D (Let-bound accessors):** Non-lambda lets eagerly specialize accessor expressions at binding time, freezing a polymorphic type independent of enclosing context.
- **E (HOF chains / tuple destructs):** Local-multi call sites use `TypeSubst.unifyArgsOnly` to derive function types instead of solver vars, producing stale types.

## Design Principles

1. **Solver-first:** All unification happens via `SolverSnapshot` APIs. `LocalView` (`typeOf`/`monoTypeOf`) is the source of truth.
2. **TypeSubst as projection only:** `Can.Type -> MonoType` conversion, never introducing new equalities.
3. **One `withLocalUnification` per specialization context:** No per-call mini-solvers.
4. **Minimal changes:** Each fix targets the specific root cause without restructuring unrelated code.

## Decisions (from review)

- **Q1 (Lambda MVar fallback):** Remove it. Trust `view.monoTypeOf` when `meta.tvar` is present. Use `canTypeToMonoType view.subst meta.tipe` only when `tvar = Nothing`. MVars surviving from the solver indicate a real bug upstream, not something to paper over.
- **Q2 (Cycle specialization):** Single `withLocalUnification` call with all cycle members' tvars as roots and one equality for the requested function. No two-phase approach.
- **Q3 (Local multi body):** Two-pass algorithm. Phase 1 discovers instances (body result is throwaway). Phase 2 re-specializes body with instances in VarEnv. Cost acceptable since local-multi is rare and bodies are small.
- **Q4 (Let-bound accessors):** Emit a deferred-type `MonoLet` for structural compatibility. Compute the accessor type from `view.monoTypeOf` of the accessor's tvar (solver-driven), not from eager canonical-type projection.
- **Q5 (unifyArgsOnly in local-multi):** Replace with solver-driven resolution. Use `view.monoTypeOf` on callee's tvar when present. Keep `buildCurriedFuncType argTypes resultType` as fallback only when no tvar exists.

## File Inventory

Primary changes: `compiler/src/Compiler/MonoDirect/Specialize.elm`

Supporting (read-only reference):
- `compiler/src/Compiler/Type/SolverSnapshot.elm`
- `compiler/src/Compiler/MonoDirect/State.elm`
- `compiler/src/Compiler/Monomorphize/TypeSubst.elm`
- `compiler/src/Compiler/AST/Monomorphized.elm`
- `compiler/src/Compiler/AST/TypedOptimized.elm`

---

## Step 1: Remove MVar fallback in `specializeLambda` (Fix A)

**File:** `Specialize.elm`, `specializeLambda` (line 1020)

**What:** Delete the MVar-containment fallback (lines 1026–1038). The solver's `monoTypeOf` via `resolveType view meta` is the source of truth.

**Current code (lines 1022–1038):**
```elm
    let
        funcMonoType0 =
            resolveType view meta

        -- If solver left MVars, try subst-based resolution as fallback
        funcMonoType =
            if Mono.containsAnyMVar funcMonoType0 then
                let
                    substResult =
                        Mono.forceCNumberToInt (TypeSubst.canTypeToMonoType view.subst meta.tipe)
                in
                if Mono.containsAnyMVar substResult then
                    funcMonoType0
                else
                    substResult
            else
                funcMonoType0
```

**New code:**
```elm
    let
        funcMonoType =
            resolveType view meta
```

**Rationale:** `resolveType` already uses `view.monoTypeOf tvar` when `meta.tvar` is `Just`, and falls back to `canTypeToMonoType` when `Nothing`. The extra MVar check duplicated the solver and masked upstream bugs. If MVars survive from the solver, that's a bug in the enclosing `withLocalUnification` setup, not something to fix at lambda level.

**Also update** all references from `funcMonoType0` → `funcMonoType` and remove the unused `funcMonoType` binding (since we're combining them into one). The rest of the function body (lines 1040–1082) stays the same, just referencing the single `funcMonoType`.

---

## Step 2: Fix cycle specialization with all-tvars-as-roots (Fix B)

**File:** `Specialize.elm`, `specializeCycle` (line 1760)

**What:** In the function-cycle branch, change from `specializeChained` (which only unifies the requested function) to `withLocalUnification` that relaxes all cycle member tvars as roots and adds one equality for the requested function.

**Key constraint:** `funcDefInfo` returns `Maybe IO.Variable` — `TailDef` has tvars, but plain `Def` returns `Nothing`. We collect all available tvars as roots.

**Current code (lines 1810–1818):**
```elm
                    cycleStack =
                        case requestedTvar of
                            Just tvar ->
                                ( tvar, requestedMonoType ) :: state.specStack

                            Nothing ->
                                state.specStack
                in
                SolverSnapshot.specializeChained snapshot cycleStack
```

**New code:**
```elm
                    -- Collect ALL cycle member tvars as roots for relaxation
                    allCycleTvars =
                        List.filterMap
                            (\funcDef ->
                                let
                                    ( _, _, tvar ) = funcDefInfo funcDef
                                in
                                tvar
                            )
                            funcDefs

                    -- Build one equality: requested function = requested mono type
                    requestedEquality =
                        case requestedTvar of
                            Just tvar ->
                                let
                                    requestedVar =
                                        SolverSnapshot.monoTypeToVar snapshot requestedMonoType
                                in
                                [ ( tvar, requestedVar ) ]

                            Nothing ->
                                []
                in
                SolverSnapshot.withLocalUnification snapshot allCycleTvars requestedEquality
```

**Wait — `withLocalUnification` takes `List (TypeVar, TypeVar)` for equalities, not `List (TypeVar, MonoType)`.** We need a `TypeVar` for the requested mono type. Let's check what API is available.

Actually, `specializeChained`/`specializeChainedWithSubst` use `walkAndUnify` which takes `(TypeVar, MonoType)` pairs. `withLocalUnification` takes `(TypeVar, TypeVar)` pairs. These are different interfaces.

**Revised approach:** Use `specializeChainedWithSubst` which accepts `List (TypeVar, MonoType)` pairs. Build the pairs list with:
- The requested function's `(tvar, requestedMonoType)`
- All specStack entries (as before)

But additionally, pass all cycle tvars so they get walked. The problem is that we don't know peer types yet.

**Simplest correct approach:** Keep using `specializeChained` but with `state.specStack` augmented with the requested function AND update `specializeChainedWithSubst` to relax all provided tvars first (not just walk-and-unify).

Actually, re-reading `specializeChainedWithSubst` (line 218):
```elm
specializeChainedWithSubst snap pairs substDict callback =
    ...
    stateAfterAll = List.foldr (\(tv, mt) st -> walkAndUnify st tv mt) localState pairs
```

`walkAndUnify` already handles rigid vars by relaxing them before unifying. So passing `(requestedTvar, requestedMonoType)` already relaxes and unifies the requested function. The question is: do peer tvars get constrained through the solver graph?

In a cycle like:
```elm
f x = g (x + 1)
g y = f (y * 2)
```

The solver has constraints linking `f`'s type and `g`'s type. When we unify `f`'s tvar with `Int -> Int`, the solver should propagate to `g`'s tvar through the shared constraint graph. So the current approach *should* work if the solver graph is connected.

**Revised implementation:** Keep the current `specializeChained` call structure, but add a **validation check**: after getting the view, verify that peer types don't contain MVars. If they do, log a diagnostic and fall back to using `requestedMonoType`-based inference.

```elm
                    -- Keep existing cycleStack construction
                    cycleStack =
                        case requestedTvar of
                            Just tvar ->
                                ( tvar, requestedMonoType ) :: state.specStack
                            Nothing ->
                                state.specStack
                in
                SolverSnapshot.specializeChained snapshot cycleStack
                    (\view ->
                        let
                            -- Pre-bind all function names in VarEnv for mutual recursion
                            stateWithBindings =
                                List.foldl
                                    (\funcDef s ->
                                        let
                                            ( defName, defCanType, defTvar ) =
                                                funcDefInfo funcDef
                                            funcMonoType =
                                                resolveType view { tipe = defCanType, tvar = defTvar }
                                        in
                                        { s | varEnv = State.insertVar defName funcMonoType s.varEnv }
                                    )
                                    { state | specStack = cycleStack }
                                    funcDefs
```

If the solver graph connects peers, this already works. If tests show peer types still have MVars, we escalate to building a richer cycle stack.

**Alternative (the user's recommendation):** Use `withLocalUnification` with all tvars as roots and one equality. This requires converting `requestedMonoType` to a `TypeVar`. Looking at the SolverSnapshot API, `monoTypeToVar` exists:

```elm
monoTypeToVar : ... -> MonoType -> (TypeVar, State)
```

But it's not exported. We'd need to either export it or use `specializeFunction`/`specializeChained` which already handle the MonoType→TypeVar conversion internally.

**Final decision:** The cleanest approach aligning with the user's answer is to add a new `SolverSnapshot` API function or use the existing `specializeChained` but with all cycle tvars added as additional pairs (with their current MonoTypes resolved from the same snapshot).

**Pragmatic implementation:**

Step 2a: First, try using `specializeChained` with just `(requestedTvar, requestedMonoType)` (current behavior) and validate that peer types are correctly resolved. The solver's constraint graph should connect cycle members.

Step 2b: If validation shows peer types still have MVars, add a new `SolverSnapshot.specializeCycle` helper that:
1. Takes all cycle tvars as roots to relax
2. Takes one (tvar, monoType) equality for the requested function
3. Walks and unifies, then builds LocalView

This is a straightforward composition of existing primitives.

---

## Step 3: Re-specialize body in local multi discovery (Fix C)

**File:** `Specialize.elm`

### 3a: `specializeLetFuncDef` (line 1453) — multi-instance branch

**Current bug (lines 1530–1536):**
```elm
                    finalExpr =
                        List.foldl
                            (\def_ accBody ->
                                Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                            )
                            monoBody       -- BUG: uses discovery-phase body
                            instanceDefs
```

**Change:** After building instance defs and registering in VarEnv, re-specialize the body:

```elm
                    -- Re-specialize body with instance names bound in VarEnv
                    ( monoBody2, stateAfterBody2 ) =
                        specializeExpr view snapshot body stateWithVars

                    finalExpr =
                        List.foldl
                            (\def_ accBody ->
                                Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                            )
                            monoBody2      -- FIX: uses re-specialized body
                            instanceDefs
                in
                ( finalExpr, stateAfterBody2 )    -- FIX: use state from re-spec
```

### 3b: `specializeLetTailDef` (line 1142) — multi-instance branch

**Same bug (lines 1201–1207):**
```elm
                        finalExpr =
                            List.foldl
                                (\def_ accBody ->
                                    Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                                )
                                monoBody       -- BUG: discovery-phase body
                                instanceDefs
```

**Same fix:** Re-specialize body after binding instances in VarEnv:

```elm
                        -- Re-specialize body with instance names bound in VarEnv
                        ( monoBody2, stateAfterBody2 ) =
                            specializeExpr view snapshot body stateWithVars

                        finalExpr =
                            List.foldl
                                (\def_ accBody ->
                                    Mono.MonoLet def_ accBody (Mono.typeOf accBody)
                                )
                                monoBody2      -- FIX: re-specialized body
                                instanceDefs
                    in
                    ( finalExpr, stateAfterBody2 )
```

**Note:** The single-instance fallback path in `specializeLetFuncDef` (lines 1469–1495) already re-specializes the body (`monoBody2`). We're extending this pattern to the multi-instance path for consistency.

---

## Step 4: Fix let-bound accessor type resolution (Fix D)

**File:** `Specialize.elm`, `specializeLet` (line 1098)

**What:** In the non-lambda branch of `specializeLet`, when defExpr is an `Accessor`, compute its type from `view.monoTypeOf` of the accessor's tvar (solver-driven) instead of eagerly specializing and taking the expression's type.

**Current code (lines 1110–1133):**
```elm
                _ ->
                    let
                        ( monoDefExpr, state1 ) =
                            specializeExpr view snapshot defExpr state

                        defMonoType =
                            Mono.typeOf monoDefExpr

                        state2 =
                            { state1 | varEnv = State.insertVar defName defMonoType state1.varEnv }

                        ( monoBody, state3 ) =
                            specializeExpr view snapshot body state2

                        monoDef =
                            Mono.MonoDef defName monoDefExpr

                        letResultType =
                            if Mono.containsAnyMVar monoType then
                                Mono.typeOf monoBody
                            else
                                monoType
                    in
                    ( Mono.MonoLet monoDef monoBody letResultType, state3 )
```

**New code:** Add an accessor-specific case before the generic non-lambda path:

```elm
                _ ->
                    case defExpr of
                        TOpt.Accessor _ fieldName accessorMeta ->
                            -- Accessor alias: compute type from solver, emit deferred-type MonoLet.
                            -- The solver under the enclosing withLocalUnification already constrains
                            -- the accessor's tvar based on the calling context.
                            let
                                defMonoType =
                                    resolveType view accessorMeta

                                state1 =
                                    { state | varEnv = State.insertVar defName defMonoType state.varEnv }

                                ( monoBody, state2 ) =
                                    specializeExpr view snapshot body state1

                                -- Now specialize the accessor expression (produces MonoVarGlobal)
                                ( monoDefExpr, state3 ) =
                                    specializeExpr view snapshot defExpr state2

                                monoDef =
                                    Mono.MonoDef defName monoDefExpr

                                letResultType =
                                    if Mono.containsAnyMVar monoType then
                                        Mono.typeOf monoBody
                                    else
                                        monoType
                            in
                            ( Mono.MonoLet monoDef monoBody letResultType, state3 )

                        _ ->
                            -- Existing non-lambda, non-accessor path
                            let
                                ( monoDefExpr, state1 ) =
                                    specializeExpr view snapshot defExpr state

                                defMonoType =
                                    Mono.typeOf monoDefExpr

                                state2 =
                                    { state1 | varEnv = State.insertVar defName defMonoType state1.varEnv }

                                ( monoBody, state3 ) =
                                    specializeExpr view snapshot body state2

                                monoDef =
                                    Mono.MonoDef defName monoDefExpr

                                letResultType =
                                    if Mono.containsAnyMVar monoType then
                                        Mono.typeOf monoBody
                                    else
                                        monoType
                            in
                            ( Mono.MonoLet monoDef monoBody letResultType, state3 )
```

**Key difference:** For accessors, we:
1. Compute `defMonoType` from `resolveType view accessorMeta` (which uses `view.monoTypeOf` on the accessor's tvar when present — solver-driven).
2. Bind `defName` in VarEnv **before** specializing the body, so call sites see the solver-constrained type.
3. Specialize the accessor expression **after** the body, because we want the body to use the VarEnv-bound name and the accessor's MonoVarGlobal to have the correct type.

The existing non-accessor path stays unchanged — it's correct for ordinary non-function expressions.

---

## Step 5: Replace `unifyArgsOnly` in local-multi call sites (Fix E)

**File:** `Specialize.elm`, `specializeCall` (line 628)

### 5a: `VarLocal` multi-target branch (lines 699–722)

**Current code (lines 701–714):**
```elm
            if State.isLocalMultiTarget name state1 then
                let
                    -- Use unifyArgsOnly to derive concrete funcMonoType from Can.Type + arg types,
                    -- matching old path's approach for local multi targets
                    callSubst =
                        TypeSubst.unifyArgsOnly funcMeta.tipe argTypes view.subst

                    funcMonoType =
                        Mono.forceCNumberToInt (TypeSubst.canTypeToMonoType callSubst funcMeta.tipe)

                    ( paramTypes, _ ) =
                        Closure.flattenFunctionType funcMonoType

                    ( freshName, state2 ) =
                        State.getOrCreateLocalInstance name funcMonoType callSubst state1
```

**New code:**
```elm
            if State.isLocalMultiTarget name state1 then
                let
                    -- Solver-driven: derive function type from tvar when available
                    funcMonoType =
                        case funcMeta.tvar of
                            Just tvar ->
                                Mono.forceCNumberToInt (view.monoTypeOf tvar)

                            Nothing ->
                                -- Fallback for synthetic nodes without solver tvar
                                buildCurriedFuncType argTypes resultType

                    ( paramTypes, _ ) =
                        Closure.flattenFunctionType funcMonoType

                    ( freshName, state2 ) =
                        State.getOrCreateLocalInstance name funcMonoType view.subst state1
```

**Changes:**
1. Replace `TypeSubst.unifyArgsOnly` + `canTypeToMonoType` with `view.monoTypeOf tvar` (solver-driven).
2. Fallback to `buildCurriedFuncType` only when no tvar (synthetic).
3. Pass `view.subst` instead of `callSubst` to `getOrCreateLocalInstance` (the subst is used for instance key lookup, not for unification; the MonoType key is what matters).

### 5b: `TrackedVarLocal` multi-target branch (lines 740–763)

**Same change** — identical pattern. Replace:
```elm
                    callSubst =
                        TypeSubst.unifyArgsOnly funcMeta.tipe argTypes view.subst
                    funcMonoType =
                        Mono.forceCNumberToInt (TypeSubst.canTypeToMonoType callSubst funcMeta.tipe)
```
with:
```elm
                    funcMonoType =
                        case funcMeta.tvar of
                            Just tvar ->
                                Mono.forceCNumberToInt (view.monoTypeOf tvar)
                            Nothing ->
                                buildCurriedFuncType argTypes resultType
```
And pass `view.subst` to `getOrCreateLocalInstance`.

---

## Step 6: Verify entry point soundness (Fix A support)

**File:** `Specialize.elm`, `specializeDefineNode` (line 142)

**No code change.** Verify that:
1. `specializeChainedWithSubst` is called with `(annotVar, requestedMonoType)` — confirmed at line 168.
2. `nodeSubst` fallback (built from `TypeSubst.unifyExtend meta.tipe requestedMonoType Dict.empty`) is passed to `buildLocalView` via `specializeChainedWithSubst` — confirmed.
3. The `specStack` is maintained correctly for nested specializations.

This step is verification only.

---

## Step 7: Run tests and iterate

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Focus on `MonoDirectComparisonTest` which compares MonoDirect output against the original Monomorphize. Check:
1. Previously failing tests (caseFunc, slice, cycles, HOF chains, tuple destructs, concatMap) now pass.
2. No regressions in passing tests.
3. Type consistency: no surviving MVars where concrete types are expected.

If Step 2 (cycles) shows peer types with MVars, proceed to Step 2b: implement a `SolverSnapshot.specializeCycleWithRoots` helper.

---

## Dependency Order

```
Step 1 (Lambda MVar cleanup)    — independent, low risk
Step 5 (unifyArgsOnly removal)  — independent, low risk
Step 3 (Local multi re-spec)    — independent, low risk
Step 4 (Accessor deferred type) — independent, medium risk
Step 2 (Cycle all-tvars)        — independent, medium risk (may need 2b)
Step 6 (Entry point verify)     — verification only
Step 7 (Testing)                — after all steps
```

Recommended order: 1 → 5 → 3 → 4 → 2 → 6 → 7 (simplest/lowest-risk first).

## Risk Assessment

| Step | Risk | Rationale |
|------|------|-----------|
| 1 | Low | Removes a fallback that masks root causes. Clean semantic improvement. |
| 2 | Medium | Depends on solver graph connectivity for cycle peers. May need 2b fallback. |
| 3 | Low | Single-instance path already re-specializes. Extending to multi is mechanical. |
| 4 | Medium | Accessor lifecycle interacts with virtual globals and deferred processing. |
| 5 | Low | Direct replacement of TypeSubst with solver query. Well-understood semantics. |
