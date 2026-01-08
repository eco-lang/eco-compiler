# ResultTypesInference Pass

## Overview

The ResultTypesInference pass analyzes `eco.case` operations and infers their `result_types` attribute from the types of values returned by `eco.return` operations within each alternative. This enables downstream SCF lowering patterns to work without requiring explicit result type annotations in the source IR.

**File**: `runtime/src/codegen/Passes/ResultTypesInference.cpp`

## Pseudocode

```
FUNCTION runOnOperation(module):
    FOR EACH caseOp IN module:
        // Skip if already has result_types
        IF caseOp.getCaseResultTypes() IS NOT NULL:
            CONTINUE

        alternatives = caseOp.getAlternatives()
        IF alternatives.empty():
            CONTINUE

        // Get types from first alternative
        firstTypes = getReturnTypes(alternatives[0])
        IF firstTypes IS NULL:
            CONTINUE  // Not a pure-return case

        // Check all other alternatives have same types
        typesMatch = true
        FOR i = 1 TO alternatives.size() - 1:
            altTypes = getReturnTypes(alternatives[i])
            IF altTypes IS NULL OR NOT typesEqual(firstTypes, altTypes):
                typesMatch = false
                BREAK

        IF typesMatch:
            // Set result_types attribute
            typeAttrs = []
            FOR EACH type IN firstTypes:
                typeAttrs.append(TypeAttr::get(type))
            caseOp.setAttr("result_types", ArrayAttr::get(typeAttrs))

FUNCTION getReturnTypes(region):
    IF region.empty() OR region.front().empty():
        RETURN NULL

    terminator = region.front().getTerminator()
    IF terminator IS NOT eco.return:
        RETURN NULL

    types = []
    FOR EACH operand IN terminator.operands:
        types.append(operand.getType())
    RETURN types

FUNCTION typesEqual(a, b):
    IF a.size() != b.size():
        RETURN false
    FOR i = 0 TO a.size() - 1:
        IF a[i] != b[i]:
            RETURN false
    RETURN true
```

## Purpose

The `result_types` attribute is required by SCF lowering patterns (`scf.if`, `scf.index_switch`) because SCF operations produce SSA results. Without explicit result types:

1. The SCF operations cannot be created (they require result types at construction)
2. Values flowing out of case branches cannot be properly typed

## Pre-conditions

1. Input module contains valid ECO dialect IR
2. `eco.case` operations have well-formed alternative regions
3. Each alternative region, if non-empty, has exactly one block
4. Alternative blocks have valid terminators

## Post-conditions

1. All `eco.case` operations where:
   - All alternatives terminate with `eco.return`
   - All alternatives have identical return types

   Will have the `result_types` attribute set

2. `eco.case` operations that don't meet these criteria remain unchanged:
   - Mixed terminators (some return, some jump)
   - Type mismatches between alternatives
   - Empty alternatives

3. Already-annotated case operations are left unchanged

## Invariants

1. **Type Consistency**: If `result_types` is set, ALL alternatives have matching types
2. **Idempotence**: Running the pass multiple times produces identical results
3. **Non-Destructive**: Pass never removes existing `result_types` attributes
4. **Conservative**: Only sets attribute when ALL alternatives agree on types

## Example Transformation

**Before:**
```mlir
eco.case %scrutinee [0, 1] {
    %a = eco.project %scrutinee[0] : !eco.value
    eco.return %a : !eco.value
}, {
    %b = eco.project %scrutinee[1] : !eco.value
    eco.return %b : !eco.value
}
```

**After:**
```mlir
eco.case %scrutinee [0, 1] result_types [!eco.value] {
    %a = eco.project %scrutinee[0] : !eco.value
    eco.return %a : !eco.value
}, {
    %b = eco.project %scrutinee[1] : !eco.value
    eco.return %b : !eco.value
}
```

## Cases NOT Handled

1. **Mixed terminators** - Some alternatives use `eco.jump`, others use `eco.return`:
   ```mlir
   eco.case %x [0, 1] {
       eco.return %a : !eco.value  // return
   }, {
       eco.jump id(%b)             // jump - NOT a pure-return case
   }
   ```

2. **Type mismatch** - Alternatives return different types:
   ```mlir
   eco.case %x [0, 1] {
       eco.return %a : i64         // i64
   }, {
       eco.return %b : f64         // f64 - types don't match
   }
   ```

3. **Void returns** - Alternatives with zero return values produce empty `result_types`:
   ```mlir
   eco.case %x [0, 1] result_types [] {
       eco.return
   }, {
       eco.return
   }
   ```

## Relationship to Other Passes

- **Should Run Before**: `EcoControlFlowToSCF` (which requires `result_types` to create SCF ops)
- **Does Not Affect**: `EcoToLLVM` (which handles case ops without `result_types`)

## Attribute Format

The `result_types` attribute is an `ArrayAttr` of `TypeAttr`:

```mlir
result_types [!eco.value]          // Single value
result_types [i64, f64]            // Multiple values
result_types []                    // Void (no return values)
```
