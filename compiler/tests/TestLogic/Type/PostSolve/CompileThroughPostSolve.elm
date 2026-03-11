module TestLogic.Type.PostSolve.CompileThroughPostSolve exposing
    ( Artifacts
    , DetailedArtifacts
    , compileToPostSolve
    , compileToPostSolveDetailed
    )

{-| Compile helper for POST\_005/POST\_006 invariants.

This module provides a compilation helper that captures both pre-PostSolve
and post-PostSolve NodeTypes snapshots for non-regression testing.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Data.Map
import Dict
import Data.Set as EverySet
import System.TypeCheck.IO as IO
import TestLogic.TestPipeline as Pipeline


{-| Artifacts from running through PostSolve, including both pre and post snapshots.
-}
type alias Artifacts =
    { annotations : Dict.Dict Name.Name Can.Annotation
    , nodeTypesPre : PostSolve.NodeTypes
    , nodeTypesPost : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , canonical : Can.Module
    }


{-| Detailed artifacts including synthetic expression IDs for POST\_001/POST\_003 tests.
-}
type alias DetailedArtifacts =
    { annotations : Dict.Dict Name.Name Can.Annotation
    , nodeTypesPre : PostSolve.NodeTypes
    , nodeTypesPost : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , canonical : Can.Module
    , syntheticExprIds : EverySet.EverySet Int Int
    }


{-| Run the pipeline through PostSolve and capture both pre and post NodeTypes.
-}
compileToPostSolve : Src.Module -> Result String Artifacts
compileToPostSolve srcModule =
    -- Delegate to shared pipeline
    Pipeline.runToPostSolve srcModule
        |> Result.map
            (\pipelineResult ->
                { annotations = pipelineResult.annotations
                , nodeTypesPre = pipelineResult.nodeTypesPre
                , nodeTypesPost = pipelineResult.nodeTypesPost
                , kernelEnv = pipelineResult.kernelEnv
                , canonical = pipelineResult.canonical
                }
            )


{-| Run the pipeline through PostSolve with detailed synthetic expression tracking.

This version uses `constrainWithIdsDetailed` to capture which expression IDs
had synthetic placeholder variables allocated during constraint generation.

-}
compileToPostSolveDetailed : Src.Module -> Result String DetailedArtifacts
compileToPostSolveDetailed srcModule =
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

        ( _, Ok canModule ) ->
            let
                typeCheckResult =
                    IO.unsafePerformIO (runWithIdsTypeCheckDetailed canModule)
            in
            case typeCheckResult of
                Err errCount ->
                    Err ("Type checking failed with " ++ String.fromInt errCount ++ " error(s)")

                Ok typedData ->
                    let
                        postSolveResult =
                            PostSolve.postSolve typedData.annotations canModule typedData.nodeTypes
                    in
                    Ok
                        { annotations = Dict.fromList (Data.Map.toList compare typedData.annotations)
                        , nodeTypesPre = typedData.nodeTypes
                        , nodeTypesPost = postSolveResult.nodeTypes
                        , kernelEnv = postSolveResult.kernelEnv
                        , canonical = canModule
                        , syntheticExprIds = typedData.syntheticExprIds
                        }


{-| Run type checking with detailed ID tracking, including synthetic expression IDs.
-}
runWithIdsTypeCheckDetailed :
    Can.Module
    ->
        IO.IO
            (Result
                Int
                { annotations : Data.Map.Dict String Name.Name Can.Annotation
                , nodeTypes : PostSolve.NodeTypes
                , syntheticExprIds : EverySet.EverySet Int Int
                }
            )
runWithIdsTypeCheckDetailed canModule =
    ConstrainTyped.constrainWithIdsDetailed canModule
        |> IO.andThen
            (\( constraint, nodeIdState ) ->
                Solve.runWithIds constraint nodeIdState.mapping
                    |> IO.map
                        (\result ->
                            case result of
                                Ok data ->
                                    Ok
                                        { annotations = data.annotations
                                        , nodeTypes = data.nodeTypes
                                        , syntheticExprIds = nodeIdState.syntheticExprIds
                                        }

                                Err (NE.Nonempty _ rest) ->
                                    Err (1 + List.length rest)
                        )
            )
