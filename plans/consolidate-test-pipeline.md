# Consolidate Test Pipeline

## Problem Statement

The test logic files in `compiler/tests/TestLogic/` contain significant duplication of compilation pipeline code. While a shared module exists (`TypedOptimizedMonomorphize`), many tests either:
1. Duplicate the same helper functions (e.g., `runWithIdsTypeCheck` appears in 5 files)
2. Write their own pipeline because they need intermediate artifacts the shared module doesn't expose
3. Need only early pipeline stages but must write boilerplate for canonicalization

## Design Decisions

1. **Module name**: `TestPipeline` (renamed from `TypedOptimizedMonomorphize`)
2. **GenerateMLIR**: Fully merged into `TestPipeline`
3. **Design principle**: Maximal exposure - the shared pipeline exposes ALL intermediate compilation artifacts
4. **Artifact design**: Cumulative - each stage returns ALL artifacts available up to that point
5. **Legacy aliases**: Temporary for migration, removed in final phase
6. **Exception tests**: Even tests with special needs use the pipeline as much as possible

## Current Duplication

### `runWithIdsTypeCheck` - 5 copies
- `TypedOptimizedMonomorphize.elm:126-141`
- `GenerateMLIR.elm:138-153`
- `CompileThroughPostSolve.elm:100-124`
- `TypePreservation.elm:168-188`
- `OptimizeEquivalent.elm:144-160`

### Pipeline helpers duplicated between TOMono and GenerateMLIR
- `runTypedOptimization` (~25 lines)
- `localGraphToGlobalGraph` (~3 lines)
- `buildGlobalTypeEnv` (~12 lines)
- `monomorphizeAny` (~12 lines)
- `findAnyEntryPoint` (~20 lines)
- `runWithIdsTypeCheck` (~20 lines)

### Tests with custom canonicalization boilerplate
- `IdAssignment.elm`
- `GlobalNames.elm`
- `DuplicateDecls.elm`

## Target Architecture

### New Module: `TestLogic.TestPipeline`

Location: `compiler/tests/TestLogic/TestPipeline.elm`

```elm
module TestLogic.TestPipeline exposing
    ( -- Cumulative artifact types
      CanonicalArtifacts
    , TypeCheckArtifacts
    , PostSolveArtifacts
    , TypedOptArtifacts
    , MonoArtifacts
    , MlirArtifacts

    -- Pipeline entry points (each runs full pipeline to that stage)
    , runToCanonical
    , runToTypeCheck
    , runToPostSolve
    , runToTypedOpt
    , runToMono
    , runToMlir

    -- Low-level helpers (for tests needing fine-grained control)
    , runWithIdsTypeCheck
    , localGraphToGlobalGraph
    , buildGlobalTypeEnv
    , monomorphizeAny
    , findAnyEntryPoint
    , runMLIRGeneration
    )
```

### Artifact Types (Cumulative)

Each stage's artifact type includes ALL previous stages' outputs:

```elm
-- Stage 1: Canonicalization
type alias CanonicalArtifacts =
    { canonical : Can.Module
    }

-- Stage 2: Type Checking (includes Stage 1)
type alias TypeCheckArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : Dict Int Int Can.Type  -- Pre-PostSolve
    }

-- Stage 3: PostSolve (includes Stages 1-2)
type alias PostSolveArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypesPre : Dict Int Int Can.Type   -- Before PostSolve
    , nodeTypesPost : PostSolve.NodeTypes    -- After PostSolve
    , kernelEnv : KernelTypes.KernelTypeEnv
    }

-- Stage 4: Typed Optimization (includes Stages 1-3)
type alias TypedOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    }

-- Stage 5: Monomorphization (includes Stages 1-4)
type alias MonoArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    , globalGraph : TOpt.GlobalGraph
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    }

-- Stage 6: MLIR Generation (includes Stages 1-5)
type alias MlirArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    , globalGraph : TOpt.GlobalGraph
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    , mlirModule : MlirModule
    , mlirOutput : String
    }
```

### Pipeline Entry Points

```elm
runToCanonical : Src.Module -> Result String CanonicalArtifacts

runToTypeCheck : Src.Module -> Result String TypeCheckArtifacts

runToPostSolve : Src.Module -> Result String PostSolveArtifacts

runToTypedOpt : Src.Module -> Result String TypedOptArtifacts

runToMono : Src.Module -> Result String MonoArtifacts

runToMlir : Src.Module -> Result String MlirArtifacts
```

### Usage Patterns

**Test needing only monoGraph:**
```elm
case Pipeline.runToMono srcModule of
    Err msg -> Expect.fail msg
    Ok { monoGraph } -> checkMonoGraph monoGraph
```

**Test needing canonical AND monoGraph:**
```elm
case Pipeline.runToMono srcModule of
    Err msg -> Expect.fail msg
    Ok { canonical, monoGraph } -> checkBoth canonical monoGraph
```

**Test needing nodeTypesPre AND nodeTypesPost:**
```elm
case Pipeline.runToPostSolve srcModule of
    Err msg -> Expect.fail msg
    Ok { nodeTypesPre, nodeTypesPost } -> compareNodeTypes nodeTypesPre nodeTypesPost
```

**Test needing localGraph AND kernelEnv:**
```elm
case Pipeline.runToTypedOpt srcModule of
    Err msg -> Expect.fail msg
    Ok { localGraph, kernelEnv } -> checkWithEnv localGraph kernelEnv
```

## Implementation Plan

### Phase 1: Create TestPipeline Module

1. **Create `TestLogic/TestPipeline.elm`**
   - Define all cumulative artifact types
   - Implement pipeline entry points (each builds on previous)
   - Move helper functions from TypedOptimizedMonomorphize
   - Move MLIR generation from GenerateMLIR

2. **Internal implementation** - each stage calls previous and extends:
   ```elm
   runToCanonical : Src.Module -> Result String CanonicalArtifacts
   runToCanonical srcModule =
       case Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule |> Result.run of
           ( _, Err errors ) -> Err (formatErrors errors)
           ( _, Ok canonical ) -> Ok { canonical = canonical }

   runToTypeCheck : Src.Module -> Result String TypeCheckArtifacts
   runToTypeCheck srcModule =
       case runToCanonical srcModule of
           Err e -> Err e
           Ok { canonical } ->
               case IO.unsafePerformIO (runWithIdsTypeCheck canonical) of
                   Err count -> Err ("Type checking failed with " ++ String.fromInt count ++ " error(s)")
                   Ok { annotations, nodeTypes } ->
                       Ok { canonical = canonical
                          , annotations = annotations
                          , nodeTypes = nodeTypes
                          }

   -- etc., each stage extending the previous
   ```

3. **Add temporary legacy aliases** for backward compatibility:
   ```elm
   -- TEMPORARY: Remove in Phase 5
   runToMonoGraph : Src.Module -> Result String Mono.MonoGraph
   runToMonoGraph src = runToMono src |> Result.map .monoGraph

   runToTypedOptimized : Src.Module -> Result String TypedOptResult
   -- Returns record matching old TypedOptResult shape

   compileToMlirModule : Src.Module -> Result String CompileResult
   -- Returns record matching old CompileResult shape
   ```

### Phase 2: Create Compatibility Shims

1. **Update `TypedOptimizedMonomorphize.elm`** to re-export from TestPipeline:
   ```elm
   module TestLogic.Generate.TypedOptimizedMonomorphize exposing (..)
   import TestLogic.TestPipeline exposing (..)
   ```

2. **Update `GenerateMLIR.elm`** to re-export from TestPipeline:
   ```elm
   module TestLogic.Generate.CodeGen.GenerateMLIR exposing (..)
   import TestLogic.TestPipeline exposing (..)
   ```

### Phase 3: Migrate Test Files

**Group A: Simple import change (27 files using TOMono)**

```elm
-- Before
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono
...
case TOMono.runToMonoGraph srcModule of

-- After
import TestLogic.TestPipeline as Pipeline
...
case Pipeline.runToMono srcModule of
    Ok { monoGraph } -> ...
```

Files: All Generate/, Monomorphize/, most LocalOpt/, some Type/, some Canonicalize/

**Group B: Canonicalize-only tests (3 files)**

`IdAssignment.elm`, `GlobalNames.elm`, `DuplicateDecls.elm`:
```elm
-- Before
let result = Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces modul
in case Result.run result of ...

-- After
case Pipeline.runToCanonical modul of
    Err msg -> Expect.fail msg
    Ok { canonical } -> ...
```

**Group C: Tests needing extended artifacts (3 files)**

`CompileThroughPostSolve.elm`:
```elm
-- Before: own pipeline
-- After: use runToPostSolve which includes nodeTypesPre
case Pipeline.runToPostSolve srcModule of
    Ok { nodeTypesPre, nodeTypesPost, kernelEnv, canonical } -> ...
```

`TypePreservation.elm`:
```elm
-- Before: own pipeline
-- After: use runToTypedOpt which includes kernelEnv
case Pipeline.runToTypedOpt srcModule of
    Ok { localGraph, kernelEnv, annotations } -> ...
```

`OptimizeEquivalent.elm`:
```elm
-- Before: own runWithIdsTypeCheck
-- After: import from Pipeline
import TestLogic.TestPipeline exposing (runWithIdsTypeCheck)
```

**Group D: MLIR tests (45+ files)**
```elm
-- Before
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)

-- After
import TestLogic.TestPipeline as Pipeline
...
case Pipeline.runToMlir srcModule of
    Ok { mlirModule } -> ...
```

**Group E: Exception tests using partial pipeline (3 files)**

`AnnotationEnforcement.elm`:
```elm
case Pipeline.runToCanonical srcModule of
    Err msg -> Expect.fail msg
    Ok { canonical } ->
        -- Custom type checking that expects errors
        let result = IO.unsafePerformIO (customTypeCheck canonical) in
        ...
```

`UnificationErrors.elm` - same pattern

`TypedErasedCheckingParity.elm`:
```elm
case Pipeline.runToCanonical srcModule of
    Ok { canonical } ->
        let
            standardResult = IO.unsafePerformIO (runStandardPath canonical)
            withIdsResult = IO.unsafePerformIO (runWithIdsPath canonical)
        in
        -- Compare the two paths
```

### Phase 4: Delete Compatibility Shims

1. **Delete `TestLogic/Generate/TypedOptimizedMonomorphize.elm`**
2. **Delete `TestLogic/Generate/CodeGen/GenerateMLIR.elm`**
3. **Remove duplicated code from**:
   - `CompileThroughPostSolve.elm` (delete local runWithIdsTypeCheck, pipeline code)
   - `TypePreservation.elm` (delete local runWithIdsTypeCheck, pipeline code)
   - `OptimizeEquivalent.elm` (delete local runWithIdsTypeCheck)

### Phase 5: Remove Legacy Aliases

Remove from `TestPipeline.elm`:
- `runToMonoGraph` (use `runToMono` + destructure `.monoGraph`)
- `runToTypedOptimized` (use `runToTypedOpt`)
- `compileToMlirModule` (use `runToMlir`)
- Old type aliases: `TypedOptResult`, `PostSolveResult`, `CompileResult`

Update any remaining consumers to use new names.

### Phase 6: Final Cleanup

1. Update module documentation
2. Verify no orphaned imports
3. Run full test suite

## File Changes Summary

### New Files
- `TestLogic/TestPipeline.elm` (~400 lines)

### Deleted Files
- `TestLogic/Generate/TypedOptimizedMonomorphize.elm`
- `TestLogic/Generate/CodeGen/GenerateMLIR.elm`

### Modified Files
- 27 files: TOMono → Pipeline import change
- 45+ files: GenerateMLIR → Pipeline import change
- 3 files: Custom canonicalization → Pipeline.runToCanonical
- 3 files: Custom pipeline → Pipeline with extended artifacts
- 3 files: Exception tests → Pipeline.runToCanonical + custom remainder

### Lines of Code Impact
- **Deleted**: ~450 lines (duplicated pipeline code, old modules)
- **Added**: ~400 lines (TestPipeline.elm with cumulative types)
- **Net reduction**: ~50 lines
- **Complexity reduction**: Significant (single source of truth)

## Verification

After each phase, run:
```bash
cd compiler && npx elm-test-rs --fuzz 1
```

## Success Criteria

1. Single `TestPipeline.elm` module contains all shared pipeline code
2. `runWithIdsTypeCheck` exists in exactly ONE location
3. No pipeline helper functions duplicated anywhere
4. All tests use `Pipeline.runToCanonical` for canonicalization (even exception tests)
5. Legacy shim files deleted
6. Legacy aliases removed
7. Test suite passes completely
