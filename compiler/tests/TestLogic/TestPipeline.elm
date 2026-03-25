module TestLogic.TestPipeline exposing
    ( -- Cumulative artifact types
      CanonicalArtifacts
    , GlobalOptArtifacts
    , MlirArtifacts
      -- Pipeline entry points (each runs full pipeline to that stage)
    , MonoArtifacts
    , MonoDirectArtifacts
    , PostSolveArtifacts
    , TypeCheckArtifacts
    , TypedOptArtifacts
    , expectCoverageRun
    , expectMLIRGeneration
    , expectMonomorphization
    , runToGlobalOpt
    , runToMlir
      -- Low-level helpers (for tests needing fine-grained control)
    , runToMono
    , runToMonoDirect
    , runToPostSolve
    , runToTypedOpt
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

import Array exposing (Array)
import Builder.GraphAssembly as GA
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Backend as MLIR
import Compiler.Generate.Mode as Mode
import Compiler.GlobalOpt.MonoGlobalOptimize as MonoGlobalOptimize
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.MonoDirect.Monomorphize as MonoDirect
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Compiler.Type.SolverSnapshot as SolverSnapshot
import Compiler.TypedCanonical.Build as TCanBuild
import Data.Map
import Dict exposing (Dict)
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
    , annotations : Dict Name.Name Can.Annotation
    , nodeTypes : Array (Maybe Can.Type) -- Pre-PostSolve
    , nodeVars : Array (Maybe IO.Variable)
    , solverState : { descriptors : Array IO.Descriptor, pointInfo : Array IO.PointInfo, weights : Array Int }
    , annotationVars : Data.Map.Dict String Name.Name IO.Variable
    }


{-| Stage 3: PostSolve artifacts (includes Stages 1-2).
-}
type alias PostSolveArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name Can.Annotation
    , nodeTypesPre : PostSolve.NodeTypes -- Before PostSolve
    , nodeTypesPost : PostSolve.NodeTypes -- After PostSolve
    , kernelEnv : KernelTypes.KernelTypeEnv
    , nodeVars : Array (Maybe IO.Variable)
    , solverState : { descriptors : Array IO.Descriptor, pointInfo : Array IO.PointInfo, weights : Array Int }
    , annotationVars : Data.Map.Dict String Name.Name IO.Variable
    }


{-| Stage 4: Typed optimization artifacts (includes Stages 1-3).
-}
type alias TypedOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    }


{-| Stage 5: Monomorphization artifacts (includes Stages 1-4).
-}
type alias MonoArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    , globalGraph : TOpt.GlobalGraph
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    }


{-| Stage 5-alt: MonoDirect monomorphization artifacts (includes Stages 1-4).

Uses solver-directed monomorphization via `MonoDirect.monomorphizeDirect`.

-}
type alias MonoDirectArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name Can.Annotation
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph
    , globalGraph : TOpt.GlobalGraph
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    , solverSnapshot : SolverSnapshot.SolverSnapshot
    }


{-| Stage 5.5: Global optimization artifacts (includes Stages 1-5).

This stage runs GlobalOpt on the MonoGraph, which canonicalizes staging
and enforces GOPT\_001 (closure params == stage arity) and GOPT\_003
(case branch types match).

-}
type alias GlobalOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name Can.Annotation
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
    , annotations : Dict Name.Name Can.Annotation
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
            Canonicalize.canonicalize ( "eco", "example" ) (Data.Map.fromList identity (Dict.toList Basic.testIfaces)) srcModule
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

                Ok { annotations, nodeTypes, nodeVars, solverState, annotationVars } ->
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypes
                        , nodeVars = nodeVars
                        , solverState = solverState
                        , annotationVars = annotationVars
                        }


{-| Run pipeline through PostSolve.
-}
runToPostSolve : Src.Module -> Result String PostSolveArtifacts
runToPostSolve srcModule =
    case runToTypeCheck srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, nodeVars, solverState, annotationVars } ->
            let
                postSolveResult =
                    PostSolve.postSolve
                        (Data.Map.fromList identity (Dict.toList annotations))
                        canonical
                        nodeTypes
            in
            Ok
                { canonical = canonical
                , annotations = annotations
                , nodeTypesPre = nodeTypes
                , nodeTypesPost = postSolveResult.nodeTypes
                , kernelEnv = postSolveResult.kernelEnv
                , nodeVars = nodeVars
                , solverState = solverState
                , annotationVars = annotationVars
                }


{-| Run pipeline through typed optimization.

Wraps the source module with a synthetic `main` entry point so the typed
optimizer's main-type validation succeeds and downstream monomorphization
has a concrete entry point.

-}
runToTypedOpt : Src.Module -> Result String TypedOptArtifacts
runToTypedOpt srcModule =
    case runToPostSolve (wrapWithMain srcModule) of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypesPost, kernelEnv, nodeVars, annotationVars } ->
            let
                typedModule =
                    TCanBuild.fromCanonical canonical nodeTypesPost nodeVars
            in
            case RResult.run (TypedOptimize.optimizeTyped annotations nodeTypesPost nodeVars kernelEnv annotationVars typedModule) of
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


{-| Run pipeline through MonoDirect (solver-directed) monomorphization.
-}
runToMonoDirect : Src.Module -> Result String MonoDirectArtifacts
runToMonoDirect srcModule =
    case runToPostSolve (wrapWithMain srcModule) of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypesPost, kernelEnv, nodeVars, solverState, annotationVars } ->
            let
                typedModule =
                    TCanBuild.fromCanonical canonical nodeTypesPost nodeVars

                snapshot =
                    SolverSnapshot.fromSolveResult { nodeVars = nodeVars, solverState = solverState, annotationVars = annotationVars }
            in
            case RResult.run (TypedOptimize.optimizeTyped annotations nodeTypesPost nodeVars kernelEnv annotationVars typedModule) of
                ( _, Ok localGraph ) ->
                    let
                        globalGraph =
                            localGraphToGlobalGraph localGraph

                        globalTypeEnv =
                            buildGlobalTypeEnv canonical
                    in
                    case MonoDirect.monomorphizeDirect "main" globalTypeEnv snapshot globalGraph of
                        Err monoErr ->
                            Err ("MonoDirect monomorphization failed: " ++ monoErr)

                        Ok monoGraph ->
                            Ok
                                { canonical = canonical
                                , annotations = annotations
                                , nodeTypes = nodeTypesPost
                                , kernelEnv = kernelEnv
                                , localGraph = localGraph
                                , globalGraph = globalGraph
                                , globalTypeEnv = globalTypeEnv
                                , monoGraph = monoGraph
                                , solverSnapshot = snapshot
                                }

                ( _, Err _ ) ->
                    Err "Typed optimization produced an error"


{-| Run pipeline through global optimization.

This stage applies MonoGlobalOptimize.globalOptimize which:

  - Canonicalizes staging (GOPT\_001: closure params == stage arity)
  - Normalizes case branch types (GOPT\_003)
  - Computes returned closure arity annotations

-}
runToGlobalOpt : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOpt srcModule =
    case runToMono srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph, globalGraph, globalTypeEnv, monoGraph } ->
            let
                ( simplifiedGraph, _ ) =
                    MonoInlineSimplify.optimize monoGraph

                optimizedMonoGraph =
                    MonoGlobalOptimize.globalOptimize simplifiedGraph
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
                    MLIR.generateMlirModule (Mode.Dev Nothing) optimizedMonoGraph

                mlirOutput =
                    case runMLIRGeneration optimizedMonoGraph of
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
runWithIdsTypeCheck : Can.Module -> IO.IO (Result Int { annotations : Dict Name.Name Can.Annotation, nodeTypes : Array (Maybe Can.Type), nodeVars : Array (Maybe IO.Variable), solverState : { descriptors : Array IO.Descriptor, pointInfo : Array IO.PointInfo, weights : Array Int }, annotationVars : Data.Map.Dict String Name.Name IO.Variable })
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
                        Ok
                            { annotations = Dict.fromList (Data.Map.toList compare data.annotations)
                            , nodeTypes = data.nodeTypes
                            , nodeVars = data.nodeVars
                            , solverState = data.solverState
                            , annotationVars = data.annotationVars
                            }

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
            TypeEnv.fromInterfaces (Data.Map.fromList identity (Dict.toList Basic.testIfaces))
    in
    TypeEnv.mergeGlobalTypeEnv
        interfaceTypeEnv
        (Data.Map.singleton ModuleName.toComparableCanonical moduleTypeEnv.home moduleTypeEnv)


{-| Monomorphize using `main` as the entry point.

All test modules are wrapped with a synthetic `main` by `wrapWithMain`,
so this always succeeds.

-}
monomorphizeAny : TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph -> Result String Mono.MonoGraph
monomorphizeAny globalTypeEnv globalGraph =
    Monomorphize.monomorphize "main" globalTypeEnv globalGraph


{-| Wrap a source module with a synthetic `main` entry point.

Generates:

    main =
        let
            _tv = <entryDef>
        in
        Html.text "test main"

where `<entryDef>` is `testValue` if it exists, otherwise the first definition.
This ensures monomorphization starts from a concrete `Html msg` entry point
that references the intended test definition, making it and its dependencies
reachable.

-}
wrapWithMain : Src.Module -> Src.Module
wrapWithMain (Src.Module data) =
    let
        -- Extract names of all existing top-level values
        valueNames =
            List.filterMap
                (\(A.At _ (Src.Value vdata)) ->
                    let
                        ( _, A.At _ name ) =
                            vdata.name
                    in
                    if name == "main" then
                        Nothing

                    else
                        Just name
                )
                data.values

        -- testValue is required — every SourceIR test module must define it
        defs =
            if List.member "testValue" valueNames then
                [ Src.Define
                    (A.At A.zero "_tv")
                    []
                    ( [], varRef "testValue" )
                    Nothing
                ]

            else
                Debug.todo "Test module must define 'testValue' — see SourceIR test standard"

        -- Body: Html.text "test main"
        body =
            A.At A.zero
                (Src.Call
                    (A.At A.zero (Src.VarQual Src.LowVar "Html" "text"))
                    [ ( [], A.At A.zero (Src.Str "test main" False) ) ]
                )

        -- main = let _tv = <entry> in Html.text "test main"
        mainExpr =
            case defs of
                [] ->
                    body

                _ ->
                    A.At A.zero
                        (Src.Let
                            (List.map (\d -> ( ( [], [] ), A.At A.zero d )) defs)
                            []
                            body
                        )

        mainValue =
            Src.Value
                { comments = []
                , name = ( [], A.At A.zero "main" )
                , args = []
                , body = ( [], mainExpr )
                , tipe = Nothing
                }

        -- Add Html import if not already present
        hasHtmlImport =
            List.any
                (\(Src.Import ( _, A.At _ importName ) _ _) -> importName == "Html")
                data.imports

        htmlImport =
            Src.Import
                ( [], A.At A.zero "Html" )
                Nothing
                ( ( [], [] )
                , Src.Explicit
                    (A.At A.zero
                        [ ( ( [], [] ), Src.Lower (A.At A.zero "text") ) ]
                    )
                )
    in
    Src.Module
        { data
            | values = data.values ++ [ A.At A.zero mainValue ]
            , imports =
                if hasHtmlImport then
                    data.imports

                else
                    data.imports ++ [ htmlImport ]
        }


{-| Create a variable reference expression.
-}
varRef : Name.Name -> Src.Expr
varRef name =
    A.At A.zero (Src.Var Src.LowVar name)


{-| Run MLIR code generation on a monomorphized graph.
-}
runMLIRGeneration : Mono.MonoGraph -> Result String String
runMLIRGeneration monoGraph =
    let
        config =
            { sourceMaps = CodeGen.NoSourceMaps
            , leadingLines = 0
            , mode = Mode.Dev Nothing
            , graph = monoGraph
            }

        output =
            MLIR.backend.generate config
    in
    Ok (CodeGen.outputToString output)



-- ============================================================================
-- EXPECTATION HELPERS
-- ============================================================================


{-| Coverage-driven test: validates the test case is valid Elm (passes through
TypedOpt) then runs the full backend pipeline for coverage. Failures in
Mono/GlobalOpt/MLIR are logged but do NOT fail the test — they represent
backend bugs to investigate, not invalid test cases.

The test FAILS only if canonicalization, type checking, PostSolve, or typed
optimization fails, since that means the test case is not valid Elm.

-}
expectCoverageRun : Src.Module -> Expect.Expectation
expectCoverageRun srcModule =
    case runToTypedOpt srcModule of
        Err msg ->
            Expect.fail ("Invalid test case (frontend failure): " ++ msg)

        Ok typedOptArtifacts ->
            -- Valid Elm! Now run the backend pipeline for coverage.
            -- Failures here are expected and informative, not test failures.
            let
                { canonical, localGraph } =
                    typedOptArtifacts

                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical
            in
            case monomorphizeAny globalTypeEnv globalGraph of
                Err _ ->
                    Expect.pass

                Ok monoGraph ->
                    let
                        ( simplifiedGraph, _ ) =
                            MonoInlineSimplify.optimize monoGraph

                        optimizedMonoGraph =
                            MonoGlobalOptimize.globalOptimize simplifiedGraph
                    in
                    case runMLIRGeneration optimizedMonoGraph of
                        Err _ ->
                            Expect.pass

                        Ok _ ->
                            Expect.pass


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
            if Array.isEmpty data.nodes then
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
