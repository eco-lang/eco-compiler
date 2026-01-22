# Fix Test String Accumulation Pattern

## Problem

Multiple test files accumulate failure messages as `List String` and join them at the end with `String.join "\n"`. This pattern causes high memory usage (up to 2GB+) because Elm keeps all intermediate strings in memory.

## Solution

Convert tests to use `Expect.all` with lazy expectations `List (() -> Expect.Expectation)` instead of accumulating strings. This defers string creation until needed and leverages the test framework's built-in failure collection.

## Files to Fix

### High Priority (Shared Infrastructure)
1. **`tests/Compiler/Generate/CodeGen/Invariants.elm`** - `violationsToExpectation` function
   - Used by ~30+ CodeGen tests
   - Single fix benefits many tests

### Individual Test Files
2. **`tests/Compiler/Generate/MonoGraphIntegrity.elm`** - 4 functions
3. **`tests/Compiler/Generate/MonoLayoutIntegrity.elm`** - 4 functions
4. **`tests/Compiler/Generate/MonoNumericResolution.elm`** - 2 functions
5. **`tests/Compiler/Optimize/DeciderExhaustive.elm`** - 2 functions
6. **`tests/Compiler/Type/PostSolve/GroupBTypes.elm`** - 1 function

## Implementation Pattern

### Before (problematic):
```elm
expectSomething : Src.Module -> Expect.Expectation
expectSomething srcModule =
    case compile srcModule of
        Err msg -> Expect.fail msg
        Ok result ->
            let
                issues = collectIssues result  -- List String
            in
            if List.isEmpty issues then
                Expect.pass
            else
                Expect.fail (String.join "\n" issues)

collectIssues : Data -> List String
collectIssues data =
    -- accumulates strings
```

### After (fixed):
```elm
expectSomething : Src.Module -> Expect.Expectation
expectSomething srcModule =
    case compile srcModule of
        Err msg -> Expect.fail msg
        Ok result ->
            let
                checks = collectChecks result  -- List (() -> Expect.Expectation)
            in
            case checks of
                [] -> Expect.pass
                _ -> Expect.all checks ()

collectChecks : Data -> List (() -> Expect.Expectation)
collectChecks data =
    -- returns lazy expectations
```

## Implementation Order

1. Fix `Invariants.elm` first (highest impact)
2. Fix `MonoGraphIntegrity.elm`
3. Fix `MonoLayoutIntegrity.elm`
4. Fix `MonoNumericResolution.elm`
5. Fix `DeciderExhaustive.elm`
6. Fix `GroupBTypes.elm`

## Verification

After each fix, run the specific test to verify:
1. Test still passes
2. Memory usage is reduced (check with `/usr/bin/time -v`)
