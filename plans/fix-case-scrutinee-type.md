# Plan: Fix Case Scrutinee Type Mismatch

## Problem Summary

In `generateFanOutGeneral`, the scrutinee type is always set to `Types.ecoValue` (boxed), but when `case_kind` is `"int"` or `"chr"`, the MLIR dialect expects primitive types (`i64` or `i16` respectively).

**Error patterns:**
```
case_kind='int' requires i64 scrutinee, got eco.value
_operand_types declares eco.value but SSA type is i64
```

**Affected tests:** 34 failures (19 in CaseKindScrutineeTest + 15 in OperandTypeConsistencyTest)

## Root Cause

`generateFanOutGeneral` (Expr.elm:2154-2224) does:

1. Calls `generateDTPath` with `Types.ecoValue` (always boxed)
2. Computes `caseKind` from the first test (correctly returns "int"/"chr")
3. Calls `Ops.ecoCase` with `Types.ecoValue` as scrutinee type

The mismatch: `caseKind="int"` but `scrutineeType=eco.value`.

## Solution

### Step 1: Add `scrutineeTypeFromCaseKind` helper to Patterns.elm

**Location:** After `caseKindFromTest` (around line 526)

```elm
{-| Get the MLIR type for the scrutinee based on case_kind.

Int cases need i64 scrutinee, Char cases need i16, all others use eco.value.
-}
scrutineeTypeFromCaseKind : String -> MlirType
scrutineeTypeFromCaseKind caseKind =
    case caseKind of
        "int" ->
            I64

        "chr" ->
            Types.ecoChar

        "str" ->
            Types.ecoValue

        -- "ctor" and anything else: boxed ADTs
        _ ->
            Types.ecoValue
```

### Step 2: Update `generateFanOutGeneral` in Expr.elm

**Key change:** Compute `caseKind` FIRST, then derive `scrutineeType` from it.

**Current code:**
```elm
generateFanOutGeneral ctx root path edges fallback resultTy =
    let
        -- For ADT patterns, use !eco.value scrutinee (boxed heap pointer)
        -- The runtime extracts the tag from the boxed value
        ( pathOps, scrutineeVar, ctx1 ) =
            Patterns.generateDTPath ctx root path Types.ecoValue

        -- Collect tags from edges
        edgeTags =
            List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

        -- Compute the fallback tag (for the fallback region)
        edgeTests =
            List.map Tuple.first edges

        fallbackTag =
            Patterns.computeFallbackTag edgeTests

        -- Determine case kind from the first edge test
        caseKind =
            case edgeTests of
                firstTest :: _ ->
                    Patterns.caseKindFromTest firstTest

                [] ->
                    "ctor"

        ...

        -- eco.case always uses !eco.value for scrutinee
        -- Pass caseKind to inform runtime how to handle matching
        ( ctx3, caseOp ) =
            Ops.ecoCase ctx2a scrutineeVar Types.ecoValue caseKind tags allRegions [ resultTy ]
```

**New code:**
```elm
generateFanOutGeneral ctx root path edges fallback resultTy =
    let
        -- Collect edge tests for tag computation
        edgeTests =
            List.map Tuple.first edges

        -- Determine case kind from the first edge test
        caseKind =
            case edgeTests of
                firstTest :: _ ->
                    Patterns.caseKindFromTest firstTest

                [] ->
                    "ctor"

        -- Derive scrutinee type from case_kind:
        -- "int" -> i64, "chr" -> i16, others -> eco.value
        scrutineeType =
            Patterns.scrutineeTypeFromCaseKind caseKind

        -- Generate path to scrutinee with correct type
        -- If root is boxed but we need primitive, generateDTPath emits eco.unbox
        ( pathOps, scrutineeVar, ctx1 ) =
            Patterns.generateDTPath ctx root path scrutineeType

        -- Collect tags from edges
        edgeTags =
            List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

        -- Compute the fallback tag (for the fallback region)
        fallbackTag =
            Patterns.computeFallbackTag edgeTests

        ...

        -- Build eco.case with correct scrutinee type
        -- _operand_types will now match the actual SSA type
        ( ctx3, caseOp ) =
            Ops.ecoCase ctx2a scrutineeVar scrutineeType caseKind tags allRegions [ resultTy ]
```

### Step 3: Export the new function from Patterns.elm

Add `scrutineeTypeFromCaseKind` to the module exports.

## How This Fixes the Issue

**Key properties of the fix:**

1. For `"int"` and `"chr"` cases, `scrutineeType` is primitive (`i64` / `ecoChar`)

2. `Patterns.generateDTPath` will:
   - If the root is boxed `!eco.value`, emit a single `eco.unbox` and update the context mapping to the primitive type
   - If the root is already unboxed `i64`/`i16`, just pass it through

3. `_operand_types` inside `ecoCase` will now match the actual SSA type of the scrutinee, because it's driven by the `scrutineeType` parameter in `ecoCase`'s builder

**This fixes:**
- `"case_kind='int' requires i64 scrutinee, got eco.value"`
- `"operand 0 declares eco.value but SSA type is i64/i16"`
- Corresponding E2E type mismatches in integer/char case tests

## Bool Cases: Already Handled Correctly

Bool patterns are handled by **separate code paths**:
- `generateBoolFanOut` - for Bool FanOut patterns
- `generateChainForBoolADT` - for Bool Chain patterns

These already use:
- Scrutinee type `I1`
- Case kind `"bool"`

The `scrutineeTypeFromCaseKind` function returns `Types.ecoValue` for `"bool"` (fallthrough case), but this is **never used** because Bool patterns don't go through `generateFanOutGeneral`.

**Verification:** Ensure Bool patterns continue to be routed to their dedicated handlers, not to `generateFanOutGeneral`. The existing `generateFanOut` dispatcher already does this:

```elm
generateFanOut ctx root path edges fallback resultTy =
    if isBoolFanOut edges then
        generateBoolFanOut ctx root path edges fallback resultTy
    else
        generateFanOutGeneral ctx root path edges fallback resultTy
```

## Files to Modify

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/MLIR/Patterns.elm` | Add `scrutineeTypeFromCaseKind` function, export it |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Reorder `generateFanOutGeneral` to compute `caseKind` first, derive `scrutineeType`, use both |

## Test Commands

```bash
# Targeted tests for this fix
cd compiler
timeout 10 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/CaseKindScrutineeTest.elm
timeout 10 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/OperandTypeConsistencyTest.elm

# Full CodeGen suite
for f in tests/Compiler/Generate/CodeGen/*Test.elm; do
  timeout 5 npx elm-test --fuzz 1 "$f"
done

# Eco E2E tests
cd /work && TEST_FILTER=elm cmake --build build --target check
```

## Expected Impact

- **CaseKindScrutineeTest:** All 19 failures should be fixed
- **OperandTypeConsistencyTest:** 15 of 25 failures should be fixed (the scrutinee-related ones)
- **Eco E2E tests:** Many type mismatch errors involving int/char case expressions should be resolved

## Design Principle: SSA Typing & Context as Single Source of Truth

This fix follows a broader design principle that should be maintained across all MLIR generation:

### Rule 1: Update context mapping when representation changes

Every time you change the representation of a bound Elm name (e.g., unboxing), update the context mapping:

- `Patterns.generateDTPath` already does this when unboxing a root parameter: it calls `Ctx.addVarMapping` after `eco.unbox` so all future uses of that Elm name see the unboxed SSA var and its new `MlirType`
- `Expr.generateLet` and `generateDestruct` have been migrated away from wrapping in `eco.construct` and now just add a mapping from the let-bound/destruct name to the expression/path result and its type
- **Keep this pattern everywhere** - the context is the single source of truth for variable types

### Rule 2: Never re-interpret an SSA value with a different type

All consumers (`eco.case`, `eco.call`, `eco.return`, `eco.project.*`, `eco.unbox`) must get their types from the same context-driven pipeline. They must **not** guess or hard-code a type that disagrees with the actual SSA type.

**What this fix changes:**
- Previously: `generateFanOutGeneral` hard-coded `Types.ecoValue` for scrutinee
- Now: It derives `scrutineeType` from `caseKind`, which reflects the actual expected type

### Rule 3: Validators catch inconsistencies early

Existing validators help enforce these rules:
- `checkEcoUnboxWellTyped`: `eco.unbox` operand must be `!eco.value`, result must be primitive
- `checkOperandTypeConsistency`: `_operand_types` attributes must match actual SSA types

**Potential future enhancement:** Add an MLIR check that each SSA name has a unique inferred type and that any `_operand_types` attributes match those inferred types.

### How this fix adheres to the principles

1. `generateDTPath` updates context when unboxing (Rule 1) ✓
2. `generateFanOutGeneral` uses context-derived type for `ecoCase` (Rule 2) ✓
3. Existing validators will verify the fix works (Rule 3) ✓

## Risk Assessment

**Low risk:**
1. The change only affects case expressions with Int/Char/Str patterns
2. ADT (constructor) patterns continue to use `eco.value` unchanged
3. Bool patterns use a completely separate code path
4. The unboxing infrastructure is already tested and used by Chain generation
5. The fix is a straightforward mapping from `caseKind` to type
6. The fix follows established patterns already used in Chain generation
