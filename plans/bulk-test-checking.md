# Bulk Test Checking Optimization

## Overview

Collapse many individual `Test.test` nodes into single bulk tests using `Expect.andThen` chaining. This reduces test node count from ~40,000 to ~1,710 (96% reduction).

## Design Decisions

- **Granularity**: One bulk test per module per invariant (Option B)
- **Failure reporting**: Labeled failures showing which test case failed
- **DeepFuzzTests**: Keep as-is with real `Test.fuzz` calls (randomness is the point)
- **Debugging**: Use `Debug.log` when needed, no separate verbose mode

## Architecture

### Before
```
InvariantTest (e.g., GlobalNamesTest)
└── StandardTestSuites.expectSuite
    └── LiteralTests.expectSuite
    │   └── Test.describe "Int literals"
    │   │   └── Test.test "Zero"        ← node
    │   │   └── Test.test "Positive"    ← node
    │   │   └── Test.test "Negative"    ← node
    │   └── Test.describe "Float literals"
    │       └── Test.test "Zero float"  ← node
    │       └── ...
    └── TupleTests.expectSuite
        └── ...

~700 nodes × 57 invariants = ~40,000 nodes
```

### After
```
InvariantTest (e.g., GlobalNamesTest)
└── StandardTestSuites.expectSuite
    └── Test.describe "Standard tests"
        └── Test.test "LiteralTests"     ← 1 node (runs ~40 cases internally)
        └── Test.test "TupleTests"       ← 1 node (runs ~24 cases internally)
        └── Test.test "RecordTests"      ← 1 node
        └── ...
└── DeepFuzzTests.expectSuite            ← kept as-is (~25 fuzz nodes)

~30 bulk nodes + ~25 fuzz nodes = ~55 nodes per invariant
~55 nodes × 57 invariants = ~3,135 nodes
```

## Implementation

### Step 1: Create BulkCheck.elm helper module

Create `/work/compiler/tests/Compiler/BulkCheck.elm`:

```elm
module Compiler.BulkCheck exposing (TestCase, bulkCheck)

import Expect exposing (Expectation)


type alias TestCase =
    { label : String
    , run : () -> Expectation
    }


{-| Run multiple test cases as a single bulk test.
Fails on first failure, reporting the label of the failing case.
-}
bulkCheck : List TestCase -> Expectation
bulkCheck cases =
    cases
        |> List.foldl
            (\{ label, run } acc ->
                acc
                    |> Expect.andThen
                        (\_ ->
                            run ()
                                |> mapFailure (\msg -> label ++ ": " ++ msg)
                        )
            )
            Expect.pass


{-| Map over a failure message if the expectation fails.
-}
mapFailure : (String -> String) -> Expectation -> Expectation
mapFailure f expectation =
    -- Expect.andThen only continues on pass, so we use onFail pattern
    case Expect.getFailure expectation of
        Nothing ->
            expectation

        Just { description, reason } ->
            Expect.fail (f description)
```

**Note**: Need to verify `Expect.getFailure` exists in elm-explorations/test. If not, alternative approach:

```elm
bulkCheck : List TestCase -> Expectation
bulkCheck cases =
    case cases of
        [] ->
            Expect.pass

        { label, run } :: rest ->
            case Expect.getFailure (run ()) of
                Nothing ->
                    bulkCheck rest

                Just failure ->
                    Expect.fail (label ++ ": " ++ failure.description)
```

### Step 2: Refactor each test module

Transform each test module to expose a `testCases` function and convert `expectSuite` to use bulk checking.

#### Pattern for each module:

**Before** (e.g., `LiteralTests.elm`):
```elm
module Compiler.LiteralTests exposing (expectSuite)

expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Literal expressions " ++ condStr)
        [ intLiteralTests expectFn condStr
        , floatLiteralTests expectFn condStr
        ]

intLiteralTests expectFn condStr =
    Test.describe ("Int literals " ++ condStr)
        [ Test.test ("Zero " ++ condStr) (zeroInt expectFn)
        , Test.test ("Positive " ++ condStr) (positiveInt expectFn)
        ]

zeroInt : (Src.Module -> Expectation) -> (() -> Expectation)
zeroInt expectFn _ =
    expectFn (makeModule "x" (intExpr 0))
```

**After**:
```elm
module Compiler.LiteralTests exposing (expectSuite, testCases)

import Compiler.BulkCheck exposing (TestCase, bulkCheck)

expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Literal expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ intLiteralCases expectFn
        , floatLiteralCases expectFn
        ]


intLiteralCases : (Src.Module -> Expectation) -> List TestCase
intLiteralCases expectFn =
    [ { label = "Zero int", run = zeroInt expectFn }
    , { label = "Positive int", run = positiveInt expectFn }
    ]


zeroInt : (Src.Module -> Expectation) -> (() -> Expectation)
zeroInt expectFn _ =
    expectFn (makeModule "x" (intExpr 0))
```

### Step 3: Files to modify

| # | File | Test Cases (approx) |
|---|------|---------------------|
| 1 | `BulkCheck.elm` (new) | - |
| 2 | `LiteralTests.elm` | ~35 |
| 3 | `TupleTests.elm` | ~24 |
| 4 | `RecordTests.elm` | ~45 |
| 5 | `ListTests.elm` | ~35 |
| 6 | `FunctionTests.elm` | ~60 |
| 7 | `LetTests.elm` | ~35 |
| 8 | `LetRecTests.elm` | ~25 |
| 9 | `LetDestructTests.elm` | ~35 |
| 10 | `CaseTests.elm` | ~50 |
| 11 | `BinopTests.elm` | ~55 |
| 12 | `OperatorTests.elm` | ~20 |
| 13 | `HigherOrderTests.elm` | ~45 |
| 14 | `AsPatternTests.elm` | ~30 |
| 15 | `EdgeCaseTests.elm` | ~30 |
| 16 | `PatternArgTests.elm` | ~45 |
| 17 | `AnnotatedTests.elm` | ~25 |
| 18 | `ArrayTest.elm` | ~15 |
| 19 | `BitwiseTests.elm` | ~20 |
| 20 | `ClosureTests.elm` | ~30 |
| 21 | `ControlFlowTests.elm` | ~25 |
| 22 | `DecisionTreeAdvancedTests.elm` | ~20 |
| 23 | `FloatMathTests.elm` | ~15 |
| 24 | `ForeignTests.elm` | ~10 |
| 25 | `KernelTests.elm` | ~20 |
| 26 | `MultiDefTests.elm` | ~20 |
| 27 | `PatternMatchingTests.elm` | ~35 |
| 28 | `PortEncodingTests.elm` | ~15 |
| 29 | `SpecializeAccessorTests.elm` | ~15 |
| 30 | `SpecializeConstructorTests.elm` | ~15 |
| 31 | `SpecializeCycleTests.elm` | ~10 |
| 32 | `SpecializeExprTests.elm` | ~15 |
| 33 | `TypeCheckFails.elm` | ~12 |
| 34 | `StandardTestSuites.elm` | (aggregator, no changes needed) |

**Not modified**:
- `DeepFuzzTests.elm` - Keep as-is with real `Test.fuzz` calls (randomness is the point)

### Step 4: Update StandardTestSuites.elm

No changes needed if each module's `expectSuite` now returns a single bulk `Test.test`. The structure remains:

```elm
expectSuite expectFn condStr =
    Test.describe condStr
        [ LiteralTests.expectSuite expectFn condStr      -- 1 bulk test
        , TupleTests.expectSuite expectFn condStr        -- 1 bulk test
        , ...
        ]
```

## Transformation Template

For each test module, apply this transformation:

### 1. Add import
```elm
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
```

### 2. Update module exports
```elm
module Compiler.XxxTests exposing (expectSuite, testCases)
```

### 3. Convert expectSuite
```elm
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Xxx expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)
```

### 4. Create testCases aggregator
```elm
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ section1Cases expectFn
        , section2Cases expectFn
        , ...
        ]
```

### 5. Convert each Test.describe section to a cases function
```elm
-- Before
section1Tests expectFn condStr =
    Test.describe ("Section 1 " ++ condStr)
        [ Test.test ("Test A " ++ condStr) (testA expectFn)
        , Test.test ("Test B " ++ condStr) (testB expectFn)
        ]

-- After
section1Cases : (Src.Module -> Expectation) -> List TestCase
section1Cases expectFn =
    [ { label = "Test A", run = testA expectFn }
    , { label = "Test B", run = testB expectFn }
    ]
```

## Expected Impact

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Test nodes per invariant | ~700 | ~30 | 96% |
| Total test nodes | ~40,000 | ~1,710 | 96% |
| Reporter records | ~40,000 | ~1,710 | 96% |
| Path strings | ~40,000 | ~1,710 | 96% |
| Labels/metadata | ~40,000 | ~1,710 | 96% |

## Verification

After implementation:
1. Run `npm test` - all tests should pass
2. Intentionally break one test case - verify the label appears in failure message
3. Check memory usage before/after if possible
