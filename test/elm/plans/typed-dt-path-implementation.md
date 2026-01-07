# Plan: Typed Decision Tree Path Implementation

## Overview

This plan implements the design in `/work/design_docs/typed-dt-path.md` to add container type information to decision tree paths, enabling the MLIR backend to use type-specific projection operations instead of the deprecated generic `eco.project`.

## Current State Analysis

Files currently importing `Compiler.Optimize.Erased.DecisionTree as DT`:

| File | Pipeline | Action |
|------|----------|--------|
| `Compiler/AST/Optimized.elm` | JS/Erased | Keep erased DT |
| `Compiler/Optimize/Erased/Case.elm` | JS/Erased | Keep erased DT |
| `Compiler/Generate/JavaScript/Expression.elm` | JS/Erased | Keep erased DT |
| `Compiler/AST/TypedOptimized.elm` | Typed/MLIR | Change to typed DT |
| `Compiler/Optimize/Typed/Case.elm` | Typed/MLIR | Change to typed DT |
| `Compiler/AST/Monomorphized.elm` | Typed/MLIR | Change to typed DT |
| `Compiler/Generate/CodeGen/MLIR.elm` | Typed/MLIR | Change to typed DT |
| `Compiler/Generate/Monomorphize.elm` | Typed/MLIR | Change to typed DT* |

*Note: The design says to remove the DT import from Monomorphize.elm, but it's actually used in `specializeEdges` type signature (line 1804). Will need to change import rather than remove.

## Implementation Steps

### Step 1: Create `Compiler/Optimize/Typed/DecisionTree.elm`

**Location:** `compiler/src/Compiler/Optimize/Typed/DecisionTree.elm`

1. Copy entire contents from `compiler/src/Compiler/Optimize/Erased/DecisionTree.elm`
2. Change module declaration from `Compiler.Optimize.Erased.DecisionTree` to `Compiler.Optimize.Typed.DecisionTree`
3. Add `ContainerHint` to exports
4. Add `ContainerHint` type:
   ```elm
   type ContainerHint
       = HintList
       | HintTuple2
       | HintTuple3
       | HintCustom
       | HintUnknown
   ```
5. Change `Path` type from `Index Index.ZeroBased Path` to `Index Index.ZeroBased ContainerHint Path`
6. Update all pattern matches on `Path` to handle new `ContainerHint` parameter
7. Change `subPositions` signature to accept `ContainerHint`:
   ```elm
   subPositions : ContainerHint -> Path -> List Can.Pattern -> List ( Path, Can.Pattern )
   ```
8. Update `flatten` function:
   - `Can.PCtor` case: use `HintCustom`
   - `Can.PTuple` case: use `HintTuple2`/`HintTuple3`/`HintCustom` based on tuple size
   - `Can.PUnit` case: unchanged (no Index paths created, no hints needed)
9. Update `toRelevantBranch` function:
   - `Can.PList`/`Can.PCons` cases: use `HintList`
   - `Can.PCtor` case: use `HintCustom`
   - `Can.PTuple` case: calculate hint based on tuple size (same logic as `flatten`):
     ```elm
     Can.PTuple a b cs ->
         let
             all = a :: b :: cs
             len = List.length all
             hint =
                 case len of
                     2 -> HintTuple2
                     3 -> HintTuple3
                     _ -> HintCustom
         in
         Just (Branch goal (start ++ subPositions hint path all ++ end))
     ```
   - `Can.PUnit` case: unchanged (no Index paths created, no hints needed)
10. Add `containerHintEncoder` and `containerHintDecoder`
11. Update `pathEncoder` and `pathDecoder` to include hint

### Step 2: Update `Compiler/AST/TypedOptimized.elm`

**Location:** `compiler/src/Compiler/AST/TypedOptimized.elm`

1. Change import from `Compiler.Optimize.Erased.DecisionTree as DT` to `Compiler.Optimize.Typed.DecisionTree as DT`
2. No other changes needed - `Decider` type and encoders/decoders automatically use new typed DT

### Step 3: Update `Compiler/Optimize/Typed/Case.elm`

**Location:** `compiler/src/Compiler/Optimize/Typed/Case.elm`

1. Change import from `Compiler.Optimize.Erased.DecisionTree as DT` to `Compiler.Optimize.Typed.DecisionTree as DT`
2. No other changes needed

### Step 4: Update `Compiler/AST/Monomorphized.elm`

**Location:** `compiler/src/Compiler/AST/Monomorphized.elm`

1. Change import from `Compiler.Optimize.Erased.DecisionTree as DT` to `Compiler.Optimize.Typed.DecisionTree as DT`
2. No other changes needed - `Decider` type automatically uses new typed DT

### Step 5: Update `Compiler/Generate/Monomorphize.elm`

**Location:** `compiler/src/Compiler/Generate/Monomorphize.elm`

1. Change import from `Compiler.Optimize.Erased.DecisionTree as DT` to `Compiler.Optimize.Typed.DecisionTree as DT`
2. Note: Cannot remove import as design suggests - `DT.Test` is used in `specializeEdges` type signature

### Step 6: Update `Compiler/Generate/CodeGen/MLIR.elm`

**Location:** `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

1. Change import from `Compiler.Optimize.Erased.DecisionTree as DT` to `Compiler.Optimize.Typed.DecisionTree as DT`
2. Update `generateDTPath` function's `DT.Index` case:
   - Change pattern from `DT.Index index subPath` to `DT.Index index hint subPath`
   - Replace generic `ecoProject` call with hint-based dispatch:
     - `DT.HintList` + index 0 -> `ecoProjectListHead`
     - `DT.HintList` + index 1 -> `ecoProjectListTail`
     - `DT.HintTuple2` -> `ecoProjectTuple2`
     - `DT.HintTuple3` -> `ecoProjectTuple3`
     - `DT.HintCustom` -> `ecoProjectCustom`
     - `DT.HintUnknown` -> `ecoProjectCustom` (fallback)

### Step 7: Verify Erased Pipeline Unchanged

Verify these files still import erased DT and are unchanged:
- `Compiler/AST/Optimized.elm`
- `Compiler/Optimize/Erased/Case.elm`
- `Compiler/Generate/JavaScript/Expression.elm`

## Verification Plan

1. Build the compiler after each step to catch errors early
2. Run the full test suite after completion
3. Verify MLIR output uses type-specific projection ops instead of generic `eco.project`
4. Confirm JS output is unchanged (erased pipeline untouched)

## Questions (Resolved)

### Question 1: Tuple Handling in `toRelevantBranch` - RESOLVED

**Answer:** Yes, update `Can.PTuple` in `toRelevantBranch` with the same hint calculation logic as `flatten`. Required because `subPositions` signature changes.

### Question 2: Unit Handling - RESOLVED

**Answer:** No special handling needed. `Can.PUnit` doesn't create any `Index` paths (it passes through without creating sub-paths), so no hints are needed.

### Question 3: Binary Compatibility Verification - RESOLVED

**Answer:** No extra testing required. Breaking binary format is acceptable.

## Files Summary

| Action | File |
|--------|------|
| **ADD** | `compiler/src/Compiler/Optimize/Typed/DecisionTree.elm` |
| **MODIFY** | `compiler/src/Compiler/AST/TypedOptimized.elm` |
| **MODIFY** | `compiler/src/Compiler/Optimize/Typed/Case.elm` |
| **MODIFY** | `compiler/src/Compiler/AST/Monomorphized.elm` |
| **MODIFY** | `compiler/src/Compiler/Generate/Monomorphize.elm` |
| **MODIFY** | `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` |
| **UNCHANGED** | `compiler/src/Compiler/AST/Optimized.elm` |
| **UNCHANGED** | `compiler/src/Compiler/Optimize/Erased/Case.elm` |
| **UNCHANGED** | `compiler/src/Compiler/Optimize/Erased/DecisionTree.elm` |
| **UNCHANGED** | `compiler/src/Compiler/Generate/JavaScript/Expression.elm` |
