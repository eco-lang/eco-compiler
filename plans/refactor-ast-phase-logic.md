# Plan: Refactor Compiler Phase Logic Out of AST/ Folder

## Overview

The `compiler/src/Compiler/AST/` folder should contain only:
- Data type definitions for compiler IRs
- Simple property accessors: `readSomeProperty : IR -> ...`
- Simple property setters: `setSomeProperty : ... -> IR -> IR`
- Encoders/decoders for serialization
- Comparison/ordering functions

However, several files contain **compiler phase logic** that performs transformations, builds complex structures, or implements algorithms specific to particular compilation phases. This plan outlines moving that logic to the appropriate compiler phases.

**Principle**: When logic could move to multiple phases, move it to the **earliest** phase that uses it, since early phases cannot depend on later ones.

---

## Phase 1: Graph Assembly Functions (AST/Optimized.elm, AST/TypedOptimized.elm)

### Functions to Move

**From `AST/Optimized.elm`:**
| Function | Lines | Description |
|----------|-------|-------------|
| `addGlobalGraph` | 250-253 | Merges two GlobalGraphs |
| `addLocalGraph` | 259-262 | Merges LocalGraph into GlobalGraph |
| `addKernel` | 268-280 | Adds kernel to GlobalGraph |
| `addKernelDep` | (helper) | Computes kernel dependencies |

**From `AST/TypedOptimized.elm`:**
| Function | Lines | Description |
|----------|-------|-------------|
| `addGlobalGraph` | ~similar | Merges two TypedGlobalGraphs |
| `addLocalGraph` | ~similar | Merges TypedLocalGraph into TypedGlobalGraph |

### Current Usage
- `Builder/Elm/Details.elm` - package artifact assembly
- `Builder/Generate.elm` - code generation graph assembly

### Target Location
Create new module: **`Builder/GraphAssembly.elm`**

This is build-time linking logic, not a compiler phase per se, so it belongs in `Builder/`.

### Changes Required

1. Create `Builder/GraphAssembly.elm` with:
   ```elm
   module Builder.GraphAssembly exposing
       ( addOptGlobalGraph, addOptLocalGraph, addOptKernel
       , addTypedGlobalGraph, addTypedLocalGraph
       )
   ```

2. Move function bodies from `AST/Optimized.elm` and `AST/TypedOptimized.elm`

3. Update imports in:
   - `Builder/Elm/Details.elm`
   - `Builder/Generate.elm`

4. Remove functions from `AST/Optimized.elm` and `AST/TypedOptimized.elm` exports

---

## Phase 2: TypedCanonical Transformation (AST/TypedCanonical.elm)

### Functions to Move

| Function | Lines | Description |
|----------|-------|-------------|
| `fromCanonical` | 158-172 | Transforms Can.Module → TCan.Module |
| `toTypedDecls` | 176-189 | Transforms Can.Decls → TCan.Decls |
| `toTypedDef` | 193-199 | Transforms Can.Def → TCan.Def |
| `toTypedExpr` | 212-228 | Annotates expressions with types |

### Current Usage
- `Compiler/Compile.elm` (line 266) - single call site

### Target Location
**`Compiler/TypedCanonical/Build.elm`** (new module)

### Changes Required

1. Create `Compiler/TypedCanonical/Build.elm`:
   ```elm
   module Compiler.TypedCanonical.Build exposing (fromCanonical)
   ```

2. Move `fromCanonical`, `toTypedDecls`, `toTypedDef`, `toTypedExpr` to the new module (only `fromCanonical` needs to be exposed)

2. Update `Compiler/Compile.elm` imports

3. Remove functions from `AST/TypedCanonical.elm` exports

4. Keep only type definitions and `tipe` accessor in `AST/TypedCanonical.elm`

---

## Phase 3: TypeEnv Construction (AST/TypeEnv.elm)

### Functions to Move

| Function | Lines | Description |
|----------|-------|-------------|
| `fromCanonical` | 73-77 | Extracts ModuleTypeEnv from Can.Module |
| `fromInterface` | 87-91 | Constructs ModuleTypeEnv from Interface |
| `fromInterfaces` | 101-111 | Builds GlobalTypeEnv from interfaces |

### Current Usage
- `Compiler/Compile.elm` (line 152) - single call site

### Target Location
**`Compiler/Compile.elm`** (inline) or keep in `AST/TypeEnv.elm` as these are simple constructors

### Recommendation
These are borderline - they're essentially constructors that extract/reorganize data. **Keep in `AST/TypeEnv.elm`** but document them as "construction helpers" rather than transformation logic.

### Changes Required
- Add documentation clarifying these are construction utilities
- No code movement needed

---

## Phase 4: Type Normalization Utilities (AST/Utils/Type.elm)

### Functions to Relocate

| Function | Lines | Description | Used By (Earliest First) |
|----------|-------|-------------|--------------------------|
| `delambda` | 36-43 | Flattens function type to list | Canonicalize/Effects |
| `dealias` | 53-60 | Expands type alias | Canonicalize/Effects |
| `deepDealias` | 105-128 | Recursively expands all aliases | Canonicalize/Effects |
| `iteratedDealias` | 142-149 | Expands top-level aliases | Canonicalize/Expression |

### Current Usage (by phase order)
1. `Compiler/Canonicalize/Effects.elm` - `delambda`, `dealias`, `deepDealias`
2. `Compiler/Canonicalize/Expression.elm` - `iteratedDealias`
3. `Compiler/Type/Type.elm` - `iteratedDealias`
4. `Compiler/LocalOpt/Typed/Port.elm` - `dealias`
5. `Compiler/LocalOpt/Erased/Port.elm` - `dealias`
6. `Compiler/LocalOpt/Typed/Module.elm` - `deepDealias`
7. `Compiler/LocalOpt/Erased/Module.elm` - `deepDealias`
8. `Compiler/Elm/Compiler/Type/Extract.elm` - `dealias`

### Target Location
**`Compiler/Type/Normalize.elm`** (new module)

The earliest significant user is Canonicalize, but these utilities are fundamentally about *type* manipulation and are used across many phases. Placing them in `Compiler/Type/` makes them accessible to all phases that need them.

### Changes Required

1. Create `Compiler/Type/Normalize.elm`:
   ```elm
   module Compiler.Type.Normalize exposing
       ( delambda
       , dealias, deepDealias, iteratedDealias
       )
   ```

2. Move all functions from `AST/Utils/Type.elm`

3. Update imports in all 8 dependent files

4. Delete `AST/Utils/Type.elm`

---

## Phase 5: Specialization Registry (AST/Monomorphized.elm)

### Functions to Move

| Function | Description |
|----------|-------------|
| `emptyRegistry` | Creates empty SpecializationRegistry |
| `getOrCreateSpecId` | Gets/creates specialization ID |
| `lookupSpecKey` | Looks up SpecKey in registry |
| `updateRegistryType` | Updates registry entry |

### Current Usage
- `Compiler/Monomorphize/Monomorphize.elm`
- `Compiler/Monomorphize/Specialize.elm`

### Target Location
**`Compiler/Monomorphize/Registry.elm`** (new module)

### Changes Required

1. Create `Compiler/Monomorphize/Registry.elm`:
   ```elm
   module Compiler.Monomorphize.Registry exposing
       ( SpecializationRegistry
       , emptyRegistry
       , getOrCreateSpecId
       , lookupSpecKey
       , updateRegistryType
       )
   ```

2. Move `SpecializationRegistry` type and related functions

3. Keep `SpecId`, `SpecKey` types in `AST/Monomorphized.elm` (they're data types)

4. Update imports in:
   - `Compiler/Monomorphize/Monomorphize.elm`
   - `Compiler/Monomorphize/Specialize.elm`

5. Update `AST/Monomorphized.elm` exports

---

## Phase 6: Segmentation Logic (AST/Monomorphized.elm)

### Functions to Move

| Function | Description |
|----------|-------------|
| `segmentLengths` | Computes currying segmentation |
| `chooseCanonicalSegmentation` | Picks canonical segmentation from branches |
| `buildSegmentedFunctionType` | Constructs nested MFunction |
| `decomposeFunctionType` | Breaks function to flat args + return |
| `countTotalArity` | Counts total arity |
| `stageParamTypes` | Gets params for a stage |
| `stageArity` | Gets arity for a stage |
| `stageReturnType` | Gets return type for a stage |

### Current Usage (by phase order)
1. `Compiler/Monomorphize/Closure.elm` - `segmentLengths`
2. `Compiler/GlobalOpt/MonoGlobalOptimize.elm` - `segmentLengths`, `chooseCanonicalSegmentation`, `buildSegmentedFunctionType`

### Target Location
**`Compiler/Monomorphize/Segmentation.elm`** (new module)

The earliest phase using this is Monomorphize/Closure.

### Changes Required

1. Create `Compiler/Monomorphize/Segmentation.elm`:
   ```elm
   module Compiler.Monomorphize.Segmentation exposing
       ( segmentLengths
       , chooseCanonicalSegmentation
       , buildSegmentedFunctionType
       , decomposeFunctionType
       , countTotalArity
       , stageParamTypes, stageArity, stageReturnType
       , Segmentation
       )
   ```

2. Move `Segmentation` type and all segmentation functions

3. Update imports in:
   - `Compiler/Monomorphize/Closure.elm`
   - `Compiler/GlobalOpt/MonoGlobalOptimize.elm`

4. Update `AST/Monomorphized.elm` exports

---

## Implementation Order

Execute phases in this order to minimize intermediate breakage:

1. **Phase 1**: Graph Assembly (isolated, Builder-only)
2. **Phase 4**: Type Normalization (many dependents, but simple)
3. **Phase 5**: Specialization Registry (Monomorphize-only)
4. **Phase 6**: Segmentation Logic (Monomorphize + GlobalOpt)
5. **Phase 2**: TypedCanonical Transformation (single user)
6. **Phase 3**: TypeEnv Construction (evaluation only, may skip)

---

## Verification

After each phase:

1. Run `cd compiler && npx elm-test-rs --fuzz 1` to verify Elm tests pass
2. Run `cmake --build build --target check` to verify full build

---

## Files Created

| New File | Content |
|----------|---------|
| `Builder/GraphAssembly.elm` | Graph merging functions |
| `Compiler/TypedCanonical/Build.elm` | TypedCanonical construction from Canonical |
| `Compiler/Type/Normalize.elm` | Type alias expansion utilities |
| `Compiler/Monomorphize/Registry.elm` | Specialization registry logic |
| `Compiler/Monomorphize/Segmentation.elm` | Currying segmentation logic |

## Files Modified

| File | Changes |
|------|---------|
| `AST/Optimized.elm` | Remove `addGlobalGraph`, `addLocalGraph`, `addKernel` |
| `AST/TypedOptimized.elm` | Remove `addGlobalGraph`, `addLocalGraph` |
| `AST/TypedCanonical.elm` | Remove transformation functions |
| `AST/Monomorphized.elm` | Remove registry and segmentation functions |
| `Compiler/Compile.elm` | Update import to use `Compiler.TypedCanonical.Build` |
| Various dependents | Update imports |

## Files Deleted

| File | Reason |
|------|--------|
| `AST/Utils/Type.elm` | Moved to `Compiler/Type/Normalize.elm` |

## Files Unchanged (Confirmed Appropriate)

| File | Reason to Keep |
|------|----------------|
| `AST/Utils/Binop.elm` | Only type definitions and encoders/decoders |
| `AST/Utils/Shader.elm` | Only type definitions and encoders/decoders |
| `AST/DecisionTree/Test.elm` | Only type definitions and encoders/decoders |
| `AST/DecisionTree/Path.elm` | Only type definitions and encoders/decoders |
| `AST/DecisionTree/TypedPath.elm` | Only type definitions and encoders/decoders |
| `AST/TypeEnv.elm` | Construction utilities are acceptable (simple data extraction) |

---

## What Remains in AST/

After refactoring, AST/ will contain only:

- **Type definitions** for all IRs
- **Simple accessors**: `typeOf`, `nodeType`, `getMonoPathType`, `fieldsToList`, `tipe`
- **Comparison functions**: `toComparable*`, `compare*`
- **Encoders/Decoders**: All `*Encoder`, `*Decoder` functions
- **Debug utilities**: `monoTypeToDebugString`
- **Pure queries**: `isFunctionType`, `functionArity` (no transformation)
- **Construction utilities** (borderline): `TypeEnv.from*` functions

This aligns with the principle that AST/ defines *what* the data structures are, while compiler phases define *how* to transform them.
