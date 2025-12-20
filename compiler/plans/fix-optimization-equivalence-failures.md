# Fix Optimization Equivalence Test Failures

## Overview

The `OptimizeEquivalentTest` suite compares the Erased and Typed optimization paths to verify they produce structurally equivalent IRs. Current results show 307 passed and 211 failed tests.

## Test Results Summary

| Category | Count | Root Cause |
|----------|-------|------------|
| "Local variable not in scope" | ~145 | Missing scope management + no-op error handling |
| "Dependencies mismatch" | ~67 | Missing `registerKernel` calls in Typed path |
| "Float value mismatch" | 2 | NaN handling differences |

---

## Category 1: "Local variable not in scope" (~145 failures)

### Error Message
```
Local variable not in scope: <varname>
```

### Root Cause

Two interrelated issues in the Typed optimization path:

#### Issue 1A: Let-bound variables not added to scope before body optimization

**Location**: `/work/compiler/src/Compiler/Optimize/Typed/Expression.elm:218-221`

```elm
Can.Let def body ->
    optimize kernelEnv annotations exprTypes cycle (TCan.toTypedExpr exprTypes body)
        |> Names.andThen (optimizeDef kernelEnv annotations exprTypes cycle def tipe)
```

The body is optimized **before** the let-bound variable is added to scope. When the body references the let-bound variable, `lookupLocalType` is called but fails because the variable isn't in scope yet.

**Contrast with Erased path** (`/work/compiler/src/Compiler/Optimize/Erased/Expression.elm:76-77`):

```elm
Can.VarLocal name ->
    Names.pure (Opt.TrackedVarLocal region name)
```

The Erased path simply creates the node without any scope lookup, so it works.

#### Issue 1B: `catchMissing` is a no-op

**Location**: `/work/compiler/src/Compiler/Optimize/Typed/Expression.elm:405-411`

```elm
catchMissing : Names.Tracker a -> Names.Tracker a -> Names.Tracker a
catchMissing fallback tracker =
    -- In a proper implementation, we'd catch the error
    -- For now, just use the tracker
    tracker
```

This function was intended to catch the "missing variable" error and use a fallback (the solver-inferred type), but it doesn't actually catch anything. It just returns the tracker, which crashes.

**Usage at line 73-76**:

```elm
Can.VarLocal name ->
    Names.lookupLocalType name
        |> Names.map (\localType -> TOpt.TrackedVarLocal region name localType)
        |> catchMissing (Names.pure (TOpt.TrackedVarLocal region name tipe))
```

The fallback (`Names.pure (TOpt.TrackedVarLocal region name tipe)`) would use the solver-inferred `tipe`, but `catchMissing` never triggers it.

**The crash happens in** `/work/compiler/src/Compiler/Optimize/Typed/Names.elm:345-354`:

```elm
lookupLocalType : Name -> Tracker Can.Type
lookupLocalType name =
    Tracker <|
        \uid deps fields locals ->
            case Dict.get Basics.identity name locals of
                Just tipe ->
                    tResult uid deps fields locals tipe
                Nothing ->
                    crash ("Local variable not in scope: " ++ name)
```

### Fix Options

**Option A (Recommended)**: Add let-bound variables to scope before optimizing the body

This requires restructuring `Can.Let` handling to:
1. Extract the variable name and type from the definition
2. Add it to scope with `withVarTypes`
3. Optimize the body within that scope
4. Then process the definition

**Option B**: Implement proper error catching in `catchMissing`

This would require changing `Names.Tracker` to support error recovery, which is more invasive.

---

## Category 2: "Dependencies mismatch" (~67 failures)

### Error Message
```
Dependencies mismatch: Erased has ... but Typed has ...
```

### Root Cause

Missing `registerKernel` calls in the Typed optimization path.

### Key Example: List handling

**Erased** (`/work/compiler/src/Compiler/Optimize/Erased/Expression.elm:113-115`):

```elm
Can.List entries ->
    Names.traverse (optimize cycle) entries
        |> Names.andThen (Names.registerKernel Name.list << Opt.List region)
```

**Typed** (`/work/compiler/src/Compiler/Optimize/Typed/Expression.elm:121-123`):

```elm
Can.List entries ->
    Names.traverse (optimize kernelEnv annotations exprTypes cycle << TCan.toTypedExpr exprTypes) entries
        |> Names.map (\optEntries -> TOpt.List region optEntries tipe)
```

The Typed version uses `Names.map` instead of `Names.andThen ... registerKernel`, so it **never registers the `List` kernel dependency**.

### Comparison of `registerKernel` calls

| Expression | Erased | Typed |
|------------|--------|-------|
| `Can.Chr` | `Name.utils` | `Name.utils` |
| `Can.List` | `Name.list` | **Missing** |
| `Can.Unit` | `Name.utils` | `Name.utils` |
| `Can.Tuple` | `Name.utils` | `Name.utils` |
| `Can.VarKernel` | `home` | `home` |

### Fix

Change the Typed `Can.List` case to register the kernel:

```elm
Can.List entries ->
    Names.traverse (optimize kernelEnv annotations exprTypes cycle << TCan.toTypedExpr exprTypes) entries
        |> Names.andThen (\optEntries -> Names.registerKernel Name.list (TOpt.List region optEntries tipe))
```

---

## Category 3: "Float value mismatch" (2 failures)

### Error Message
```
Float value mismatch: Erased=NaN but Typed=NaN
```

### Root Cause

NaN comparison semantics issue. IEEE 754 specifies that `NaN /= NaN`, so:

```elm
erasedFloat == typedFloat  -- False when both are NaN
```

The comparison function treats this as a mismatch even though both paths produce the same NaN value. This affects edge cases like `0/0` or operations that produce NaN.

### Fix

Update Float comparison in `OptimizeEquivalent.elm` to handle NaN:

```elm
compareFloats : Float -> Float -> Bool
compareFloats a b =
    if isNaN a && isNaN b then
        True
    else
        a == b
```

---

## Implementation Order

1. **Fix Category 2 first** (simplest) - Add missing `registerKernel Name.list`
2. **Fix Category 3 second** (simple) - Update NaN comparison logic
3. **Fix Category 1 last** (most complex) - Restructure let-binding scope management

---

## Files to Modify

| File | Changes |
|------|---------|
| `src/Compiler/Optimize/Typed/Expression.elm` | Add `registerKernel Name.list` for List; restructure `Can.Let` handling |
| `tests/Compiler/Optimize/OptimizeEquivalent.elm` | Add NaN-aware Float comparison |

---

## Verification

After fixes, run:

```bash
cd compiler
npx elm-test tests/Compiler/Optimize/OptimizeEquivalentTest.elm
```

Expected result: All 518 tests pass.
