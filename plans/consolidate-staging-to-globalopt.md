# Plan: Consolidate Staged-Curried Form Logic to GlobalOpt

## Overview

This plan refactors the compiler to make a clean separation between:
- **Monomorphize**: Builds correct closures according to whatever MonoType says about the first stage (reads `stageParamTypes` when creating closures)
- **GlobalOpt**: Normalizes which staging to use at control-flow joins, builds ABI wrappers, and enforces MONO_016 globally

This addresses the issues identified in the investigation:
1. Dead code (`Closure.buildAbiWrapper` never called)
2. Duplicated logic between phases
3. Tight coupling where GlobalOpt depends on `Compiler.Monomorphize.Segmentation`
4. `Segmentation.elm` is redundant with `Compiler.AST.Monomorphized` helpers

## Design Rationale

### What Monomorphize Does
- Type specialization and closure conversion
- **Stage-aware closure creation**: Uses `stageParamTypes`/`stageReturnType` to ensure closures have params consistent with their type's first stage
- Creates correct closures from the start so GlobalOpt sees well-formed values

### What GlobalOpt Does
- Picks common staging for `case` and `if` results using `chooseCanonicalSegmentation`
- Builds ABI wrappers for branches whose segmentation doesn't match the canonical choice
- Enforces MONO_016 globally via `validateClosureStaging`

### Why Monomorphize Can't Ignore Staging
The Mono IR and MONO_016 are stated in terms of staged-curried types. Monomorphize must read `stageParamTypes` when creating closures; otherwise GlobalOpt would see broken values and fail.

## Prerequisites

**VERIFIED**: All required helpers are **defined** in `Compiler.AST.Monomorphized` but **not yet exported**:
- `Segmentation` (type alias)
- `segmentLengths`
- `stageParamTypes`
- `stageReturnType`
- `stageArity`
- `chooseCanonicalSegmentation`
- `buildSegmentedFunctionType`
- `decomposeFunctionType`

These must be added to the module's export list before other phases can proceed.

---

## Phase 0: Export Staging Helpers from Monomorphized.elm

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

**Changes:**
Add to the module's exposing list:
```elm
module Compiler.AST.Monomorphized exposing
    ( MonoType(..), Literal(..), Constraint(..)
    , LambdaId(..)
    , Global(..), SpecKey(..), SpecId, SpecializationRegistry
    , MonoGraph(..), MainInfo(..), MonoNode(..), CtorShape, nodeType
    , MonoExpr(..), ClosureInfo, MonoDef(..), MonoDestructor(..), MonoPath(..)
    , Decider(..), MonoChoice(..)
    , ContainerKind(..)
    , typeOf
    , toComparableSpecKey, toComparableMonoType
    , getMonoPathType
    , monoTypeToDebugString
    , toComparableGlobal, toComparableLambdaId
    -- Staging/Segmentation helpers (added)
    , Segmentation
    , segmentLengths
    , stageParamTypes
    , stageReturnType
    , stageArity
    , chooseCanonicalSegmentation
    , buildSegmentedFunctionType
    , decomposeFunctionType
    )
```

**Rationale:** These functions already exist in the module but are internal. Exporting them allows Monomorphize and GlobalOpt to use `Mono.*` instead of `Seg.*`.

---

## Phase 1: Delete Dead Code

### 1.1 Remove `buildAbiWrapper` from Closure.elm

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm`

**Changes:**
1. Update exposing list to remove `buildAbiWrapper`:
   ```elm
   module Compiler.Monomorphize.Closure exposing
       ( ensureCallableTopLevel
       , freshParams, extractRegion, buildNestedCalls
       , computeClosureCaptures
       )
   ```

2. Delete the entire `buildAbiWrapper` function definition (lines ~304-399)

**Rationale:** This function is never called anywhere. `buildAbiWrapperGO` in GlobalOpt is the only ABI wrapper actually used.

---

## Phase 2: Replace Seg.* with Mono.* in Monomorphize

### 2.1 Update `Specialize.elm`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

**Changes:**
1. Replace import:
   ```elm
   -- BEFORE:
   import Compiler.Monomorphize.Segmentation as Seg

   -- AFTER:
   -- (remove Seg import, Mono is already imported)
   ```

2. Replace `Seg.decomposeFunctionType` (line 147) with `Mono.decomposeFunctionType`:
   ```elm
   -- BEFORE:
   ( flatArgTypes, flatRetType ) =
       Seg.decomposeFunctionType monoType0

   -- AFTER:
   ( flatArgTypes, flatRetType ) =
       Mono.decomposeFunctionType monoType0
   ```

3. Replace `Seg.stageParamTypes` in MONO_016 assertion (line 338) with `Mono.stageParamTypes`:
   ```elm
   -- BEFORE:
   stageArityCheck =
       Seg.stageParamTypes effectiveMonoType

   -- AFTER:
   stageArityCheck =
       Mono.stageParamTypes effectiveMonoType
   ```

4. Remove the `Seg` import line

**Note:** Keep the MONO_016 assertion in place - it catches bugs early. GlobalOpt validates globally, but catching issues during monomorphization is still valuable for debugging.

---

### 2.2 Update `Closure.elm`

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm`

**Current `Seg.*` usage (after deleting `buildAbiWrapper`):**
- `ensureCallableTopLevel`: `Seg.stageParamTypes`, `Seg.stageReturnType` (lines 61, 64)
- `buildNestedCalls`: `Seg.segmentLengths`, `Seg.stageReturnType` (lines 253, 276)

**Changes:**
1. Replace import:
   ```elm
   -- BEFORE:
   import Compiler.Monomorphize.Segmentation as Seg

   -- AFTER:
   -- (remove Seg import, Mono is already imported)
   ```

2. In `ensureCallableTopLevel`, replace:
   ```elm
   -- BEFORE:
   stageArgTypes = Seg.stageParamTypes monoType
   stageRetType = Seg.stageReturnType monoType

   -- AFTER:
   stageArgTypes = Mono.stageParamTypes monoType
   stageRetType = Mono.stageReturnType monoType
   ```

3. In `buildNestedCalls`, replace:
   ```elm
   -- BEFORE:
   srcSeg = Seg.segmentLengths calleeType
   resultType = Seg.stageReturnType currentCalleeType

   -- AFTER:
   srcSeg = Mono.segmentLengths calleeType
   resultType = Mono.stageReturnType currentCalleeType
   ```

4. Remove the `Seg` import line

**Important:** Keep `ensureCallableTopLevel` stage-aware. It must continue using `stageParamTypes`/`stageReturnType` to ensure closures satisfy MONO_016 from creation.

---

## Phase 3: Replace Seg.* with Mono.* in GlobalOpt

### 3.1 Update `MonoReturnArity.elm`

**File:** `compiler/src/Compiler/GlobalOpt/MonoReturnArity.elm`

**Changes:**
1. Remove import:
   ```elm
   -- DELETE: import Compiler.Monomorphize.Segmentation as Seg
   ```

2. Replace `Seg.stageParamTypes` with `Mono.stageParamTypes`:
   ```elm
   -- BEFORE:
   stageParamCount =
       List.length (Seg.stageParamTypes closureType)

   -- AFTER:
   stageParamCount =
       List.length (Mono.stageParamTypes closureType)
   ```

---

### 3.2 Update `MonoGlobalOptimize.elm`

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Changes:**
1. Remove import:
   ```elm
   -- DELETE: import Compiler.Monomorphize.Segmentation as Seg
   ```

2. Replace all `Seg.*` calls with `Mono.*`:

| Location | Before | After |
|----------|--------|-------|
| `buildAbiWrapperGO` | `Seg.segmentLengths targetType` | `Mono.segmentLengths targetType` |
| `buildAbiWrapperGO` | `Seg.segmentLengths srcType` | `Mono.segmentLengths srcType` |
| `buildStages` | `Seg.stageParamTypes remainingType` | `Mono.stageParamTypes remainingType` |
| `buildStages` | `Seg.stageReturnType remainingType` | `Mono.stageReturnType remainingType` |
| `rewriteCaseForAbi` | `Seg.chooseCanonicalSegmentation leafTypes` | `Mono.chooseCanonicalSegmentation leafTypes` |
| `rewriteCaseForAbi` | `Seg.buildSegmentedFunctionType flatArgs flatRet canonicalSeg` | `Mono.buildSegmentedFunctionType flatArgs flatRet canonicalSeg` |
| `rewriteCaseLeavesToAbiGO` | `Seg.segmentLengths (Mono.typeOf expr)` | `Mono.segmentLengths (Mono.typeOf expr)` |
| `rewriteIfForAbi` | `Seg.chooseCanonicalSegmentation leafTypes` | `Mono.chooseCanonicalSegmentation leafTypes` |
| `rewriteIfForAbi` | `Seg.buildSegmentedFunctionType flatArgs flatRet canonicalSeg` | `Mono.buildSegmentedFunctionType flatArgs flatRet canonicalSeg` |
| `rewriteIfForAbi` | `Seg.segmentLengths (Mono.typeOf expr)` | `Mono.segmentLengths (Mono.typeOf expr)` |
| `validateExprClosures` | `Seg.stageParamTypes tipe` | `Mono.stageParamTypes tipe` |

---

## Phase 4: Delete Segmentation.elm

**File:** `compiler/src/Compiler/Monomorphize/Segmentation.elm`

After Phases 2 and 3, `Segmentation.elm` will have no importers.

**Changes:**
1. Delete the entire file
2. Remove from any build configuration if needed

**Verification:** Before deleting, run:
```bash
cd compiler
grep -r "Compiler.Monomorphize.Segmentation" src/
```
This should return no results.

---

## Phase 5: Update Documentation

### 5.1 Update invariants.csv

**File:** `design_docs/invariants.csv`

Update MONO_016 entry to clarify:
- Monomorphize creates closures that satisfy MONO_016 (reads stageParamTypes)
- GlobalOpt enforces MONO_016 globally via `validateClosureStaging`

### 5.2 Update code comments

Update any comments that reference `Segmentation.elm` to point to `Mono.*` helpers instead.

---

## Phase 6: Testing

### 6.1 Run compiler tests

```bash
cd compiler
npx elm-test-rs --fuzz 1
```

### 6.2 Run full E2E tests

```bash
cmake --build build --target check
```

### 6.3 Run boundary check

```bash
cd compiler
npx elm-review --rules EnforceBoundaries
```

**Note:** Leave existing tests as-is. Address any test failures as they arise rather than preemptively modifying tests.

---

## Expected Behavior Changes

1. **No semantic changes** to generated code - same algorithms, different import source

2. **Cleaner phase boundaries**:
   - Monomorphize: type specialization, closure creation (stage-aware)
   - GlobalOpt: ABI normalization at control-flow joins, global MONO_016 validation

3. **Reduced coupling**: GlobalOpt no longer imports from `Compiler.Monomorphize.*` for segmentation utilities

---

## Files Modified Summary

| File | Changes |
|------|---------|
| `Compiler/AST/Monomorphized.elm` | Export `Segmentation` and staging helper functions |
| `Compiler/Monomorphize/Closure.elm` | Remove `buildAbiWrapper`, replace `Seg.*` with `Mono.*`, remove `Seg` import |
| `Compiler/Monomorphize/Specialize.elm` | Replace `Seg.*` with `Mono.*`, remove `Seg` import |
| `Compiler/GlobalOpt/MonoReturnArity.elm` | Replace `Seg.*` with `Mono.*`, remove `Seg` import |
| `Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Replace `Seg.*` with `Mono.*`, remove `Seg` import |
| `Compiler/Monomorphize/Segmentation.elm` | **DELETE ENTIRE FILE** |
| `design_docs/invariants.csv` | Update MONO_016 description |

---

## Questions Resolved

1. **Should we remove `Segmentation.elm` entirely?**
   - **YES** - Delete it after migrating all uses to `Mono.*`

2. **Are there tests that expect MONO_016 failures in Monomorphize?**
   - Leave tests as-is, address later if any fail

3. **Should `ensureCallableTopLevel` be staging-agnostic?**
   - **NO** - Keep it stage-aware. Monomorphize must create closures that satisfy MONO_016 from the start.

4. **Does `Segmentation` type alias need to be added to `Mono.*`?**
   - It already exists in the module, just needs to be exported (handled in Phase 0)

5. **What about the MONO_016 assertion in `specializeLambda`?**
   - Keep it as an early-catch mechanism for debugging. GlobalOpt is the authoritative enforcer, but catching issues during monomorphization is still valuable.
