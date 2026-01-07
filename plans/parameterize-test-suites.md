# Plan: Parameterize Test Suites with Expectation Function

## Goal

Transform all test files in `tests/Compiler/*.elm` to pull `expectUniqueIds` up to the top-level `suite` function, making the entire test suite parameterizable by the expectation function and condition string.

## Current Structure

```elm
suite : Test
suite =
    Test.describe "Literal expressions"
        [ intLiteralTests
        , floatLiteralTests
        ]

intLiteralTests : Test
intLiteralTests =
    Test.describe "Int literals"
        [ Test.fuzz Fuzz.int "Random int has unique IDs" (randomInt expectUniqueIds)
        , Test.test "Zero has unique IDs" (zeroInt expectUniqueIds)
        ]
```

## Target Structure

```elm
suite : Test
suite =
    expectSuite expectUniqueIds "has unique IDs"

expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Literal expressions " ++ condStr)
        [ intLiteralTests expectFn condStr
        , floatLiteralTests expectFn condStr
        ]

intLiteralTests : (Src.Module -> Expectation) -> String -> Test
intLiteralTests expectFn condStr =
    Test.describe ("Int literals " ++ condStr)
        [ Test.fuzz Fuzz.int ("Random int " ++ condStr) (randomInt expectFn)
        , Test.test ("Zero " ++ condStr) (zeroInt expectFn)
        ]
```

## Benefits

1. **Reusability**: The entire suite can be run with different expectation functions
2. **Flexibility**: Can easily add new expectation checks (e.g., `expectPreservesValues`, `expectCorrectTypes`)
3. **Composability**: Suites can be combined with different condition strings for clarity

## Transformation Steps

For each test file in `tests/Compiler/*.elm`:

### Step 1: Add `expectSuite` function
- Create new function `expectSuite : (Src.Module -> Expectation) -> String -> Test`
- Move the `Test.describe` from `suite` into `expectSuite`
- Append `condStr` to the top-level describe string (with space before)

### Step 2: Update `suite` function
- Change `suite` to call `expectSuite expectUniqueIds "has unique IDs"`

### Step 3: Update each sub-test group function
For each nested test group (e.g., `intLiteralTests`, `floatLiteralTests`):
- Change signature from `functionName : Test` to `functionName : (Src.Module -> Expectation) -> String -> Test`
- Add parameters `expectFn condStr`
- Append `condStr` to the `Test.describe` string (with space before)
- For each `Test.test` or `Test.fuzz*` call:
  - Replace the test description from `"Description has unique IDs"` to `("Description " ++ condStr)`
  - Replace `(testCase expectUniqueIds)` with `(testCase expectFn)`

### Step 4: Update `expectSuite` calls to sub-groups
- Change each sub-group call from `intLiteralTests` to `intLiteralTests expectFn condStr`

### Step 5: Export `expectSuite`
- Add `expectSuite` to the module's export list

## Files to Transform (17 files)

1. `LiteralTests.elm`
2. `TupleTests.elm`
3. `ListTests.elm`
4. `RecordTests.elm`
5. `FunctionTests.elm`
6. `LetTests.elm`
7. `LetRecTests.elm`
8. `LetDestructTests.elm`
9. `CaseTests.elm`
10. `BinopTests.elm` (partially done - needs completion)
11. `OperatorTests.elm`
12. `AsPatternTests.elm`
13. `PatternArgTests.elm`
14. `EdgeCaseTests.elm`
15. `HigherOrderTests.elm`
16. `MultiDefTests.elm`
17. `KernelTests.elm` (uses `Can.Module` and `expectUniqueIdsCanonical`)

## Special Cases

### KernelTests.elm
- Uses `Can.Module` instead of `Src.Module`
- Uses `expectUniqueIdsCanonical` instead of `expectUniqueIds`
- Type signature: `expectSuite : (Can.Module -> Expectation) -> String -> Test`

### Fuzz Tests
- Fuzz test descriptions follow the same pattern:
  ```elm
  -- Before:
  Test.fuzz Fuzz.int "Random int has unique IDs" (randomInt expectUniqueIds)

  -- After:
  Test.fuzz Fuzz.int ("Random int " ++ condStr) (randomInt expectFn)
  ```

### Test Description Pattern
- Current: `"Description has unique IDs"`
- New: `("Description " ++ condStr)`
- The condition string includes the verb, e.g., `"has unique IDs"`

## Example Complete Transformation

### Before (LiteralTests.elm excerpt):
```elm
suite : Test
suite =
    Test.describe "Literal expressions"
        [ intLiteralTests
        , floatLiteralTests
        ]

intLiteralTests : Test
intLiteralTests =
    Test.describe "Int literals"
        [ Test.fuzz Fuzz.int "Random int has unique IDs" (randomInt expectUniqueIds)
        , Test.test "Zero has unique IDs" (zeroInt expectUniqueIds)
        ]
```

### After:
```elm
suite : Test
suite =
    expectSuite expectUniqueIds "has unique IDs"

expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Literal expressions " ++ condStr)
        [ intLiteralTests expectFn condStr
        , floatLiteralTests expectFn condStr
        ]

intLiteralTests : (Src.Module -> Expectation) -> String -> Test
intLiteralTests expectFn condStr =
    Test.describe ("Int literals " ++ condStr)
        [ Test.fuzz Fuzz.int ("Random int " ++ condStr) (randomInt expectFn)
        , Test.test ("Zero " ++ condStr) (zeroInt expectFn)
        ]
```

## Validation

After transformation, the tests should:
1. Compile without errors
2. Pass all existing tests (behavior unchanged)
3. Allow calling `expectSuite` with different expectation functions
