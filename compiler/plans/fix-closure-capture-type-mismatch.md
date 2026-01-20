# Plan: Fix Closure Capture Type Mismatch

## Problem Summary

When closures capture primitive variables (e.g., `Int`), the captured values are:
1. Boxed to `eco.value` when creating the PAP (`eco.papCreate`)
2. Passed to the lambda body as `eco.value` type
3. **Never unboxed** back to their primitive type (`i64`, `i16`, etc.)

This causes type mismatches when the captured variable is used in primitive operations like `eco.int.add`, which expect `i64` operands.

**Example failing test:**
```
Closure over single local:
  Violation in eco.int.add (op16): operand 0 ('%x'): _operand_types declares i64 but SSA type is eco.value
```

## Root Cause Analysis (UPDATED)

### Investigation Summary

The initial hypothesis was that `generateLambdaFunc` in `Lambdas.elm` wasn't unboxing captures. A fix was applied to process both `lambda.captures ++ lambda.params` through the unboxing fold.

**However, the tests still failed.** Further investigation revealed the REAL root cause is **upstream in the monomorphization phase**.

### Actual Root Cause Location

**File:** `compiler/src/Compiler/Generate/Monomorphize/Closure.elm`

**Function:** `computeClosureCaptures` (lines 271-299)

**The Bug:**
```elm
captureFor name =
    let
        -- We do not track an environment here; in practice we only
        -- capture by name and type from the VarLocal uses.
        -- For now, use a placeholder MUnit when the type is unknown.
        placeholderType =
            Mono.MUnit
    in
    ( name, Mono.MonoVarLocal name placeholderType, False )
```

The function creates capture expressions with `MUnit` as a **placeholder type** instead of the actual type of the captured variable.

### Chain of Failure

1. **In `computeClosureCaptures`:** `findFreeLocals` walks the body and collects free variable NAMES only, discarding types
2. **In `captureFor`:** Creates `( "x", MonoVarLocal "x" MUnit, False )` - uses `MUnit` placeholder!
3. **In `generateClosure`:** `captureTypes = [("x", Mono.typeOf expr)]` → `[("x", MUnit)]` (MUnit, not MInt!)
4. **In `generateLambdaFunc`:** For `("x", MUnit)` → `mlirType = Types.monoTypeToMlir MUnit = eco.value`
5. **Result:** `isEcoValueType ecoValue = True` → No unboxing happens, variable mapped to `("%x", eco.value)`
6. **At use site:** `eco.int.add` expects `i64` operand but gets `eco.value`

### Why the Lambdas.elm Fix Didn't Work

The fix to `generateLambdaFunc` was correct in principle - it now processes both captures and params for unboxing. But the unboxing decision is based on the MonoType:

```elm
if Types.isEcoValueType mlirType then
    -- No unboxing (this branch is taken for MUnit!)
else
    -- Unbox to primitive
```

Since capture types are `MUnit` (which maps to `eco.value`), the code correctly concludes "no unboxing needed" - because it thinks the type is already `eco.value`, not a primitive.

**The Lambdas.elm fix is correct but insufficient** - the real fix must be in the monomorphization phase.

## Correct Fix

### Option 1: Extract types from MonoVarLocal nodes in the body (Recommended)

The body expression (`monoBody`) at this point already has correct types in its `MonoVarLocal` nodes. Instead of just collecting names and creating new expressions with placeholder types, collect the actual expressions with their types.

**Current (broken):**
```elm
findFreeLocals bound expr =
    case expr of
        Mono.MonoVarLocal name _ ->
            if EverySet.member identity name bound then []
            else [ name ]  -- Type is discarded!
```

**Fixed approach:** Create a new function that collects `(Name, MonoType)` pairs by extracting the type from each `MonoVarLocal`:

```elm
-- New function: collect (name, type) pairs instead of just names
findFreeLocalTypes : EverySet String Name -> Mono.MonoExpr -> List ( Name, Mono.MonoType )
findFreeLocalTypes bound expr =
    case expr of
        Mono.MonoVarLocal name monoType ->
            if EverySet.member identity name bound then []
            else [ ( name, monoType ) ]
        -- ... recurse for other cases, collecting and merging
```

Then update `computeClosureCaptures`:
```elm
computeClosureCaptures params body =
    let
        boundInitial = ... -- same as before

        freeVars : List ( Name, Mono.MonoType )
        freeVars =
            findFreeLocalTypes boundInitial body
                |> dedupeByName  -- keep first occurrence of each name
    in
    List.map (\( name, ty ) -> ( name, Mono.MonoVarLocal name ty, False )) freeVars
```

### Option 2: Pass environment/substitution to `computeClosureCaptures`

Pass the type environment from the specialization phase so capture types can be looked up. This is more invasive but potentially more correct.

## Implementation Plan

### Step 1: Fix `findFreeLocals` to preserve types

Modify the function to return `List ( Name, MonoType )` instead of `List Name`.

### Step 2: Update `computeClosureCaptures` to use actual types

Use the types extracted from the body instead of `MUnit` placeholder.

### Step 3: Handle deduplication carefully

When the same variable appears multiple times in the body, use the first occurrence's type (or verify all occurrences have the same type).

### Step 4: Verify the fix

Run closure tests:
```bash
cd compiler
timeout 5 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/OperandTypeConsistencyTest.elm
```

## Files to Modify

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` | Fix `findFreeLocals` and `computeClosureCaptures` to preserve capture types |
| `compiler/src/Compiler/Generate/MLIR/Lambdas.elm` | Already fixed (process both captures and params) - keep this change |

## Test Commands

```bash
# Focused Elm compiler test
cd compiler
timeout 5 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/OperandTypeConsistencyTest.elm

# Runtime test
cd /work
TEST_FILTER=elm cmake --build build --target check
```

## Risk Assessment

**Medium risk:** This change modifies the monomorphization phase which affects all closure capture analysis. The change should be safe because:
1. Types are already present in `MonoVarLocal` nodes - we're just preserving them instead of discarding
2. The invariant "capture type matches variable's actual type" should already hold

## Additional Finding: Silent Fallback in lookupVar

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

The `lookupVar` function has a silent fallback that masks invariant violations:
```elm
lookupVar ctx name =
    case Dict.get name ctx.varMappings of
        Just ( ssaVar, mlirTy ) -> ( ssaVar, mlirTy )
        Nothing -> ( "%" ++ name, Types.ecoValue )  -- Silent fallback!
```

This should be changed to crash with a descriptive error message, as a variable not being in varMappings indicates a broken invariant. However, this is a separate change that should be done carefully to avoid breaking other code paths.

## Implementation Status: COMPLETED

The fix was implemented in `Closure.elm` by:
1. Adding a `collectVarTypes` helper that walks the body expression to build a mapping from variable names to their actual types
2. Using this mapping in `computeClosureCaptures` instead of the `MUnit` placeholder

**Test Results:**
- Before fix: 38 failures in OperandTypeConsistencyTest
- After fix: 26 failures (12 closure-related tests now pass)

The remaining 26 failures are unrelated to closure captures - they involve:
- Case expression scrutinee type mismatches
- Constructor payload extraction type mismatches

## Other MUnit Fallback Locations (Not Fixed Yet)

The following locations also use `MUnit` as a fallback/placeholder:

1. **Expr.elm:1207** - In Debug.log handling, when args list doesn't have exactly 2 elements. Low risk since Debug.log signature is fixed.

2. **Expr.elm:1706** - Uses `MUnit` as type parameter for a temporary `MonoLet` expression constructed just to collect bound names. Safe since only the structure matters for `collectLetBoundNames`.

3. **KernelAbi.elm:333** - When List type has wrong number of type args (not exactly 1), falls back to `MList MUnit`. Could cause issues with malformed types.

4. **TypeSubst.elm:299** - Same as KernelAbi.elm - when List has wrong arity, uses `MList MUnit`.

## Non-Goals

This plan does NOT address:
- Case expression scrutinee type issues (separate fix needed)
- Tail recursion issues (separate fix needed)
- Block terminator issues for nested cases (separate fix needed)
