module TestLogic.Type.PostSolve.CompileThroughPostSolve exposing
    ( Artifacts
    , DetailedArtifacts
    , compileToPostSolve
    , compileToPostSolveDetailed
    )

{-| Compiles a test program as far as PostSolve and keeps its node types from
both sides of it, so that a check on PostSolve can compare what the solver
produced with what PostSolve made of it.

The solver returns its _node types_, the types of the program's expressions
and patterns, as an array indexed by node id.
`Compiler.Type.PostSolve.postSolve` then rewrites some of those types.
`compileToPostSolve` returns the array from before and from after, taking both
from `TestLogic.TestPipeline.runToPostSolve`.

Some checks also need to know which nodes were typed through a _synthetic
placeholder_. That is a fresh type variable which constraint generation
allocates for an expression with no result variable of its own, records as
that expression's type, and constrains to equal the type its context expects.
String, character, float and unit literals are such expressions.
`runToPostSolve` does not keep the ids of those expressions, so
`compileToPostSolveDetailed` runs the same stages itself, with
`Compiler.Type.Constrain.Typed.Module.constrainWithIdsDetailed`, and returns
the ids as well.

Both canonicalize the program as a module of the package `eco/example`
against `Compiler.Elm.Interface.Basic.testIfaces`, and neither adds a synthetic
`main`. A canonicalization or type error gives `Err` with a message that
carries only the number of errors.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Data.Set as EverySet
import Dict
import System.TypeCheck.IO as IO
import TestLogic.TestPipeline as Pipeline


{-| What compiling one test program through PostSolve leaves behind: its
canonical module, the annotations the solver gives its top-level values, its
node types from before and after PostSolve, and the kernel type environment
PostSolve builds.

`nodeTypesPre` is the array as the solver left it and `nodeTypesPost` the one
PostSolve returned; both are indexed by node id.

-}
type alias Artifacts =
    { annotations : Dict.Dict Name.Name (Can.Annotation Name)
    , nodeTypesPre : PostSolve.NodeTypes
    , nodeTypesPost : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , canonical : Can.Module
    }


{-| The same as `Artifacts`, with `syntheticExprIds` added: the ids of the
expressions that constraint generation typed through a synthetic placeholder.
-}
type alias DetailedArtifacts =
    { annotations : Dict.Dict Name.Name (Can.Annotation Name)
    , nodeTypesPre : PostSolve.NodeTypes
    , nodeTypesPost : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , canonical : Can.Module
    , syntheticExprIds : EverySet.EverySet Int Int
    }


{-| Compiles `srcModule` through PostSolve with
`TestLogic.TestPipeline.runToPostSolve` and returns its artifacts, or that
function's error message.
-}
compileToPostSolve : Src.Module -> Result String Artifacts
compileToPostSolve srcModule =
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


{-| Compiles `srcModule` through PostSolve and returns its artifacts together
with the ids of the expressions typed through a synthetic placeholder.

It canonicalizes, generates constraints with node ids recorded, solves them and
runs PostSolve, the stages `compileToPostSolve` runs, and gives the same error
messages.

-}
compileToPostSolveDetailed : Src.Module -> Result String DetailedArtifacts
compileToPostSolveDetailed srcModule =
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
                        { annotations = typedData.annotations
                        , nodeTypesPre = typedData.nodeTypes
                        , nodeTypesPost = postSolveResult.nodeTypes
                        , kernelEnv = postSolveResult.kernelEnv
                        , canonical = canModule
                        , syntheticExprIds = typedData.syntheticExprIds
                        }


{-| Builds the IO action that generates `canModule`'s constraints with node ids
recorded and solves them, giving the solver's annotations and node types with
the synthetic placeholder ids, or the number of type errors.
-}
runWithIdsTypeCheckDetailed :
    Can.Module
    ->
        IO.IO
            (Result
                Int
                { annotations : Dict.Dict Name.Name (Can.Annotation Name)
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
