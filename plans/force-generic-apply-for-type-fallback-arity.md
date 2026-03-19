# Force GenericApply for Type-Fallback Arity

## Problem

When `sourceArityForCallee` falls back to `firstStageArityFromType` (for function parameters, captured staged functions without `varSourceArity`), the resulting arity often doesn't match the actual closure's `max_values - n_values`. This incorrect arity flows into `CallDirectKnownSegmentation` → typed `papExtend` with wrong `remaining_arity`, causing:

- **CGEN_052 failures** (`papExtend.remaining_arity` mismatch)
- **Runtime crashes** (`eco_closure_call_saturated: argument count mismatch`)
- **CGEN_056 failures** (saturated result type wrong)

The root cause is that `isDynamicCallee` (which checks `dynamicSlots`) and `sourceArityForExpr` (which checks `varSourceArity`) answer different questions. A callee can be *not* in `dynamicSlots` (its staging slot has a producer) yet still have no entry in `varSourceArity`, causing `sourceArityForExpr` to return `Nothing` and the type fallback to kick in. The current code then picks `CallDirectKnownSegmentation` (slot isn't dynamic) with a type-based `initialRemaining` (no producer arity) — exactly the wrong combination.

## Goal

Route StageCurried calls through `CallGenericApply` whenever the arity comes from a type fallback rather than a real producer. Only allow `CallDirectKnownSegmentation` when arity is producer-derived. This decouples "is the staging segmentation known?" from "do we have a trustworthy numerical remaining arity?"

## Scope

All changes in **one file**: `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

No changes to MLIR codegen, runtime, or dialect — `CallGenericApply` already emits generic `papExtend` (no `remaining_arity`), which is exempt from CGEN_052/056 by design.

---

## Implementation Steps

### Step 1: Add `SourceArity` type

**Where:** Just above `sourceArityForCallee` (~line 1588), after `sourceArityForExpr`.

```elm
type SourceArity
    = FromProducer Int
    | FromType Int
```

**Rationale:** Tags arity origin so `computeCallInfo` can branch on it.

### Step 2: Change `sourceArityForCallee` return type

**Where:** Lines 1585–1602.

Change signature from `-> Int` to `-> SourceArity`. Wrap the two branches:

```elm
sourceArityForCallee : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> SourceArity
sourceArityForCallee graph env funcExpr =
    case sourceArityForExpr graph env funcExpr of
        Just arity ->
            FromProducer arity

        Nothing ->
            FromType (firstStageArityFromType (Mono.typeOf funcExpr))
```

Only one call site (`computeCallInfo` at ~line 1850) — no other callers to update.

### Step 3: Rewrite the StageCurried branch in `computeCallInfo`

**Where:** Lines ~1840–1909 (the `Mono.StageCurried ->` branch).

Changes within that branch:

1. **Bind `sourceArityInfo : SourceArity`** instead of `sourceArity : Int`.

2. **Derive `sourceArity : Int`** from `sourceArityInfo`:
   - `FromProducer a` → `a`
   - `FromType _` → `0`

3. **`isSingleStageSaturated`** — unchanged formula (`argCount == sourceArity && sourceArity > 0`). With `FromType`, `sourceArity = 0` so this is always `False` — correct, these calls should not claim saturation.

4. **`initialRemaining`** — unchanged (`= sourceArity`). With `FromType`, this is `0` — irrelevant because `CallGenericApply` ignores it.

5. **`stageAritiesFull`** — **no change**. Keep computing from the type via `collectStageArities` for all StageCurried calls. Required by GOPT_011/GOPT_012 invariants (stageArities must be non-empty and sum to flattened arity).

6. **`remainingStageArities`** — **no change**. Keep computing via `closureBodyStageArities` as today. This is cheap, harmless even if dead for GenericApply, and avoids needing to gate GOPT_013.

7. **`callKind`** — rewrite:
   ```elm
   callKind =
       case sourceArityInfo of
           FromProducer _ ->
               if isDynamicCallee env func then
                   Mono.CallGenericApply
               else
                   Mono.CallDirectKnownSegmentation

           FromType _ ->
               Mono.CallGenericApply
   ```

8. **Record construction** — unchanged fields, same record shape.

### Step 4: Verify compilation

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

### Step 5: Run E2E tests

```bash
cmake --build build --target check
```

Expect:
- CGEN_052/056 failures for parameter calls to disappear (now generic mode, exempt).
- No regressions for calls with known producers (still `CallDirectKnownSegmentation`).

---

## Resolved Questions

### Q1: False negatives / perf regression risk

**Yes, there will be false negatives** — call sites where `firstStageArityFromType` happens to match the true closure remaining arity but we force GenericApply anyway. This is the intended trade-off.

Mitigations that make this safe:
- **`CallGenericApply` is effectively never used today.** `computeCallInfo` always picks `CallDirectKnownSegmentation` for StageCurried callees (except dynamicSlots cases, which are rare). No existing tests assert typed vs generic dispatch behavior.
- **No tests check `_dispatch_mode` / `_closure_kind` / `_fast_evaluator` attributes** on papExtend — those attributes are never emitted; all saturated papExtend lowering goes through the legacy inline path.
- **GlobalOpt invariants don't check `callKind`** — GOPT_011/012 only require `stageArities` to be non-empty and consistent with the type for StageCurried calls.
- **CGEN_052/056 are explicitly exempt for generic papExtend** (no `remaining_arity`).

The perf regression (more boxing, runtime saturation checks) is confined to higher-order parameter calls and is acceptable as a temporary measure until producer-arity propagation is implemented.

### Q2: Are `stageArities` / `remainingStageArities` used on the GenericApply path?

**No.** `generateGenericApply` ignores all staging metadata — it boxes args, emits a single `eco.papExtend` with no `remaining_arity`, and returns `!eco.value`. The staging fields (`stageArities`, `initialRemaining`, `remainingStageArities`) are only consumed by `applyByStages` in the `CallDirectKnownSegmentation` path.

However, **GOPT_011/012 invariants still check `stageArities`** for all StageCurried calls regardless of callKind. So we keep computing them from the type as today — cheap and satisfies the invariants.

For `remainingStageArities`, GOPT_013 defines semantics for typed calls. Keeping the existing computation is harmless and avoids touching invariant definitions.

### Q3: Can a callee be outside `dynamicSlots` yet have `FromType` arity?

**Yes — this is exactly the main bug scenario.** A callee like an outer parameter `alter` may not be in `dynamicSlots` (its staging slot has a producer) but has no `varSourceArity` entry for the inner closure body. `sourceArityForExpr` returns `Nothing`, type fallback kicks in, and today the code picks `CallDirectKnownSegmentation` with an untrustworthy `initialRemaining`.

The `FromProducer` / `FromType` split decouples "is the staging segmentation known?" (`dynamicSlots`) from "do we have a trustworthy numerical remaining arity?" (`varSourceArity` / `sourceArityForExpr`). Forcing `FromType → CallGenericApply` closes exactly this hole.

---

## Assumptions

- **`CallGenericApply` codegen path is fully functional.** `generateGenericApply` correctly handles all argument counts and types. Since it was already wired for dynamicSlots cases, the path exists and works.

- **No other module reads `sourceArityForCallee`.** Confirmed: module-internal with exactly one call site in `computeCallInfo`.

- **Setting `initialRemaining = 0` for `FromType` is harmless.** `CallGenericApply` codegen doesn't use `initialRemaining`. No invariant test checks `initialRemaining > 0` for StageCurried calls regardless of callKind.

- **Performance impact is acceptable.** Generic apply uses runtime `eco_apply_closure`, slower than typed dispatch. Affects only function-parameter calls (higher-order arguments), not direct calls to known functions. This is the intended trade-off for correctness.
