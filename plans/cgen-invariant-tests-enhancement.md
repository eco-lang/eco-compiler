# CGEN Invariant Tests Enhancement Plan

## Overview

This plan adds tests for 7 CGEN invariants that currently lack test coverage:
- **CGEN_001**: Boxing only between primitives and eco.value
- **CGEN_002**: Partial applications routed through closure generation
- **CGEN_005**: Heap projection respects layout bitmap
- **CGEN_009**: Boolean constants use !eco.value except in control-flow
- **CGEN_013**: CEcoValue MVars always lower to eco.value
- **CGEN_014**: MLIR uses only MonoGraph ctorLayouts for unions
- **CGEN_045**: eco.case is NOT a block terminator

All tests follow the established pattern: logic module + test module using StandardTestSuites.

---

## Phase 1: Simple MLIR-Only Tests (3-4 hours)

These tests only need `MlirModule` access (already available).

### 1.1 CGEN_001: Boxing Validation

**File:** `compiler/tests/TestLogic/Generate/CodeGen/BoxingValidation.elm`
**Test file:** `compiler/tests/TestLogic/Generate/CodeGen/BoxingValidationTest.elm`

**Logic:**
```
For each eco.box op:
  - Input operand must be i64, f64, or i16
  - Result must be !eco.value
  - Report violation if input is !eco.value (no-op box) or wrong primitive

For each eco.unbox op:
  - Input operand must be !eco.value
  - Result must be i64, f64, or i16
  - Report violation if result is !eco.value (no-op unbox)

Cross-primitive conversions (i64 <-> f64) are monomorphization bugs, not codegen bugs,
but detecting them here provides defense in depth.
```

**Implementation:**
```elm
checkBoxingValidation : MlirModule -> List Violation
checkBoxingValidation mlirModule =
    let
        boxOps = findOpsNamed "eco.box" mlirModule
        unboxOps = findOpsNamed "eco.unbox" mlirModule
    in
    List.filterMap checkBoxOp boxOps ++ List.filterMap checkUnboxOp unboxOps

checkBoxOp : MlirOp -> Maybe Violation
checkBoxOp op =
    case (extractOperandTypes op, extractResultTypes op) of
        (Just [inputType], [resultType]) ->
            if not (isUnboxable inputType) then
                Just { opId = op.id, opName = op.name
                     , message = "eco.box input should be primitive, got " ++ typeToString inputType }
            else if not (isEcoValueType resultType) then
                Just { opId = op.id, opName = op.name
                     , message = "eco.box result should be !eco.value, got " ++ typeToString resultType }
            else
                Nothing
        _ -> Nothing
```

### 1.2 CGEN_009: Boolean Constants

**File:** `compiler/tests/TestLogic/Generate/CodeGen/BooleanConstants.elm`
**Test file:** `compiler/tests/TestLogic/Generate/CodeGen/BooleanConstantsTest.elm`

**Logic:**
```
For each eco.constant op with value "True" or "False":
  - Result type must be !eco.value
  - i1 result is a violation (Bool must be boxed at storage boundaries)

For i1 values appearing anywhere:
  - Must only be used as eco.case scrutinee (case_kind="bool")
  - i1 appearing as construct operand, PAP capture, or function arg is a violation
```

**Implementation:**
```elm
checkBooleanConstants : MlirModule -> List Violation
checkBooleanConstants mlirModule =
    let
        constantOps = findOpsNamed "eco.constant" mlirModule
        boolConstants = List.filter isBoolConstant constantOps

        -- Check all Bool constants produce !eco.value
        constantViolations = List.filterMap checkBoolConstantType boolConstants

        -- Check i1 only used in case scrutinee
        i1Violations = checkI1Usage mlirModule
    in
    constantViolations ++ i1Violations

isBoolConstant : MlirOp -> Bool
isBoolConstant op =
    case getStringAttr "value" op of
        Just "True" -> True
        Just "False" -> True
        _ -> False

checkBoolConstantType : MlirOp -> Maybe Violation
checkBoolConstantType op =
    case extractResultTypes op of
        [resultType] ->
            if not (isEcoValueType resultType) then
                Just { opId = op.id, opName = op.name
                     , message = "Bool constant must produce !eco.value, got " ++ typeToString resultType }
            else
                Nothing
        _ -> Nothing
```

### 1.3 CGEN_045: eco.case Not a Terminator

**File:** `compiler/tests/TestLogic/Generate/CodeGen/CaseNotTerminator.elm`
**Test file:** `compiler/tests/TestLogic/Generate/CodeGen/CaseNotTerminatorTest.elm`

**Logic:**
```
For every block in every region:
  - If block.terminator.name == "eco.case", report violation
  - eco.case must appear in block.body, not as terminator
  - eco.case is value-producing, not control-flow terminating
```

**Implementation:**
```elm
checkCaseNotTerminator : MlirModule -> List Violation
checkCaseNotTerminator mlirModule =
    walkAllBlocks mlirModule
        |> List.filterMap checkBlockTerminator

checkBlockTerminator : MlirBlock -> Maybe Violation
checkBlockTerminator block =
    if block.terminator.name == "eco.case" then
        Just { opId = block.terminator.id
             , opName = "eco.case"
             , message = "eco.case found as block terminator but it is a value-producing op, not a terminator"
             }
    else
        Nothing

walkAllBlocks : MlirModule -> List MlirBlock
walkAllBlocks mod =
    walkAllOps mod
        |> List.concatMap (\op -> List.concatMap allBlocks op.regions)
```

---

## Phase 2: Partial Application Routing (4 hours)

### 2.1 CGEN_002: Partial Applications Through Closure Generation

**File:** `compiler/tests/TestLogic/Generate/CodeGen/PartialApplicationRouting.elm`
**Test file:** `compiler/tests/TestLogic/Generate/CodeGen/PartialApplicationRoutingTest.elm`

**Logic:**
```
For each eco.call op:
  - Get the result type from op.results
  - If result type is a function type (FunctionType), report violation
  - All partial applications must go through eco.papCreate/eco.papExtend
  - eco.call should only produce non-function results (fully saturated calls)
```

**Implementation:**
```elm
checkPartialApplicationRouting : MlirModule -> List Violation
checkPartialApplicationRouting mlirModule =
    let
        callOps = findOpsNamed "eco.call" mlirModule
    in
    List.filterMap checkCallResultType callOps

checkCallResultType : MlirOp -> Maybe Violation
checkCallResultType op =
    case extractResultTypes op of
        [resultType] ->
            if isFunctionType resultType then
                Just { opId = op.id
                     , opName = op.name
                     , message = "eco.call produces function type " ++ typeToString resultType
                              ++ " but partial applications must use eco.papCreate/papExtend"
                     }
            else
                Nothing
        _ -> Nothing

isFunctionType : MlirType -> Bool
isFunctionType t =
    case t of
        FunctionType _ -> True
        _ -> False
```

**Note:** This test may need refinement. Some eco.call ops may legitimately return function types if the callee itself returns a function (not a partial application). The test should focus on detecting when `generateCall` incorrectly emits `eco.call` instead of PAP machinery for undersaturated calls.

---

## Phase 3: MonoGraph-Enabled Tests (4-6 hours)

These tests require access to `monoGraph` from `CompileResult`. The infrastructure already provides this - tests just need to use it.

### 3.0 Infrastructure Update

Update existing test modules to destructure both `mlirModule` and `monoGraph`:

```elm
-- Before:
Ok { mlirModule } ->
    violationsToExpectation (checkSomething mlirModule)

-- After:
Ok { mlirModule, monoGraph } ->
    violationsToExpectation (checkSomething mlirModule monoGraph)
```

Add import for layout computation:
```elm
import Compiler.Generate.MLIR.Types as Types
```

### 3.1 CGEN_005: Heap Projection Respects Layout Bitmap

**File:** `compiler/tests/TestLogic/Generate/CodeGen/ProjectionLayoutBitmap.elm`
**Test file:** `compiler/tests/TestLogic/Generate/CodeGen/ProjectionLayoutBitmapTest.elm`

**Logic:**
```
For each eco.project.custom op:
  - Extract the type_id or tag from the op attributes
  - Look up the corresponding CtorShape in monoGraph.ctorShapes
  - Compute CtorLayout via Types.computeCtorLayout
  - Get the field_index from the projection op
  - Check if layout says field is unboxed (bitmap bit set)
  - Verify projection result type matches:
    - If layout.fields[field_index].isUnboxed -> result should be i64/f64/i16
    - Otherwise -> result should be !eco.value
```

**Implementation:**
```elm
checkProjectionLayoutBitmap : MlirModule -> Mono.MonoGraph -> List Violation
checkProjectionLayoutBitmap mlirModule monoGraph =
    let
        (Mono.MonoGraph { ctorShapes }) = monoGraph

        -- Build lookup from (type name, tag) -> CtorLayout
        ctorLayoutMap = buildCtorLayoutMap ctorShapes

        projectionOps = findOpsNamed "eco.project.custom" mlirModule
    in
    List.filterMap (checkProjectionOp ctorLayoutMap) projectionOps

buildCtorLayoutMap : Dict (List String) (List String) (List Mono.CtorShape) -> Dict (String, Int) Types.CtorLayout
buildCtorLayoutMap ctorShapes =
    Dict.foldl (\_ shapes acc ->
        List.foldl (\shape inner ->
            let layout = Types.computeCtorLayout shape
            in Dict.insert (shape.name, shape.tag) layout inner
        ) acc shapes
    ) Dict.empty ctorShapes

checkProjectionOp : Dict (String, Int) Types.CtorLayout -> MlirOp -> Maybe Violation
checkProjectionOp layoutMap op =
    case (getIntAttr "field_index" op, getIntAttr "tag" op) of
        (Just fieldIndex, Just tag) ->
            -- Look up layout and verify result type matches
            ...
        _ -> Nothing
```

### 3.2 CGEN_014: MLIR Uses Only MonoGraph ctorLayouts

**File:** `compiler/tests/TestLogic/Generate/CodeGen/CtorLayoutConsistency.elm`
**Test file:** `compiler/tests/TestLogic/Generate/CodeGen/CtorLayoutConsistencyTest.elm`

**Logic:**
```
For each eco.construct.custom op:
  - Extract tag, size, unboxed_bitmap from op attributes
  - Find corresponding CtorShape in monoGraph.ctorShapes
  - Compute CtorLayout via Types.computeCtorLayout
  - Verify:
    - op.tag == layout.tag
    - op.size == List.length layout.fields
    - op.unboxed_bitmap == layout.unboxedBitmap
```

**Implementation:**
```elm
checkCtorLayoutConsistency : MlirModule -> Mono.MonoGraph -> List Violation
checkCtorLayoutConsistency mlirModule monoGraph =
    let
        (Mono.MonoGraph { ctorShapes }) = monoGraph
        ctorLayoutMap = buildCtorLayoutMap ctorShapes

        constructOps = findOpsNamed "eco.construct.custom" mlirModule
    in
    List.filterMap (checkConstructOp ctorLayoutMap) constructOps

checkConstructOp : Dict (String, Int) Types.CtorLayout -> MlirOp -> Maybe Violation
checkConstructOp layoutMap op =
    case (getIntAttr "tag" op, getIntAttr "size" op, getIntAttr "unboxed_bitmap" op) of
        (Just tag, Just size, Just bitmap) ->
            -- Find matching layout and compare
            case findLayoutByTag tag layoutMap of
                Just layout ->
                    if size /= List.length layout.fields then
                        Just { ... message = "size mismatch" ... }
                    else if bitmap /= layout.unboxedBitmap then
                        Just { ... message = "bitmap mismatch" ... }
                    else
                        Nothing
                Nothing ->
                    Just { ... message = "no matching layout found" ... }
        _ -> Nothing
```

### 3.3 CGEN_013: CEcoValue MVars Lower to eco.value

**File:** `compiler/tests/TestLogic/Generate/CodeGen/CEcoValueLowering.elm`
**Test file:** `compiler/tests/TestLogic/Generate/CodeGen/CEcoValueLoweringTest.elm`

**Logic:**
```
This is harder to test directly because MonoType information is not preserved in MLIR.
However, we can test indirectly:

1. Find MonoNodes in monoGraph that contain MVar(CEcoValue) in their types
2. Identify the corresponding MLIR operations by matching function names/structure
3. Verify those positions use !eco.value type

Alternative approach:
- Focus on Debug.* calls which are known to preserve CEcoValue polymorphism
- Verify all Debug kernel call operands are !eco.value
```

**Implementation (simpler approach):**
```elm
checkCEcoValueLowering : MlirModule -> Mono.MonoGraph -> List Violation
checkCEcoValueLowering mlirModule monoGraph =
    let
        -- Find Debug.* calls
        callOps = findOpsNamed "eco.call" mlirModule
        debugCalls = List.filter isDebugCall callOps
    in
    List.filterMap checkDebugCallOperands debugCalls

isDebugCall : MlirOp -> Bool
isDebugCall op =
    case getStringAttr "callee" op of
        Just callee -> String.contains "Debug" callee
        Nothing -> False

checkDebugCallOperands : MlirOp -> Maybe Violation
checkDebugCallOperands op =
    case extractOperandTypes op of
        Just operandTypes ->
            -- All non-primitive args to Debug functions should be !eco.value
            List.indexedMap checkDebugOperand operandTypes
                |> List.filterMap identity
                |> List.head
        Nothing -> Nothing
```

---

## Phase 4: Documentation Update

Update `design_docs/invariant-test-logic.md`:

1. Add `tests:` field for CGEN_001, CGEN_002, CGEN_005, CGEN_009, CGEN_013, CGEN_014, CGEN_045
2. Update CGEN_004 from "NOT YET IMPLEMENTED" to reference existing test

---

## File Structure

```
compiler/tests/TestLogic/Generate/CodeGen/
├── BoxingValidation.elm          # CGEN_001 logic
├── BoxingValidationTest.elm      # CGEN_001 test
├── BooleanConstants.elm          # CGEN_009 logic
├── BooleanConstantsTest.elm      # CGEN_009 test
├── CaseNotTerminator.elm         # CGEN_045 logic
├── CaseNotTerminatorTest.elm     # CGEN_045 test
├── PartialApplicationRouting.elm     # CGEN_002 logic
├── PartialApplicationRoutingTest.elm # CGEN_002 test
├── ProjectionLayoutBitmap.elm        # CGEN_005 logic
├── ProjectionLayoutBitmapTest.elm    # CGEN_005 test
├── CtorLayoutConsistency.elm         # CGEN_014 logic
├── CtorLayoutConsistencyTest.elm     # CGEN_014 test
├── CEcoValueLowering.elm             # CGEN_013 logic
└── CEcoValueLoweringTest.elm         # CGEN_013 test
```

---

## Estimated Effort

| Phase | Invariants | Effort |
|-------|------------|--------|
| Phase 1 | CGEN_001, CGEN_009, CGEN_045 | 3-4 hours |
| Phase 2 | CGEN_002 | 4 hours |
| Phase 3 | CGEN_005, CGEN_013, CGEN_014 | 4-6 hours |
| Phase 4 | Documentation | 30 min |
| **Total** | **7 invariants** | **12-15 hours** |

---

## Testing Strategy

1. Run `npx elm-test-rs --fuzz 1` after each new test module
2. Verify tests pass on the standard test suites
3. Create focused negative tests where possible (code that should violate the invariant)
4. Run full `cmake --build build --target check` to ensure no regressions

---

## Dependencies

- No external dependencies
- Uses existing `Invariants.elm` infrastructure
- Uses existing `StandardTestSuites` for broad coverage
- Uses existing `Types.computeCtorLayout` for layout computation
