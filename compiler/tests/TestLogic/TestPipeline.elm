module TestLogic.TestPipeline exposing
    ( -- Cumulative artifact types
      CanonicalArtifacts
    , TypeCheckArtifacts
    , PostSolveArtifacts
    , TypedOptArtifacts
    , MonoArtifacts
    , GlobalOptArtifacts
    , MlirArtifacts
      -- Pipeline entry points (each runs full pipeline to that stage)
    , runToCanonical
    , runToTypeCheck
    , runToPostSolve
    , runToTypedOpt
    , runToMono
    , runToGlobalOpt
    , runToMlir
      -- Low-level helpers (for tests needing fine-grained control)
    , runWithIdsTypeCheck
    , localGraphToGlobalGraph
    , buildGlobalTypeEnv
    , monomorphizeAny
    , findAnyEntryPoint
    , runMLIRGeneration
      -- Expectation helpers
    , expectMonomorphization
    , expectMLIRGeneration
    )

{-| Unified test pipeline for the Eco compiler.

This module provides a single source of truth for running the compilation
pipeline in tests. Each stage returns cumulative artifacts - all outputs
from that stage and all previous stages.

Pipeline stages:

1.  Canonicalization: Source AST -> Canonical AST
2.  Type Checking: Canonical -> annotations + nodeTypes (pre-PostSolve)
3.  PostSolve: Fix Group B types, compute kernel env
4.  Typed Optimization: TypedCanonical -> LocalGraph
5.  Monomorphization: LocalGraph -> GlobalGraph -> MonoGraph
6.  MLIR Generation: MonoGraph -> MlirModule

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypedOptimized as TOpt
import Compiler.TypedCanonical.Build as TCanBuild
import Builder.GraphAssembly as GA
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Backend as MLIR
import Compiler.Generate.Mode as Mode
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.GlobalOpt.MonoGlobalOptimize as MonoGlobalOptimize
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Data.Map as Dict exposing (Dict)
import Expect
import Mlir.Mlir exposing (MlirModule)
import System.TypeCheck.IO as IO



-- ============================================================================
-- CUMULATIVE ARTIFACT TYPES
-- ============================================================================


{-| Stage 1: Canonicalization artifacts.
-}
type alias CanonicalArtifacts =
    { canonical : Can.Module
    }


{-| Stage 2: Type checking artifacts (includes Stage 1).
-}
type alias TypeCheckArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : Dict Int Int Can.Type -- Pre-PostSolve
    }


{-| Stage 3: PostSolve artifacts (includes Stages 1-2).
-}
type alias PostSolveArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypesPre : Dict Int Int Can.Type -- Before PostSolve
    , nodeTypesPost : PostSolve.NodeTypes -- After PostSolve
    , kernelEnv : KernelTypes.KernelTypeEnv
    }


{-| Stage 4: Typed optimization artifacts (includes Stages 1-3).
-}
type alias TypedOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    }


{-| Stage 5: Monomorphization artifacts (includes Stages 1-4).
-}
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


{-| Stage 5.5: Global optimization artifacts (includes Stages 1-5).

This stage runs GlobalOpt on the MonoGraph, which canonicalizes staging
and enforces GOPT_001 (closure params == stage arity) and GOPT_003
(case branch types match).
-}
type alias GlobalOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    , globalGraph : TOpt.GlobalGraph
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    , optimizedMonoGraph : Mono.MonoGraph
    }


{-| Stage 6: MLIR generation artifacts (includes Stages 1-5.5).
-}
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



-- ============================================================================
-- PIPELINE ENTRY POINTS
-- ============================================================================


{-| Run pipeline through canonicalization.
-}
runToCanonical : Src.Module -> Result String CanonicalArtifacts
runToCanonical srcModule =
    let
        canonResult =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule
    in
    case RResult.run canonResult of
        ( _, Err errors ) ->
            let
                errorCount =
                    OneOrMore.destruct (::) errors |> List.length
            in
            Err ("Canonicalization failed with " ++ String.fromInt errorCount ++ " error(s)")

        ( _, Ok canonical ) ->
            Ok { canonical = canonical }


{-| Run pipeline through type checking.
-}
runToTypeCheck : Src.Module -> Result String TypeCheckArtifacts
runToTypeCheck srcModule =
    case runToCanonical srcModule of
        Err e ->
            Err e

        Ok { canonical } ->
            case IO.unsafePerformIO (runWithIdsTypeCheck canonical) of
                Err errCount ->
                    Err ("Type checking failed with " ++ String.fromInt errCount ++ " error(s)")

                Ok { annotations, nodeTypes } ->
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypes
                        }


{-| Run pipeline through PostSolve.
-}
runToPostSolve : Src.Module -> Result String PostSolveArtifacts
runToPostSolve srcModule =
    case runToTypeCheck srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes } ->
            let
                postSolveResult =
                    PostSolve.postSolve annotations canonical nodeTypes
            in
            Ok
                { canonical = canonical
                , annotations = annotations
                , nodeTypesPre = nodeTypes
                , nodeTypesPost = postSolveResult.nodeTypes
                , kernelEnv = postSolveResult.kernelEnv
                }


{-| Run pipeline through typed optimization.
-}
runToTypedOpt : Src.Module -> Result String TypedOptArtifacts
runToTypedOpt srcModule =
    case runToPostSolve srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypesPost, kernelEnv } ->
            let
                typedModule =
                    TCanBuild.fromCanonical canonical nodeTypesPost
            in
            case RResult.run (TypedOptimize.optimizeTyped annotations nodeTypesPost kernelEnv typedModule) of
                ( _, Ok localGraph ) ->
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypesPost
                        , kernelEnv = kernelEnv
                        , localGraph = localGraph
                        }

                ( _, Err _ ) ->
                    Err "Typed optimization produced an error"


{-| Run pipeline through monomorphization.
-}
runToMono : Src.Module -> Result String MonoArtifacts
runToMono srcModule =
    case runToTypedOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph } ->
            let
                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical
            in
            case monomorphizeAny globalTypeEnv globalGraph of
                Err monoErr ->
                    Err ("Monomorphization failed: " ++ monoErr)

                Ok monoGraph ->
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypes
                        , kernelEnv = kernelEnv
                        , localGraph = localGraph
                        , globalGraph = globalGraph
                        , globalTypeEnv = globalTypeEnv
                        , monoGraph = monoGraph
                        }


{-| Run pipeline through global optimization.

This stage applies MonoGlobalOptimize.globalOptimize which:
- Canonicalizes staging (GOPT_001: closure params == stage arity)
- Normalizes case branch types (GOPT_003)
- Computes returned closure arity annotations
-}
runToGlobalOpt : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOpt srcModule =
    case runToMono srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph, globalGraph, globalTypeEnv, monoGraph } ->
            let
                optimizedMonoGraph =
                    MonoGlobalOptimize.globalOptimize globalTypeEnv monoGraph
            in
            Ok
                { canonical = canonical
                , annotations = annotations
                , nodeTypes = nodeTypes
                , kernelEnv = kernelEnv
                , localGraph = localGraph
                , globalGraph = globalGraph
                , globalTypeEnv = globalTypeEnv
                , monoGraph = monoGraph
                , optimizedMonoGraph = optimizedMonoGraph
                }


{-| Run pipeline through MLIR generation.
-}
runToMlir : Src.Module -> Result String MlirArtifacts
runToMlir srcModule =
    case runToGlobalOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph, globalGraph, globalTypeEnv, optimizedMonoGraph } ->
            let
                mlirModule =
                    MLIR.generateMlirModule (Mode.Dev Nothing) globalTypeEnv optimizedMonoGraph

                mlirOutput =
                    case runMLIRGeneration globalTypeEnv optimizedMonoGraph of
                        Ok output ->
                            output

                        Err _ ->
                            ""
            in
            Ok
                { canonical = canonical
                , annotations = annotations
                , nodeTypes = nodeTypes
                , kernelEnv = kernelEnv
                , localGraph = localGraph
                , globalGraph = globalGraph
                , globalTypeEnv = globalTypeEnv
                , monoGraph = optimizedMonoGraph
                , mlirModule = mlirModule
                , mlirOutput = mlirOutput
                }



-- ============================================================================
-- LOW-LEVEL HELPERS
-- ============================================================================


{-| Run type checking with expression ID tracking.
-}
runWithIdsTypeCheck : Can.Module -> IO.IO (Result Int { annotations : Dict String Name.Name Can.Annotation, nodeTypes : Dict Int Int Can.Type })
runWithIdsTypeCheck modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars ) ->
                Solve.runWithIds constraint nodeVars
            )
        |> IO.map
            (\result ->
                case result of
                    Ok data ->
                        Ok data

                    Err (NE.Nonempty _ rest) ->
                        Err (1 + List.length rest)
            )


{-| Convert a LocalGraph to a GlobalGraph for monomorphization.
-}
localGraphToGlobalGraph : TOpt.LocalGraph -> TOpt.GlobalGraph
localGraphToGlobalGraph localGraph =
    GA.addTypedLocalGraph localGraph TOpt.emptyGlobalGraph


{-| Build a GlobalTypeEnv from a canonical module and test interfaces.
-}
buildGlobalTypeEnv : Can.Module -> TypeEnv.GlobalTypeEnv
buildGlobalTypeEnv canModule =
    let
        moduleTypeEnv =
            TypeEnv.fromCanonical canModule

        interfaceTypeEnv =
            TypeEnv.fromInterfaces Basic.testIfaces
    in
    TypeEnv.mergeGlobalTypeEnv
        interfaceTypeEnv
        (Dict.singleton ModuleName.toComparableCanonical moduleTypeEnv.home moduleTypeEnv)


{-| Monomorphize using the first defined function as entry point.
-}
monomorphizeAny : TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph -> Result String Mono.MonoGraph
monomorphizeAny globalTypeEnv (TOpt.GlobalGraph nodes _ _) =
    case findAnyEntryPoint nodes of
        Nothing ->
            Err "No function found in graph"

        Just ( TOpt.Global _ name, _ ) ->
            Monomorphize.monomorphize name globalTypeEnv (TOpt.GlobalGraph nodes Dict.empty Dict.empty)


{-| Find any entry point in the global graph (the first defined function).
-}
findAnyEntryPoint : Dict (List String) TOpt.Global TOpt.Node -> Maybe ( TOpt.Global, Can.Type )
findAnyEntryPoint nodes =
    Dict.foldl TOpt.compareGlobal
        (\global node acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case node of
                        TOpt.Define _ _ tipe ->
                            Just ( global, tipe )

                        TOpt.TrackedDefine _ _ _ tipe ->
                            Just ( global, tipe )

                        _ ->
                            Nothing
        )
        Nothing
        nodes


{-| Run MLIR code generation on a monomorphized graph.
-}
runMLIRGeneration : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Result String String
runMLIRGeneration globalTypeEnv monoGraph =
    let
        config =
            { sourceMaps = CodeGen.NoSourceMaps
            , leadingLines = 0
            , mode = Mode.Dev Nothing
            , graph = monoGraph
            , typeEnv = globalTypeEnv
            }

        output =
            MLIR.backend.generate config
    in
    Ok (CodeGen.outputToString output)



-- ============================================================================
-- EXPECTATION HELPERS
-- ============================================================================


{-| Verify that a source module can be successfully monomorphized.
-}
expectMonomorphization : Src.Module -> Expect.Expectation
expectMonomorphization srcModule =
    case runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            verifyMonoGraph monoGraph


{-| Verify that a source module can be successfully compiled to MLIR.
-}
expectMLIRGeneration : Src.Module -> Expect.Expectation
expectMLIRGeneration srcModule =
    case runToMlir srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph, mlirOutput } ->
            verifyMLIROutput monoGraph mlirOutput


{-| Verify that the monomorphized graph has the expected structure.
-}
verifyMonoGraph : Mono.MonoGraph -> Expect.Expectation
verifyMonoGraph (Mono.MonoGraph data) =
    case data.main of
        Nothing ->
            Expect.fail "Monomorphized graph has no main entry point"

        Just _ ->
            if Dict.isEmpty data.nodes then
                Expect.fail "Monomorphized graph has no nodes"

            else
                Expect.pass


{-| Verify that the MLIR output has expected structure.
-}
verifyMLIROutput : Mono.MonoGraph -> String -> Expect.Expectation
verifyMLIROutput _ output =
    if String.isEmpty output then
        Expect.fail "MLIR output is empty"

    else if not (String.contains "func.func" output || String.contains "eco." output) then
        Expect.fail "MLIR output doesn't contain expected operations"

    else
        Expect.pass
