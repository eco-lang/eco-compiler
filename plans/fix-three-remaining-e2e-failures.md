# Fix 3 Remaining E2E Test Failures

## Status: PLAN — not yet implemented

## Overview

Three E2E tests remain failing. Two are genuine compiler bugs; one is likely a manifestation of Bug 1.

| # | Test | Category | Phase | Bug? |
|---|------|----------|-------|------|
| 1 | PolyApplyLambdaTest | Premature VarGlobal specialization | Monomorphize (Specialize.elm) | Yes |
| 2 | PapExtendArityTest | Missing stage arity through locals | GlobalOpt (MonoGlobalOptimize.elm) | Yes |
| 3 | PolyLetConstTest | Likely Bug 1 manifestation | Monomorphize (Specialize.elm) | Verify after Bug 1 fix |

---

## Bug 1: PolyApplyLambdaTest — Premature VarGlobal Specialization

**Error:** `'eco.papExtend' op newarg 0 has type 'i64' but evaluator parameter 0 expects '!eco.value'`

**Test code:**
```elm
apply f x = f x
intId n = n       -- polymorphic: a -> a
-- apply intId 1  -- should specialize intId to Int -> Int
```

**Root cause:** In `processCallArgs` (Specialize.elm:2271–2383), VarGlobal arguments fall through to the `_ ->` default branch (line 2373), which calls `specializeExpr` immediately with the caller's substitution. For `intId` (type `a -> a`), the substitution is empty, so `a` becomes `CEcoValue`, producing `(!eco.value) -> (!eco.value)`. Call-site unification runs *after* processCallArgs and correctly determines `a = Int`, but `intId` was already enqueued as `intId_$_1` with `CEcoValue` types.

### Fix: Add `PendingGlobal` variant to `ProcessedArg`

**This is the correct root-cause fix.** The existing deferral pattern (`PendingAccessor`, `PendingKernel`, `LocalFunArg`) is well-established and proves the architecture supports deferred resolution.

### Resolved Design Decisions

**Gating predicate: `Mono.containsCEcoMVar`** (not `containsAnyMVar`).

- `containsCEcoMVar` targets exactly the failure mode: unconstrained type variables where layout is always boxed, producing `!eco.value` ABI mismatches.
- `containsAnyMVar` would also flag `CNumber` sites, but those are already handled by `forceCNumberToInt` at monomorphization boundaries and guarded by MONO_008/MONO_002 invariants.
- `containsCEcoMVar` is the same litmus test used by MONO_021/MONO_024 for "still polymorphic in a way we care about".

**Scope: VarGlobal only** (not VarEnum/VarCtor).

- Constructors and enum variants are specialized via their `SpecKey` (`requestedMonoType`), not via the caller's substitution alone. The enclosing specialization's substitution is already meaningful by the time they appear as arguments.
- No current test reproduces premature ctor/enum specialization with this shape.
- Widening deferral to all polymorphic callables risks interaction with MONO_021/MONO_024 CEcoValue checks and value-multi machinery.
- If a ctor/enum failure with this same shape surfaces later, add `PendingCtor`/`PendingEnum` as a separate change.

### Implementation Plan

**Step 1:** Add `PendingGlobal` variant to `ProcessedArg` (Specialize.elm:52–56)
```elm
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type
    | PendingKernel A.Region String String Can.Type
    | PendingGlobal TOpt.Expr Substitution Can.Type   -- NEW
    | LocalFunArg Name Can.Type
```

**Step 2:** In `processCallArgs` (line 2373, the `_ ->` branch), add a VarGlobal check gated by `containsCEcoMVar`:
```elm
_ ->
    case arg of
        TOpt.VarGlobal _ _ meta ->
            let
                canType = meta.tipe
                monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            if Mono.containsCEcoMVar monoType then
                -- Defer: polymorphic global needs call-site context
                ( PendingGlobal arg subst canType :: accArgs
                , monoType :: accTypes
                , st
                )
            else
                -- Concrete type: specialize immediately
                let
                    ( monoExpr, st1 ) = specializeExpr arg subst st
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )
        _ ->
            let
                ( monoExpr, st1 ) = specializeExpr arg subst st
            in
            ( ResolvedArg monoExpr :: accArgs
            , Mono.typeOf monoExpr :: accTypes
            , st1
            )
```

**Step 3:** Add `PendingGlobal` case to `resolveProcessedArg` (after line 2514):
- Receive `maybeParamType` from the unified callee signature
- Refine substitution: `refinedSubst = TypeSubst.unifyExtend canType paramType savedSubst`
- Call `specializeExpr` on the saved VarGlobal expr with `refinedSubst`
- Return the resulting `(MonoExpr, State)`

**Step 4:** Update any exhaustive pattern matches on `ProcessedArg`.

**Step 5:** Run tests:
- `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` (front-end)
- `cmake --build build --target check` (E2E, including PolyApplyLambdaTest)

---

## Bug 2: PapExtendArityTest — Missing Stage Arity Propagation Through Local Variables

**Error:** `result2: <fn>` instead of `result2: 10`

**Test code:**
```elm
curried x = \y -> x + y    -- MFunction [Int] (MFunction [Int] Int), staging [1,1]
flip f b a = f a b
result2 = flip curried 4 6  -- after inlining: let f'=curried in f' 6 4
```

**Root cause:** After `flip` is inlined, the code becomes `let f' = curried in f' 6 4`. In `computeCallInfo`, `closureBodyStageArities graph func` is called where `func = MonoVarLocal f'`. But `closureBodyStageArities` (lines 1773–1782) only handles `MonoVarGlobal` and `MonoClosure` — `MonoVarLocal` hits `_ -> Nothing`, yielding `remainingStageArities = []`. This causes `applyByStages` to stop after the first stage (1 arg consumed), returning a closure instead of applying the second arg.

### Fix: Propagate body stage arities through `CallEnv`

**This is the correct approach.** Both alternative fixes were correctly rejected:
- Fix B1 (type-derived staging from `stageAritiesFull` tail): Unreliable post-canonicalization — GlobalOpt phase 2 may change staging without updating type annotations.
- Fix B2 (closure params in `varSourceArity`): Forces ABI on dynamic callees, causing CGEN_040/CGEN_056 violations across 27+ tests.

### Resolved Design Decision

**Transitivity is handled for free** by the existing `annotateExprCalls` recursion through nested `MonoLet` chains. The environment is threaded through:
- `let g = curried` → `closureBodyStageArities graph (MonoVarGlobal curried)` succeeds → insert into `varBodyStageArities["g"]`
- `let f = g` → when processing `f`'s bound expression, `env` already has `g`'s entry → `varBodyStageArities["f"]` gets populated from `g`'s usage

No explicit multi-hop fixup needed.

### Implementation Plan

**Step 1:** Add `varBodyStageArities : Dict Name (List Int)` to `CallEnv` (MonoGlobalOptimize.elm:72–77):
```elm
type alias CallEnv =
    { varCallModel : Dict Name Mono.CallModel
    , varSourceArity : Dict Name Int
    , varBodyStageArities : Dict Name (List Int)  -- NEW
    , dynamicSlots : Set String
    , paramSlotKeys : Dict Name String
    }
```

**Step 2:** Update all `CallEnv` construction sites to include `varBodyStageArities = Dict.empty`.

**Step 3:** In `annotateDefCalls` (line 1306–1358), when processing `MonoDef name bound1`:
```elm
maybeBodyStageArities =
    closureBodyStageArities graph bound1

env3 =
    case maybeBodyStageArities of
        Just arities ->
            { env2 | varBodyStageArities = Dict.insert name arities env2.varBodyStageArities }
        Nothing ->
            env2
```

**Step 4:** In `computeCallInfo`, change the `remainingStageArities` computation to fall back to `CallEnv`:
```elm
remainingStageArities =
    case closureBodyStageArities graph func of
        Just arities ->
            arities

        Nothing ->
            case func of
                Mono.MonoVarLocal name _ ->
                    Dict.get name env.varBodyStageArities
                        |> Maybe.withDefault []

                _ ->
                    []
```

**Step 5:** Verify `isDynamicCallee` returns `False` for let-bound locals aliasing globals (it should — `f'` won't be in `paramSlotKeys` since it's not a closure parameter).

**Step 6:** Run tests (same as Bug 1).

---

## Bug 3: PolyLetConstTest — Likely Bug 1 Manifestation

**Test code:**
```elm
const a b = a
r1 = const 1 "hi"   -- CHECK: r1: 1
r2 = const "hi" 1   -- CHECK: r2: "hi"
```

**Hypothesis:** This is the same premature-specialization shape as Bug 1. A polymorphic let-bound `const` (type `a -> b -> a`) gets monomorphized once with `CEcoValue` in its result position before call-site unification can determine `a = Int` or `a = String`. The `PendingGlobal` fix should resolve it.

### Verification Strategy

1. Implement Bug 1 fix (`PendingGlobal` with `containsCEcoMVar` gating).
2. Re-run PolyLetConstTest.
3. **If it passes:** Bug 3 was indeed a manifestation of Bug 1. Done.
4. **If it persists:** Inspect failing MLIR to determine whether the mis-typed expression is:
   - (a) A `MonoVarGlobal` that never went through the deferral path → widen gating or add another deferred variant
   - (b) An inlined body whose `Mono.typeOf` still carries `MVar _ CEcoValue` → separate propagation fix (similar to the `apR` pipeline bug pattern)

---

## Execution Order

1. **Bug 1** first — earlier compiler phase, self-contained, may also fix Bug 3
2. **Bug 3 verification** — re-run after Bug 1 to confirm/reject hypothesis
3. **Bug 2** last — independent GlobalOpt fix, no interaction with Bug 1
