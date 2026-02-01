# Plan: MONO_018 - MonoCase Branch Result Types Match MonoCase ResultType

## Overview

Add an elm-test regression test that enforces a new MONO invariant:

> In the monomorphized IR, every `MonoCase _ _ decider jumps resultType` must have `Mono.typeOf branchExpr == resultType` for every branch expression in `jumps` and for every `Inline expr` leaf in the `decider`.

This is a test-only invariant (not a compiler validation pass). It catches ill-typed `MonoCase` nodes that could be silently constructed because `Mono.typeOf (MonoCase ...)` just returns the stored `resultType` field without checking branches.

## Affected Files

| Action | File |
|--------|------|
| **EDIT** | `design_docs/invariants.csv` |
| **EDIT** | `design_docs/invariant-test-logic.md` |
| **EDIT** | `compiler/tests/Compiler/HigherOrderTests.elm` |
| **NEW** | `compiler/tests/Compiler/Generate/Monomorphize/MonoCaseBranchResultType.elm` |
| **NEW** | `compiler/tests/Compiler/Generate/Monomorphize/MonoCaseBranchResultTypeTest.elm` |

## Existing Infrastructure

- **Compilation helper**: `Compiler.Generate.TypedOptimizedMonomorphize.runToMonoGraph : Src.Module -> Result String Mono.MonoGraph`
- **Test pattern**: Uses `StandardTestSuites.expectSuite` with a checker function `expectFn : Src.Module -> Expectation`
- **Test case pattern**: Test cases are defined using `Compiler.AST.SourceBuilder` to construct `Src.Module` values
- **MonoCase structure**: `MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType`
  - `Decider a = Leaf a | Chain ... | FanOut ...`
  - `MonoChoice = Inline MonoExpr | Jump Int`

## Implementation Steps

### Step 1: Update `design_docs/invariants.csv`

Add new row after MONO_017:

```csv
MONO_018;Monomorphization;Types;enforced;Every MonoCase jump branch expression and every Inline leaf in the decider must have the same MonoType as the MonoCase resultType ensuring case expressions are well typed;Compiler.Generate.Monomorphize
```

### Step 2: Update `design_docs/invariant-test-logic.md`

Add entry after MONO_017 (around line 615):

```text
--
name: MonoCase branches match case result type
phase: monomorphization
invariants: MONO_018
ir: MonoCase expressions
logic: For every MonoCase _ _ decider jumps resultType:
  * For each (idx, branchExpr) in jumps:
      Assert Mono.typeOf branchExpr == resultType
  * Walk the decider tree:
      For each Leaf (Inline expr): Assert Mono.typeOf expr == resultType
      For each Leaf (Jump idx): No check needed (checked via jumps)
  * Recursively check all sub-expressions in the MonoGraph
inputs: Monomorphized graphs
oracle: MonoCase resultType agrees with the types of all branch expressions.
tests: compiler/tests/Compiler/Generate/Monomorphize/MonoCaseBranchResultTypeTest.elm
--
```

### Step 3: Add Targeted Test Case to HigherOrderTests.elm

Add a new test case to the `caseReturningFunctionCases` section that specifically exercises "different staging boundaries across branches":

**File**: `compiler/tests/Compiler/HigherOrderTests.elm`

Add to `caseReturningFunctionCases`:
```elm
caseReturningFunctionCases : (Src.Module -> Expectation) -> List TestCase
caseReturningFunctionCases expectFn =
    [ { label = "Case returns curried binary operator", run = caseReturnsCurriedBinaryOp expectFn }
    , { label = "Case returns curried ternary function", run = caseReturnsCurriedTernaryFn expectFn }
    , { label = "Case returns differently staged lambdas", run = caseReturnsDifferentlyStagedLambdas expectFn }  -- NEW
    ]
```

Add new test function:
```elm
{-| Tests MONO_018: MonoCase branch result types must match MonoCase resultType.

This test creates different syntactic lambda nestings across branches that have
the same Elm type but potentially different staging boundaries in Mono IR:

    type Selector = UseFlat | UseNested | UseDoubleNested

    selectFn : Selector -> Int -> Int -> Int -> Int
    selectFn sel a =
        case sel of
            UseFlat ->
                \b c -> a + b + c           -- single 2-arg lambda

            UseNested ->
                \b -> \c -> a + b + c       -- nested single-arg lambdas

            UseDoubleNested ->
                (\b -> \c -> a + b + c)     -- explicitly nested

    testValue = selectFn UseFlat 1 2 3

If monomorphization doesn't normalize these to the same MFunction shape, the
branches would have different MonoTypes, violating MONO_018.
-}
caseReturnsDifferentlyStagedLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
```

The test should use `SourceBuilder` helpers to construct:
1. A custom type `Selector` with variants `UseFlat | UseNested | UseDoubleNested`
2. A function `selectFn` that cases on the selector and returns differently-structured lambdas
3. A call site that invokes the function

### Step 4: Create Checker Module

**File**: `compiler/tests/Compiler/Generate/Monomorphize/MonoCaseBranchResultType.elm`

```elm
module Compiler.Generate.Monomorphize.MonoCaseBranchResultType exposing
    ( expectMonoCaseBranchResultTypes
    , checkMonoCaseBranchResultTypes
    )

{-| Test logic for MONO_018: MonoCase branch result types match MonoCase resultType.

For every MonoCase in the MonoGraph, the types of all branch expressions (both
in the jumps list and inline leaves in the decider) must equal the MonoCase's
resultType.

@docs expectMonoCaseBranchResultTypes, checkMonoCaseBranchResultTypes

-}
```

Key functions:
- `expectMonoCaseBranchResultTypes : Src.Module -> Expectation` - compiles to MonoGraph, runs check
- `checkMonoCaseBranchResultTypes : Mono.MonoGraph -> List Violation` - walks all nodes
- `checkExpr : String -> Mono.MonoExpr -> List Violation` - recursive expression checker
- `checkDecider : String -> Mono.MonoType -> Mono.Decider Mono.MonoChoice -> List Violation` - decider tree walker
- `checkJumps : String -> Mono.MonoType -> List ( Int, Mono.MonoExpr ) -> List Violation` - jump list checker

Logic:
1. Walk all `MonoNode` variants that contain expressions (MonoDefine, MonoTailFunc, MonoPortIncoming, MonoPortOutgoing, MonoCycle)
2. For each `MonoCase _ _ decider jumps resultType`:
   - Check each `(idx, branchExpr)` in jumps: `Mono.typeOf branchExpr == resultType`
   - Walk decider tree: for each `Leaf (Inline expr)`, check `Mono.typeOf expr == resultType`
3. Recursively check all sub-expressions (MonoIf, MonoLet, MonoClosure, MonoCall, etc.)

### Step 5: Create Test Suite

**File**: `compiler/tests/Compiler/Generate/Monomorphize/MonoCaseBranchResultTypeTest.elm`

```elm
module Compiler.Generate.Monomorphize.MonoCaseBranchResultTypeTest exposing (suite)

{-| Test suite for MONO_018: MonoCase branch result types match MonoCase resultType.
-}

import Compiler.Generate.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MONO_018: MonoCase branches match case result type"
        [ StandardTestSuites.expectSuite expectMonoCaseBranchResultTypes "case branch types match"
        ]
```

This runs the checker over **all** test cases in `StandardTestSuites`, including the new test case added to `HigherOrderTests.elm`.

### Step 6: Verification

```bash
cd compiler
npx elm-test-rs --fuzz 1 -- tests/Compiler/Generate/Monomorphize/MonoCaseBranchResultTypeTest.elm
```

## What MONO_018 Catches

This invariant catches the "different staging boundaries across branches" bug:

1. **Same Elm type, different lambda structuring**:
   - Branch 1: `\b c -> a + b + c` (single 2-arg lambda)
   - Branch 2: `\b -> \c -> a + b + c` (nested lambdas)

2. **Potential type divergence**:
   - If monomorphization doesn't normalize these to the same `MFunction` shape, the branches would have different `MonoType`s
   - `MonoCase resultType` could store one shape while branches have another

3. **Why Mono.typeOf exposes this**:
   - Each `MonoExpr` carries its own `MonoType` tag
   - `Mono.typeOf` extracts this per-expression type
   - If branch type differs from `resultType`, we have an ill-typed IR

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Invariant ID | MONO_018 | Next available after MONO_017 |
| Check inline leaves | Yes | `MonoChoice = Inline expr` can have type mismatches too |
| Recursive checking | Yes | MonoCase can appear nested in any expression |
| Use StandardTestSuites | Yes | Consistent with existing MONO tests, runs over ALL test cases |
| Test case location | HigherOrderTests.elm | Fits with existing `caseReturningFunctionCases` section |
| Test case format | Source IR via SourceBuilder | Consistent with all other test cases |
| Runtime enforcement | No | Test-only enforcement is sufficient |

## Summary

| Step | Action | File |
|------|--------|------|
| 1 | Add MONO_018 invariant | `design_docs/invariants.csv` |
| 2 | Add MONO_018 test logic | `design_docs/invariant-test-logic.md` |
| 3 | Add targeted test case | `compiler/tests/Compiler/HigherOrderTests.elm` |
| 4 | Create checker module | `compiler/tests/.../MonoCaseBranchResultType.elm` |
| 5 | Create test suite | `compiler/tests/.../MonoCaseBranchResultTypeTest.elm` |
| 6 | Run tests | Verify all pass |
