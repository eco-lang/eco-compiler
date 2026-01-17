# CGEN Invariant Test Modules Plan

This plan describes the implementation of test logic modules for MLIR codegen invariants CGEN_015 through CGEN_039 defined in `design_docs/invariants.csv`.

## Overview

The MLIR codegen phase transforms a `MonoGraph` into an `MlirModule`. These invariants ensure the generated MLIR is well-formed and matches the Eco dialect specification.

**Key insight**: We can verify most invariants by inspecting the `MlirModule` AST structure in Elm, avoiding the need for MLIR text parsing.

## Data Structures

The MLIR AST in Elm (`Mlir/Mlir.elm`):

```elm
type alias MlirModule =
    { body : List MlirOp, loc : Loc }

type alias MlirOp =
    { name : String
    , id : String
    , operands : List String
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

type MlirType = I1 | I16 | I32 | I64 | F64 | EcoValue | ...

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
├── Invariants.elm                 (shared verification logic)
├── CharTypeMappingTest.elm        (CGEN_015)
├── ListConstructionTest.elm       (CGEN_016)
├── TupleConstructionTest.elm      (CGEN_017)
├── RecordConstructionTest.elm     (CGEN_018)
├── SingletonConstantsTest.elm     (CGEN_019)
├── CustomConstructionTest.elm     (CGEN_020)
├── ListProjectionTest.elm         (CGEN_021)
├── TupleProjectionTest.elm        (CGEN_022)
├── RecordProjectionTest.elm       (CGEN_023)
├── CustomProjectionTest.elm       (CGEN_024)
├── ConstructResultTypeTest.elm    (CGEN_025)
├── UnboxedBitmapTest.elm          (CGEN_026, CGEN_027)
├── CaseTerminationTest.elm        (CGEN_028)
├── CaseTagsCountTest.elm          (CGEN_029)
├── JumpTargetTest.elm             (CGEN_030)
├── JoinpointUniqueIdTest.elm      (CGEN_031)
├── OperandTypesAttrTest.elm       (CGEN_032)
├── PapCreateArityTest.elm         (CGEN_033)
├── PapExtendResultTest.elm        (CGEN_034)
├── TypeTableUniquenessTest.elm    (CGEN_035)
├── DbgTypeIdsTest.elm             (CGEN_036)
├── CaseScrutineeTypeTest.elm      (CGEN_037)
├── KernelAbiConsistencyTest.elm   (CGEN_038)
├── NoAllocateOpsTest.elm          (CGEN_039)
└── CgenInvariantsTest.elm         (aggregator)
```

## Shared Infrastructure

### Compiler.Generate.CodeGen.Invariants

Located at `compiler/tests/Compiler/Generate/CodeGen/Invariants.elm`.

```elm
module Compiler.Generate.CodeGen.Invariants exposing
    ( walkAllOps
    , walkOpsInFunc
    , walkOpsInRegion
    , walkOpsInBlock
    , findOpsNamed
    , findOpsWithPrefix
    , findFuncOps
    , getIntAttr
    , getStringAttr
    , getArrayAttr
    , getTypeAttr
    , getBoolAttr
    , extractOperandTypes
    , isEcoValueType
    , isPrimitiveType
    , Violation
    , checkAll
    , checkNone
    )

type alias Violation =
    { opId : String
    , opName : String
    , message : String
    }

-- Recursively walk all ops in module, including nested regions
walkAllOps : MlirModule -> List MlirOp
walkAllOps mod =
    List.concatMap walkOpAndChildren mod.body

walkOpAndChildren : MlirOp -> List MlirOp
walkOpAndChildren op =
    op :: List.concatMap walkOpsInRegion op.regions

walkOpsInRegion : MlirRegion -> List MlirOp
walkOpsInRegion (MlirRegion { entry, blocks }) =
    walkOpsInBlock entry ++ List.concatMap walkOpsInBlock (Dict.values blocks)

walkOpsInBlock : MlirBlock -> List MlirOp
walkOpsInBlock block =
    List.concatMap walkOpAndChildren block.body
        ++ walkOpAndChildren block.terminator

-- Find all ops with exact name match
findOpsNamed : String -> MlirModule -> List MlirOp
findOpsNamed name mod =
    List.filter (\op -> op.name == name) (walkAllOps mod)

-- Find all ops with name starting with prefix
findOpsWithPrefix : String -> MlirModule -> List MlirOp
findOpsWithPrefix prefix mod =
    List.filter (\op -> String.startsWith prefix op.name) (walkAllOps mod)

-- Find func.func ops (top-level functions)
findFuncOps : MlirModule -> List MlirOp
findFuncOps mod =
    List.filter (\op -> op.name == "func.func") mod.body

-- Attribute extraction helpers
getIntAttr : String -> MlirOp -> Maybe Int
getIntAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractInt

extractInt : MlirAttr -> Maybe Int
extractInt attr =
    case attr of
        IntAttr _ n -> Just n
        _ -> Nothing

getStringAttr : String -> MlirOp -> Maybe String
getStringAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractString

extractString : MlirAttr -> Maybe String
extractString attr =
    case attr of
        StringAttr s -> Just s
        _ -> Nothing

getArrayAttr : String -> MlirOp -> Maybe (List MlirAttr)
getArrayAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractArray

extractArray : MlirAttr -> Maybe (List MlirAttr)
extractArray attr =
    case attr of
        ArrayAttr _ items -> Just items
        _ -> Nothing

getBoolAttr : String -> MlirOp -> Maybe Bool
getBoolAttr key op =
    getIntAttr key op |> Maybe.map (\n -> n /= 0)

-- Extract _operand_types as list of MlirType
extractOperandTypes : MlirOp -> Maybe (List MlirType)
extractOperandTypes op =
    getArrayAttr "_operand_types" op
        |> Maybe.map (List.filterMap extractTypeFromAttr)

extractTypeFromAttr : MlirAttr -> Maybe MlirType
extractTypeFromAttr attr =
    case attr of
        TypeAttr t -> Just t
        _ -> Nothing

-- Type predicates
isEcoValueType : MlirType -> Bool
isEcoValueType t =
    case t of
        EcoValue -> True
        _ -> False

isPrimitiveType : MlirType -> Bool
isPrimitiveType t =
    case t of
        I1 -> True
        I16 -> True
        I64 -> True
        F64 -> True
        _ -> False

-- Check that all items pass predicate, collect violations
checkAll : (a -> Maybe Violation) -> List a -> List Violation
checkAll check items =
    List.filterMap check items

-- Check that no items exist (list should be empty)
checkNone : String -> List MlirOp -> List Violation
checkNone message ops =
    List.map (\op -> { opId = op.id, opName = op.name, message = message }) ops
```

---

## Invariant Test Specifications

---

### CGEN_015: Char Type Mapping

**Invariant**: `monoTypeToMlir` maps `MChar` to `i16` (not `i32`), and all char constants/ops use `i16`.

**Test Function**:
```elm
expectCharTypeIsI16 : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCharTypeMapping(module):
    violations = []

    # Step 1: Find all eco.char.* operations
    charOps = findOpsWithPrefix("eco.char.", module)

    FOR each op IN charOps:
        # eco.char.toInt: i16 -> i64
        IF op.name == "eco.char.toInt":
            operandTypes = extractOperandTypes(op)
            IF operandTypes[0] != I16:
                ADD violation: "eco.char.toInt operand should be i16, got {type}"

        # eco.char.fromInt: i64 -> i16
        ELIF op.name == "eco.char.fromInt":
            resultType = op.results[0].type
            IF resultType != I16:
                ADD violation: "eco.char.fromInt result should be i16, got {type}"

    # Step 2: Find arith.constant ops that might be char literals
    # Char literals have result type i16
    constants = findOpsNamed("arith.constant", module)
    FOR each op IN constants:
        IF op has result type I32 AND value is in Unicode range (0-65535):
            # This might be a char constant incorrectly typed as i32
            # Flag for review (could be false positive for int constants)
            ADD warning: "arith.constant with i32 in char range, expected i16"

    # Step 3: Check projection ops returning char types
    # eco.project.* with result type should use i16 for char fields
    projectOps = findOpsWithPrefix("eco.project.", module)
    FOR each op IN projectOps:
        resultType = op.results[0].type
        IF resultType == I32:
            ADD violation: "projection result i32 may indicate char mapping error"

    RETURN violations
```

**Violation Conditions**:
- `eco.char.toInt` operand type is not `I16`
- `eco.char.fromInt` result type is not `I16`
- Any char-related constant uses `I32` instead of `I16`

**Test Cases**:
- `'a'` character literal
- `Char.toCode 'x'` conversion
- `Char.fromCode 65` conversion
- String operations that extract characters

---

### CGEN_016: List Construction

**Invariant**: List values use `eco.construct.list` for cons cells and `eco.constant Nil` for empty lists; never `eco.construct.custom`.

**Test Function**:
```elm
expectListConstructionCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkListConstruction(module):
    violations = []

    # Step 1: Verify all eco.construct.list ops are valid (just existence check)
    listConstructOps = findOpsNamed("eco.construct.list", module)
    # These are valid by definition - cons cell construction

    # Step 2: Verify eco.constant Nil exists for empty lists (informational)
    constantOps = findOpsNamed("eco.constant", module)
    nilOps = FILTER constantOps WHERE getStringAttr("kind") == "Nil"
    # Valid usage

    # Step 3: Check eco.construct.custom for list misuse
    customOps = findOpsNamed("eco.construct.custom", module)

    FOR each op IN customOps:
        constructorName = getStringAttr("constructor", op)

        # Check for explicit list constructor names
        IF constructorName IN ["Cons", "Nil", "List.Cons", "List.Nil", "::"] :
            ADD violation:
                opId = op.id
                opName = op.name
                message = "eco.construct.custom used for list constructor '{name}', should use eco.construct.list or eco.constant Nil"

        # Check for tag=0, size=0 pattern that looks like Nil
        # (Nil should be eco.constant, not eco.construct.custom with 0 fields)
        tag = getIntAttr("tag", op)
        size = getIntAttr("size", op)
        IF tag == 0 AND size == 0 AND constructorName == Nothing:
            # Could be a nullary constructor - need to verify it's not list-related
            # This is a weaker check; may need context
            PASS

    RETURN violations
```

**Violation Conditions**:
- `eco.construct.custom` with `constructor` attribute containing "Cons", "Nil", or "::"
- Any pattern suggesting list construction through custom ops

**Test Cases**:
- `[]` empty list
- `[1, 2, 3]` list literal
- `x :: xs` cons expression
- `1 :: 2 :: []` chained cons

---

### CGEN_017: Tuple Construction

**Invariant**: Tuples use `eco.construct.tuple2` or `eco.construct.tuple3`; never `eco.construct.custom`.

**Test Function**:
```elm
expectTupleConstructionCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkTupleConstruction(module):
    violations = []

    # Step 1: Verify tuple construct ops exist and have correct operand counts
    tuple2Ops = findOpsNamed("eco.construct.tuple2", module)
    FOR each op IN tuple2Ops:
        IF length(op.operands) != 2:
            ADD violation: "eco.construct.tuple2 should have exactly 2 operands"

    tuple3Ops = findOpsNamed("eco.construct.tuple3", module)
    FOR each op IN tuple3Ops:
        IF length(op.operands) != 3:
            ADD violation: "eco.construct.tuple3 should have exactly 3 operands"

    # Step 2: Check eco.construct.custom for tuple misuse
    customOps = findOpsNamed("eco.construct.custom", module)

    FOR each op IN customOps:
        constructorName = getStringAttr("constructor", op)

        # Check for tuple-like constructor names
        IF constructorName matches pattern like "Tuple2", "Tuple3", "(,)", "(,,)":
            ADD violation:
                message = "eco.construct.custom used for tuple constructor, should use eco.construct.tuple2 or tuple3"

        # Tuples don't have named constructors in Elm, so any eco.construct.custom
        # should have a constructor name (for custom ADTs) - tuples have no name
        # This is a structural check: tuples are anonymous

    RETURN violations
```

**Violation Conditions**:
- `eco.construct.tuple2` with operand count != 2
- `eco.construct.tuple3` with operand count != 3
- `eco.construct.custom` with tuple-like constructor name

**Test Cases**:
- `(1, 2)` 2-tuple
- `(1, 2, 3)` 3-tuple
- `Tuple.pair a b` tuple construction
- Nested tuples `((1, 2), 3)`

---

### CGEN_018: Record Construction

**Invariant**: Non-empty records use `eco.construct.record`; empty records use `eco.constant EmptyRec`.

**Test Function**:
```elm
expectRecordConstructionCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkRecordConstruction(module):
    violations = []

    # Step 1: Check eco.construct.record ops have field_count > 0
    recordOps = findOpsNamed("eco.construct.record", module)

    FOR each op IN recordOps:
        fieldCount = getIntAttr("field_count", op)

        IF fieldCount == Nothing:
            ADD violation: "eco.construct.record missing field_count attribute"
        ELIF fieldCount == 0:
            ADD violation: "eco.construct.record with field_count=0, should use eco.constant EmptyRec"
        ELIF fieldCount != length(op.operands):
            ADD violation: "eco.construct.record field_count ({count}) doesn't match operand count ({ops})"

    # Step 2: Verify eco.constant EmptyRec for empty records
    constantOps = findOpsNamed("eco.constant", module)
    emptyRecOps = FILTER constantOps WHERE getStringAttr("kind") == "EmptyRec"
    # These are valid

    # Step 3: Check eco.construct.custom is not used for records
    customOps = findOpsNamed("eco.construct.custom", module)
    FOR each op IN customOps:
        constructorName = getStringAttr("constructor", op)
        # Records don't have constructor names - they're structural
        # If a custom op looks like it could be a record (no constructor, multiple fields)
        # it might be misuse, but this is hard to detect without type info

    RETURN violations
```

**Violation Conditions**:
- `eco.construct.record` with missing `field_count` attribute
- `eco.construct.record` with `field_count = 0`
- `eco.construct.record` where `field_count` != operand count

**Test Cases**:
- `{}` empty record
- `{ x = 1 }` single field
- `{ x = 1, y = 2, z = 3 }` multiple fields
- Record update `{ rec | x = 1 }`

---

### CGEN_019: Singleton Constants

**Invariant**: Well-known singletons (Unit, True, False, Nil, Nothing, EmptyString, EmptyRec) always use `eco.constant`.

**Test Function**:
```elm
expectSingletonConstantsUsed : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkSingletonConstants(module):
    violations = []
    KNOWN_SINGLETONS = ["Unit", "True", "False", "Nil", "Nothing", "EmptyString", "EmptyRec"]

    # Step 1: Verify eco.constant ops use valid kinds
    constantOps = findOpsNamed("eco.constant", module)
    FOR each op IN constantOps:
        kind = getStringAttr("kind", op)
        IF kind NOT IN KNOWN_SINGLETONS:
            ADD violation: "eco.constant with unknown kind '{kind}'"

    # Step 2: Check eco.construct.custom doesn't create singletons
    customOps = findOpsNamed("eco.construct.custom", module)

    FOR each op IN customOps:
        constructorName = getStringAttr("constructor", op)
        tag = getIntAttr("tag", op)
        size = getIntAttr("size", op)

        # Check for explicit singleton constructor names
        IF constructorName IN ["True", "False", "Nothing", "Nil", "Unit"]:
            ADD violation:
                message = "eco.construct.custom used for singleton '{name}', should use eco.constant"

        # Check for nullary constructor pattern (tag=any, size=0)
        # that matches known singletons
        IF size == 0:
            IF constructorName == "True" OR (tag == 0 AND constructorName matches "True"):
                ADD violation: "True should use eco.constant True"
            IF constructorName == "False" OR (tag == 1 AND constructorName matches "False"):
                ADD violation: "False should use eco.constant False"
            IF constructorName == "Nothing":
                ADD violation: "Nothing should use eco.constant Nothing"

    # Step 3: Check string literals for empty string
    stringOps = findOpsNamed("eco.string_literal", module)
    FOR each op IN stringOps:
        value = getStringAttr("value", op)
        IF value == "":
            ADD violation: "Empty string should use eco.constant EmptyString, not eco.string_literal"

    RETURN violations
```

**Violation Conditions**:
- `eco.constant` with unknown kind
- `eco.construct.custom` with constructor name matching a known singleton
- `eco.construct.custom` with `size=0` for True/False/Nothing patterns
- `eco.string_literal` with empty value

**Test Cases**:
- `()` unit value
- `True`, `False` boolean literals
- `[]` empty list (Nil)
- `Nothing` from Maybe
- `""` empty string
- `{}` empty record

---

### CGEN_020: Custom ADT Construction

**Invariant**: `eco.construct.custom` is only for user-defined custom ADTs; attributes match `CtorLayout`.

**Test Function**:
```elm
expectCustomConstructionMatchesLayout : MonoGraph -> MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCustomConstruction(monoGraph, module):
    violations = []

    customOps = findOpsNamed("eco.construct.custom", module)

    FOR each op IN customOps:
        # Extract attributes
        tag = getIntAttr("tag", op)
        size = getIntAttr("size", op)
        unboxedBitmap = getIntAttr("unboxed_bitmap", op)
        constructorName = getStringAttr("constructor", op)
        operandCount = length(op.operands)

        # Validation 1: Required attributes present
        IF tag == Nothing:
            ADD violation: "eco.construct.custom missing tag attribute"
            CONTINUE
        IF size == Nothing:
            ADD violation: "eco.construct.custom missing size attribute"
            CONTINUE

        # Validation 2: size matches operand count
        IF size != operandCount:
            ADD violation:
                "eco.construct.custom size={size} but operand count={operandCount}"

        # Validation 3: unboxed_bitmap defaults to 0 if missing
        IF unboxedBitmap == Nothing:
            unboxedBitmap = 0

        # Validation 4: Cross-reference with MonoGraph.ctorLayouts (if available)
        IF constructorName != Nothing:
            layout = lookupCtorLayout(monoGraph, constructorName)
            IF layout != Nothing:
                IF layout.tag != tag:
                    ADD violation: "tag mismatch: op has {tag}, layout has {layout.tag}"
                IF layout.fieldCount != size:
                    ADD violation: "size mismatch: op has {size}, layout has {layout.fieldCount}"
                IF layout.unboxedBitmap != unboxedBitmap:
                    ADD violation: "unboxed_bitmap mismatch"

        # Validation 5: Not a built-in type (covered by CGEN_016-019)
        # This is defense in depth
        IF constructorName IN ["Cons", "Nil", "True", "False", "Nothing", "Just"]:
            # Already covered by other invariants, but double-check
            IF constructorName IN ["Cons", "Nil"]:
                ADD violation: "List constructor should use eco.construct.list"

    RETURN violations
```

**Violation Conditions**:
- Missing `tag` or `size` attributes
- `size` != operand count
- Attributes don't match `CtorLayout` from MonoGraph
- Constructor name matches built-in types

**Test Cases**:
- `Just 5` Maybe constructor
- `Ok "value"` Result constructor
- User-defined ADT with multiple constructors
- ADT with unboxed fields

---

### CGEN_021: List Projection

**Invariant**: List destructuring uses only `eco.project.list_head` and `eco.project.list_tail`.

**Test Function**:
```elm
expectListProjectionCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkListProjection(module):
    violations = []

    # Step 1: Verify list projection ops exist (informational)
    headOps = findOpsNamed("eco.project.list_head", module)
    tailOps = findOpsNamed("eco.project.list_tail", module)
    # These are valid by definition

    # Step 2: Validate head ops
    FOR each op IN headOps:
        # Should have exactly 1 operand (the list)
        IF length(op.operands) != 1:
            ADD violation: "eco.project.list_head should have exactly 1 operand"

        # Should have exactly 1 result
        IF length(op.results) != 1:
            ADD violation: "eco.project.list_head should have exactly 1 result"

    # Step 3: Validate tail ops
    FOR each op IN tailOps:
        IF length(op.operands) != 1:
            ADD violation: "eco.project.list_tail should have exactly 1 operand"

        IF length(op.results) != 1:
            ADD violation: "eco.project.list_tail should have exactly 1 result"

        # Tail always returns !eco.value (a list)
        resultType = op.results[0].type
        IF resultType != EcoValue:
            ADD violation: "eco.project.list_tail result should be !eco.value"

    # Step 3: Check eco.project.custom is not used for lists
    # This is hard to verify without type context, but we can check for
    # suspicious patterns (field_index 0 or 1 repeatedly in same region)
    customProjectOps = findOpsNamed("eco.project.custom", module)
    # Informational: these should be for custom ADTs only

    RETURN violations
```

**Violation Conditions**:
- `eco.project.list_head` with wrong operand/result count
- `eco.project.list_tail` with wrong operand/result count
- `eco.project.list_tail` result type not `!eco.value`

**Test Cases**:
- `case xs of x :: rest -> x`
- `case xs of _ :: _ :: rest -> rest`
- Nested list pattern matching

---

### CGEN_022: Tuple Projection

**Invariant**: Tuple destructuring uses `eco.project.tuple2` or `eco.project.tuple3` with valid field indices.

**Test Function**:
```elm
expectTupleProjectionCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkTupleProjection(module):
    violations = []

    # Step 1: Check eco.project.tuple2 ops
    tuple2Ops = findOpsNamed("eco.project.tuple2", module)
    FOR each op IN tuple2Ops:
        field = getIntAttr("field", op)

        IF field == Nothing:
            ADD violation: "eco.project.tuple2 missing field attribute"
        ELIF field < 0 OR field > 1:
            ADD violation: "eco.project.tuple2 field={field} out of range [0,1]"

        IF length(op.operands) != 1:
            ADD violation: "eco.project.tuple2 should have exactly 1 operand"

        IF length(op.results) != 1:
            ADD violation: "eco.project.tuple2 should have exactly 1 result"

    # Step 2: Check eco.project.tuple3 ops
    tuple3Ops = findOpsNamed("eco.project.tuple3", module)
    FOR each op IN tuple3Ops:
        field = getIntAttr("field", op)

        IF field == Nothing:
            ADD violation: "eco.project.tuple3 missing field attribute"
        ELIF field < 0 OR field > 2:
            ADD violation: "eco.project.tuple3 field={field} out of range [0,2]"

        IF length(op.operands) != 1:
            ADD violation: "eco.project.tuple3 should have exactly 1 operand"

        IF length(op.results) != 1:
            ADD violation: "eco.project.tuple3 should have exactly 1 result"

    RETURN violations
```

**Violation Conditions**:
- Missing `field` attribute
- `field` out of valid range (0-1 for tuple2, 0-2 for tuple3)
- Wrong operand or result count

**Test Cases**:
- `Tuple.first (a, b)`
- `Tuple.second (a, b)`
- `case (a, b, c) of (x, y, z) -> ...`
- Let destructuring `let (a, b) = tuple in ...`

---

### CGEN_023: Record Projection

**Invariant**: Record field access uses `eco.project.record` with valid field index.

**Test Function**:
```elm
expectRecordProjectionCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkRecordProjection(module):
    violations = []

    recordProjectOps = findOpsNamed("eco.project.record", module)

    FOR each op IN recordProjectOps:
        fieldIndex = getIntAttr("field_index", op)

        IF fieldIndex == Nothing:
            ADD violation: "eco.project.record missing field_index attribute"
        ELIF fieldIndex < 0:
            ADD violation: "eco.project.record field_index={index} is negative"

        IF length(op.operands) != 1:
            ADD violation: "eco.project.record should have exactly 1 operand"

        IF length(op.results) != 1:
            ADD violation: "eco.project.record should have exactly 1 result"

    RETURN violations
```

**Violation Conditions**:
- Missing `field_index` attribute
- Negative `field_index`
- Wrong operand or result count

**Test Cases**:
- `record.field` access
- `let { x, y } = record in ...`
- Accessor function `.field` applied to record

---

### CGEN_024: Custom ADT Projection

**Invariant**: Custom ADT field access uses `eco.project.custom` with valid field index.

**Test Function**:
```elm
expectCustomProjectionCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCustomProjection(module):
    violations = []

    customProjectOps = findOpsNamed("eco.project.custom", module)

    FOR each op IN customProjectOps:
        fieldIndex = getIntAttr("field_index", op)

        IF fieldIndex == Nothing:
            ADD violation: "eco.project.custom missing field_index attribute"
        ELIF fieldIndex < 0:
            ADD violation: "eco.project.custom field_index={index} is negative"

        IF length(op.operands) != 1:
            ADD violation: "eco.project.custom should have exactly 1 operand"

        IF length(op.results) != 1:
            ADD violation: "eco.project.custom should have exactly 1 result"

    RETURN violations
```

**Violation Conditions**:
- Missing `field_index` attribute
- Negative `field_index`
- Wrong operand or result count

**Test Cases**:
- `case maybe of Just x -> x`
- `case result of Ok v -> v | Err e -> ...`
- User-defined ADT pattern matching

---

### CGEN_025: Construct Result Types

**Invariant**: All `eco.construct.*` ops produce `!eco.value` result type.

**Test Function**:
```elm
expectConstructResultsEcoValue : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkConstructResultTypes(module):
    violations = []

    # Find all construction ops
    constructOps = findOpsWithPrefix("eco.construct.", module)

    FOR each op IN constructOps:
        # Every construct op should have exactly 1 result
        IF length(op.results) != 1:
            ADD violation: "{op.name} should have exactly 1 result, has {count}"
            CONTINUE

        (resultName, resultType) = op.results[0]

        # Result type must be !eco.value
        IF NOT isEcoValueType(resultType):
            ADD violation:
                "{op.name} result type should be !eco.value, got {resultType}"

    RETURN violations
```

**Violation Conditions**:
- `eco.construct.*` op with result count != 1
- `eco.construct.*` op with result type not `!eco.value`

**Test Cases**:
- All construction operations from other invariant tests
- Verify homogeneous result type

---

### CGEN_026: Unboxed Bitmap Consistency (Containers)

**Invariant**: For container construct ops, bit N of `unboxed_bitmap` is set iff operand N is a primitive type.

**Test Function**:
```elm
expectUnboxedBitmapMatchesOperands : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkUnboxedBitmap(module):
    violations = []

    # Ops with unboxed_bitmap: tuple2, tuple3, record, custom
    targetOps = []
    targetOps.addAll(findOpsNamed("eco.construct.tuple2", module))
    targetOps.addAll(findOpsNamed("eco.construct.tuple3", module))
    targetOps.addAll(findOpsNamed("eco.construct.record", module))
    targetOps.addAll(findOpsNamed("eco.construct.custom", module))

    FOR each op IN targetOps:
        unboxedBitmap = getIntAttr("unboxed_bitmap", op)
        IF unboxedBitmap == Nothing:
            unboxedBitmap = 0  # Default

        operandTypes = extractOperandTypes(op)
        IF operandTypes == Nothing:
            # Can't verify without _operand_types
            ADD warning: "{op.name} missing _operand_types, cannot verify bitmap"
            CONTINUE

        FOR i IN 0..length(operandTypes)-1:
            bitIsSet = (unboxedBitmap AND (1 << i)) != 0
            typeIsPrimitive = isPrimitiveType(operandTypes[i])

            IF bitIsSet AND NOT typeIsPrimitive:
                ADD violation:
                    "unboxed_bitmap bit {i} is set but operand type is {type}, expected primitive"

            IF NOT bitIsSet AND typeIsPrimitive:
                ADD violation:
                    "unboxed_bitmap bit {i} is clear but operand type is {type}, expected !eco.value"

    RETURN violations
```

**Violation Conditions**:
- Bitmap bit N set but operand N type is `!eco.value`
- Bitmap bit N clear but operand N type is primitive (i64, f64, i1, i16)
- Missing `_operand_types` attribute (warning, not failure)

**Test Cases**:
- Record with `Int` field (unboxed)
- Record with `String` field (boxed)
- Tuple with mixed types `(Int, String)`
- Custom ADT with unboxed fields

---

### CGEN_027: List Head Unboxed Flag

**Invariant**: For `eco.construct.list`, `head_unboxed` is true iff head operand is primitive.

**Test Function**:
```elm
expectListHeadUnboxedCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkListHeadUnboxed(module):
    violations = []

    listOps = findOpsNamed("eco.construct.list", module)

    FOR each op IN listOps:
        headUnboxed = getBoolAttr("head_unboxed", op)
        IF headUnboxed == Nothing:
            headUnboxed = False  # Default

        operandTypes = extractOperandTypes(op)
        IF operandTypes == Nothing OR length(operandTypes) < 1:
            ADD warning: "{op.name} missing _operand_types for head"
            CONTINUE

        # First operand is head, second is tail
        headType = operandTypes[0]
        headIsPrimitive = isPrimitiveType(headType)

        IF headUnboxed AND NOT headIsPrimitive:
            ADD violation:
                "head_unboxed=true but head type is {type}, expected primitive"

        IF NOT headUnboxed AND headIsPrimitive:
            ADD violation:
                "head_unboxed=false but head type is {type}, expected !eco.value"

    RETURN violations
```

**Violation Conditions**:
- `head_unboxed=true` but head operand type is `!eco.value`
- `head_unboxed=false` but head operand type is primitive

**Test Cases**:
- `[1, 2, 3]` list of Int (unboxed heads)
- `["a", "b"]` list of String (boxed heads)
- `[(1, 2)]` list of tuples (boxed heads)

---

### CGEN_028: Case Alternative Termination

**Invariant**: Every `eco.case` alternative region terminates with `eco.return` or `eco.jump`.

**Test Function**:
```elm
expectCaseAlternativesTerminate : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCaseTermination(module):
    violations = []
    VALID_TERMINATORS = ["eco.return", "eco.jump", "eco.crash"]

    caseOps = findOpsNamed("eco.case", module)

    FOR each caseOp IN caseOps:
        FOR i, region IN enumerate(caseOp.regions):
            violations.addAll(checkRegionTermination(region, i, caseOp.id))

    RETURN violations

FUNCTION checkRegionTermination(region, branchIndex, parentId):
    violations = []
    MlirRegion { entry, blocks } = region

    # Check entry block terminator
    IF entry.terminator.name NOT IN VALID_TERMINATORS:
        ADD violation:
            opId = parentId
            message = "eco.case branch {branchIndex} entry block terminates with {name}, expected eco.return or eco.jump"

    # Check all additional blocks
    FOR blockName, block IN blocks:
        IF block.terminator.name NOT IN VALID_TERMINATORS:
            ADD violation:
                message = "eco.case branch {branchIndex} block {blockName} terminates with {name}"

        # Recursively check nested ops in block body for nested eco.case
        FOR op IN block.body:
            IF op.name == "eco.case":
                FOR j, nestedRegion IN enumerate(op.regions):
                    violations.addAll(checkRegionTermination(nestedRegion, j, op.id))

    RETURN violations
```

**Violation Conditions**:
- Block terminator is not `eco.return`, `eco.jump`, or `eco.crash`
- Applies recursively to nested regions

**Test Cases**:
- Simple `case x of True -> ... | False -> ...`
- Case with shared joinpoint `eco.jump`
- Nested case expressions
- Case with crash branch

---

### CGEN_029: Case Tags Count

**Invariant**: `eco.case` `tags` array length equals the number of alternative regions.

**Test Function**:
```elm
expectCaseTagsMatchRegions : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCaseTagsCount(module):
    violations = []

    caseOps = findOpsNamed("eco.case", module)

    FOR each op IN caseOps:
        tagsAttr = getArrayAttr("tags", op)

        IF tagsAttr == Nothing:
            ADD violation: "eco.case missing tags attribute"
            CONTINUE

        tagCount = length(tagsAttr)
        regionCount = length(op.regions)

        IF tagCount != regionCount:
            ADD violation:
                "eco.case tags count ({tagCount}) != region count ({regionCount})"

    RETURN violations
```

**Violation Conditions**:
- Missing `tags` attribute
- `tags` array length != number of regions

**Test Cases**:
- Boolean case (2 tags, 2 regions)
- Maybe case (2 tags: Nothing=0, Just=1)
- Large ADT case (many tags)

---

### CGEN_030: Jump Target Validity

**Invariant**: `eco.jump` target refers to a lexically enclosing `eco.joinpoint` with matching id, and argument types match.

**Test Function**:
```elm
expectJumpTargetsValid : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkJumpTargets(module):
    violations = []

    funcOps = findFuncOps(module)

    FOR each funcOp IN funcOps:
        # Collect all joinpoints in this function
        joinpointMap = {}  # id -> (MlirOp, blockArgTypes)
        collectJoinpoints(funcOp, joinpointMap)

        # Find all jumps and verify targets
        jumps = findJumpsInOp(funcOp)
        FOR each jumpOp IN jumps:
            targetId = getIntAttr("target", jumpOp)

            IF targetId == Nothing:
                ADD violation: "eco.jump missing target attribute"
                CONTINUE

            IF targetId NOT IN joinpointMap:
                ADD violation:
                    "eco.jump target {targetId} not found in enclosing joinpoints"
                CONTINUE

            # Verify argument count matches
            (joinpointOp, expectedArgTypes) = joinpointMap[targetId]
            jumpArgCount = length(jumpOp.operands)
            expectedArgCount = length(expectedArgTypes)

            IF jumpArgCount != expectedArgCount:
                ADD violation:
                    "eco.jump has {jumpArgCount} args but joinpoint {targetId} expects {expectedArgCount}"

    RETURN violations

FUNCTION collectJoinpoints(op, map):
    IF op.name == "eco.joinpoint":
        id = getIntAttr("id", op)
        # Get block args from body region entry
        IF length(op.regions) > 0:
            MlirRegion { entry, _ } = op.regions[0]
            argTypes = entry.args  # List of (name, type)
            map[id] = (op, argTypes)

    FOR region IN op.regions:
        FOR block IN allBlocks(region):
            FOR bodyOp IN block.body:
                collectJoinpoints(bodyOp, map)
            collectJoinpoints(block.terminator, map)
```

**Violation Conditions**:
- Missing `target` attribute on `eco.jump`
- Target ID not found in enclosing function's joinpoints
- Jump argument count doesn't match joinpoint parameter count

**Test Cases**:
- Tail-recursive function with single joinpoint
- Function with multiple joinpoints
- Nested joinpoints

---

### CGEN_031: Joinpoint ID Uniqueness

**Invariant**: Within a single `func.func`, each `eco.joinpoint` id is unique.

**Test Function**:
```elm
expectJoinpointIdsUnique : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkJoinpointUniqueness(module):
    violations = []

    funcOps = findFuncOps(module)

    FOR each funcOp IN funcOps:
        funcName = getStringAttr("sym_name", funcOp)
        seenIds = {}  # id -> first occurrence opId

        joinpoints = findJoinpointsInOp(funcOp)
        FOR each jpOp IN joinpoints:
            id = getIntAttr("id", jpOp)

            IF id == Nothing:
                ADD violation: "eco.joinpoint missing id attribute"
                CONTINUE

            IF id IN seenIds:
                ADD violation:
                    "Duplicate joinpoint id {id} in function {funcName}, first at {seenIds[id]}"
            ELSE:
                seenIds[id] = jpOp.id

    RETURN violations

FUNCTION findJoinpointsInOp(op):
    result = []
    IF op.name == "eco.joinpoint":
        result.add(op)
    FOR region IN op.regions:
        FOR block IN allBlocks(region):
            FOR bodyOp IN block.body:
                result.addAll(findJoinpointsInOp(bodyOp))
            result.addAll(findJoinpointsInOp(block.terminator))
    RETURN result
```

**Violation Conditions**:
- Missing `id` attribute on `eco.joinpoint`
- Duplicate `id` within same function

**Test Cases**:
- Function with multiple distinct joinpoints
- Nested case expressions each generating joinpoints

---

### CGEN_032: Operand Types Attribute

**Invariant**: `_operand_types` is required when op has operands and must have correct length.

**Test Function**:
```elm
expectOperandTypesCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkOperandTypesAttr(module):
    violations = []

    # Ops that should have _operand_types when they have operands
    REQUIRED_OPS = [
        "eco.construct.list",
        "eco.construct.tuple2",
        "eco.construct.tuple3",
        "eco.construct.record",
        "eco.construct.custom",
        "eco.call",
        "eco.papCreate",
        "eco.papExtend",
        "eco.return",
        "eco.box",
        "eco.unbox"
    ]

    allOps = walkAllOps(module)

    FOR each op IN allOps:
        IF op.name NOT IN REQUIRED_OPS:
            CONTINUE

        operandCount = length(op.operands)

        IF operandCount == 0:
            # No operands, attribute not required
            CONTINUE

        operandTypes = getArrayAttr("_operand_types", op)

        IF operandTypes == Nothing:
            ADD violation:
                "{op.name} has {operandCount} operands but missing _operand_types"
            CONTINUE

        typeCount = length(operandTypes)
        IF typeCount != operandCount:
            ADD violation:
                "{op.name} has {operandCount} operands but _operand_types has {typeCount} entries"

    RETURN violations
```

**Violation Conditions**:
- Op has operands but missing `_operand_types`
- `_operand_types` length != operand count

**Test Cases**:
- Construction ops with varying operand counts
- Call ops
- Return ops with values

---

### CGEN_033: PapCreate Arity Constraints

**Invariant**: `eco.papCreate` requires `arity > 0`, `num_captured == operand count`, `num_captured < arity`.

**Test Function**:
```elm
expectPapCreateArityValid : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkPapCreateArity(module):
    violations = []

    papCreateOps = findOpsNamed("eco.papCreate", module)

    FOR each op IN papCreateOps:
        arity = getIntAttr("arity", op)
        numCaptured = getIntAttr("num_captured", op)
        operandCount = length(op.operands)

        # Check required attributes
        IF arity == Nothing:
            ADD violation: "eco.papCreate missing arity attribute"
            CONTINUE
        IF numCaptured == Nothing:
            ADD violation: "eco.papCreate missing num_captured attribute"
            CONTINUE

        # Check arity > 0
        IF arity <= 0:
            ADD violation: "eco.papCreate arity must be > 0, got {arity}"

        # Check num_captured == operand count
        IF numCaptured != operandCount:
            ADD violation:
                "eco.papCreate num_captured={numCaptured} but operand count={operandCount}"

        # Check num_captured < arity (partial application must leave room)
        IF numCaptured >= arity:
            ADD violation:
                "eco.papCreate num_captured={numCaptured} >= arity={arity}, not a valid partial application"

        # Check function attribute exists
        funcAttr = getStringAttr("function", op)
        IF funcAttr == Nothing:
            ADD violation: "eco.papCreate missing function attribute"

    RETURN violations
```

**Violation Conditions**:
- Missing `arity`, `num_captured`, or `function` attribute
- `arity <= 0`
- `num_captured != operandCount`
- `num_captured >= arity`

**Test Cases**:
- `(+) 1` partial application (arity=2, num_captured=1)
- `List.map f` partial application
- Function reference without arguments (arity=n, num_captured=0)

---

### CGEN_034: PapExtend Result Type

**Invariant**: `eco.papExtend` produces `!eco.value` result.

**Test Function**:
```elm
expectPapExtendResultEcoValue : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkPapExtendResult(module):
    violations = []

    papExtendOps = findOpsNamed("eco.papExtend", module)

    FOR each op IN papExtendOps:
        IF length(op.results) != 1:
            ADD violation: "eco.papExtend should have exactly 1 result"
            CONTINUE

        (resultName, resultType) = op.results[0]

        IF NOT isEcoValueType(resultType):
            ADD violation:
                "eco.papExtend result should be !eco.value, got {resultType}"

        # Check remaining_arity attribute exists
        remainingArity = getIntAttr("remaining_arity", op)
        IF remainingArity == Nothing:
            ADD violation: "eco.papExtend missing remaining_arity attribute"

    RETURN violations
```

**Violation Conditions**:
- Result count != 1
- Result type not `!eco.value`
- Missing `remaining_arity` attribute

**Test Cases**:
- Closure application `f x`
- Saturated closure call
- Chained application `f x y`

---

### CGEN_035: Type Table Uniqueness

**Invariant**: Each module has at most one `eco.type_table` op at module scope.

**Test Function**:
```elm
expectSingleTypeTable : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkTypeTableUniqueness(module):
    violations = []

    # Only check top-level ops (module.body), not nested
    typeTableOps = FILTER module.body WHERE op.name == "eco.type_table"

    IF length(typeTableOps) > 1:
        ADD violation:
            "Module has {count} eco.type_table ops, expected at most 1"

    RETURN violations
```

**Violation Conditions**:
- More than one `eco.type_table` at module scope

**Test Cases**:
- Module with debug logging (has type table)
- Module without debug (may not have type table)

---

### CGEN_036: Dbg Type IDs Valid

**Invariant**: When `eco.dbg` has `arg_type_ids`, each ID references a valid type table entry.

**Test Function**:
```elm
expectDbgTypeIdsValid : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkDbgTypeIds(module):
    violations = []

    # Find type table
    typeTableOps = FILTER module.body WHERE op.name == "eco.type_table"

    maxTypeId = -1
    IF length(typeTableOps) > 0:
        typeTable = typeTableOps[0]
        typesAttr = getArrayAttr("types", typeTable)
        IF typesAttr != Nothing:
            maxTypeId = length(typesAttr) - 1

    # Find all eco.dbg ops with arg_type_ids
    dbgOps = findOpsNamed("eco.dbg", module)

    FOR each op IN dbgOps:
        typeIdsAttr = getArrayAttr("arg_type_ids", op)
        IF typeIdsAttr == Nothing:
            CONTINUE  # No type IDs, OK

        IF maxTypeId < 0:
            ADD violation:
                "eco.dbg has arg_type_ids but no eco.type_table in module"
            CONTINUE

        FOR i, idAttr IN enumerate(typeIdsAttr):
            typeId = extractInt(idAttr)
            IF typeId == Nothing:
                ADD violation: "eco.dbg arg_type_ids[{i}] is not an integer"
            ELIF typeId < 0 OR typeId > maxTypeId:
                ADD violation:
                    "eco.dbg arg_type_ids[{i}]={typeId} out of range [0,{maxTypeId}]"

    RETURN violations
```

**Violation Conditions**:
- `eco.dbg` has `arg_type_ids` but no `eco.type_table` exists
- Type ID is negative or exceeds type table size
- Type ID is not an integer

**Test Cases**:
- `Debug.log "msg" value`
- `Debug.toString value`
- Multiple debug calls with different types

---

### CGEN_037: Case Scrutinee Type Agreement

**Invariant**: `eco.case` scrutinee is `i1` only for boolean cases; otherwise `!eco.value`.

**Test Function**:
```elm
expectCaseScrutineeTypeCorrect : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkCaseScrutineeType(module):
    violations = []

    caseOps = findOpsNamed("eco.case", module)

    FOR each op IN caseOps:
        # Get scrutinee type from _operand_types (first operand)
        operandTypes = extractOperandTypes(op)
        IF operandTypes == Nothing OR length(operandTypes) < 1:
            ADD warning: "eco.case missing scrutinee type info"
            CONTINUE

        scrutineeType = operandTypes[0]
        caseKind = getStringAttr("case_kind", op)
        tags = getArrayAttr("tags", op)

        # Determine if this is a boolean case
        isBooleanCase = False
        IF caseKind == "ctor":
            isBooleanCase = False  # ADT case
        ELIF scrutineeType == I1:
            isBooleanCase = True
        ELIF tags != Nothing AND length(tags) == 2:
            # Could be boolean if tags are [0, 1] and scrutinee is i1
            tag0 = extractInt(tags[0])
            tag1 = extractInt(tags[1])
            IF (tag0 == 0 AND tag1 == 1) OR (tag0 == 1 AND tag1 == 0):
                IF scrutineeType == I1:
                    isBooleanCase = True

        # Validate type matches case kind
        IF isBooleanCase:
            IF scrutineeType != I1:
                ADD violation:
                    "Boolean case should have i1 scrutinee, got {scrutineeType}"
        ELSE:
            IF scrutineeType != EcoValue:
                ADD violation:
                    "Non-boolean case should have !eco.value scrutinee, got {scrutineeType}"

        # If case_kind is specified, validate consistency
        IF caseKind != Nothing:
            IF caseKind IN ["ctor", "int", "chr", "str"]:
                IF scrutineeType != EcoValue:
                    ADD violation:
                        "case_kind={caseKind} requires !eco.value scrutinee"

    RETURN violations
```

**Violation Conditions**:
- Boolean case with scrutinee type != `i1`
- Non-boolean case with scrutinee type != `!eco.value`
- `case_kind` attribute inconsistent with scrutinee type

**Test Cases**:
- `if cond then ... else ...` (boolean, i1)
- `case maybe of ...` (ADT, !eco.value)
- `case intValue of 0 -> ... | 1 -> ...` (int pattern)

---

### CGEN_038: Kernel ABI Consistency

**Invariant**: All calls to the same kernel function use identical MLIR argument and result types.

**Test Function**:
```elm
expectKernelAbiConsistent : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkKernelAbiConsistency(module):
    violations = []

    # Find all eco.call ops with callee attribute (direct calls)
    callOps = findOpsNamed("eco.call", module)

    # Group calls by callee name
    callsByCallee = {}  # callee -> List of (opId, argTypes, resultTypes)

    FOR each op IN callOps:
        callee = getStringAttr("callee", op)
        IF callee == Nothing:
            CONTINUE  # Indirect call

        # Only check kernel functions (identified by naming convention)
        IF NOT isKernelFunction(callee):
            CONTINUE

        argTypes = extractOperandTypes(op)
        resultTypes = [t for (_, t) in op.results]

        signature = (argTypes, resultTypes)

        IF callee NOT IN callsByCallee:
            callsByCallee[callee] = []
        callsByCallee[callee].add((op.id, signature))

    # Check consistency within each group
    FOR callee, calls IN callsByCallee:
        IF length(calls) <= 1:
            CONTINUE  # Only one call, trivially consistent

        (firstOpId, firstSig) = calls[0]
        (firstArgTypes, firstResultTypes) = firstSig

        FOR i IN 1..length(calls)-1:
            (opId, sig) = calls[i]
            (argTypes, resultTypes) = sig

            IF argTypes != firstArgTypes:
                ADD violation:
                    "Kernel {callee} call {opId} has different arg types than {firstOpId}"

            IF resultTypes != firstResultTypes:
                ADD violation:
                    "Kernel {callee} call {opId} has different result types than {firstOpId}"

    RETURN violations

FUNCTION isKernelFunction(name):
    # Kernel functions have specific naming patterns
    RETURN name starts with "eco_"
        OR name contains "$kernel$"
        OR name in KNOWN_KERNEL_FUNCTIONS
```

**Violation Conditions**:
- Same kernel function called with different argument types
- Same kernel function called with different result types

**Test Cases**:
- Multiple `(+)` calls on Int
- Mixed numeric operations
- String operations

---

### CGEN_039: No Allocate Ops in Codegen

**Invariant**: MLIR codegen does not emit `eco.allocate*` ops; these are introduced by later lowering.

**Test Function**:
```elm
expectNoAllocateOps : MlirModule -> Expect.Expectation
```

**Detailed Logic**:

```
ALGORITHM checkNoAllocateOps(module):
    violations = []

    ALLOCATE_OPS = [
        "eco.allocate",
        "eco.allocate_ctor",
        "eco.allocate_string",
        "eco.allocate_closure"
    ]

    allOps = walkAllOps(module)

    FOR each op IN allOps:
        IF op.name IN ALLOCATE_OPS:
            ADD violation:
                "Found {op.name} in codegen output; allocation ops should only be introduced by lowering"

    RETURN violations
```

**Violation Conditions**:
- Any `eco.allocate*` op present in codegen output

**Test Cases**:
- Any compiled module should pass
- Verify construction ops are used instead

---

## Implementation Priority

### Phase 1: Core Type-Specific Invariants (High Priority)
1. CGEN_016: ListConstructionTest
2. CGEN_017: TupleConstructionTest
3. CGEN_018: RecordConstructionTest
4. CGEN_019: SingletonConstantsTest
5. CGEN_020: CustomConstructionTest
6. CGEN_025: ConstructResultTypeTest
7. CGEN_015: CharTypeMappingTest

### Phase 2: Projection Invariants (High Priority)
8. CGEN_021: ListProjectionTest
9. CGEN_022: TupleProjectionTest
10. CGEN_023: RecordProjectionTest
11. CGEN_024: CustomProjectionTest

### Phase 3: Control Flow Invariants (High Priority)
12. CGEN_028: CaseTerminationTest
13. CGEN_029: CaseTagsCountTest
14. CGEN_030: JumpTargetTest
15. CGEN_031: JoinpointUniqueIdTest

### Phase 4: Attribute Consistency (Medium Priority)
16. CGEN_026 + CGEN_027: UnboxedBitmapTest
17. CGEN_032: OperandTypesAttrTest
18. CGEN_037: CaseScrutineeTypeTest

### Phase 5: Closure Invariants (Medium Priority)
19. CGEN_033: PapCreateArityTest
20. CGEN_034: PapExtendResultTest

### Phase 6: Module-Level Invariants (Lower Priority)
21. CGEN_035: TypeTableUniquenessTest
22. CGEN_036: DbgTypeIdsTest
23. CGEN_038: KernelAbiConsistencyTest
24. CGEN_039: NoAllocateOpsTest

---

## Testing Approach

### Property-Based Testing
Most invariants can use property-based testing:
- Generate random Elm source programs
- Compile through monomorphization
- Run MLIR codegen
- Verify invariants on resulting `MlirModule`

### Unit Testing
Some invariants need specific test cases:
- CGEN_015: Character operations
- CGEN_019: Specific singleton values
- CGEN_037: Boolean vs ADT case distinction

### Integration Testing
Some invariants require end-to-end verification:
- CGEN_038: Multiple calls to same kernel (requires larger programs)
- CGEN_030/031: Joinpoint handling (requires tail-recursive programs)

---

## Test Infrastructure Requirements

1. **MlirModule access**: Codegen already returns `MlirModule` before serialization
2. **Test harness**: Function `compileToMlir : String -> Result Error MlirModule`
3. **MonoGraph access**: CGEN_020 needs both `MonoGraph` and `MlirModule` for cross-reference

---

## Dependencies

- `Mlir.Mlir` module for AST types
- `Compiler.Generate.MLIR.*` for codegen
- `Compiler.AST.Monomorphized` for `MonoGraph`
- Test framework (`Test`, `Expect`)
- Property-based testing (`Fuzz`)
