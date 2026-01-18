# Implementation Plan: Additional MLIR Codegen Invariant Tests

This plan implements the MLIR invariant checks described in `design_docs/more-mlir-checks.md`.

## Overview

The design document describes 5 test plans targeting runtime error categories B (SSA type inconsistency), D (record update wrong), and E (segfaults from boxing/unboxing mistakes):

| Plan | Target | Status |
|------|--------|--------|
| B1 | Global SSA Type Consistency | **NEW** - needs implementation |
| B2/E1 | `_operand_types` matches SSA types | **EXISTING** - covered by `OperandTypeConsistencyTest.elm` |
| D1 | Record Update Dataflow Shape | **NEW** - needs implementation |
| E1 | Projection Container Types | **NEW** - needs implementation |
| E2 | eco.unbox Sanity | **NEW** - needs implementation |

Plan B2/E1 is already implemented in `compiler/tests/Compiler/Generate/CodeGen/OperandTypeConsistencyTest.elm`, which checks that `_operand_types` attributes match the actual SSA operand types within each function scope.

## New Test Modules

All tests will be added to `compiler/tests/Compiler/Generate/CodeGen/`.

---

## 1. SSA Type Consistency Test (Plan B1)

**File**: `SsaTypeConsistencyTest.elm`

**Invariant**: CGEN_0B1 - "SSA value has a single MLIR type within each function". An SSA name must never be assigned different types within the same function scope.

### Implementation Details

The test processes each `func.func` separately and:
1. Records the type of each SSA result `(name, type)` into a per-function `Dict String MlirType`
2. If the same SSA name is assigned a different type within the function, reports a violation

This catches the "use of value '%X' expects different type than prior uses" runtime error.

**Important**: SSA names like `%0` are reused across functions, so checking must be per-function, not module-wide.

### Algorithm

```
INPUT: MlirModule

FOR each funcOp IN findFuncOps(module):
    ssaType : Dict String MlirType = {}

    // Include function entry block args
    FOR each (argName, argTy) IN funcOp.regions[0].entry.args:
        ssaType[argName] = argTy

    FOR each op IN walkOpsInFunc(funcOp):
        FOR each (resultName, resultTy) IN op.results:
            IF resultName IN ssaType AND ssaType[resultName] != resultTy:
                REPORT "SSA retyped in {funcName}: {resultName} was {oldType}, now {resultTy}"
            ELSE:
                ssaType[resultName] = resultTy

        // Also record block args from nested regions
        FOR each region IN op.regions:
            FOR each block IN allBlocks(region):
                FOR each (argName, argTy) IN block.args:
                    IF argName IN ssaType AND ssaType[argName] != argTy:
                        REPORT "SSA retyped: {argName}"
                    ELSE:
                        ssaType[argName] = argTy
```

### Key Functions to Implement

```elm
module Compiler.Generate.CodeGen.SsaTypeConsistencyTest exposing (suite)

-- Uses existing from Invariants.elm:
-- - walkAllOps
-- - allBlocks
-- - Violation type
-- - violationsToExpectation

checkSsaTypeConsistency : MlirModule -> List Violation
checkSsaTypeConsistency mlirModule =
    -- Build SSA type environment, checking for conflicts
    ...

suite : Test
suite =
    Test.describe "CGEN_0B1: SSA Type Consistency"
        [ Test.test "SSA values have consistent types" basicTest
        , Test.test "function calls don't retype SSA names" callTest
        , Test.test "nested regions maintain type consistency" nestedTest
        ]
```

### Test Cases

1. Basic: Simple function with let bindings
2. Call test: Function calls that produce results
3. Nested test: Case expressions with nested regions

---

## 2. Record Update Dataflow Shape Test (Plan D1)

**File**: `RecordUpdateDataflowTest.elm`

**Invariant**: CGEN_0D1 - "Record update operands come from projections or explicit update values". Detects when a whole record is incorrectly stored as a field.

### Implementation Details

The bug symptom: `{ original | x = 10 }` yields a record where field `x` becomes the *original record* instead of `10`.

The test detects this by checking that `eco.construct.record` operands are NOT the same SSA name as the source record being updated (identified via `eco.project.record` ops).

### Algorithm

```
INPUT: MlirModule

FOR each funcOp IN findFuncOps(module):
    funcOps = collectOpsInFunc(funcOp)

    // Step 1: Collect projection info
    projectionsBySource : Dict String (Set String) = {}
    FOR each op IN funcOps WHERE op.name == "eco.project.record":
        sourceRecord = op.operands[0]
        projResult = op.results[0].name
        projectionsBySource[sourceRecord].add(projResult)

    // Step 2: Check each record construction
    FOR each op IN funcOps WHERE op.name == "eco.construct.record":
        // Find the "source record" - the record most projected from
        bestSource = findMostProjectedSource(op.operands, projectionsBySource)

        IF bestSource != Nothing:
            IF bestSource IN op.operands:
                REPORT "Record construction stores whole record {bestSource} as field"
```

### Key Functions to Implement

```elm
module Compiler.Generate.CodeGen.RecordUpdateDataflowTest exposing (suite)

type alias ProjInfo =
    { source : String
    , result : String
    }

collectProjections : List MlirOp -> Dict String (Set String)
-- Group eco.project.record ops by source record

findMostProjectedSource : List String -> Dict String (Set String) -> Maybe String
-- Find source record whose projections appear most often in operand list

checkRecordUpdateDataflow : MlirModule -> List Violation
checkRecordUpdateDataflow mlirModule =
    -- For each function, check record constructs don't have source as operand
    ...

suite : Test
suite =
    Test.describe "CGEN_0D1: Record Update Dataflow"
        [ Test.test "record update doesn't store whole record as field" recordUpdateTest
        , Test.test "multi-field record update is correct" multiFieldTest
        ]
```

### Test Cases

1. `let r = { x = 1, y = 2 } in { r | x = 10 }` - should NOT have `r` as operand
2. `let r = { a = 1, b = 2, c = 3 } in { r | a = 5, c = 7 }` - multi-field update
3. Fresh record construction `{ x = 1, y = 2 }` - should pass (no source record)

### Note on Heuristics

This check is intentionally heuristic - it can't catch all cases but specifically targets the observed bug pattern. False positives are unlikely since storing a whole record as a field is almost always wrong.

---

## 3. Projection Container Types Test (Plan E1)

**File**: `ProjectionContainerTypeTest.elm`

**Invariant**: CGEN_0E1 - "Values of primitive MLIR type never flow into `eco.project.*` container operands". All projection ops must have `!eco.value` as their container operand type.

### Implementation Details

This prevents segfaults from treating primitives as heap pointers. The dangerous pattern is `project -> eco.unbox -> project` where `eco.unbox` produces a primitive that is then incorrectly used as a container.

### Algorithm

```
INPUT: MlirModule

PROJECTION_OPS = [
    "eco.project.record",
    "eco.project.custom",
    "eco.project.tuple2",
    "eco.project.tuple3",
    "eco.project.list_head",
    "eco.project.list_tail"
]

typeEnv = buildTypeEnv(module)

FOR each op IN walkAllOps(module):
    IF op.name IN PROJECTION_OPS:
        IF length(op.operands) != 1:
            REPORT "Projection op should have exactly 1 operand"
            CONTINUE

        containerName = op.operands[0]
        containerType = typeEnv[containerName]

        IF containerType == Nothing:
            REPORT "Unknown container SSA: {containerName}"
        ELIF NOT isEcoValueType(containerType):
            REPORT "Projection container is not eco.value: {containerName} has type {containerType}"
```

### Key Functions to Implement

```elm
module Compiler.Generate.CodeGen.ProjectionContainerTypeTest exposing (suite)

projectionOpNames : List String
projectionOpNames =
    [ "eco.project.record"
    , "eco.project.custom"
    , "eco.project.tuple2"
    , "eco.project.tuple3"
    , "eco.project.list_head"
    , "eco.project.list_tail"
    ]

checkProjectionContainerTypes : MlirModule -> List Violation
checkProjectionContainerTypes mlirModule =
    let
        typeEnv = buildTypeEnv mlirModule
        allOps = walkAllOps mlirModule
        projectionOps = List.filter (\op -> List.member op.name projectionOpNames) allOps
    in
    List.filterMap (checkProjectionOp typeEnv) projectionOps

checkProjectionOp : TypeEnv -> MlirOp -> Maybe Violation
checkProjectionOp typeEnv op =
    -- Check that container operand is eco.value type
    ...

suite : Test
suite =
    Test.describe "CGEN_0E1: Projection Container Types"
        [ Test.test "record projection uses eco.value container" recordProjTest
        , Test.test "tuple projection uses eco.value container" tupleProjTest
        , Test.test "list projection uses eco.value container" listProjTest
        , Test.test "custom ADT projection uses eco.value container" customProjTest
        ]
```

### Test Cases

1. `record.field` - record projection
2. `Tuple.first (a, b)` - tuple projection
3. `case xs of x :: rest -> x` - list projection
4. `case maybe of Just x -> x` - custom ADT projection

---

## 4. Eco.Unbox Sanity Test (Plan E2)

**File**: `EcoUnboxSanityTest.elm`

**Invariant**: CGEN_0E2 - "eco.unbox result types are primitive; eco.unbox operand is eco.value". This validates every unboxing operation.

### Implementation Details

`eco.unbox` converts `!eco.value` (boxed) to a primitive type (i1, i16, i64, f64). This test verifies:
1. The operand is `!eco.value`
2. The result is a primitive type

### Algorithm

```
INPUT: MlirModule

typeEnv = buildTypeEnv(module)

FOR each op IN walkAllOps(module) WHERE op.name == "eco.unbox":
    // Check structure
    IF length(op.operands) != 1:
        REPORT "eco.unbox should have exactly 1 operand"
        CONTINUE
    IF length(op.results) != 1:
        REPORT "eco.unbox should have exactly 1 result"
        CONTINUE

    // Check operand type is eco.value
    operandName = op.operands[0]
    operandType = typeEnv[operandName]

    IF operandType == Nothing:
        REPORT "eco.unbox operand unknown: {operandName}"
    ELIF NOT isEcoValueType(operandType):
        REPORT "eco.unbox operand not eco.value, got {operandType}"

    // Check result type is primitive
    (resultName, resultType) = op.results[0]
    IF NOT isPrimitiveType(resultType):
        REPORT "eco.unbox result not primitive, got {resultType}"
```

### Key Functions to Implement

```elm
module Compiler.Generate.CodeGen.EcoUnboxSanityTest exposing (suite)

-- Note: isPrimitiveType in Invariants.elm currently excludes I32
-- Need to verify if I32 should be included for unbox results

checkEcoUnboxSanity : MlirModule -> List Violation
checkEcoUnboxSanity mlirModule =
    let
        typeEnv = buildTypeEnv mlirModule
        unboxOps = findOpsNamed "eco.unbox" mlirModule
    in
    List.filterMap (checkUnboxOp typeEnv) unboxOps

checkUnboxOp : TypeEnv -> MlirOp -> Maybe Violation
checkUnboxOp typeEnv op =
    -- Validate operand is eco.value and result is primitive
    ...

suite : Test
suite =
    Test.describe "CGEN_0E2: eco.unbox Sanity"
        [ Test.test "eco.unbox converts eco.value to i64" intUnboxTest
        , Test.test "eco.unbox converts eco.value to f64" floatUnboxTest
        , Test.test "eco.unbox converts eco.value to i1" boolUnboxTest
        , Test.test "eco.unbox converts eco.value to i16" charUnboxTest
        ]
```

### Test Cases

1. Integer arithmetic: `x + 1` where `x` is Int (unbox to i64)
2. Float arithmetic: `x * 2.0` where `x` is Float (unbox to f64)
3. Boolean conditions: `if b then ...` (unbox to i1)
4. Character operations: `Char.toCode c` (unbox to i16)

---

## Shared Infrastructure Updates

### Updates to Invariants.elm

The existing `Invariants.elm` already has most needed utilities. May need to add:

```elm
-- findOpsNamed is already present
-- May need to ensure isPrimitiveType includes I32 if needed for unbox

-- Potentially add if not present:
findOpsInFunc : MlirOp -> List MlirOp
findOpsInFunc funcOp =
    case funcOp.regions of
        [ MlirRegion r ] ->
            walkOpsInBlock r.entry
        _ ->
            []
```

### Updates to GenerateMLIR.elm

No changes needed. The existing `compileToMlirModule` function provides the compilation pipeline.

---

## Implementation Order

1. **ProjectionContainerTypeTest.elm** (Plan E1) - Simple, builds on existing infrastructure
2. **EcoUnboxSanityTest.elm** (Plan E2) - Simple, complements E1
3. **SsaTypeConsistencyTest.elm** (Plan B1) - Medium complexity
4. **RecordUpdateDataflowTest.elm** (Plan D1) - Most complex, heuristic-based

---

## Test Module Template

Each test module follows this pattern:

```elm
module Compiler.Generate.CodeGen.XxxTest exposing (suite)

import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants exposing (..)
import Expect
import Mlir.Mlir exposing (..)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_XXX: Description"
        [ Test.test "test case 1" test1
        , Test.test "test case 2" test2
        ]


checkInvariant : MlirModule -> List Violation
checkInvariant mlirModule =
    -- Implementation
    []


runInvariantTest : String -> () -> Expect.Expectation
runInvariantTest elmSource _ =
    case compileToMlirModule elmSource of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            checkInvariant mlirModule
                |> violationsToExpectation


test1 : () -> Expect.Expectation
test1 =
    runInvariantTest
        """
module Test exposing (main)

main = ...
"""
```

---

## Resolved Questions

1. **isPrimitiveType and I32**: I32 is NOT a primitive in eco. The current `isPrimitiveType` correctly excludes I32. Only I1, I16, I64, and F64 are eco primitives.

2. **SSA Type Consistency Scope (Plan B1)**: Check per-function, NOT module-wide. SSA names like `%0` are routinely reused across functions, so a module-wide check would produce false positives.

3. **Compilation Approach**: Use the existing `compileToMlirModule` approach for all tests.

## Assumptions

1. **SSA names are unique within functions**: The MLIR generation creates unique SSA names within each function scope. Cross-function reuse of SSA names is allowed and expected.

2. **eco.unbox always takes eco.value**: Based on code inspection, `eco.unbox` is always generated with `_operand_types = [TypeAttr Types.ecoValue]`.

3. **Projection ops always have single operand**: All projection ops in `Ops.elm` take exactly one operand (the container).

---

## Dependencies

- `Mlir.Mlir` - MLIR AST types
- `Compiler.Generate.CodeGen.Invariants` - Shared test utilities
- `Compiler.Generate.CodeGen.GenerateMLIR` - Compilation pipeline
- `Test`, `Expect` - Test framework

---

## Acceptance Criteria

1. All four new test modules compile and pass on the existing codebase
2. Tests detect injected bugs (verified manually during development)
3. Test coverage includes the specific bug patterns mentioned in the design document
4. No false positives on valid code patterns
