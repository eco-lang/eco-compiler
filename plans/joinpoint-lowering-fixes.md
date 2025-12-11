# Plan: Fixing Joinpoint Lowering Issues

## Overview

Two related issues in `EcoToLLVM.cpp` prevent certain control flow patterns from compiling:
1. Nested joinpoints fail to lower
2. `eco.case` inside joinpoint body crashes

Both issues stem from how the joinpoint lowering interacts with the MLIR dialect conversion framework.

## Issue 1: Nested Joinpoints

### Current Behavior
```mlir
eco.joinpoint 0(%outer: i64) {
  eco.joinpoint 1(%inner: i64) {   // FAILS
    eco.jump 0(%inner : i64)
  } continuation {
    eco.jump 1(%c10 : i64)
  }
  eco.return
} continuation { ... }
```

Error: `failed to legalize operation 'eco.joinpoint' that was explicitly marked illegal`

### Root Cause
The `JoinpointOpLowering` pattern:
1. Clones operations from the body region into a new basic block (lines 1575-1590)
2. When it encounters a nested `JoinpointOp`, it just clones it
3. The cloned inner joinpoint remains unlowered because:
   - It's a new operation created during pattern rewriting
   - The pattern applicator has already visited the original operation
   - The dialect conversion target marks `JoinpointOp` as illegal

### Relevant Code (`EcoToLLVM.cpp:1575-1590`)
```cpp
for (Operation &innerOp : llvm::make_early_inc_range(bodyEntry)) {
    if (isa<ReturnOp>(&innerOp)) {
        rewriter.create<cf::BranchOp>(loc, exitBlock);
    } else if (isa<JumpOp>(&innerOp)) {
        rewriter.clone(innerOp, mapping);
    } else {
        // BUG: Nested JoinpointOp gets cloned but not recursively lowered
        Operation *cloned = rewriter.clone(innerOp, mapping);
        ...
    }
}
```

---

## Issue 2: Case Inside Joinpoint

### Current Behavior
```mlir
eco.joinpoint 0(%val: !eco.value) {
  eco.case %val [0, 1] { ... }  // CRASHES
  eco.return
} continuation { ... }
```

Error: `Assertion 'isa<To>(Val)' failed` in cast to `TypedValue<eco::ValueType>`

### Root Cause
In `CaseOpLowering::matchAndRewrite` (line 1462):
```cpp
mapping.map(op.getScrutinee(), scrutinee);
```

- `op.getScrutinee()` is a generated accessor that returns `TypedValue<ValueType>`
- It internally does `cast<TypedValue<ValueType>>(getOperand(0))`
- Inside a joinpoint body, the operand has been cloned with type conversion
- The original `!eco.value` operand is now `i64` (LLVM type)
- The cast fails because `i64` is not `!eco.value`

### The Correct Approach
Line 1401 correctly uses the adaptor:
```cpp
Value scrutinee = adaptor.getScrutinee();  // Gets converted operand
```

Line 1462 incorrectly uses the original op:
```cpp
mapping.map(op.getScrutinee(), scrutinee);  // Tries to access unconverted operand
```

---

## Proposed Fixes

### Fix 1: Nested Joinpoints - Recursive Lowering

**Option A: Process joinpoints bottom-up**
Change the lowering to process innermost joinpoints first by using a topological sort or worklist.

**Option B: Handle nested joinpoints explicitly in the pattern**
When cloning body operations, detect `JoinpointOp` and recursively lower it:

```cpp
for (Operation &innerOp : llvm::make_early_inc_range(bodyEntry)) {
    if (isa<ReturnOp>(&innerOp)) {
        rewriter.create<cf::BranchOp>(loc, exitBlock);
    } else if (isa<JumpOp>(&innerOp)) {
        rewriter.clone(innerOp, mapping);
    } else if (auto nestedJP = dyn_cast<JoinpointOp>(&innerOp)) {
        // Recursively lower nested joinpoint
        // This requires extracting the lowering logic into a helper function
        lowerJoinpointRecursive(nestedJP, rewriter, mapping);
    } else {
        Operation *cloned = rewriter.clone(innerOp, mapping);
        ...
    }
}
```

**Option C: Pre-flatten pass**
Add a separate pass before lowering that flattens nested joinpoints into sequential form:

```mlir
// Before flattening:
eco.joinpoint 0(%outer) {
  eco.joinpoint 1(%inner) { ... }
  eco.return
}

// After flattening:
eco.joinpoint 1(%inner) { ... }
eco.joinpoint 0(%outer) {
  eco.jump 1(...)  // Moved inside
  eco.return
}
```

**Recommendation:** Option B (explicit handling) is the cleanest for the current architecture.

---

### Fix 2: Case Inside Joinpoint - Use Operand Index

Replace the problematic `op.getScrutinee()` call with direct operand access:

**Before (line 1462):**
```cpp
mapping.map(op.getScrutinee(), scrutinee);
```

**After:**
```cpp
mapping.map(op.getOperand(0), scrutinee);
```

Or more explicitly, avoid the mapping entirely since we already have the converted scrutinee from the adaptor:

```cpp
// The adaptor already provides the converted scrutinee (line 1401)
// No need to map old->new; just use the converted value directly
// The mapping is only needed for results, not for the scrutinee input
```

Actually, examining the code more carefully, the issue is that the mapping at line 1462 is trying to set up a mapping for operations *inside* the case regions that reference the scrutinee. The fix should be:

**Option A: Use getOperand(0)**
```cpp
// Line 1462
mapping.map(op->getOperand(0), scrutinee);
```

This accesses the raw `Value` without the type cast.

**Option B: Cache the original operand before conversion**
Store the original operand at the start of the function before any type issues.

**Recommendation:** Option A is the minimal fix.

---

## Implementation Plan

### Phase 1: Fix Case Inside Joinpoint (Simple Fix)
1. Edit `CaseOpLowering::matchAndRewrite` in `EcoToLLVM.cpp`
2. Change line 1462 from `op.getScrutinee()` to `op->getOperand(0)`
3. Test with `XFAIL_case_in_joinpoint.mlir`

### Phase 2: Fix Nested Joinpoints (More Complex)
1. Extract joinpoint lowering logic into a helper function
2. Add detection for nested `JoinpointOp` in the body cloning loop
3. Call helper recursively for nested joinpoints
4. Ensure `joinpointBlocks` map is updated before any jumps reference it
5. Test with `XFAIL_nested_joinpoint.mlir`

### Phase 3: Verification
1. Remove XFAIL markers from test files
2. Run full test suite to ensure no regressions
3. Add additional tests for more complex nesting patterns

---

## Test Files

### `XFAIL_nested_joinpoint.mlir`
Tests nested joinpoint lowering. Currently fails with legalization error.

### `XFAIL_case_in_joinpoint.mlir`
Tests case dispatch inside joinpoint body. Currently crashes with type cast assertion.

---

## Risk Assessment

**Fix 1 (Case):** Low risk - simple change to use raw operand access
**Fix 2 (Nested JP):** Medium risk - requires recursive handling, potential for infinite loops if IDs collide

---

## COMPLETED - Implementation Summary

Both fixes have been implemented and tested successfully.

### Fix 1: Case Inside Joinpoint
**File:** `EcoToLLVM.cpp` line 1464
**Change:** `op.getScrutinee()` → `op->getOperand(0)`

### Fix 2: Nested Joinpoints
**File:** `EcoToLLVM.cpp` lines 1522-1618

Added two helper functions:
1. `lowerNestedJoinpoint()` - Handles nested JoinpointOp by creating blocks and recursively lowering
2. `lowerJoinpointRegion()` - Processes operations from a source block, detecting nested joinpoints

Key bug fixed: After `createBlock()`, the insertion point moves to the new block. The original code was branching from the wrong block. Fixed by saving `insertBlock` before creating new blocks and explicitly setting insertion point back.

### Test Files Renamed
- `XFAIL_case_in_joinpoint.mlir` → `case_in_joinpoint.mlir`
- `XFAIL_nested_joinpoint.mlir` → `nested_joinpoint.mlir`

All 21+ joinpoint and case tests now pass.
