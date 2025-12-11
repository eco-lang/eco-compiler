# Fix: Nested Case Lowering Bug [IMPLEMENTED]

## Problem Statement

The `CaseOpLowering` pattern crashes with "operation destroyed but still has uses" when processing nested `eco.case` operations.

**Error observed:**
```
loc("test/codegen/case_in_case.mlir":52:5): error: failed to legalize operation 'eco.case' that was explicitly marked illegal
loc("test/codegen/case_in_case.mlir":27:13): error: 'eco.construct' op operation destroyed but still has uses
```

## Root Cause Analysis

The bug is in `CaseOpLowering::matchAndRewrite` at `runtime/src/codegen/Passes/EcoToLLVM.cpp:1498-1514`.

### Current Implementation (Buggy)

```cpp
for (Operation &innerOp : llvm::make_early_inc_range(entryBlock)) {
    if (isa<ReturnOp>(&innerOp)) {
        rewriter.create<cf::BranchOp>(loc, mergeBlock);
    } else if (isa<JumpOp>(&innerOp)) {
        rewriter.clone(innerOp, mapping);
    } else {
        // Clone with mapping and update mapping for results.
        Operation *cloned = rewriter.clone(innerOp, mapping);  // <-- PROBLEM
        for (auto [oldResult, newResult] :
             llvm::zip(innerOp.getResults(), cloned->getResults())) {
            mapping.map(oldResult, newResult);
        }
    }
}
```

### Why This Fails

1. When `rewriter.clone(innerOp, mapping)` is called on an inner `CaseOp`:
   - The clone operation applies `mapping` to the **immediate operands** only
   - Operations **inside the inner CaseOp's regions** do NOT get remapped
   - They still reference original values (like `%inner_result`) defined in the outer case

2. When the outer `CaseOp` is erased via `rewriter.eraseOp(op)`:
   - The original operations in its regions are destroyed
   - But the cloned inner `CaseOp`'s regions still reference those destroyed values

3. The dialect conversion framework fails because:
   - The inner `CaseOp` clone has invalid references
   - It cannot be legalized

### Example Scenario

```mlir
eco.case %just_ok [0, 1] {           // Outer case
  ...
}, {
  %inner_result = eco.project %just_ok[0]   // Defined in outer case region

  eco.case %inner_result [0, 1] {           // Inner case - scrutinee uses %inner_result
    %ok_payload = eco.project %inner_result[0]  // Region op ALSO uses %inner_result
    ...
  }, { ... }
}
```

When cloning:
1. `eco.project` is cloned → `%inner_result_clone`, mapping updated
2. Inner `CaseOp` is cloned:
   - Scrutinee remapped: `%inner_result` → `%inner_result_clone` ✓
   - But `eco.project %inner_result[0]` inside its region still references original `%inner_result` ✗

## Solution: Move Regions Instead of Cloning

The fix is to use `inlineRegionBefore()` to **move** operations instead of cloning them.

### Key Insight

Moving operations instead of cloning means:
- Original operations are relocated to the new blocks
- The outer CaseOp's regions become **empty** before erasure
- When we erase the CaseOp, there's nothing to destroy
- Inner CaseOps (now in the new blocks) will be processed by the conversion framework in subsequent iterations

### Implementation Changes

Replace the clone-based approach with region inlining:

```cpp
// For each alternative region:
for (size_t i = 0; i < alternatives.size(); ++i) {
    Region &altRegion = alternatives[i];
    Block *caseBlock = caseBlocks[i];

    if (altRegion.empty())
        continue;

    Block &entryBlock = altRegion.front();

    // Move all operations to the case block (don't clone!)
    rewriter.setInsertionPointToEnd(caseBlock);

    // Handle block arguments if any (map them to appropriate values)
    // ...

    // Use inlineBlockBefore to MOVE operations
    rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());

    // The region's block is now empty and will be cleaned up
    // when we erase the CaseOp
}

// Now find and replace terminators (eco.return → cf.br to merge)
for (Block *caseBlock : caseBlocks) {
    Operation *term = caseBlock->getTerminator();
    if (auto retOp = dyn_cast<ReturnOp>(term)) {
        rewriter.setInsertionPoint(term);
        rewriter.create<cf::BranchOp>(loc, mergeBlock);
        rewriter.eraseOp(term);
    }
}

// Safe to erase - regions are now empty
rewriter.eraseOp(op);
```

### Why This Works

1. **Preserves SSA validity**: Values defined in the outer case region move with their uses
2. **Handles nesting automatically**: Inner CaseOps move intact to new blocks
3. **Dialect conversion handles the rest**: The pattern driver will process inner CaseOps in subsequent iterations
4. **No dangling references**: Nothing is destroyed that still has uses

## Detailed Implementation Steps

### Step 1: Refactor the region inlining loop

Current code (lines 1486-1515):
```cpp
for (size_t i = 0; i < alternatives.size(); ++i) {
    Region &altRegion = alternatives[i];
    Block *caseBlock = caseBlocks[i];
    rewriter.setInsertionPointToEnd(caseBlock);

    if (!altRegion.empty()) {
        Block &entryBlock = altRegion.front();
        for (Operation &innerOp : llvm::make_early_inc_range(entryBlock)) {
            // ... clone operations
        }
    }
}
```

Replace with:
```cpp
for (size_t i = 0; i < alternatives.size(); ++i) {
    Region &altRegion = alternatives[i];
    Block *caseBlock = caseBlocks[i];

    if (altRegion.empty()) {
        // Empty region - just add branch to merge
        rewriter.setInsertionPointToEnd(caseBlock);
        rewriter.create<cf::BranchOp>(loc, mergeBlock);
        continue;
    }

    Block &entryBlock = altRegion.front();

    // Move operations from region block to case block
    rewriter.inlineBlockBefore(&entryBlock, caseBlock, caseBlock->end());
}
```

### Step 2: Replace terminators after inlining

After all regions are inlined, walk through case blocks and replace terminators:

```cpp
for (Block *caseBlock : caseBlocks) {
    // Find the terminator
    if (caseBlock->empty())
        continue;

    Operation *term = caseBlock->getTerminator();
    rewriter.setInsertionPoint(term);

    if (isa<ReturnOp>(term)) {
        rewriter.create<cf::BranchOp>(loc, mergeBlock);
        rewriter.eraseOp(term);
    }
    // JumpOps are handled by JumpOpLowering - leave them alone
}
```

### Step 3: Remove the IRMapping for scrutinee

The IRMapping was used to remap references to the scrutinee when cloning. Since we're now moving operations (not cloning), we need a different approach:

- The scrutinee is passed as an operand to the CaseOp
- Operations inside the region that use block arguments need those remapped
- For operations that directly reference the CaseOp's scrutinee, we may need to use `replaceAllUsesWith` or similar

Actually, looking at the current code more carefully, the scrutinee is just `op.getScrutinee()` / `adaptor.getScrutinee()`, not a block argument. The inner operations reference the scrutinee directly. After moving, they'll still reference the same value (which is defined outside the CaseOp), so this should work automatically.

### Step 4: Handle potential block arguments

If the alternative regions have block arguments (for pattern-matched bindings), those need to be handled:

```cpp
// If region has block arguments, create corresponding values
// and replace uses within the moved block
if (entryBlock.getNumArguments() > 0) {
    // For case alternatives, block args represent pattern bindings
    // These should be extracted from the scrutinee
    // (This may already be handled by the eco.project operations)
}
```

## Testing

After implementation:

1. Remove `XFAIL` from `test/codegen/case_in_case.mlir`
2. Run the test: `./build/runtime/src/codegen/ecoc test/codegen/case_in_case.mlir -emit=jit`
3. Expected output:
   ```
   10
   30
   -20
   ```

4. Add additional test cases:
   - Triple-nested case
   - Case with construct defined in outer case, used in inner case's scrutinee AND body
   - Case interleaved with joinpoint

## Risk Assessment

**Low risk** - This is a localized change to one pattern:
- Only affects `CaseOpLowering`
- Uses standard MLIR APIs (`inlineBlockBefore`)
- Follows the recommended pattern for handling nested regions in dialect conversion

**Potential issues to watch:**
- Ensure JumpOp handling still works (it should - they're just moved, not transformed)
- Ensure terminators are properly replaced
- Verify block arguments are handled correctly (if any)

## Files to Modify

1. `runtime/src/codegen/Passes/EcoToLLVM.cpp` - CaseOpLowering (lines ~1486-1520)

## References

- MLIR Dialect Conversion docs: region inlining patterns
- Similar fix applied for JoinpointOp in `plans/joinpoint-lowering-fixes.md`

---

## Implementation Notes (2024-12-11)

**Status: COMPLETED**

The fix was implemented in `runtime/src/codegen/Passes/EcoToLLVM.cpp` (lines 1478-1529).

Key changes:
1. Replaced clone-based approach with `inlineBlockBefore()` to move operations
2. Added `replaceUsesOfWith()` to update scrutinee references after moving
3. Separated terminator replacement into a second pass after all regions are inlined

Test results:
- `case_in_case.mlir` now passes (was XFAIL)
- All 25 case-related tests pass
- XFAIL marker removed from test file
