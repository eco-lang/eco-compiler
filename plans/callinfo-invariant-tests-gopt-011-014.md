# Plan: Implement CallInfo Invariant Tests (GOPT_011 through GOPT_014)

## Context

Bug 1 in test-failure-report.md shows that `sourceArityForCallee` returns total arity
instead of first-stage arity for function parameters with multi-stage types. This produces
wrong `initialRemaining` in CallInfo, which cascades to wrong `remaining_arity` on papExtend
ops (CGEN_052) and wrong result types (CGEN_056).

The existing plan `globalopt-callinfo-invariants.md` describes these tests but they were
never implemented. This plan implements them.

## Scope

Create two files:
1. `compiler/tests/TestLogic/GlobalOpt/CallInfoComplete.elm` — test logic
2. `compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm` — test runner

These enforce GOPT_011, GOPT_012, GOPT_013, and GOPT_014 by walking all MonoCall nodes
in the GlobalOpt output graph and validating CallInfo fields.

## Test Logic Design

### Entry point

```elm
expectCallInfoComplete : Src.Module -> Expectation
```

Runs `Pipeline.runToGlobalOpt`, then walks `optimizedMonoGraph` collecting all violations.

### Graph walker

A recursive walker visits all MonoExpr nodes, collecting `(callInfo, funcExpr, args, context)`
tuples for every MonoCall encountered. Each check function processes these tuples.

### Checks

**GOPT_011 — stageArities non-empty and positive for StageCurried:**
- For each MonoCall with `callModel == StageCurried`:
  - Assert `stageArities` is non-empty
  - Assert all elements > 0

**GOPT_012 — stageArities sum equals flattened arity:**
- For each MonoCall with `callModel == StageCurried`:
  - Compute `flattenedArity` from `Mono.typeOf funcExpr` using `decomposeFunctionType`
  - Assert `List.sum stageArities == flattenedArity`

**GOPT_013 — initialRemaining ≤ first stage arity:**
- For each MonoCall with `callModel == StageCurried`:
  - `firstStageArity = List.head stageArities |> Maybe.withDefault 0`
  - Assert `initialRemaining <= firstStageArity`
  - This catches the Bug 1 pattern: for a multi-stage parameter `f : Int -> Int -> Int`
    with type `MFunction [Int] (MFunction [Int] Int)`, stageArities=[1,1],
    firstStageArity=1, but buggy initialRemaining=2. The check 2 <= 1 fails.

Additionally, for consistency:
  - Assert `initialRemaining == List.sum remainingStageArities`
    (the initialRemaining should equal the total remaining across all unsatisfied stages,
    but per the invariant doc, this is only checked for partial application calls)

**GOPT_014 — isSingleStageSaturated consistency:**
- For each MonoCall with `callModel == StageCurried`:
  - `argCount = List.length args`
  - `expectedSaturated = (argCount >= initialRemaining) && (initialRemaining > 0)`
  - Assert `isSingleStageSaturated == expectedSaturated`

### Test runner

Uses `StandardTestSuites.expectSuite` to run against all standard source IR test cases,
exactly like MonoFunctionArityTest.

## Implementation Steps

1. Create `compiler/tests/TestLogic/GlobalOpt/CallInfoComplete.elm`
2. Create `compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm`
3. Run elm-test-rs to verify

## Expected Outcome

These tests are expected to **fail** on test cases that exercise the Bug 1 pattern
(multi-stage function parameters, higher-order calls). This is correct — they are
detecting a real bug. The failures confirm the tests work as intended.
