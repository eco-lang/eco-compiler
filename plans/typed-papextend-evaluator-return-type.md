# Plan: Typed papExtend uses evaluator's func.func result type (CGEN_056)

## Problem

For typed / stage‑curried `eco.papExtend` ops, the saturated result type is
currently derived from `MonoCall.resultType` (the caller's fully‑applied call
type). When a call **over‑saturates** an evaluator whose body returns a
closure (e.g. `caseFunc 0 0 5` where the stage‑1 evaluator of `caseFunc :
Int -> Int -> Int -> Int` returns an `Int -> Int` closure), this disagrees
with the callee's `func.func` result type and violates **CGEN_056**.

Concrete failing scenarios already captured as reproducers:

- `SKI stdlib > B`
- `SKI > I (S K K)`
- `JoinpointABI 4.1 nestedCaseInBranch`
- `Accessor selected via nested case`

The misleading comment at `Expr.elm:1646-1647` claims
> both are derived via `Types.monoTypeToAbi` from the same Mono return type
which is false in the over‑saturated case.

## Design Rule

For any **typed** (`remaining_arity` present) `eco.papExtend` that invokes
evaluator `@f`, the op's SSA result type must equal the result type in
`@f`'s `func.func` declaration. Generic / segmentation‑unknown papExtends
are explicitly **not** covered by CGEN_056 (Eco_PapExtendOp TableGen).

We will plumb the evaluator's func.func result type through `CallInfo` and
use it for typed papExtends instead of `MonoCall.resultType`.

## Step‑by‑step Implementation Plan

### Step 0 — Preflight trace (resolves Q1 before coding)

`Mono.MonoType` represents stages as `MFunction (List MonoType) MonoType`
— **multi‑arg per stage is allowed**, and GlobalOpt may flatten chains
(e.g. `MFunction [Int] (MFunction [Int] Int)` → `MFunction [Int,Int] Int`).
The peel logic in Step 2 must work for both shapes, but we still need to
confirm what `Mono.typeOf func` actually looks like for the four failing
callees.

Add temporary `Eco.Console.log` instrumentation in
`computeCallInfo` (or just before the papExtend emit site) dumping
`Mono.typeOf func` and the chosen `evaluatorReturnType` for each of:

- `caseFunc 0 0 5` from `NestedCaseRepro.elm`
- `I (S K K)` from `IComboRepro.elm`
- accessor‑via‑case reproducer
- joinpoint nested case reproducer

Run via
`node compiler/build-kernel/bin/eco-boot-2-runner.js make <file> --text-mlir`
(per the [Eco.Console.log no-op under XHR] memory note). Confirm that one
`MFunction` peel yields the expected closure type (`MFunction [_] _` →
`!eco.value` once mapped through `monoTypeToAbi`). Remove the
instrumentation before committing.

### Step 1 — Extend `CallInfo` with `evaluatorReturnType`

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

1. Add a new field to `CallInfo` (around line 1107):
   ```elm
   type alias CallInfo =
       { callModel : CallModel
       , stageArities : List Int
       , isSingleStageSaturated : Bool
       , initialRemaining : Int
       , remainingStageArities : List Int
       , closureKind : MaybeClosureKind
       , captureAbi : Maybe CaptureABI
       , callKind : CallKind
       , evaluatorReturnType : MonoType   -- NEW
       }
   ```

2. Update `defaultCallInfo` (around line 1122) with a placeholder
   (e.g. `MInt`, or a dedicated `MUnit`/`MErased` if convention allows).
   The default value is only used until `annotateCallStaging` overwrites
   it; for safety, set it to whatever sentinel is already used for
   uninitialized `MonoType` fields in similar default records.

3. Update `@docs` block to mention the new field.

### Step 2 — Populate `evaluatorReturnType` in GlobalOpt

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

In `computeCallInfo` (around line 1865) populate the new field for both
call models:

1. Add a helper that peels exactly **one `MFunction` layer**, irrespective
   of whether that layer is single‑arg or multi‑arg:
   ```elm
   monoReturnTypeOfFunction : MonoType -> MonoType -> MonoType
   monoReturnTypeOfFunction fallback t =
       case t of
           Mono.MFunction _ body -> body
           _ -> fallback
   ```
   One peel is the right unit because each `MFunction` layer in the
   chain corresponds to one stage's evaluator (Q1 resolution). Multi‑arg
   stages are handled naturally: the args list is ignored, the body is
   the next stage's type.

2. In the **`FlattenedExternal`** branch, set
   `evaluatorReturnType = resultType`. Confirmed safe per Q4 —
   kernel/extern callees route through `instanceAbi.abiResultType` and
   are checked by CGEN_038, so this path is already aligned with the
   `func.func` signature.

3. In the **`StageCurried`** branch, set
   `evaluatorReturnType = monoReturnTypeOfFunction resultType funcType`,
   where `funcType = Mono.typeOf func` is already computed at line 1894.
   Per Q2, `StageCurried` only fires when `Mono.isFunctionType funcType`
   is true (`callModelForCallee` / `sourceArityForCallee` gate on this),
   so the fallback branch should never trigger in practice. The
   fallback exists purely as defense‑in‑depth.

4. Audit and update **all** non‑default `CallInfo {...}` constructors
   (Q5 resolution — these are confirmed to exist):
   - `Compiler/GlobalOpt/Staging/Rewriter.elm` `buildNestedCalls` (~line 635).
   - `Compiler/GlobalOpt/MonoGlobalOptimize.elm` `buildNestedCallsGO`.
   - `Compiler/GlobalOpt/MonoGlobalOptimize.elm` `computeCallInfo`
     (both `FlattenedExternal` and `StageCurried` branches).
   - `defaultCallInfo` in `Monomorphized.elm`.

   For nested‑call builders, the evaluator return type is the body of
   the current stage's `MFunction` — same peel logic. Grep for
   `{ callModel =` to catch any test fixtures or other literal
   constructions before declaring the audit complete.

### Step 3 — Add helper in `Expr.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Near the existing `monoTypeToAbi` usages add:

```elm
{-| MLIR ABI result type of the evaluator func.func at this call site.
This is what CGEN_056 requires saturating typed papExtends to use.
-}
evaluatorAbiResultType : Mono.CallInfo -> MlirType
evaluatorAbiResultType callInfo =
    Types.monoTypeToAbi callInfo.evaluatorReturnType
```

### Step 4 — Fix `generateClosureApplication` (3 staged sites)

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

There are three staged closure‑call sites that currently pass a single
`expectedType` derived from `resultType`. All three follow the same
pattern: zero‑arg fast path coerces to call result type; otherwise call
`applyByStages` with `saturatedReturnType`.

Apply the same edit to each site:

1. **Primary site — `generateClosureApplication` `Mono.StageCurried`
   branch, lines ~1949–2024:**
   - Replace single `expectedType` with two locals:
     ```elm
     callResultMlirType =
         Types.monoTypeToAbi resultType
     evaluatorResultMlirType =
         evaluatorAbiResultType callInfo
     ```
   - The zero‑arg "already evaluated" fast path keeps using
     `callResultMlirType` (no papExtend emitted).
   - The papExtend path passes `evaluatorResultMlirType` as
     `saturatedReturnType` to `applyByStages`.

2. **Secondary site — `MonoVarLocal` `Mono.StageCurried` branch,
   lines ~3191–3254:** same edit.

3. **Tertiary site — `_` fallback `Mono.StageCurried` branch,
   lines ~3257–3310:** same edit.

### Step 5 — Update `applyByStages` doc comment

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`, lines ~1644–1647

Replace the misleading sentence
> both are derived via `Types.monoTypeToAbi` from the same Mono return type

with:
> `saturatedReturnType` must equal the callee's `func.func` result type.
> The caller passes
> `Types.monoTypeToAbi callInfo.evaluatorReturnType`, derived from the
> evaluator's Mono body return type recorded in CallInfo by GlobalOpt.

No change to `applyByStages` body — the bug was always in callers.

### Step 5b — Optional debug assertion on consistency

Per Q6, when `remainingStageArities` is non‑empty there must be at least
one further stage, which implies the evaluator's body type is itself
`MFunction`. Add a cheap defensive check at the papExtend emit sites
(or inside `applyByStages` once `saturatedReturnType` is parameterized
by `evaluatorReturnType`):

```elm
-- Sanity: if more stages remain, evaluatorReturnType must be a function.
-- Firing this indicates a staging-metadata inconsistency, not a legal program.
```

Concretely, we can assert in the GlobalOpt path that the computed
`evaluatorReturnType` is a function whenever
`List.isEmpty callInfo.remainingStageArities == False`. If asserts are
not idiomatic in this codebase, leave a `Eco.Console.log` warning
guarded by a debug flag. Defer if it adds noise.

### Step 6 — Leave generic / segmentation‑unknown paths alone

`generateGenericApply` and `generateUnknownSegmentationCall` emit
`papExtend` **without** `remaining_arity` (generic mode). CGEN_056 does
not apply there per `Eco_PapExtendOp` TableGen. **Do not touch.**

Confirm `PapExtendSaturatedResultType.elm` test logic only fires when
`remaining_arity` is present on the papExtend (typed mode). If it
already filters by `remaining_arity` (per the existing plan
`cgen056-saturated-papextend-result-type.md`), no changes needed.

### Step 7 — Tests

1. Add reproducer Elm modules under
   `compiler/tests/Compiler/Generate/CodeGen/` (or wherever per‑module
   invariant test corpora live) for:
   - `NestedCaseRepro` (caseFunc returning a lambda from a nested case)
   - `IComboRepro` (`I (S K K)`, B combinator) — already preserved at
     `/tmp/repro/src/`
   - `AccessorViaCase` (accessor selected via nested case)
   - `JoinpointABINestedCase`

2. Verify `PapExtendSaturatedResultTypeTest.suite` passes on all
   reproducers after the fix.

3. Run full elm‑test‑rs to confirm the 4 originally‑failing tests now
   pass:
   ```
   cd compiler && npx elm-test-rs --project build-xhr --fuzz 1 2>&1 | tee /tmp/test_output.txt
   ```

4. Run `cmake --build build --target full` to ensure no MLIR verifier
   regressions.

### Step 8 — Memory cleanup

After the fix lands and tests pass, update
`~/.claude/projects/-work/memory/papextend_saturated_result_type_bug.md`
status from "open" to a brief "resolved" note (or delete and update
`MEMORY.md` index accordingly).

---

## Files Touched (summary)

| File | Change |
|---|---|
| `compiler/src/Compiler/AST/Monomorphized.elm` | Add `evaluatorReturnType` field; update default and docs |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Populate `evaluatorReturnType` in `computeCallInfo` both branches |
| `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm` (audit) | Set new field at any literal `CallInfo {…}` construction |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `evaluatorAbiResultType` helper; split `expectedType` into `callResultMlirType` + `evaluatorResultMlirType` at 3 staged sites; update `applyByStages` doc |
| `compiler/tests/.../*Repro.elm` (new) | Reproducer modules wired into invariant suite |

No runtime / C++ changes. No invariants CSV changes.

---

## Resolved Questions (user‑confirmed 2026‑05‑14)

### Q1 — Shape of `MFunction`: RESOLVED with caveat

`Mono.MFunction (List MonoType) MonoType` allows multi‑arg per stage,
and GlobalOpt may flatten chains. **Peel of one `MFunction` layer is
the correct unit** regardless of shape — the args list is ignored, the
body is the next stage. **Still need the Step 0 trace** to confirm the
actual shape produced for the four failing callees before relying on
"one peel = one evaluator's body".

### Q2 — Non‑`MFunction` fallback: RESOLVED

`StageCurried` only fires when `Mono.isFunctionType funcType` is true
(per `callModelForCallee` / `sourceArityForCallee`, and GOPT_011 /
GOPT_012 require non‑empty `stageArities`). Higher‑order locals with
unknown staging route to `CallSegmentationUnknown` / generic apply
instead. Fallback to `resultType` is defensive and should never fire;
firing indicates a staging bug, suitable for a debug assertion.

### Q3 — Can we shortcut by only overriding intermediate stages?: NO

`MonoCall.resultType` equals the last stage evaluator's body return
type **only in the non‑over‑applied case**. The four failing scenarios
are precisely over‑applied past a closure‑returning stage that
GlobalOpt considers saturated at this call site — so the equality
breaks at exactly the stage we care about. Plan must do full plumbing;
the smaller patch is fragile.

### Q4 — `FlattenedExternal` already aligned: CONFIRMED

Kernel/extern result types flow through `registerKernelInstance` →
`instanceAbi.abiResultType` for the `eco.call` result type, and CGEN_038
verifies operand/result types against the kernel `func.func` for
`eco.call`, `eco.papCreate`, and `eco.papExtend`. Setting
`evaluatorReturnType = resultType` for this branch is safe.

### Q5 — Non‑default `CallInfo {...}` constructors: ENUMERATED

The audit list (Step 2.4) is confirmed exhaustive for the optimizer
and staging rewriter; a follow‑up grep is still prudent to catch any
test fixtures.

### Q6 — Defensive assertion: ADOPTED (deferred, optional)

When `remainingStageArities` is non‑empty, the evaluator's body type
must be `MFunction`. Step 5b adds this as an optional sanity check.

### Q7 — `ctx.signatures` alternative: REJECTED

`ctx.signatures` keys by `specId` and would not cover the failing
local / accessor / joinpoint callees that lack `specId`. `CallInfo`
plumbing is the only approach that generalizes; keep as designed.
