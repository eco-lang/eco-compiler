# Implementation Plan: PAP Arity and Stage-Curried Type Test Updates

## Summary of Issues Found

After analyzing the codebase, I found the following issues:

1. **MonoFunctionArity.elm** - Uses `getFlattenedArity` for closures, but should use `stageArity` per MONO_016
2. **TailFuncSpecializationTest.elm** - Outdated comments mention flattened types
3. **PapExtendArity.elm** - Docstring describes old semantics
4. **Test coverage gaps** - Need to verify chained PAP tests exist

---

## Step 1: Fix MonoFunctionArity.elm Closure Check

**File:** `compiler/tests/Compiler/Generate/MonoFunctionArity.elm`

**Problem:** Lines 150-167 use `getFlattenedArity` for checking closures, but MONO_016 specifies that `closureInfo.params.length` must equal the **stage arity** (outermost MFunction args), not the flattened arity.

**Changes:**
1. Add a `stageArity` helper function (similar to the one in `WrapperCurriedCalls.elm`)
2. Modify `checkTypeExprArityConsistency` to use `stageArity` for closures instead of `getFlattenedArity`
3. The check should be `paramCount == stageArity monoType` (exact match), not `paramCount > flattenedArity` (upper bound only)
4. Adjust the comparison logic: closures should have `params == stageArity` per MONO_016

**Note:** The `MonoTailFunc` check (lines 71-87) using `getFlattenedArity` is **correct** because tail functions have all parameters flattened.

---

## Step 2: Update TailFuncSpecializationTest.elm Comments

**File:** `compiler/tests/Compiler/Generate/Monomorphize/TailFuncSpecializationTest.elm`

**Problem:** Comments are outdated:
- Line 65: Says `Expected MonoType: MFunction [MInt, MInt] MInt`
- Line 108: Says `Overall function type: MFunction [MInt, MInt] MInt`

**Changes:**
1. Update line 65 comment to: `Expected MonoType: MFunction [MInt] (MFunction [MInt] MInt)`
2. Update line 108 comment to: `Overall function type: MFunction [MInt] (MFunction [MInt] MInt)`

The actual code at line 178 is already correct.

---

## Step 3: Update PapExtendArity.elm Docstrings

**File:** `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity.elm`

**Problem:** Lines 8-9 describe old semantics:
```elm
  - `remaining_arity = source_pap_arity - num_new_args`
```

**Changes:**
1. Update module docstring (lines 6-15) to describe the "remaining" semantics:
   - `remaining_arity = source PAP's remaining arity (before this application)`
   - For `papCreate`: remaining = arity - num_captured
   - For chained `papExtend`: remaining comes from source PAP's remaining

2. Update the docstring at line 35 to match

---

## Step 4: Verify Chained PAP Test Coverage

**Investigation needed:** Check if existing tests cover:
1. Chained `papExtend` operations (apply PAP, get new PAP, apply again)
2. Edge case: `remaining_arity = 1` (saturating application)
3. Multiple stages of partial application

**Files to check:**
- `HigherOrderTests.elm` - `multiplePartialApplications` case (lines 499-519)
- `ClosureTests.elm` - nested closure cases

**If gaps exist, add test cases to `HigherOrderTests.elm`:**
1. `chainedPartialApplication` - Create PAP, apply to get new PAP, then saturate
2. `saturatingPartialApplication` - PAP with remaining=1, apply 1 arg

---

## Step 5: Review Other Tests for Flattened Type Assumptions

**Files to check:**
- `compiler/tests/Compiler/Generate/MonomorphizeTest.elm` - Check for flattened `MFunction` expectations
- Any tests with pattern `MFunction [.*,.*]` (multiple args in one stage)

**Action:** If tests expect flattened types, update to nested structure or use helper functions that work with both.

---

## Step 6: Run Tests and Iterate

1. Run the test suite:
   ```bash
   cd compiler && npx elm-test-rs --fuzz 1
   ```

2. If failures occur:
   - Capture error messages
   - Identify if it's a test expectation issue or codegen issue
   - Fix accordingly

---

## Detailed File Changes

| File | Change Type | Description |
|------|-------------|-------------|
| `MonoFunctionArity.elm` | Logic fix | Use `stageArity` for closure check, keep `flattenedArity` for TailFunc |
| `TailFuncSpecializationTest.elm` | Comment fix | Update 2 comments to reflect nested MFunction |
| `PapExtendArity.elm` | Docstring fix | Update module and function docstrings |
| `HigherOrderTests.elm` | Possible addition | Add chained PAP tests if missing |

---

## Questions and Assumptions

### Resolved Questions:

1. **MonoTailFunc vs MonoClosure semantics:** ✅ CONFIRMED
   - `MonoTailFunc` params list = total (flattened) arity - tail functions see all arguments in one go (fully uncurried)
   - `MonoClosure` params list = stage (first-level) arity - per MONO_016: `length closureInfo.params == length (Types.stageParamTypes monoType)`

2. **MonoFunctionArity.elm check intent:** ✅ CONFIRMED - Use **exact match**
   - The closure check should be: `paramCount == stageArity monoType`
   - The old `paramCount <= flattenedArity` logic was for the "fully flattened" world and is now too weak
   - Exact match is required by the new MONO_016

3. **Test suite scope:** Open - recommend starting with Elm front-end tests, then E2E if needed

### Assumptions:

1. The backend code changes (Expr.elm) are already complete and correct.

2. The `Types.stageArity` function exists in the compiler and returns the outermost MFunction param count.

3. The invariants.csv descriptions are already in their final correct form.

---

## Recommended Order of Implementation

1. **Step 3** (PapExtendArity.elm docstrings) - Low risk, pure documentation
2. **Step 2** (TailFuncSpecializationTest.elm comments) - Low risk, pure documentation
3. **Step 4** (Verify test coverage) - Investigation before making changes
4. **Step 1** (MonoFunctionArity.elm logic fix) - Higher risk, needs careful testing
5. **Step 5** (Review other tests) - May reveal additional changes
6. **Step 6** (Run tests) - Validate all changes
