# Source IR Roundtrip Validation for Tests

## Problem Statement

Tests that construct Source IR directly via `SourceBuilder.elm` can create syntactically invalid AST nodes that the Elm parser would reject. For example, `lambdaExpr []` creates a zero-argument lambda, which:

1. The **parser** rejects (requires at least one argument after `\`)
2. The **type checker** accepts (treats it as the body's type with no function wrapper)
3. The **monomorphizer** crashes on (`specializeLambda` expects non-zero params)

This creates false test failures that are actually test bugs, not compiler bugs.

## Proposed Solution

Add a validation step to all test pipelines that start from `Src.Module`:

1. Pretty-print the `Src.Module` to an Elm source string
2. Parse the string back to `Src.Module`
3. If parsing fails, fail the test with a clear error indicating invalid Source IR
4. If parsing succeeds, continue with the original test logic

## Implementation Steps

### Step 1: Create Roundtrip Validation Helper

Create a new module `tests/Compiler/Validation/SourceRoundtrip.elm`:

```elm
module Compiler.Validation.SourceRoundtrip exposing (validateSourceModule)

import Compiler.AST.Source as Src
import Common.Format.Render as Render
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)

{-| Validate that a Source module can be pretty-printed and re-parsed.
Returns Ok with the original module if valid, or Err with parse error details.
-}
validateSourceModule : Src.Module -> Result String Src.Module
validateSourceModule srcModule =
    let
        prettyPrinted : String
        prettyPrinted =
            Render.moduleToString srcModule
    in
    case Parse.fromSource "Test.elm" prettyPrinted of
        Ok _ ->
            Ok srcModule

        Err parseError ->
            Err ("Source IR roundtrip failed. Pretty-printed:\n"
                ++ prettyPrinted
                ++ "\n\nParse error: "
                ++ errorToString parseError)
```

### Step 2: Modify StandardTestSuites.expectSuite

Update `tests/Compiler/StandardTestSuites.elm` to wrap the expectation function:

```elm
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    let
        validatedExpectFn : Src.Module -> Expectation
        validatedExpectFn srcModule =
            case SourceRoundtrip.validateSourceModule srcModule of
                Ok validModule ->
                    expectFn validModule

                Err errorMsg ->
                    Expect.fail ("Invalid Source IR in test case: " ++ errorMsg)
    in
    Test.describe condStr
        [ AnnotatedTests.expectSuite validatedExpectFn condStr
        , ...
        ]
```

### Step 3: Modify PackageCompilation Pipeline

Update `tests/Compiler/PackageCompilation.elm` to validate before processing:

```elm
compileModule : Src.Module -> ... -> Result CompileError ...
compileModule srcModule ... =
    case SourceRoundtrip.validateSourceModule srcModule of
        Err msg ->
            Err (InvalidSourceIR msg)

        Ok validModule ->
            -- existing pipeline logic
            ...
```

Add new error variant:
```elm
type CompileError
    = InvalidSourceIR String
    | ParseError Syntax.Error
    | ...
```

### Step 4: Fix Existing Invalid Test Cases

After implementing validation, run tests to identify all invalid Source IR constructions. Known issues to fix:

| File | Issue | Fix |
|------|-------|-----|
| `FunctionTests.elm:127` | `lambdaExpr []` (zero-arg lambda) | **Already removed** |
| TBD | TBD | TBD |

### Step 5: Add SourceBuilder Guards (Optional)

Consider adding runtime checks to `SourceBuilder.elm` functions:

```elm
lambdaExpr : List Src.Pattern -> Src.Expr -> Src.Expr
lambdaExpr args body =
    if List.isEmpty args then
        Debug.todo "lambdaExpr requires at least one argument"
    else
        A.At A.zero (Src.Lambda (c1 (List.map c1 args)) (c1 body))
```

This catches invalid construction at the source rather than at validation time.

## Files to Modify

1. **Create**: `tests/Compiler/Validation/SourceRoundtrip.elm`
2. **Modify**: `tests/Compiler/StandardTestSuites.elm`
3. **Modify**: `tests/Compiler/PackageCompilation.elm`
4. **Modify**: `tests/Compiler/TypeCheckFails.elm` (also uses expectSuite pattern)
5. **Optional**: `tests/Compiler/AST/SourceBuilder.elm`

## Dependencies

- `Common.Format.Render` - must support rendering `Src.Module` to string
- `Compiler.Parse.Module` - must expose parsing from string

## Testing the Implementation

After implementing:

1. Run `cd compiler && npx elm-test-rs --fuzz 1`
2. Any test failures with "Invalid Source IR" indicate test cases to fix
3. After fixing all invalid test cases, all tests should pass or fail for legitimate reasons

## Benefits

1. **Catches test bugs early**: Invalid Source IR fails immediately with clear message
2. **Documents valid syntax**: Tests become implicit documentation of valid Elm syntax
3. **Prevents false failures**: No more crashes in later phases due to invalid AST
4. **Easier debugging**: Clear error message points to the problem

## Risks

1. **Pretty-printer fidelity**: If `Render.moduleToString` doesn't preserve all AST details, roundtrip may fail on valid modules
2. **Performance**: Extra pretty-print + parse step adds overhead (mitigated by only running in tests)
3. **Circular dependency**: Need to ensure no import cycles between validation and test modules
