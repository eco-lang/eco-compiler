# TypedOpt IR Plan: Preserving Types for Native Code Generation

## Overview

This plan describes how to add a new `TypedOpt` IR to the Guida compiler that preserves type information through the optimization phase. This is needed for the MLIR backend to perform monomorphization and generate efficient native code.

## Current Architecture

### Compilation Pipeline

```
Source (.elm)
    │
    ▼ Parse
Source.Module
    │
    ▼ Canonicalize
Canonical.Module + Canonical.Expr (has SOME cached type info)
    │
    ▼ Type Check
Dict Name Can.Annotation (full type annotations for all definitions)
    │
    ▼ Optimize  ◄── TYPE ERASURE HAPPENS HERE
Opt.LocalGraph (NO type information)
    │
    ▼ Serialize
.guidao files (no types) + .guidai files (interfaces with types)
    │
    ▼ Code Generation
JavaScript output
```

### Where Types Exist Today

| Location | Has Types? | Details |
|----------|------------|---------|
| `Can.Expr_` | Partial | `VarForeign`, `VarCtor`, `VarDebug`, `VarOperator`, `Binop` have `Annotation` |
| `Can.TypedDef` | Yes | Has `(List (Pattern, Type))` for params and `Type` for return |
| `Dict Name Can.Annotation` | Yes | Complete mapping from type checker |
| `Opt.Expr` | No | All type info stripped |
| `Opt.Node` | No | Only names, dependencies, no types |
| `.guidao` files | No | Serialized `Opt.LocalGraph` |
| `.guidai` files | Yes | Contains `Interface` with `Dict Name Annotation` |

### Where Types Are Lost

In `Compiler/Optimize/Expression.elm`:

```elm
-- Line 46: Annotation discarded!
Can.VarForeign home name _ ->
    Names.registerGlobal region home name

-- Line 49: Annotation discarded!
Can.VarCtor opts home name index _ ->
    Names.registerCtor region home (A.At region name) index opts

-- Lines 278-279: Type information discarded from TypedDef!
Can.TypedDef (A.At region name) _ typedArgs body resultType ->
    -- Only pattern/expr used, types dropped
```

## Proposed Solution

### Design Principles

1. **Keep existing `Opt` module unchanged** - JavaScript backend continues to work
2. **New parallel `TypedOpt` module** - For backends that need types (MLIR)
3. **New `.guidato` files** - Typed optimized artifacts (alongside `.guidao`)
4. **Backend selection at build time** - Choose which artifacts to generate

### New Module Structure

```
src/Compiler/AST/
├── Optimized.elm          # Existing, unchanged
└── TypedOptimized.elm     # NEW: Typed version

src/Compiler/Optimize/
├── Module.elm             # Existing (produces Opt.LocalGraph)
├── Expression.elm         # Existing
├── TypedModule.elm        # NEW: Produces TypedOpt.LocalGraph
└── TypedExpression.elm    # NEW: Preserves types

src/Builder/
├── Stuff.elm              # Add guidato path function
└── Build.elm              # Add TypedOpt artifact handling
```

## Detailed Implementation Plan

### Phase 1: Define TypedOpt AST

Create `src/Compiler/AST/TypedOptimized.elm`:

```elm
module Compiler.AST.TypedOptimized exposing (..)

-- Typed expression: every expression has its type
type TypedExpr
    = TBool A.Region Bool Can.Type
    | TChr A.Region String Can.Type
    | TStr A.Region String Can.Type
    | TInt A.Region Int Can.Type
    | TFloat A.Region Float Can.Type
    | TVarLocal Name Can.Type
    | TVarGlobal A.Region Global Can.Type
    | TVarEnum A.Region Global Index.ZeroBased Can.Type
    | TVarBox A.Region Global Can.Type
    | TVarCycle A.Region IO.Canonical Name Can.Type
    | TVarDebug A.Region Name IO.Canonical (Maybe Name) Can.Type
    | TVarKernel A.Region Name Name Can.Type
    | TList A.Region (List TypedExpr) Can.Type
    | TFunction (List (Name, Can.Type)) TypedExpr Can.Type  -- params with types
    | TCall A.Region TypedExpr (List TypedExpr) Can.Type
    | TTailCall Name (List (Name, TypedExpr)) Can.Type
    | TIf (List (TypedExpr, TypedExpr)) TypedExpr Can.Type
    | TLet TypedDef TypedExpr Can.Type
    | TDestruct TypedDestructor TypedExpr Can.Type
    | TCase Name Name (Decider TypedChoice) (List (Int, TypedExpr)) Can.Type
    | TAccessor A.Region Name Can.Type
    | TAccess TypedExpr A.Region Name Can.Type
    | TUpdate A.Region TypedExpr (Dict (A.Located Name) TypedExpr) Can.Type
    | TRecord (Dict Name TypedExpr) Can.Type
    | TUnit Can.Type
    | TTuple A.Region TypedExpr TypedExpr (List TypedExpr) Can.Type
    | TShader Shader.Source (EverySet Name) (EverySet Name) Can.Type

-- Helper to extract type from any expression
typeOf : TypedExpr -> Can.Type
typeOf expr =
    case expr of
        TBool _ _ t -> t
        TChr _ _ t -> t
        -- ... etc

-- Typed definition
type TypedDef
    = TDef A.Region Name TypedExpr Can.Type
    | TTailDef A.Region Name (List (A.Located Name, Can.Type)) TypedExpr Can.Type

-- Typed node in the graph
type TypedNode
    = TDefine Can.Type TypedExpr (EverySet Global)
    | TDefineTailFunc A.Region Can.Type (List (A.Located Name, Can.Type)) TypedExpr (EverySet Global)
    | TCtor Index.ZeroBased Int Can.Type        -- ctor with its type
    | TEnum Index.ZeroBased Can.Type
    | TBox Can.Type
    | TLink Global
    | TCycle (List Name) (List (Name, TypedExpr)) (List TypedDef) (EverySet Global)
    | TManager EffectsType
    | TKernel (List K.Chunk) (EverySet Global)
    | TPortIncoming TypedExpr (EverySet Global)
    | TPortOutgoing TypedExpr (EverySet Global)

-- Typed local graph
type TypedLocalGraph
    = TypedLocalGraph
        (Maybe TypedMain)
        (Dict Global TypedNode)
        (Dict Name Int)                -- field frequencies (same as Opt)
        (Dict Name Can.Annotation)     -- all type annotations

type TypedMain
    = TStatic
    | TDynamic Can.Type TypedExpr

-- Typed global graph (for code generation)
type TypedGlobalGraph
    = TypedGlobalGraph
        (Dict Global TypedNode)
        (Dict Name Int)
        (Dict Name Can.Annotation)
```

### Phase 2: Create Typed Optimizer

Create `src/Compiler/Optimize/TypedModule.elm`:

```elm
module Compiler.Optimize.TypedModule exposing (optimize)

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Optimize.TypedExpression as TExpr

type alias Annotations = Dict Name Can.Annotation

optimize : Annotations -> Can.Module -> Result Error TOpt.TypedLocalGraph
optimize annotations (Can.Module home _ _ decls unions aliases _ effects) =
    -- Similar to Optimize.Module but preserves types
    addDecls home annotations decls <|
        addEffects home effects <|
            addUnions home unions <|
                addAliases home aliases <|
                    TOpt.TypedLocalGraph Nothing Dict.empty Dict.empty annotations
```

Create `src/Compiler/Optimize/TypedExpression.elm`:

```elm
module Compiler.Optimize.TypedExpression exposing (optimize)

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt

-- The key difference: we KEEP the type information
optimize : Annotations -> Can.Expr -> Names.Tracker TOpt.TypedExpr
optimize annotations (A.At region expression) =
    case expression of
        Can.VarLocal name ->
            -- Look up type from context/annotations
            let
                localType = lookupLocalType name
            in
            pure (TOpt.TVarLocal name localType)

        Can.VarForeign home name annotation ->
            -- KEEP the annotation!
            Names.registerGlobal region home name
                |> fmap (\_ -> TOpt.TVarGlobal region (Global home name) (annotationType annotation))

        Can.VarCtor opts home name index annotation ->
            -- KEEP the annotation!
            Names.registerCtor region home (A.At region name) index opts
                |> fmap (\_ -> TOpt.TVarEnum region (Global home name) index (annotationType annotation))

        Can.Call func args ->
            -- Infer result type from function type
            optimize annotations func
                |> bind (\optFunc ->
                    traverse (optimize annotations) args
                        |> fmap (\optArgs ->
                            let
                                resultType = inferCallResultType (typeOf optFunc) (List.length optArgs)
                            in
                            TOpt.TCall region optFunc optArgs resultType
                        )
                )

        Can.Lambda patterns body ->
            -- Get parameter types from context
            optimizeLambda annotations patterns body

        -- ... handle all other cases, preserving types ...

annotationType : Can.Annotation -> Can.Type
annotationType (Can.Forall _ tipe) = tipe

inferCallResultType : Can.Type -> Int -> Can.Type
inferCallResultType funcType numArgs =
    -- Peel off `numArgs` TLambda wrappers to get result type
    case (funcType, numArgs) of
        (_, 0) -> funcType
        (Can.TLambda _ result, n) -> inferCallResultType result (n - 1)
        _ -> funcType  -- shouldn't happen with well-typed code
```

### Phase 3: Add Serialization

In `src/Compiler/AST/TypedOptimized.elm`, add encoders/decoders:

```elm
-- Encoder
typedLocalGraphEncoder : TypedLocalGraph -> BE.Encoder
typedLocalGraphEncoder (TypedLocalGraph main nodes fields annotations) =
    BE.sequence
        [ BE.maybe typedMainEncoder main
        , BE.assocListDict compareGlobal globalEncoder typedNodeEncoder nodes
        , BE.assocListDict compare BE.string BE.int fields
        , BE.assocListDict compare BE.string Can.annotationEncoder annotations
        ]

typedExprEncoder : TypedExpr -> BE.Encoder
typedExprEncoder expr =
    case expr of
        TBool region value tipe ->
            BE.sequence
                [ BE.word8 0
                , A.regionEncoder region
                , BE.bool value
                , Can.typeEncoder tipe
                ]
        -- ... etc for all constructors

-- Decoder
typedLocalGraphDecoder : BD.Decoder TypedLocalGraph
typedLocalGraphDecoder =
    BD.map4 TypedLocalGraph
        (BD.maybe typedMainDecoder)
        (BD.assocListDict toComparableGlobal globalDecoder typedNodeDecoder)
        (BD.assocListDict identity BD.string BD.int)
        (BD.assocListDict identity BD.string Can.annotationDecoder)
```

### Phase 4: Add File Path for .guidato

In `src/Builder/Stuff.elm`:

```elm
guidato : String -> ModuleName.Raw -> String
guidato root name =
    toArtifactPath root name "guidato"
```

### Phase 5: Modify Build System

In `src/Builder/Build.elm`:

```elm
-- Add typed artifact storage
type Module
    = Fresh ModuleName.Raw I.Interface Opt.LocalGraph (Maybe TOpt.TypedLocalGraph)
    | Cached ModuleName.Raw Bool (MVar CachedInterface)

-- Modify compilation to optionally produce typed output
compileModule : ... -> Task ... (Opt.LocalGraph, Maybe TOpt.TypedLocalGraph)
compileModule ... =
    -- Existing compilation
    Compile.compile pkg ifaces modul
        |> Task.fmap (\result ->
            case result of
                Ok (Compile.Artifacts canonical annotations objects) ->
                    let
                        -- Optionally generate typed output
                        typedObjects =
                            if needsTypedOutput then
                                Just (TypedOptimize.optimize annotations canonical)
                            else
                                Nothing
                    in
                    Ok (objects, typedObjects)
                Err e ->
                    Err e
        )

-- Write typed artifacts
writeTypedArtifacts : ... -> Task ...
writeTypedArtifacts root name typedGraph =
    File.writeBinary TOpt.typedLocalGraphEncoder (Stuff.guidato root name) typedGraph
```

### Phase 6: Modify Code Generation Entry Point

In `src/Builder/Generate.elm`:

```elm
-- Add typed backend support
type Backend
    = JavaScriptBackend
    | MLIRBackend

-- For MLIR, load typed objects
loadTypedObjects : FilePath -> Details -> List Build.Module -> Task Exit.Generate TypedLoadingObjects
loadTypedObjects root details modules =
    -- Similar to loadObjects but loads .guidato files
    ...

-- Generate with types for MLIR
mlirGenerate : TypedGlobalGraph -> Mains -> String
mlirGenerate typedGraph mains =
    -- Use type information for monomorphization
    ...
```

## File Changes Summary

### New Files

| File | Purpose |
|------|---------|
| `src/Compiler/AST/TypedOptimized.elm` | TypedOpt AST definitions + encoders/decoders |
| `src/Compiler/Optimize/TypedModule.elm` | Module-level typed optimization |
| `src/Compiler/Optimize/TypedExpression.elm` | Expression-level typed optimization |

### Modified Files

| File | Changes |
|------|---------|
| `src/Builder/Stuff.elm` | Add `guidato` path function |
| `src/Builder/Build.elm` | Add `TypedLocalGraph` to `Module`, write `.guidato` files |
| `src/Builder/Generate.elm` | Add typed loading for MLIR backend |
| `src/Compiler/Compile.elm` | Optionally run typed optimizer |

## Artifact File Structure

After implementation:
```
guida-stuff/1.0.0/
├── MyModule.guidai      # Interface (types for dependent modules) - unchanged
├── MyModule.guidao      # Untyped optimized (for JS backend) - unchanged
└── MyModule.guidato     # Typed optimized (for MLIR backend) - NEW
```

## Size Estimation

The `.guidato` files will be larger than `.guidao` due to type annotations:

- Each expression gains a `Can.Type` (~20-100 bytes depending on complexity)
- `TypedNode` gains type annotations (~50-200 bytes)
- Annotations dictionary duplicated from `.guidai` (could be omitted if we load both)

**Optimization**: We could reference types by ID and store a type table, reducing redundancy.

## Migration Path

1. **Implement TypedOpt AST** (Phase 1) - No changes to existing behavior
2. **Implement TypedOptimize** (Phase 2) - Can be tested in isolation
3. **Add serialization** (Phase 3) - No changes to existing files
4. **Add .guidato paths** (Phase 4) - Trivial addition
5. **Modify Build** (Phase 5) - Behind feature flag initially
6. **Wire to MLIR backend** (Phase 6) - Only affects MLIR code path

## Testing Strategy

1. **Unit tests for TypedOptimize** - Ensure type preservation
2. **Round-trip tests** - Serialize/deserialize TypedLocalGraph
3. **Comparison tests** - Verify TypedOpt produces equivalent expressions to Opt (ignoring types)
4. **Integration tests** - Compile examples to both JS and MLIR, verify JS still works

## Open Questions

1. **Should `.guidato` include the annotations dict?**
   - Pro: Self-contained, no need to also load `.guidai`
   - Con: Duplicates data, larger files

2. **Type sharing/deduplication?**
   - Could use a type table + indices to reduce size
   - More complex but smaller files

3. **Lazy vs eager typed optimization?**
   - Could generate `.guidato` only when MLIR backend is requested
   - Saves time for JS-only builds

4. **Version compatibility?**
   - Compiler version in path handles this automatically
   - Old `.guidato` files invalidated on compiler update

## Conclusion

This plan provides a clean separation between the untyped `Opt` IR (for JavaScript) and the new `TypedOpt` IR (for native backends). The existing JavaScript compilation path remains unchanged, while the MLIR backend gains access to full type information needed for monomorphization and efficient code generation.

The implementation can proceed incrementally, with each phase independently testable and the existing functionality preserved throughout.
