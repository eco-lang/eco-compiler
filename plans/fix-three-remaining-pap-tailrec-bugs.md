# Fix Three Remaining Bugs: PapSaturate, PapExtendArity, TailRecDeciderSearch

## Status: READY TO IMPLEMENT

## Problem Summary

Three E2E tests fail due to distinct but interrelated bugs in monomorphization, GlobalOpt call-info computation, and MLIR tail-rec codegen:

- **BUG-2** (`PapSaturatePolyPipeMinimalTest`): `apR` inlining preserves `CEcoValue` result type instead of concrete mono type
- **BUG-1** (`PapExtendArityTest`): Multi-stage functions get `remainingStageArities = []`, causing second-stage application to be skipped
- **BUG-3** (`TailRecDeciderSearchTest`): Tail-rec lambda leaks outer-scope SSA vars via `siblingMappings`, violating SSA dominance

---

## Fix A — BUG-2: `apR` inlining result type (`PapSaturatePolyPipeMinimalTest`)

### Goal
When `Basics.apR` is inlined via over-application, the resulting `MonoCall` must have a concrete monomorphized `resultType` (e.g., `MInt`), not `CEcoValue`.

**This fix requires TWO components:** both the monomorphization side (A2) and the inline side (A1).

### Step A1: Fix `wrapInLetsForInline` type in over-application branch

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

**Location 1:** `tryInlineCall`, line ~1513-1514

```elm
-- BEFORE (line 1514):
innerExpr =
    wrapInLetsForInline bindings substituted (Mono.typeOf body)

-- AFTER:
innerExpr =
    wrapInLetsForInline bindings substituted resultType
```

**Location 2:** `betaReduce`, line ~1085-1086

```elm
-- BEFORE (line 1086):
innerExpr =
    wrapInLets bindings substituted (Mono.typeOf closureBody)

-- AFTER:
innerExpr =
    wrapInLets bindings substituted resultType
```

**Rationale:** `wrapInLets` wraps `MonoLet` nodes with a type annotation. For `apR`, `Mono.typeOf body` is the polymorphic body type with `b = CEcoValue`. The call-site `resultType` is the concrete mono result (e.g., `MInt`). Using `resultType` prevents the CEcoValue leak into the `MonoLet` chain.

**Risk:** `wrapInLets` uses its type argument as the `MonoLet` result type. For exact and partial application, the existing code already uses `resultType`. Only the over-application branch uses `Mono.typeOf body/closureBody`, which is the bug. The `MonoCall` wrapper already correctly uses `resultType` for the outer call's result.

### Step A2: Fix monomorphization to produce concrete types for `apR` (REQUIRED)

**Confirmed:** The current `resultType` at the `apR` call site is NOT concrete after monomorphization. Both the outer `MonoCall`'s `resultType` and `Mono.typeOf body` are `CEcoValue`. A1 alone is insufficient — we must also fix the monomorphization.

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (and `TypeSubst.elm`)

**Action:** When specializing `Basics.apR` (scheme: `a -> (a -> b) -> b`), ensure `unifyCallSiteDirect` is used to unify the scheme against actual mono arg types at the call site, so that `b` resolves to the concrete type (e.g., `MInt`).

**Investigation steps:**
1. Find where `apR` is specialized — likely in `specializeCall` or equivalent.
2. Check whether `unifyCallSiteDirect` + `buildCurriedFuncType` (already in TypeSubst.elm) are being used for this call.
3. If not, wire them in so both `a` and `b` are fully resolved from call-site arg types.
4. Verify with a `Debug.log` that after the fix, the specialized `apR` call's result type is `MInt`, not `CEcoValue`.

**Note:** GlobalOpt's `annotateExprCalls` recomputes `CallInfo` but does NOT change `resultType`. So without A2, CEcoValue propagates into MLIR and hits CGEN_056.

### Step A3: No changes needed for `CallInfo`

`Mono.defaultCallInfo` is a placeholder. GlobalOpt's `annotateExprCalls` (line ~1169-1185) recomputes `CallInfo` via `computeCallInfo` when `existingCallInfo.stageArities` is empty. Once `resultType` is correct, the recomputed `CallInfo` will also be correct.

---

## Fix B — BUG-1: Missing second stage (`PapExtendArityTest`)

### Goal
For `result2 = flip curried 4 6`, after inlining `flip`, the call to `curried` with 2 args must produce two `eco.papExtend` operations (one per stage), not one. Currently `remainingStageArities = []` causes `applyByStages` to stop after the first stage.

### Step B1: Derive `remainingStageArities` structurally from `stageAritiesFull`

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
**Function:** `computeCallInfo`, StageCurried branch (lines ~1835-1927)

Current code derives `remainingStageArities` from `closureBodyStageArities graph func`, which returns `Nothing` for parameters/captures (unknown callee body), falling back to `[]`.

**Change:** When `closureBodyStageArities` returns `Nothing`, derive remaining stages structurally from `stageAritiesFull` instead of defaulting to `[]`:

```elm
remainingStageArities =
    let
        bodyArities =
            closureBodyStageArities graph func
    in
    case bodyArities of
        Just arities ->
            -- Known callee: use actual body's stage arities
            arities

        Nothing ->
            -- Unknown callee: derive from type's stage segmentation.
            -- stageAritiesFull = [a1, a2, ..., an] where a1 is the current stage.
            -- Remaining stages = tail of stageAritiesFull (stages after the first).
            case stageAritiesFull of
                _ :: rest ->
                    rest

                [] ->
                    []
```

**Rationale:** For `curried : MFunction [Int] (MFunction [Int] Int)`, `stageAritiesFull = [1, 1]`. The first element is the current stage's arity (`initialRemaining`). The remaining elements `[1]` describe subsequent stages. When the callee body isn't traceable (parameter/capture), the type-derived segmentation is the best available info. `applyByStages` uses `remainingStageArities` to know there's another closure to call after the first stage.

**Confirmed safe:** This logic only runs inside `computeCallInfo`. Wrapper-generated nested calls (from `buildAbiWrapperGO`/`buildNestedCallsGO`) bring their own pre-baked `CallInfo` with non-empty `stageArities`, so `annotateExprCalls` preserves them and never calls `computeCallInfo`. Dynamic slots are routed to `CallGenericApply` and skip the StageCurried path entirely via `isDynamicCallee`. So `List.tail stageAritiesFull` is the correct fallback for all cases where `computeCallInfo` actually runs.

### Step B2: Add closure params to `varSourceArity` in `annotateExprCalls`

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
**Function:** `annotateExprCalls`, `MonoClosure` branch (lines ~1212-1237)

Currently only captures are added to `varSourceArity`. Closure params with function types are not, causing `sourceArityForExpr` to return `Nothing` for param-bound callees like `f` in `applyPartial f a`.

**Change:** After building `envWithCaptures`, add params:

```elm
envWithParamsAndCaptures =
    List.foldl
        (\( paramName, paramType ) envAcc ->
            if Mono.isFunctionType paramType then
                let
                    firstStageArity =
                        case MonoReturnArity.collectStageArities paramType of
                            a1 :: _ -> a1
                            [] -> 0
                in
                { envAcc
                    | varSourceArity =
                        Dict.insert paramName firstStageArity envAcc.varSourceArity
                }
            else
                envAcc
        )
        envWithCaptures
        info.params
```

Then use `envWithParamsAndCaptures` (instead of `envWithCaptures`) when recursing into the body.

**Rationale:** This makes `sourceArityForCallee` return `FromProducer a1` instead of `FromType ...` for param-bound callees with known function types. This enables `CallDirectKnownSegmentation` (instead of `CallGenericApply`) and provides correct `initialRemaining`.

**Note:** B2 only adds params to `varSourceArity`, not to `paramSlotKeys`/`dynamicSlots`. So `isDynamicCallee` is unaffected — it still correctly identifies genuinely dynamic slots.

### Step B3: No changes to `callKind` logic

The existing `callKind` logic already handles the `FromProducer` vs `FromType` distinction correctly. With B2 in place, more param-bound calls will get `FromProducer`, which is the desired behavior. `isDynamicCallee` still gates truly dynamic slots to `CallGenericApply`.

---

## Fix C — BUG-3: Tail-rec SSA dominance (`TailRecDeciderSearchTest`)

### Goal
In `_tail_firstInlineExpr_31`, the self-reference `firstInlineExpr` must not resolve to `%1` from the outer function `search_$_5`. Instead, a local self-closure must be created inside the same `func.func`, before the `scf.while` loop.

**Simplified approach (confirmed):** Since `scf.while` is NOT `IsolatedFromAbove`, we define `%self` once in the entry block before the loop. No need to thread it as a loop-carried value.

### Step C1: Add `selfBindingName` field to `PendingLambda`

**File:** `compiler/src/Compiler/Generate/MLIR/Ctx.elm` (or wherever `PendingLambda` is defined)

Add a new field:
```elm
type alias PendingLambda =
    { name : String
    , captures : List ( Name.Name, Mono.MonoType )
    , params : List ( Name.Name, Mono.MonoType )
    , body : Mono.MonoExpr
    , returnType : Mono.MonoType
    , siblingMappings : Dict.Dict String VarInfo
    , isTailRecursive : Bool
    , selfBindingName : Maybe String  -- NEW: Elm-level binding name for tail-rec self-reference
    }
```

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`, `MonoTailDef` branch (line ~3513-3521)

Set `selfBindingName = Just name` (where `name` is the Elm binding name like `"firstInlineExpr"`):
```elm
pendingLambda =
    { name = tailFuncName
    , captures = captureTypes
    , params = params
    , body = tailBody
    , returnType = Mono.typeOf tailBody
    , siblingMappings = ctxWithPlaceholders.currentLetSiblings
    , isTailRecursive = True
    , selfBindingName = Just name  -- NEW
    }
```

For all other `PendingLambda` construction sites, set `selfBindingName = Nothing`.

### Step C2: Filter self-binding from `siblingMappings` for tail-rec lambdas

**File:** `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`
**Function:** `generateLambdaFunc` (lines ~150-153)

```elm
-- Replace line 152-153:
varMappingsWithSiblings =
    Dict.union varMappingsWithArgs lambda.siblingMappings

-- With:
filteredSiblingMappings =
    case lambda.selfBindingName of
        Just selfName ->
            Dict.remove selfName lambda.siblingMappings
        Nothing ->
            lambda.siblingMappings

varMappingsWithSiblings =
    Dict.union varMappingsWithArgs filteredSiblingMappings
```

This prevents importing the outer function's `%1` for `firstInlineExpr`.

### Step C3: Create a local self-closure before the `scf.while` loop

**File:** `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`
**Location:** Inside the `if lambda.isTailRecursive then` branch (line ~164)

After setting up `ctxWithArgs` (which now has filtered sibling mappings), before calling `TailRec.compileTailFuncToWhile`:

1. **Only if `selfBindingName` is `Just selfName`:**
   - Emit an `eco.papCreate` op mirroring the one in Expr.elm:3587-3592:
     - `function` = the appropriate symbol name (same logic as Expr.elm:3538-3543)
     - `arity` = `List.length lambda.captures + List.length lambda.params`
     - `num_captured` = `List.length lambda.captures`
     - `unboxed_bitmap` = computed from capture MLIR types
     - Operands = capture SSA vars (from `captureArgPairs`)
   - Allocate a fresh SSA var `%selfVar`
   - Add var mapping: `selfName -> { ssaVar = %selfVar, mlirType = Types.ecoValue }`
   - Prepend the `papCreate` op to the body ops
   - Pass updated context to `compileTailFuncToWhile`

2. **If `selfBindingName` is `Nothing`:** No change, proceed as before.

**Key point:** `%selfVar` is defined in the entry block of the `func.func`, before the `scf.while` op. Since `scf.while` is not `IsolatedFromAbove`, `%selfVar` is accessible inside both the before-region and after-region of the loop. No loop-carried threading needed.

### Step C4: No changes to `TailRec.elm`

Since `%self` is defined before the loop and accessible inside it (not `IsolatedFromAbove`), no changes to `compileTailFuncToWhile`, `buildBeforeRegion`, or `buildAfterRegion` are needed. The `setupVarMappings` call in the after-region remaps param names to loop body block args, but the self-binding mapping from C3 persists in `ctx.varMappings` and is available for lookups.

**Verify:** Confirm that `setupVarMappings` does not clobber the self-binding mapping. It only remaps original param names (e.g., `"decider"`) to new block args — it should not touch `"firstInlineExpr"`.

### Step C5: Verify the separate `%3` dominance bug

The plan's original analysis mentions a separate issue where the `scf.while` result `%3` is used inside the loop body instead of the body block argument. After C1-C3:
- The self-reference now uses `%selfVar` (defined before the loop) — correct.
- If there's still a `%3` dominance issue for other values (e.g., loop-carried params), that would be a separate TailRec.elm bug. Verify after implementing C1-C3 by checking the generated MLIR.

---

## Implementation Order

1. **Fix A** (A1 + A2) — inline fix is trivial; monomorphization fix needs investigation
2. **Fix B** (B1, then B2) — moderate change in MonoGlobalOptimize
3. **Fix C** (C1, C2, C3) — add field + filter siblings + emit self-closure

After each fix, run the corresponding test to validate before moving on.

## Verification

After all fixes:

```bash
# Run the three target tests
TEST_FILTER=PapSaturatePolyPipeMinimal cmake --build build --target check
TEST_FILTER=PapExtendArity cmake --build build --target check
TEST_FILTER=TailRecDeciderSearch cmake --build build --target check

# Run full test suite for regression
cmake --build build --target check

# Run front-end invariant tests
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

---

## Resolved Questions

### Fix A (resolved)
- **Q1: Is `resultType` already concrete after monomorphization?** NO. Both the outer `MonoCall`'s `resultType` and `Mono.typeOf body` are `CEcoValue`. Fix A requires BOTH the inline fix (A1) and the monomorphization fix (A2).
- **Q2: Does `wrapInLets` with `resultType` break any invariant?** No — exact and partial application branches already use `resultType`. Only over-application was wrong.

### Fix B (resolved)
- **Q3: Is `List.tail stageAritiesFull` always correct?** YES for all cases where `computeCallInfo` runs. Wrapper chains bring pre-baked `CallInfo` and bypass `computeCallInfo`. Dynamic slots use `CallGenericApply` and skip the StageCurried path.
- **Q5: Is `isDynamicCallee` affected by B2?** No — B2 only touches `varSourceArity`, not `paramSlotKeys`/`dynamicSlots`.

### Fix C (resolved)
- **Q9/Q10: Do we need loop-carried `%self`?** NO. Define `%self` before the loop; `scf.while` is not `IsolatedFromAbove`, so it's accessible inside the loop. Much simpler than threading.
- **Q6: What is `selfBindingName`?** The `name` from `MonoTailDef name params tailBody` (Expr.elm:3451) — the Elm-level binding name like `"firstInlineExpr"`.
- **Q7: Should `eco.papCreate` include captures?** Yes — mirror the papCreate in Expr.elm:3587-3592 with same operands and attributes.
- **Q8: Does threading affect index arithmetic?** N/A — we're not threading.

### Cross-cutting (remaining)
- **Q4: Could adding params to `varSourceArity` introduce wrong arity for partially-applied params?** At closure entry, params are fresh (not partially applied), so first-stage arity from type is correct. Low risk.
- **Q11: Other callers of `wrapInLets` with `Mono.typeOf body`?** Only the over-application branches. Exact and partial application use `resultType` correctly.
- **Q12: Regression risk?** Run full suite. B1/B2 changes could affect tests relying on `remainingStageArities = []` for unknown callees.
