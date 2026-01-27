# Fix Destructor Type Projection for Closure Arguments

## Problem Summary

When `Result.andThen half (Ok 42)` is executed:
1. The value `42` is extracted from `Ok` via `eco.project.custom` as `i64`
2. But then it's **boxed back to `!eco.value`** because the destructor's type variable maps to `!eco.value`
3. The boxed HPointer is passed to `papExtend` and stored in the closure
4. The wrapper passes the HPointer to `half(i64)`, which treats it as an integer → wrong result

## Root Cause

In `generateDestruct`, the `targetType` for path generation comes from:
```elm
destructorMlirType = Types.monoTypeToAbi monoType
```

The hypothesis is that `monoType` in the `MonoDestructor` is a type variable (`MVar`) rather than the concrete type (`MInt`), causing `monoTypeToAbi` to return `!eco.value`.

However, the design document claims `specializeDestructor` should already produce concrete types via `TypeSubst.applySubst`. This needs verification.

## Implementation Plan

### Phase 1: Verification (No Code Changes)

#### Step 1.1: Verify destructor types in specialized MLIR

Add debug output to confirm what `monoType` the destructor actually has in the failing test case.

**File**: `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Location**: `generateDestruct` function

Temporarily add a `Debug.log` to print:
- The destructor name
- The destructor's `monoType`
- The computed `destructorMlirType`

**Expected**: If the design is correct, `monoType` should be `MInt`, not `MVar`.
**If unexpected**: The bug is in monomorphization/specialization, not MLIR generation.

#### Step 1.2: Verify MonoPath resultType

Check that `MonoPath` carries the concrete type for the `Ok` field.

**File**: `compiler/src/Compiler/Generate/MLIR/Patterns.elm`
**Location**: `generateMonoPath`, `CustomContainer` case

Add debug output to print:
- `containerType`
- `resultType` from the `MonoIndex`
- `maybeIsUnboxed` result from layout lookup

**Expected**: `resultType` should be `MInt`, `maybeIsUnboxed` should be `Just True`.

#### Step 1.3: Verify CtorLayout registration

Confirm that `Result String Int`'s `Ok` constructor is registered with the correct layout.

Check `ctx.typeRegistry.ctorShapes` contains the expected entry.

### Phase 2: Determine Fix Location

Based on Phase 1 results:

#### Scenario A: Destructor `monoType` is already `MInt`

The bug is in `generateMonoPath` - specifically, the logic at lines 114-127 that decides whether to box based on `targetType`.

**Fix**: The path generation should use `resultType` from `MonoIndex` (which is `MInt`) to determine projection type, not `targetType` from the caller.

#### Scenario B: Destructor `monoType` is `MVar` (type variable)

The bug is in monomorphization - `specializeDestructor` is not fully substituting type variables.

**Fix**: Debug `specializeDestructor` in `Specialize.elm` to understand why substitution isn't working.

### Phase 3: Implementation

#### If Scenario A (likely based on MLIR output showing `-> i64`):

The MLIR shows `eco.project.custom ... -> i64`, meaning the projection IS producing `i64`. The boxing happens AFTER projection in `generateMonoPath` because `targetType` is `!eco.value`.

**The Fix**: In `generateMonoPath`, when we know the field is unboxed (`Just True`), we should:
1. Project as the primitive type (already happening)
2. Only box if the **destructor's MonoType** requires it, not based on caller's `targetType`

But wait - `generateMonoPath` doesn't have access to the destructor's MonoType directly. It receives `targetType` from the caller.

**Actual Fix Location**: `generateDestruct` passes `targetType = Types.monoTypeToAbi monoType`. If `monoType` is `MInt`, then `targetType` would be `I64`, and no boxing would occur.

So the real question is: **why is `monoType` not `MInt`?**

### Phase 4: Testing

1. Run the failing test:
   ```bash
   TEST_FILTER=elm-core/ResultAndThenTest cmake --build build --target check
   ```

2. Run full test suite to check for regressions:
   ```bash
   cmake --build build --target check
   ```

3. Run Elm frontend tests:
   ```bash
   cd compiler && npx elm-test --fuzz 1
   ```

## Questions Before Implementation

1. **Q1**: Can you confirm whether adding `Debug.log` statements to the Elm compiler is acceptable for debugging, or should I use a different approach?

2. **Q2**: The design document suggests the destructor's `monoType` should already be concrete (`MInt`). But based on the MLIR output showing boxing, it seems like it might be a type variable. Should I verify this hypothesis first, or proceed directly with the fix assuming the design is correct?

3. **Q3**: If the issue is in monomorphization (Scenario B), that would be a more significant change. Is there a known issue with `specializeDestructor` not fully substituting type variables in certain contexts (like higher-order function callbacks)?

## Files to Modify

Depending on investigation results:

- `compiler/src/Compiler/Generate/MLIR/Expr.elm` - `generateDestruct` function
- Possibly `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` - if substitution is incomplete
- `design_docs/invariants.csv` - update CGEN_003 for typed closure ABI (optional)

## Risk Assessment

- **Low risk**: The fix is localized to destructor type handling
- **Medium complexity**: Need to trace through monomorphization to understand type flow
- **Testing coverage**: Existing test suite should catch regressions
