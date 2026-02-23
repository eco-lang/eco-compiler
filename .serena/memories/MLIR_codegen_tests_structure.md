# MLIR Codegen Test Structure - Eco Compiler

## Overview
The Elm compiler (Eco) has a comprehensive test infrastructure for validating MLIR code generation. Tests follow a consistent pattern across the codebase.

## Test Directory Structure

```
compiler/tests/
├── TestLogic/Generate/CodeGen/          # MLIR codegen invariant tests (45 test modules)
│   ├── GenerateMLIRTest.elm             # Main MLIR generation test (runs all standard suites)
│   ├── [Invariant]Test.elm              # Test runner files (pair with logic files)
│   ├── [Invariant].elm                  # Test logic/checking code
│   └── Invariants.elm                   # Shared MLIR inspection utilities
│
├── SourceIR/                            # Source IR test cases (imported by MLIR tests)
│   ├── Suite/StandardTestSuites.elm     # Aggregates all test case modules
│   ├── LetCases.elm                     # Let expression tests
│   ├── LetRecCases.elm                  # Recursive let binding tests
│   ├── ClosureCases.elm                 # Closure handling tests
│   └── [...many other case modules]
│
└── [Other directories: Parse, Type, Compiler, Common]
```

## Test Execution Pattern

Tests use `elm-test-rs` test runner:
```bash
npm test              # Run with fuzz=10
npx elm-test-rs --fuzz 1
```

## MLIR Codegen Test Structure

### 1. **Test Modules Pattern**
Each invariant has TWO modules:
- `TestLogic/Generate/CodeGen/[Invariant]Test.elm` - Test runner/aggregator
- `TestLogic/Generate/CodeGen/[Invariant].elm` - Test logic & checking code

**Example: List Construction**
- `/work/compiler/tests/TestLogic/Generate/CodeGen/ListConstructionTest.elm` (runner)
- `/work/compiler/tests/TestLogic/Generate/CodeGen/ListConstruction.elm` (logic)

### 2. **Test Runner Pattern** (the `*Test.elm` file)
```elm
module TestLogic.Generate.CodeGen.ListConstructionTest exposing (suite)

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ListConstruction exposing (expectListConstruction)

suite : Test
suite =
    Test.describe "CGEN_016: List Construction"
        [ StandardTestSuites.expectSuite expectListConstruction "passes list construction invariant"
        ]
```

Key points:
- Very thin wrapper that describes the test
- References a `StandardTestSuites.expectSuite` function
- Names test with invariant code (CGEN_016, CGEN_009, etc.)
- Imports the expectation function from the logic module

### 3. **Test Logic Pattern** (the non-`*Test.elm` file)
```elm
module TestLogic.Generate.CodeGen.ListConstruction exposing (expectListConstruction, checkListConstruction)

{-| Test logic for CGEN_016: List Construction invariant.
List values must use `eco.construct.list` for cons cells...
-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.TestPipeline exposing (runToMlir)
import TestLogic.Generate.CodeGen.Invariants
    exposing (Violation, findOpsNamed, getStringAttr, violationsToExpectation)

expectListConstruction : Src.Module -> Expectation
expectListConstruction srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)
        Ok { mlirModule } ->
            violationsToExpectation (checkListConstruction mlirModule)

checkListConstruction : MlirModule -> List Violation
checkListConstruction mlirModule =
    let
        customOps = findOpsNamed "eco.construct.custom" mlirModule
        listConstructorViolations = List.filterMap checkForListConstructorMisuse customOps
    in
    listConstructorViolations
```

Key points:
- Main function: `expectXxx : Src.Module -> Expectation`
- Secondary function: `checkXxx : MlirModule -> List Violation`
- Uses `runToMlir` from TestPipeline to compile source through all stages
- Uses `violationsToExpectation` to convert violation list to Expectation
- Uses helpers from `Invariants.elm` module (findOpsNamed, getStringAttr, etc.)

### 4. **Test Case Aggregation**
All source IR test cases come from `SourceIR.Suite.StandardTestSuites`:
```elm
-- StandardTestSuites.expectSuite feeds test cases through an expectation function
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ AnnotatedCases.expectSuite expectFn condStr
        , ArrayCases.expectSuite expectFn condStr
        , BinopCases.expectSuite expectFn condStr
        ...
        , LetRecCases.expectSuite expectFn condStr
        , LetCases.expectSuite expectFn condStr
        , ClosureCases.expectSuite expectFn condStr
        ...
        ]
```

Each case module (LetCases, LetRecCases, ClosureCases, etc.) exports:
- `expectSuite : (Src.Module -> Expectation) -> String -> Test`
- `testCases : (Src.Module -> Expectation) -> List TestCase`

The test case modules define multiple test cases (usually organized into logical groups).

### 5. **Test Pipeline**
From `TestLogic/TestPipeline.elm`:

```
Source Code
    ↓ runToCanonical
Canonical AST
    ↓ runToTypeCheck
Type Checking (annotations + nodeTypes)
    ↓ runToPostSolve
PostSolve (nodeTypesPost + kernelEnv)
    ↓ runToTypedOpt
TypedOptimized (LocalGraph)
    ↓ runToMono
Monomorphized (MonoGraph)
    ↓ runToGlobalOpt
GlobalOptimized (MonoGraph)
    ↓ runToMlir
MLIR Module + Output String
```

Key helper functions:
- `runToMlir` - Full pipeline to MLIR
- `runMLIRGeneration` - MLIR text generation
- `verifyMLIROutput` - Checks output is not empty and contains expected operations

### 6. **Violation Tracking & Reporting**
From `TestLogic/Generate/CodeGen/Invariants.elm`:

```elm
type alias Violation =
    { opId : String
    , opName : String
    , message : String
    }

violationsToExpectation : List Violation -> Expectation
-- Empty list → Expect.pass
-- Non-empty → Expect.fail with formatted violations
```

### 7. **MLIR Inspection Utilities** (Invariants.elm)
All tests use shared utilities:

**Op Walking:**
- `walkAllOps : MlirModule -> List MlirOp` - All ops including nested
- `walkOpAndChildren : MlirOp -> List MlirOp` - Op + nested ops
- `walkOpsInRegion : MlirRegion -> List MlirOp` - Ops in a region
- `walkOpsInBlock : MlirBlock -> List MlirOp` - Ops in a block

**Op Finding:**
- `findOpsNamed : String -> MlirModule -> List MlirOp`
- `findOpsWithPrefix : String -> MlirModule -> List MlirOp`
- `findFuncOps : MlirModule -> List MlirOp`

**Attribute Extraction:**
- `getIntAttr : String -> MlirOp -> Maybe Int`
- `getStringAttr : String -> MlirOp -> Maybe String`
- `getArrayAttr : String -> MlirOp -> Maybe (List MlirAttr)`
- `getTypeAttr : String -> MlirOp -> Maybe MlirType`
- `getBoolAttr : String -> MlirOp -> Maybe Bool`

**Type Extraction:**
- `extractOperandTypes : MlirOp -> Maybe (List MlirType)`
- `extractResultTypes : MlirOp -> Maybe (List MlirType)`

**Type Predicates:**
- `isEcoValueType : MlirType -> Bool`
- `ecoValueType : String` - Returns "!eco.value"
- `isUnboxable : MlirType -> Bool`

## Example: BooleanConstants Invariant

**Test File Structure:**
- Test logic: `/work/compiler/tests/TestLogic/Generate/CodeGen/BooleanConstants.elm`
  - Checks Bool constants produce `!eco.value`, not `i1`
  - Checks i1 only appears in valid contexts (case scrutinee with `case_kind="bool"`)
  - Checks i1 never in `eco.construct.*` operands or closure capture
  
- Test runner: `/work/compiler/tests/TestLogic/Generate/CodeGen/BooleanConstantsTest.elm`
  - Single `suite` that runs StandardTestSuites with `expectBooleanConstants`

## Where to Add Let-Rec Codegen Tests

### Option 1: Add to Existing `LetRecCases.elm`
The module already exists at `/work/compiler/tests/SourceIR/LetRecCases.elm` and contains:
- 4 self-recursive function cases
- 2 mutually recursive cases
- 3 recursive pattern cases (tuple, cons, alias)
- 1 complex recursive case

These automatically flow through all CodeGen tests via `StandardTestSuites.expectSuite`.

### Option 2: Create New MLIR-Specific Let-Rec Tests
For codegen-specific let-rec invariants:

1. Create `/work/compiler/tests/TestLogic/Generate/CodeGen/LetRecInvariants.elm`
   - Define `expectLetRecInvariants : Src.Module -> Expectation`
   - Use `runToMlir` to compile
   - Use `Invariants` utilities to check MLIR structure
   - Check tail-recursion compilation, closure capture, etc.

2. Create `/work/compiler/tests/TestLogic/Generate/CodeGen/LetRecInvariantsTest.elm`
   - Single `suite` that runs StandardTestSuites with expectation function
   - Reference existing LetRecCases or create specialized ones

## Key Imports for New Tests

```elm
-- Pipeline execution
import TestLogic.TestPipeline exposing (runToMlir)

-- Type building (if needed)
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (...)

-- Expectations
import Expect exposing (Expectation)

-- MLIR inspection
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType)
import TestLogic.Generate.CodeGen.Invariants exposing (...)

-- Test framework
import Test exposing (Test)
```

## Test Statistics
- Total CodeGen test modules: 45 (combining logic + runner pairs)
- Total SourceIR test case modules: ~30+ covering different language constructs
- All tests aggregate through `StandardTestSuites.expectSuite`
- Tests run with fuzz testing enabled (randomized test case generation)

## Running Tests
```bash
cd /work/compiler
npm test                          # Run all tests
npx elm-test-rs --fuzz 1          # Run with low fuzz count
TEST_FILTER=codegen cmake --build build --target check  # E2E codegen tests
```

## Design Philosophy
1. **Separation of Concerns**: Test logic separate from runners
2. **Reusability**: One expectation function runs against all test cases
3. **Shared Infrastructure**: Central `Invariants.elm` for MLIR inspection
4. **Incremental Coverage**: New test cases automatically included in all runner suites
5. **Invariant-Based**: Each test verifies one specific MLIR codegen invariant
