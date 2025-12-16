module Compiler.Compile exposing
    ( Artifacts(..)
    , TypedArtifacts(..)
    , TypedArtifactsData
    , compile
    , compileTyped
    )

{-| Orchestrates the full compilation pipeline from source to optimized artifacts.

This module provides the main entry points for compiling Elm modules. It coordinates
the complete transformation from parsed source code through canonicalization, type
checking, pattern match verification, and optimization.

The compilation pipeline consists of four phases:

1.  **Canonicalization** - Resolves all names to their home modules
2.  **Type Checking** - Infers and verifies types via constraint solving
3.  **Nitpicking** - Verifies pattern match exhaustiveness
4.  **Optimization** - Produces efficient intermediate representation


# Compilation

@docs compile, compileTyped


# Artifacts

@docs Artifacts, TypedArtifacts, TypedArtifactsData

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Nitpick.PatternMatches as PatternMatches
import Compiler.Optimize.Module as Optimize
import Compiler.Optimize.TypedModule as TypedOptimize
import Compiler.Reporting.Error as E
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Compiler.Reporting.Result as ReportingResult
import Compiler.Type.Constrain.Module as Type
import Compiler.Type.Solve as Type
import Data.Map exposing (Dict)
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)



-- ====== Artifacts ======


{-| Compilation artifacts produced by the standard compilation pipeline.

Contains the canonical AST, type annotations for all definitions, and the
optimized local graph suitable for JavaScript code generation.

-}
type Artifacts
    = Artifacts Can.Module (Dict String Name Can.Annotation) Opt.LocalGraph


{-| Extended compilation artifacts with typed optimization for MLIR backend.

In addition to standard artifacts, includes a typed optimization graph that
preserves full type information throughout the optimization process. This
enables type-directed optimizations and direct lowering to MLIR.

-}
type alias TypedArtifactsData =
    { canonical : Can.Module
    , annotations : Dict String Name Can.Annotation
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph
    }


{-| Wrapper for typed compilation artifacts.
-}
type TypedArtifacts
    = TypedArtifacts TypedArtifactsData



-- ====== Compilation ======


{-| Compiles an Elm module through the complete pipeline.

Executes all compilation phases in sequence:

1.  Canonicalization - resolves names and imports
2.  Type checking - infers and verifies types
3.  Pattern match analysis - ensures exhaustiveness
4.  Optimization - produces efficient intermediate representation

Returns artifacts suitable for JavaScript code generation.

-}
compile : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error Artifacts)
compile pkg ifaces modul =
    Task.succeed
        (canonicalize pkg ifaces modul
            |> (\canonicalResult ->
                    case canonicalResult of
                        Ok canonical ->
                            Result.map2 (\annotations () -> annotations)
                                (typeCheck modul canonical)
                                (nitpick canonical)
                                |> Result.andThen
                                    (\annotations ->
                                        optimize modul annotations canonical
                                            |> Result.map (\objects -> Artifacts canonical annotations objects)
                                    )

                        Err err ->
                            Err err
               )
        )


{-| Compiles an Elm module with typed optimization for native code generation.

Performs all standard compilation phases plus typed optimization, producing:

  - `Opt.LocalGraph` - Standard optimized IR for JavaScript backend
  - `TOpt.LocalGraph` - Typed optimized IR with preserved type information

The typed optimization phase preserves type information needed for monomorphization
and direct lowering to MLIR/LLVM.

-}
compileTyped : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error TypedArtifacts)
compileTyped pkg ifaces modul =
    Task.succeed
        (canonicalize pkg ifaces modul
            |> (\canonicalResult ->
                    case canonicalResult of
                        Ok canonical ->
                            Result.map2 (\annotations () -> annotations)
                                (typeCheck modul canonical)
                                (nitpick canonical)
                                |> Result.andThen
                                    (\annotations ->
                                        optimize modul annotations canonical
                                            |> Result.andThen
                                                (\objects ->
                                                    typedOptimize modul annotations canonical
                                                        |> Result.map (\typedObjects -> TypedArtifacts { canonical = canonical, annotations = annotations, objects = objects, typedObjects = typedObjects })
                                                )
                                    )

                        Err err ->
                            Err err
               )
        )



-- ====== Internal Compilation Phases ======


-- Converts source AST to canonical form, resolving all names and imports.
canonicalize : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Result E.Error Can.Module
canonicalize pkg ifaces modul =
    case Tuple.second (ReportingResult.run (Canonicalize.canonicalize pkg ifaces modul)) of
        Ok canonical ->
            Ok canonical

        Err errors ->
            Err (E.BadNames errors)


-- Infers and verifies types for all definitions in the canonical module.
typeCheck : Src.Module -> Can.Module -> Result E.Error (Dict String Name Can.Annotation)
typeCheck modul canonical =
    case Type.constrain canonical |> TypeCheck.andThen Type.run |> TypeCheck.unsafePerformIO of
        Ok annotations ->
            Ok annotations

        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)


-- Verifies pattern match exhaustiveness and detects redundant patterns.
nitpick : Can.Module -> Result E.Error ()
nitpick canonical =
    case PatternMatches.check canonical of
        Ok () ->
            Ok ()

        Err errors ->
            Err (E.BadPatterns errors)


-- Optimizes the canonical module to produce efficient intermediate representation.
optimize : Src.Module -> Dict String Name.Name Can.Annotation -> Can.Module -> Result E.Error Opt.LocalGraph
optimize modul annotations canonical =
    case Tuple.second (ReportingResult.run (Optimize.optimize annotations canonical)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)


-- Performs typed optimization preserving full type information for MLIR backend.
typedOptimize : Src.Module -> Dict String Name.Name Can.Annotation -> Can.Module -> Result E.Error TOpt.LocalGraph
typedOptimize modul annotations canonical =
    case Tuple.second (ReportingResult.run (TypedOptimize.optimize annotations canonical)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)
