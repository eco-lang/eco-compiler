module Compiler.Compile exposing
    ( compile, compileTyped
    , Artifacts(..), TypedArtifacts(..), TypedArtifactsData
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
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.LocalOpt.Erased.Module as Optimize
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Nitpick.PatternMatches as PatternMatches
import Compiler.Reporting.Error as E
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Compiler.Reporting.Result as ReportingResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Constrain.Typed.Module as TypeTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Type
import Compiler.Type.SolverRoots as SolverRoots
import Compiler.TypedCanonical.Build as TCanBuild
import Dict
import System.IO as IO
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)



-- ====== Artifacts ======


{-| Compilation artifacts produced by the standard compilation pipeline.

Contains the canonical AST, type annotations for all definitions, and the
optimized local graph suitable for JavaScript code generation.

-}
type Artifacts
    = Artifacts Can.Module (Dict.Dict Name (Can.Annotation Name)) Opt.LocalGraph


{-| Extended compilation artifacts with typed optimization for MLIR backend.

In addition to standard artifacts, includes a typed optimization graph that
preserves full type information throughout the optimization process. This
enables type-directed optimizations and direct lowering to MLIR.

-}
type alias TypedArtifactsData =
    { canonical : Can.Module
    , annotations : Dict.Dict Name (Can.Annotation Name)
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph Name
    , typeEnv : TypeEnv.ModuleTypeEnv
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
compile : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error Artifacts)
compile pkg ifaces modul =
    let
        modName : Name
        modName =
            Src.getName modul
    in
    -- Phase logs: emit one stderr line per pipeline phase so we can see
    -- which phase the compiler is working in (canonicalize / type-check /
    -- nitpick / optimize). Each phase boundary is also a Task scheduling
    -- point, so even when the pipeline is single-threaded the GC has a
    -- chance to interleave between phases. The original implementation
    -- ran the whole pipeline inside one Task.succeed, which made the
    -- outside world blind to per-phase progress.
    phase modName "canonicalize"
        |> Task.map (\_ -> canonicalize pkg ifaces modul)
        |> Task.andThen
            (\canonicalResult ->
                case canonicalResult of
                    Ok canonical ->
                        phase modName "type-check"
                            |> Task.map (\_ -> typeCheck modul canonical)
                            |> Task.andThen
                                (\tcResult ->
                                    phase modName "nitpick"
                                        |> Task.map (\_ -> nitpick canonical)
                                        |> Task.andThen
                                            (\nitpickResult ->
                                                case Result.map2 (\annotations () -> annotations) tcResult nitpickResult of
                                                    Ok annotations ->
                                                        phase modName "optimize"
                                                            |> Task.map
                                                                (\_ ->
                                                                    optimize modul annotations canonical
                                                                        |> Result.map (\objects -> Artifacts canonical annotations objects)
                                                                )

                                                    Err err ->
                                                        Task.succeed (Err err)
                                            )
                                )

                    Err err ->
                        Task.succeed (Err err)
            )


{-| Per-phase stderr log helper. One line per (phase, module) pair so a
captured log shows the exact sequence the compiler is walking through.
-}
phase : Name -> String -> Task Never ()
phase modName name =
    IO.writeLn IO.stderr ("[phase] " ++ name ++ " " ++ modName)


{-| Compiles an Elm module with typed optimization for native code generation.

Performs all standard compilation phases plus typed optimization, producing:

  - `Opt.LocalGraph` - Standard optimized IR for JavaScript backend
  - `TOpt.LocalGraph Name` - Typed optimized IR with preserved type information

The typed optimization phase preserves type information needed for monomorphization
and direct lowering to MLIR/LLVM.

-}
compileTyped : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error TypedArtifacts)
compileTyped pkg ifaces modul =
    let
        modName : Name
        modName =
            Src.getName modul
    in
    phase modName "canonicalize"
        |> Task.map (\_ -> canonicalize pkg ifaces modul)
        |> Task.andThen
            (\canonicalResult ->
                case canonicalResult of
                    Ok canonical ->
                        let
                            moduleTypeEnv : TypeEnv.ModuleTypeEnv
                            moduleTypeEnv =
                                TypeEnv.fromCanonical canonical
                        in
                        phase modName "type-check"
                            |> Task.map (\_ -> typeCheckTyped modul canonical)
                            |> Task.andThen
                                (\tcResult ->
                                    case tcResult of
                                        Ok { annotations, typedCanonical, nodeTypes, kernelEnv, nodeVars, annotationVars, allSchemeRoots } ->
                                            phase modName "nitpick"
                                                |> Task.map (\_ -> nitpick canonical)
                                                |> Task.andThen
                                                    (\nitpickResult ->
                                                        case nitpickResult of
                                                            Ok () ->
                                                                phase modName "optimize"
                                                                    |> Task.map (\_ -> optimize modul annotations canonical)
                                                                    |> Task.andThen
                                                                        (\optResult ->
                                                                            case optResult of
                                                                                Ok objects ->
                                                                                    phase modName "typed-opt"
                                                                                        |> Task.map
                                                                                            (\_ ->
                                                                                                typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots typedCanonical
                                                                                                    |> Result.map
                                                                                                        (\typedObjects ->
                                                                                                            TypedArtifacts
                                                                                                                { canonical = canonical
                                                                                                                , annotations = annotations
                                                                                                                , objects = objects
                                                                                                                , typedObjects = typedObjects
                                                                                                                , typeEnv = moduleTypeEnv
                                                                                                                }
                                                                                                        )
                                                                                            )

                                                                                Err err ->
                                                                                    Task.succeed (Err err)
                                                                        )

                                                            Err err ->
                                                                Task.succeed (Err err)
                                                    )

                                        Err err ->
                                            Task.succeed (Err err)
                                )

                    Err err ->
                        Task.succeed (Err err)
            )



-- ====== Helpers ======
-- ====== Internal Compilation Phases ======
-- Converts source AST to canonical form, resolving all names and imports.


canonicalize : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Result E.Error Can.Module
canonicalize pkg ifaces modul =
    case Tuple.second (ReportingResult.run (Canonicalize.canonicalize pkg ifaces modul)) of
        Ok canonical ->
            Ok canonical

        Err errors ->
            Err (E.BadNames errors)



-- Infers and verifies types for all definitions in the canonical module.


typeCheck : Src.Module -> Can.Module -> Result E.Error (Dict.Dict Name (Can.Annotation Name))
typeCheck modul canonical =
    case TypeErased.constrain canonical |> TypeCheck.andThen Type.run |> TypeCheck.unsafePerformIO of
        Ok annotations ->
            Ok annotations

        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)



-- Type checks a module and produces a TypedCanonical module with per-expression types.


{-| Type check a module and produce both annotations and a TypedCanonical module.

This function extends the standard type checking to also build a TypedCanonical
module where every expression is paired with its inferred type. This is useful
for downstream phases that need access to per-expression type information.

Also runs the PostSolve phase to fix remaining Group B expression types (Str, Chr, Float, Unit) and compute
kernel function types for typed optimization.

-}
typeCheckTyped :
    Src.Module
    -> Can.Module
    ->
        Result
            E.Error
            { annotations : Dict.Dict Name (Can.Annotation Name)
            , typedCanonical : TCan.Module
            , nodeTypes : TCan.ExprTypes
            , nodeVars : TCan.ExprVars
            , kernelEnv : KernelTypes.KernelTypeEnv
            , annotationVars : Dict.Dict Name TypeCheck.Variable
            , allSchemeRoots : SolverRoots.AllSchemeRoots
            }
typeCheckTyped modul canonical =
    let
        ioResult =
            TypeTyped.constrainWithIds canonical
                |> TypeCheck.andThen
                    (\( constraint, nodeVars, schemeBinderVars ) ->
                        Type.runWithIds constraint nodeVars
                            |> TypeCheck.map (\result -> ( result, schemeBinderVars ))
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        ( Err errors, _ ) ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)

        ( Ok { annotations, annotationVars, nodeTypes, nodeVars, solverState }, schemeBinderVars ) ->
            let
                -- Normalize solver vars to union-find roots
                rootedNodeVars =
                    SolverRoots.normalizeNodeVars solverState nodeVars

                rootedAnnotationVars =
                    SolverRoots.normalizeAnnotationVars solverState annotationVars

                -- Normalize scheme binder vars to roots (from annotated Can.TypedDef defs)
                annotatedSchemeRoots =
                    SolverRoots.normalizeAllSchemeRoots solverState schemeBinderVars

                -- Extract binder roots for unannotated Can.Def defs (Step 2.4)
                inferredSchemeRoots =
                    Dict.foldl
                        (\defName annotation acc ->
                            if Dict.member defName annotatedSchemeRoots then
                                -- Already has roots from Can.TypedDef path
                                acc

                            else
                                case Dict.get defName annotationVars of
                                    Just annotVar ->
                                        let
                                            roots =
                                                SolverRoots.extractBinderRootsFromInferred
                                                    solverState
                                                    annotation
                                                    annotVar
                                        in
                                        if Dict.isEmpty roots then
                                            acc

                                        else
                                            Dict.insert defName roots acc

                                    Nothing ->
                                        acc
                        )
                        Dict.empty
                        annotations

                -- Merge annotated + inferred roots
                normalizedSchemeRoots =
                    Dict.foldl
                        (\defName roots acc -> Dict.insert defName roots acc)
                        annotatedSchemeRoots
                        inferredSchemeRoots

                -- Run PostSolve to fix remaining Group B types and compute kernel env
                postSolveResult =
                    PostSolve.postSolve annotations canonical nodeTypes

                fixedNodeTypes =
                    postSolveResult.nodeTypes

                kernelEnv =
                    postSolveResult.kernelEnv
            in
            Ok
                { annotations = annotations
                , typedCanonical = TCanBuild.fromCanonical canonical fixedNodeTypes rootedNodeVars
                , nodeTypes = fixedNodeTypes
                , kernelEnv = kernelEnv
                , nodeVars = rootedNodeVars
                , annotationVars = rootedAnnotationVars
                , allSchemeRoots = normalizedSchemeRoots
                }



-- Verifies pattern match exhaustiveness and detects redundant patterns.


nitpick : Can.Module -> Result E.Error ()
nitpick canonical =
    case PatternMatches.check canonical of
        Ok () ->
            Ok ()

        Err errors ->
            Err (E.BadPatterns errors)



-- Optimizes the canonical module to produce efficient intermediate representation.


optimize : Src.Module -> Dict.Dict Name.Name (Can.Annotation Name) -> Can.Module -> Result E.Error Opt.LocalGraph
optimize modul annotations canonical =
    case Tuple.second (ReportingResult.run (Optimize.optimize annotations canonical)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)



-- Performs typed optimization preserving full type information for MLIR backend.
-- Performs typed optimization from a TypedCanonical module.


typedOptimizeFromTyped : Src.Module -> Dict.Dict Name.Name (Can.Annotation Name) -> TCan.ExprTypes -> TCan.ExprVars -> KernelTypes.KernelTypeEnv -> Dict.Dict Name.Name TypeCheck.Variable -> SolverRoots.AllSchemeRoots -> TCan.Module -> Result E.Error (TOpt.LocalGraph Name)
typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots tcanModule =
    case Tuple.second (ReportingResult.run (TypedOptimize.optimizeTyped annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots tcanModule)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)
