# Consolidate ID Assignment Test Suites

## Goal

Create a central `IdAssignmentTest.elm` file that consolidates all individual test suites into a single `expectSuite` function, allowing the entire test collection to be run with different expectation functions.

## Current State

Each test file in `/work/compiler/tests/Compiler/` has:
- A `suite : Test` function that calls `expectSuite expectUniqueIds "has unique IDs"`
- An `expectSuite : (Src.Module -> Expectation) -> String -> Test` function

Files to consolidate (17 total):
1. AsPatternTests.elm
2. BinopTests.elm
3. CaseTests.elm
4. EdgeCaseTests.elm
5. FunctionTests.elm
6. HigherOrderTests.elm
7. KernelTests.elm (uses `Can.Module` instead of `Src.Module`)
8. LetDestructTests.elm
9. LetRecTests.elm
10. LetTests.elm
11. ListTests.elm
12. LiteralTests.elm
13. MultiDefTests.elm
14. OperatorTests.elm
15. PatternArgTests.elm
16. RecordTests.elm
17. TupleTests.elm

## Target State

### New file: `/work/compiler/tests/Compiler/Canonicalize/IdAssignmentTest.elm`

```elm
module Compiler.Canonicalize.IdAssignmentTest exposing (suite, expectSuite)

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.CaseTests as CaseTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FunctionTests as FunctionTests
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.KernelTests as KernelTests
import Compiler.LetDestructTests as LetDestructTests
import Compiler.LetRecTests as LetRecTests
import Compiler.LetTests as LetTests
import Compiler.ListTests as ListTests
import Compiler.LiteralTests as LiteralTests
import Compiler.MultiDefTests as MultiDefTests
import Compiler.OperatorTests as OperatorTests
import Compiler.PatternArgTests as PatternArgTests
import Compiler.RecordTests as RecordTests
import Compiler.TupleTests as TupleTests
import Compiler.Canonicalize.IdAssignment exposing (expectUniqueIds, expectUniqueIdsCanonical)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    expectSuite expectUniqueIds expectUniqueIdsCanonical "has unique IDs"


expectSuite : (Src.Module -> Expectation) -> (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn expectFnCanonical condStr =
    Test.describe ("Unique IDs for all nodes in Canonical form " ++ condStr)
        [ AsPatternTests.expectSuite expectFn condStr
        , BinopTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        , EdgeCaseTests.expectSuite expectFn condStr
        , FunctionTests.expectSuite expectFn condStr
        , HigherOrderTests.expectSuite expectFn condStr
        , KernelTests.expectSuite expectFnCanonical condStr  -- Uses Can.Module
        , LetDestructTests.expectSuite expectFn condStr
        , LetRecTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , ListTests.expectSuite expectFn condStr
        , LiteralTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        , OperatorTests.expectSuite expectFn condStr
        , PatternArgTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        , TupleTests.expectSuite expectFn condStr
        ]
```

### Modifications to each test file

For each of the 17 test files, remove the `suite` function and its export:

**Before:**
```elm
module Compiler.AsPatternTests exposing
    ( suite
    , expectSuite
    , ...
    )

suite : Test
suite =
    expectSuite expectUniqueIds "has unique IDs"


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr = ...
```

**After:**
```elm
module Compiler.AsPatternTests exposing
    ( expectSuite
    , ...
    )

expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr = ...
```

Also remove the import of `expectUniqueIds` from each file since it's no longer used there.

## Implementation Steps

1. Create `/work/compiler/tests/Compiler/Canonicalize/IdAssignmentTest.elm` with the consolidated `suite` and `expectSuite`

2. For each of the 17 test files:
   - Remove `suite` from the exports list
   - Remove the `suite` function definition
   - Remove the import of `expectUniqueIds` / `expectUniqueIdsCanonical` (no longer needed)

3. Run tests to verify everything still works

## Special Considerations

- **KernelTests.elm** uses `Can.Module` and `expectUniqueIdsCanonical` instead of `Src.Module` and `expectUniqueIds`. The consolidated `expectSuite` needs to accept both expectation functions.

- The consolidated `expectSuite` signature is:
  ```elm
  expectSuite : (Src.Module -> Expectation) -> (Can.Module -> Expectation) -> String -> Test
  ```

## Benefits

1. Single point of entry for running all ID assignment tests
2. Easy to add new expectation functions (e.g., for different validation modes)
3. Cleaner separation: individual test files define test cases, IdAssignmentTest.elm orchestrates them
4. Reduced duplication of the `suite` pattern across 17 files
