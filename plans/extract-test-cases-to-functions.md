# Plan: Extract Test Cases to Top-Level Functions

## Goal

Transform all tests in `/work/compiler/tests/Compiler/*.elm` (excluding AST builders and subdirectories) so that each test case is extracted into a reusable top-level function that takes an expectation function as a parameter.

## Current Structure

```elm
Test.test "Alias on variable has unique IDs" <|
    \_ ->
        let
            modul =
                makeModuleWithDefs
                    [ ( "dup", [ pAlias (pVar "x") "y" ], tupleExpr (varExpr "x") (varExpr "y") )
                    ]
        in
        expectUniqueIds modul
```

## Target Structure

```elm
Test.test "Alias on variable has unique IDs" (aliasOnVariable expectUniqueIds)

-- Top-level function
aliasOnVariable : (Can.Module -> Expectation) -> (() -> Expectation)
aliasOnVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs
                [ ( "dup", [ pAlias (pVar "x") "y" ], tupleExpr (varExpr "x") (varExpr "y") )
                ]
    in
    expectFn modul
```

## Files to Transform

1. `LiteralTests.elm` - ~40 tests (int, float, string, char, unit, bool literals)
2. `TupleTests.elm` - tuple expression tests
3. `ListTests.elm` - list expression tests
4. `RecordTests.elm` - record expression tests
5. `FunctionTests.elm` - function expression tests
6. `LetTests.elm` - let expression tests
7. `LetRecTests.elm` - recursive let tests
8. `LetDestructTests.elm` - let destructuring tests
9. `CaseTests.elm` - case expression tests
10. `BinopTests.elm` - binary operator tests
11. `OperatorTests.elm` - operator section tests
12. `AsPatternTests.elm` - as-pattern tests
13. `PatternArgTests.elm` - pattern argument tests
14. `EdgeCaseTests.elm` - edge case tests
15. `HigherOrderTests.elm` - higher-order function tests
16. `MultiDefTests.elm` - multiple definition tests
17. `KernelTests.elm` - kernel function tests

**Exclude:**
- `Compiler/AST/SourceBuilder.elm` - builder utilities, not tests
- `Compiler/AST/CanonicalBuilder.elm` - builder utilities, not tests
- `Compiler/Canonicalize/IdAssignment.elm` - test infrastructure
- `Compiler/Type/Constrain/TypedErasedCheckingParity.elm` - different test structure
- `Compiler/Elm/Interface/Basic.elm` - different test structure

## Transformation Rules

### Rule 1: Simple Test Cases (Test.test)

**Before:**
```elm
Test.test "Test name" <|
    \_ ->
        let
            modul = ...
        in
        expectUniqueIds modul
```

**After:**
```elm
Test.test "Test name" (testNameFunction expectUniqueIds)

testNameFunction : (Can.Module -> Expectation) -> (() -> Expectation)
testNameFunction expectFn _ =
    let
        modul = ...
    in
    expectFn modul
```

### Rule 2: Fuzz Tests (Test.fuzz, Test.fuzz2, Test.fuzz3)

**Before:**
```elm
Test.fuzz Fuzz.int "Random int has unique IDs" <|
    \n ->
        let
            modul = makeModule "testValue" (intExpr n)
        in
        expectUniqueIds modul
```

**After:**
```elm
Test.fuzz Fuzz.int "Random int has unique IDs" (randomInt expectUniqueIds)

randomInt : (Can.Module -> Expectation) -> (Int -> Expectation)
randomInt expectFn n =
    let
        modul = makeModule "testValue" (intExpr n)
    in
    expectFn modul
```

### Rule 3: Multi-Module Tests (using Expect.all)

**Before:**
```elm
Test.test "Multiple modules" <|
    \_ ->
        let
            modul1 = ...
            modul2 = ...
        in
        Expect.all
            [ \_ -> expectUniqueIds modul1
            , \_ -> expectUniqueIds modul2
            ]
            ()
```

**After:**
```elm
Test.test "Multiple modules" (multipleModules expectUniqueIds)

multipleModules : (Can.Module -> Expectation) -> (() -> Expectation)
multipleModules expectFn _ =
    let
        modul1 = ...
        modul2 = ...
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()
```

### Rule 4: Function Naming Convention

Convert test description to camelCase function name:
- "Alias on variable has unique IDs" → `aliasOnVariable`
- "Let with single int binding has unique IDs" → `letWithSingleIntBinding`
- "Random int has unique IDs" → `randomInt`

Rules:
1. Remove "has unique IDs" suffix (common pattern)
2. Remove "type check equivalently" suffix if present
3. Convert to camelCase
4. Keep descriptive but concise
5. Prefix with category if needed for uniqueness within file

## File Organization

Each test file will have this structure:

```elm
module Compiler.XxxTests exposing (suite, {- all test case functions -})

-- Imports...

suite : Test
suite =
    Test.describe "Xxx expressions"
        [ group1Tests
        , group2Tests
        -- ...
        ]

-- ============================================================================
-- GROUP 1 (N tests)
-- ============================================================================

group1Tests : Test
group1Tests =
    Test.describe "Group 1"
        [ Test.test "Description 1" (testCase1 expectUniqueIds)
        , Test.test "Description 2" (testCase2 expectUniqueIds)
        -- ...
        ]

-- Test case functions for Group 1

testCase1 : (Can.Module -> Expectation) -> (() -> Expectation)
testCase1 expectFn _ =
    let
        modul = ...
    in
    expectFn modul

testCase2 : (Can.Module -> Expectation) -> (() -> Expectation)
testCase2 expectFn _ =
    let
        modul = ...
    in
    expectFn modul

-- ============================================================================
-- GROUP 2 (N tests)
-- ============================================================================

-- ... similar pattern
```

## Implementation Steps

1. **For each test file:**
   a. Read the file and identify all test cases
   b. For each test case:
      - Extract the module-building logic
      - Create a top-level function with appropriate signature
      - Generate a camelCase name from the test description
   c. Update the Test.test/Test.fuzz calls to use the new functions
   d. Add necessary imports (Can.Module, Expectation if not present)
   e. Update module exports to include all test case functions

2. **Order of files to transform:**
   - Start with simpler files (LiteralTests.elm) for pattern validation
   - Progress to more complex files (LetTests.elm, CaseTests.elm)
   - Finish with edge cases (EdgeCaseTests.elm, HigherOrderTests.elm)

3. **Verification after each file:**
   - Run `npx elm-test-rs tests/Compiler/XxxTests.elm` to ensure tests pass
   - Verify the module compiles without errors

## Type Signatures

The extracted functions will have these type signatures depending on the test type:

```elm
-- Simple test
testName : (Can.Module -> Expectation) -> (() -> Expectation)

-- Fuzz test with one fuzzer
testName : (Can.Module -> Expectation) -> (a -> Expectation)

-- Fuzz2 test
testName : (Can.Module -> Expectation) -> (a -> b -> Expectation)

-- Fuzz3 test
testName : (Can.Module -> Expectation) -> (a -> b -> c -> Expectation)
```

## Benefits of This Transformation

1. **Reusability**: Test cases can be run with different expectation functions
2. **Composability**: Test cases can be combined or filtered programmatically
3. **Documentation**: Top-level functions serve as documented test scenarios
4. **Testing different properties**: Same test case can verify unique IDs, type checking, etc.

## Estimated Scope

- ~17 test files
- ~300-400 individual test cases
- Each file transformation: 15-30 minutes
- Total estimated time: 4-8 hours of implementation

## Risks and Mitigations

1. **Name collisions**: Use category prefixes if function names conflict within a file
2. **Complex multi-module tests**: May need special handling for Expect.all patterns
3. **Type annotation complexity**: For fuzz tests, type annotations may need explicit type variables
