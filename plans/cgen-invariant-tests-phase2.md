# CGEN Invariant Test Modules Plan - Phase 2

This plan describes the implementation of test logic modules for MLIR codegen invariants CGEN_040 through CGEN_044 defined in `design_docs/invariants.csv`.

## Overview

These invariants were identified from analysis of cmake test failures (`TEST_FILTER=elm cmake --build build --target check`) and existing elm-test invariant gaps. They target issues that cause:
- MLIR parsing failures (21 tests): Type mismatches between `_operand_types` and actual SSA types
- SIGABRT crashes (2 tests): Missing block terminators
- Symbol redefinition errors (1 test): Duplicate function definitions
- Wrong results (10 tests): Calls to stub implementations

**Key insight**: These invariants can catch bugs that currently escape to MLIR/LLVM lowering or runtime, allowing earlier detection during Elm codegen.

## Data Structures

The MLIR AST in Elm (`Mlir/Mlir.elm`):

```elm
type alias MlirModule =
    { body : List MlirOp, loc : Loc }

type alias MlirOp =
    { name : String
    , id : String
    , operands : List ( String, MlirType )  -- (name, type) pairs
    , results : List ( String, MlirType )
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    , loc : Loc
    , successors : List String
    }

type MlirRegion = MlirRegion { entry : MlirBlock, blocks : OrderedDict String MlirBlock }

type alias MlirBlock =
    { args : List ( String, MlirType )
    , body : List MlirOp
    , terminator : MlirOp
    }

type MlirType = I1 | I16 | I32 | I64 | F64 | NamedStruct String | FunctionType ...

type MlirAttr
    = IntAttr (Maybe MlirType) Int
    | StringAttr String
    | ArrayAttr (Maybe MlirType) (List MlirAttr)
    | TypeAttr MlirType
    | ...
```

## Directory Structure

```
compiler/tests/Compiler/Generate/CodeGen/
├── Invariants.elm                     (shared verification logic - exists)
├── OperandTypeConsistencyTest.elm     (CGEN_040) - NEW
├── SymbolUniquenessTest.elm           (CGEN_041) - NEW
├── BlockTerminatorTest.elm            (CGEN_042) - NEW
├── CaseKindScrutineeTest.elm          (CGEN_043) - NEW
├── CallTargetValidityTest.elm         (CGEN_044) - NEW
└── CgenInvariantsTest.elm             (aggregator - update to include new tests)
```

## Shared Infrastructure Updates

### Additions to Compiler.Generate.CodeGen.Invariants

The following helpers need to be added to the existing `Invariants.elm` module:

```elm
-- Get the SSA operand types from op.operands (actual types)
getActualOperandTypes : MlirOp -> List MlirType
getActualOperandTypes op =
    List.map Tuple.second op.operands

-- Check if two types are equal (handles "eco.value" vs "!eco.value" normalization)
typesEqual : MlirType -> MlirType -> Bool
typesEqual t1 t2 =
    case ( t1, t2 ) of
        ( NamedStruct n1, NamedStruct n2 ) ->
            normalizeTypeName n1 == normalizeTypeName n2
        _ ->
            t1 == t2

-- Normalize type names (handle "eco.value" vs "!eco.value")
normalizeTypeName : String -> String
normalizeTypeName name =
    if name == "eco.value" || name == "!eco.value" then
        "!eco.value"
    else
        name

-- Check if an operation is a valid terminator
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name validTerminators

validTerminators : List String
validTerminators =
    [ "eco.return"
    , "eco.jump"
    , "eco.crash"
    , "scf.yield"
    , "cf.br"
    , "cf.cond_br"
    , "func.return"
    ]

-- Get all blocks from a region (entry + named blocks)
allBlocks : MlirRegion -> List MlirBlock
allBlocks (MlirRegion { entry, blocks }) =
    entry :: OrderedDict.values blocks

-- Find all symbol-defining ops at module level
findSymbolOps : MlirModule -> List ( String, MlirOp )
findSymbolOps mod =
    List.filterMap
        (\op ->
            getStringAttr "sym_name" op
                |> Maybe.map (\name -> ( name, op ))
        )
        mod.body
```

---

## Invariant Test Specifications

---

### CGEN_040: Operand Type Consistency

**Invariant**: For any operation with `_operand_types` attribute, the list length must equal SSA operand count and each declared type must exactly match the corresponding SSA operand type.

**File**: `OperandTypeConsistencyTest.elm`

**Test Function**:
```elm
expectOperandTypesMatchSSA : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkOperandTypeConsistency(module):
    violations = []

    # Walk all operations in the module
    allOps = walkAllOps(module)

    FOR each op IN allOps:
        # Get declared operand types from attribute
        declaredTypes = extractOperandTypes(op)  # from _operand_types attr

        IF declaredTypes == Nothing:
            # No _operand_types attribute - skip (covered by CGEN_032)
            CONTINUE

        # Get actual SSA operand types
        actualTypes = getActualOperandTypes(op)  # from op.operands

        # Check length match
        IF length(declaredTypes) != length(actualTypes):
            ADD violation:
                opId = op.id
                opName = op.name
                message = "_operand_types has {declared} entries but op has {actual} operands"
            CONTINUE

        # Check each type matches
        FOR i IN 0..length(declaredTypes)-1:
            declaredType = declaredTypes[i]
            actualType = actualTypes[i]

            IF NOT typesEqual(declaredType, actualType):
                ADD violation:
                    opId = op.id
                    opName = op.name
                    message = "operand {i}: _operand_types declares {declared} but SSA type is {actual}"

    RETURN violations
```

**Violation Conditions**:
- `_operand_types` length != SSA operand count
- `_operand_types[i]` != actual operand type at position i
- Type mismatch (e.g., `!eco.value` declared but `i64` actual)

**Test Cases**:
1. **Function call with Int argument**: Verify `eco.call` with i64 operand has `_operand_types = [i64]`
2. **List construction with boxed head**: Verify `eco.construct.list` operand types match
3. **Case expression on Int**: Scrutinee should have consistent declared/actual type
4. **Higher-order function**: Closure operands match declared types
5. **Mixed boxed/unboxed operands**: Verify each position matches

**Expected to Catch**: 21 cmake test failures (MLIR type mismatch errors)

---

### CGEN_041: Symbol Name Uniqueness

**Invariant**: Within a module, all symbol definitions must be unique; no two `func.func` operations may have the same `sym_name`.

**File**: `SymbolUniquenessTest.elm`

**Test Function**:
```elm
expectSymbolNamesUnique : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkSymbolUniqueness(module):
    violations = []

    # Find all symbol-defining ops at module scope
    symbolOps = findSymbolOps(module)

    # Group by symbol name
    symbolsByName = {}  # name -> List of (opId, opName)

    FOR (symName, op) IN symbolOps:
        IF symName NOT IN symbolsByName:
            symbolsByName[symName] = []
        symbolsByName[symName].add((op.id, op.name))

    # Check for duplicates
    FOR symName, definitions IN symbolsByName:
        IF length(definitions) > 1:
            firstDef = definitions[0]
            FOR i IN 1..length(definitions)-1:
                (opId, opName) = definitions[i]
                ADD violation:
                    opId = opId
                    opName = opName
                    message = "Duplicate symbol '{symName}': already defined at {firstDef.opId}"

    RETURN violations
```

**Violation Conditions**:
- Two or more `func.func` ops with the same `sym_name`
- Two or more symbol-bearing ops with the same symbol name

**Test Cases**:
1. **Simple function definitions**: Multiple distinct functions pass
2. **Higher-order function with PAP wrapper**: Verify no duplicate `_pap_wrapper` symbols
3. **Multiple uses of same function**: PAP wrapper should be generated once
4. **Mutual recursion**: Functions referencing each other have unique names

**Expected to Catch**: HigherOrderTest failure (duplicate `_pap_wrapper` symbol)

---

### CGEN_042: Block Terminator Presence

**Invariant**: Every block in every region must end with a terminator operation. Each `eco.case` alternative region must be properly terminated.

**File**: `BlockTerminatorTest.elm`

**Test Function**:
```elm
expectAllBlocksTerminated : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkBlockTerminators(module):
    violations = []

    allOps = walkAllOps(module)

    FOR each op IN allOps:
        FOR regionIdx, region IN enumerate(op.regions):
            violations.addAll(checkRegionTerminators(op, regionIdx, region))

    RETURN violations

FUNCTION checkRegionTerminators(parentOp, regionIdx, region):
    violations = []
    MlirRegion { entry, blocks } = region

    # Check entry block
    IF NOT isValidTerminator(entry.terminator):
        ADD violation:
            opId = parentOp.id
            opName = parentOp.name
            message = "region {regionIdx} entry block terminator '{entry.terminator.name}' is not a valid terminator"

    # Check terminator has correct structure (not a placeholder/empty op)
    IF entry.terminator.name == "" OR entry.terminator.name == "NO_OP":
        ADD violation:
            message = "region {regionIdx} entry block has empty/missing terminator"

    # Check all named blocks
    FOR blockName, block IN blocks:
        IF NOT isValidTerminator(block.terminator):
            ADD violation:
                opId = parentOp.id
                opName = parentOp.name
                message = "region {regionIdx} block '{blockName}' terminator '{block.terminator.name}' is not valid"

    # Special check for eco.case: all alternatives must terminate
    IF parentOp.name == "eco.case":
        # Each region is a case alternative
        allBlocksInRegion = allBlocks(region)
        FOR block IN allBlocksInRegion:
            # Recursively check nested ops for proper termination
            FOR bodyOp IN block.body:
                IF bodyOp.name == "eco.case":
                    FOR nestedIdx, nestedRegion IN enumerate(bodyOp.regions):
                        violations.addAll(checkRegionTerminators(bodyOp, nestedIdx, nestedRegion))

    RETURN violations
```

**Violation Conditions**:
- Block terminator is not in the valid terminator list
- Block has empty or missing terminator
- Nested `eco.case` alternative has non-terminating path

**Test Cases**:
1. **Simple if-then-else**: Both branches terminate with `eco.return`
2. **Case with joinpoint**: Branches terminate with `eco.jump`
3. **Nested case expressions**: All nested alternatives properly terminate
4. **List pattern matching**: `eco.case` on list with `eco.return` in each branch
5. **Case with scf.if inside**: Verify `scf.yield` used correctly

**Expected to Catch**: CaseListTest crash (`mightHaveTerminator()` assertion)

---

### CGEN_043: Case Kind Scrutinee Type Agreement

**Invariant**: `eco.case` scrutinee type must match `case_kind`:
- `case_kind="bool"` requires `i1` scrutinee
- `case_kind="int"` requires `i64` scrutinee
- `case_kind="chr"` requires `i16` (ECO char) scrutinee
- `case_kind="ctor"` requires `!eco.value` scrutinee
- `case_kind="str"` requires `!eco.value` scrutinee

**File**: `CaseKindScrutineeTest.elm`

**Test Function**:
```elm
expectCaseKindMatchesScrutinee : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCaseKindScrutinee(module):
    violations = []

    caseOps = findOpsNamed("eco.case", module)

    FOR each op IN caseOps:
        # Get case_kind attribute
        caseKind = getStringAttr("case_kind", op)

        IF caseKind == Nothing:
            # No case_kind - may be inferred from scrutinee type
            # This is acceptable, skip explicit validation
            CONTINUE

        # Get scrutinee type (first operand)
        operandTypes = extractOperandTypes(op)
        IF operandTypes == Nothing OR length(operandTypes) < 1:
            ADD violation:
                opId = op.id
                opName = op.name
                message = "eco.case missing scrutinee type information"
            CONTINUE

        scrutineeType = operandTypes[0]

        # Validate case_kind against scrutinee type
        expectedType = getExpectedScrutineeType(caseKind)

        IF expectedType == Nothing:
            ADD violation:
                message = "Unknown case_kind '{caseKind}'"
            CONTINUE

        IF NOT typesEqual(scrutineeType, expectedType):
            ADD violation:
                opId = op.id
                opName = op.name
                message = "case_kind='{caseKind}' requires {expected} scrutinee, got {actual}"

    RETURN violations

FUNCTION getExpectedScrutineeType(caseKind):
    SWITCH caseKind:
        CASE "bool":
            RETURN I1
        CASE "int":
            RETURN I64
        CASE "chr":
            RETURN I16  # ECO char type
        CASE "ctor":
            RETURN NamedStruct "!eco.value"
        CASE "str":
            RETURN NamedStruct "!eco.value"
        DEFAULT:
            RETURN Nothing
```

**Violation Conditions**:
- `case_kind="bool"` with non-`i1` scrutinee
- `case_kind="int"` with non-`i64` scrutinee
- `case_kind="chr"` with non-`i16` scrutinee
- `case_kind="ctor"` with non-`!eco.value` scrutinee (e.g., `i1`)
- `case_kind="str"` with non-`!eco.value` scrutinee
- Unknown `case_kind` value

**Test Cases**:
1. **Boolean if-expression**: `case_kind="bool"` with `i1` scrutinee
2. **Maybe pattern match**: `case_kind="ctor"` with `!eco.value` scrutinee
3. **Integer case**: `case_kind="int"` with `i64` scrutinee
4. **List pattern match**: `case_kind="ctor"` with `!eco.value` (not `i1` from tag comparison)
5. **String case**: `case_kind="str"` with `!eco.value` scrutinee
6. **Character case**: `case_kind="chr"` with `i16` scrutinee

**Expected to Catch**:
- CaseIntTest, CaseManyBranchesTest (type mismatch)
- CaseListTest (ctor case with i1 scrutinee)
- 6 elm-test CGEN_037 failures

---

### CGEN_044: Call Target Validity

**Invariant**: Every `eco.call` callee must resolve to an existing `func.func` symbol. Calls must not target stub implementations when a non-stub implementation exists.

**File**: `CallTargetValidityTest.elm`

**Test Function**:
```elm
expectCallTargetsValid : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCallTargetValidity(module):
    violations = []

    # Build map of all defined functions
    funcDefs = {}  # sym_name -> MlirOp
    FOR op IN module.body:
        IF op.name == "func.func":
            symName = getStringAttr("sym_name", op)
            IF symName != Nothing:
                funcDefs[symName] = op

    # Find all eco.call ops
    callOps = findOpsNamed("eco.call", module)

    FOR each callOp IN callOps:
        callee = getStringAttr("callee", callOp)

        IF callee == Nothing:
            # Indirect call - skip symbol resolution check
            CONTINUE

        # Remove leading @ if present
        calleeName = stripLeadingAt(callee)

        # Check callee exists
        IF calleeName NOT IN funcDefs:
            ADD violation:
                opId = callOp.id
                opName = callOp.name
                message = "eco.call references undefined function '{calleeName}'"
            CONTINUE

        # Check callee is not a trivial stub
        targetFunc = funcDefs[calleeName]
        IF isTrivialStub(targetFunc):
            # Check if a non-stub version exists with different suffix
            nonStubName = findNonStubVersion(calleeName, funcDefs)
            IF nonStubName != Nothing:
                ADD violation:
                    opId = callOp.id
                    opName = callOp.name
                    message = "eco.call targets stub '{calleeName}' but non-stub '{nonStubName}' exists"

    RETURN violations

FUNCTION isTrivialStub(funcOp):
    # A stub function has trivial body that just returns a constant
    # typically: entry block with just eco.constant + eco.return
    IF length(funcOp.regions) == 0:
        RETURN True  # Declaration without body

    MlirRegion { entry, blocks } = funcOp.regions[0]

    # Check if body is trivially small (1-2 ops before terminator)
    IF length(entry.body) <= 2:
        # Check if all body ops are constants
        allConstants = ALL op IN entry.body: op.name IN ["arith.constant", "eco.constant"]
        IF allConstants:
            # Check if return just returns a constant
            IF entry.terminator.name == "eco.return":
                RETURN True

    RETURN False

FUNCTION findNonStubVersion(stubName, funcDefs):
    # Look for functions with similar names but different suffixes
    # e.g., "Foo_bar_$_4" (stub) vs "Foo_bar_$_5" (real)
    baseName = extractBaseName(stubName)  # Remove trailing _$_N

    FOR funcName, funcOp IN funcDefs:
        IF funcName != stubName AND startsWith(funcName, baseName):
            IF NOT isTrivialStub(funcOp):
                RETURN funcName

    RETURN Nothing

FUNCTION extractBaseName(name):
    # Remove _$_N suffix
    # "Foo_bar_$_4" -> "Foo_bar"
    IF matches(name, ".*_\\$_\\d+$"):
        RETURN substringBeforeLast(name, "_$_")
    RETURN name
```

**Violation Conditions**:
- `eco.call` references undefined function (no `func.func` with matching `sym_name`)
- `eco.call` targets a stub function when a non-stub implementation exists

**Test Cases**:
1. **Direct function call**: Call to defined function passes
2. **Tail recursive function**: Helper function properly resolved
3. **Higher-order function**: Calls to passed functions valid
4. **Multiple specializations**: Call targets correct specialization
5. **Kernel function call**: External kernel call (declaration-only) is valid

**Expected to Catch**:
- TailRecursiveSumTest (calls stub `sumHelper_$_4` instead of real `sumHelper_$_5`)
- ListFoldlTest, ListLengthTest, ListReverseTest (similar issues)

---

## Implementation Priority

### Phase 1: Critical Type Safety (Highest Priority)
1. **CGEN_040**: OperandTypeConsistencyTest - Catches 21 MLIR parsing failures
2. **CGEN_043**: CaseKindScrutineeTest - Catches case kind/scrutinee mismatches

### Phase 2: Structure Validation (High Priority)
3. **CGEN_041**: SymbolUniquenessTest - Catches duplicate symbol errors
4. **CGEN_042**: BlockTerminatorTest - Catches missing terminator crashes

### Phase 3: Semantic Validation (Medium Priority)
5. **CGEN_044**: CallTargetValidityTest - Catches stub vs real function issues

---

## Infrastructure Updates Required

### 1. Update Invariants.elm

Add the following helper functions to `compiler/tests/Compiler/Generate/CodeGen/Invariants.elm`:

```elm
-- Normalize eco.value type name (handle with/without ! prefix)
normalizeEcoValueType : MlirType -> MlirType
normalizeEcoValueType t =
    case t of
        NamedStruct name ->
            if name == "eco.value" || name == "!eco.value" then
                NamedStruct "!eco.value"
            else
                NamedStruct name
        _ ->
            t

-- Compare types with normalization
typesMatch : MlirType -> MlirType -> Bool
typesMatch t1 t2 =
    normalizeEcoValueType t1 == normalizeEcoValueType t2

-- Get actual SSA operand types from op.operands
getActualOperandTypes : MlirOp -> List MlirType
getActualOperandTypes op =
    List.map Tuple.second op.operands

-- Valid terminator operations
validTerminators : List String
validTerminators =
    [ "eco.return", "eco.jump", "eco.crash"
    , "scf.yield", "cf.br", "cf.cond_br", "func.return"
    ]

-- Check if op is a valid terminator
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name validTerminators

-- Get all blocks from a region
allBlocks : MlirRegion -> List MlirBlock
allBlocks (MlirRegion { entry, blocks }) =
    entry :: OrderedDict.values blocks
```

### 2. Update isEcoValueType

Fix the existing `isEcoValueType` to handle both naming conventions:

```elm
isEcoValueType : MlirType -> Bool
isEcoValueType t =
    case t of
        NamedStruct name ->
            name == "!eco.value" || name == "eco.value"
        _ ->
            False
```

### 3. Update CgenInvariantsTest.elm

Add imports and test suite entries for the new test modules.

---

## Testing Approach

### Unit Testing with Specific Elm Source

Each invariant test should include specific Elm source programs that:
1. **Pass**: Well-formed programs that satisfy the invariant
2. **Would Fail**: Programs that would violate the invariant (if codegen had bugs)

Example test structure:
```elm
suite : Test
suite =
    Test.describe "CGEN_040: Operand Type Consistency"
        [ Test.test "Direct Int call has consistent types" directIntCallTest
        , Test.test "List.map with closure has consistent types" listMapClosureTest
        , Test.test "Case on Int scrutinee has consistent types" caseIntScrutineeTest
        ]

directIntCallTest : () -> Expectation
directIntCallTest _ =
    let
        modul = makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "negate") [ intExpr 42 ])
    in
    runInvariantTest modul
```

### Integration with Existing Test Framework

Use the existing `compileToMlirModule` helper from `GenerateMLIR.elm`:

```elm
runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkInvariant mlirModule)
```

---

## Dependencies

- `Mlir.Mlir` module for AST types
- `Compiler.Generate.MLIR.*` for codegen
- `Compiler.Generate.CodeGen.Invariants` for shared helpers
- `Compiler.AST.SourceBuilder` for test case construction
- Test framework (`Test`, `Expect`)

---

## Success Criteria

After implementing these invariants:

1. **CGEN_040**: All 21 MLIR type mismatch failures should be caught at Elm test phase
2. **CGEN_041**: HigherOrderTest duplicate symbol error caught at Elm test phase
3. **CGEN_042**: CaseListTest terminator crash caught at Elm test phase
4. **CGEN_043**: Case kind/scrutinee mismatches caught (6+ failures)
5. **CGEN_044**: Stub vs real function issues identified for wrong-result tests

Total expected impact: ~30 cmake test failures detectable earlier in the Elm codegen phase.
