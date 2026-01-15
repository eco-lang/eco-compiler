module Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)

{-| Test infrastructure for verifying that TypedOptimized code can be monomorphized.

This module runs the typed compilation pipeline through monomorphization:

1.  Source AST
2.  Canonical AST (with expression IDs)
3.  Type checking (with ID tracking)
4.  TypedCanonical
5.  TypedOptimized (LocalGraph)
6.  GlobalGraph (for monomorphization)
7.  Monomorphized (MonoGraph)

The test verifies that monomorphization completes successfully and produces
a valid MonoGraph.

Note: For testing, we use "testValue" as the entry point instead of "main",
since the test modules define `testValue` as their primary definition.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.Package as Pkg
import Compiler.Generate.Monomorphize as Monomorphize
import Compiler.Optimize.Typed.Module as TypedOptimize
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Data.Map as Dict exposing (Dict)
import Expect
import System.TypeCheck.IO as IO


{-| Verify that a source module can be successfully monomorphized.

This runs the full typed compilation pipeline through monomorphization and
verifies that it completes without errors.

-}
expectMonomorphization : Src.Module -> Expect.Expectation
expectMonomorphization srcModule =
    let
        canonResult =
            Canonicalize.canonicalize ("eco", "example") Basic.testIfaces srcModule
    in
    case Result.run canonResult of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                errorCount =
                    List.length errorList
            in
            Expect.fail
                ("Canonicalization failed with "
                    ++ String.fromInt errorCount
                    ++ " error(s)"
                )

        ( _, Ok canModule ) ->
            -- Run type checking with IDs
            let
                typeCheckResult =
                    IO.unsafePerformIO (runWithIdsTypeCheck canModule)
            in
            case typeCheckResult of
                Err errCount ->
                    Expect.fail
                        ("Type checking failed with "
                            ++ String.fromInt errCount
                            ++ " error(s)"
                        )

                Ok typedData ->
                    -- Run typed optimization
                    case runTypedOptimization typedData.annotations typedData.nodeTypes canModule of
                        Err optErr ->
                            Expect.fail ("Typed optimization failed: " ++ optErr)

                        Ok localGraph ->
                            -- Convert to GlobalGraph and run monomorphization with any entry point
                            let
                                globalGraph =
                                    localGraphToGlobalGraph localGraph
                            in
                            case monomorphizeAny globalGraph of
                                Err monoErr ->
                                    Expect.fail ("Monomorphization failed: " ++ monoErr)

                                Ok monoGraph ->
                                    -- Verify the monomorphized graph has expected structure
                                    verifyMonoGraph monoGraph



-- ============================================================================
-- TYPE CHECKING
-- ============================================================================


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



-- ============================================================================
-- OPTIMIZATION
-- ============================================================================


runTypedOptimization : Dict String Name.Name Can.Annotation -> Dict Int Int Can.Type -> Can.Module -> Result String (TOpt.LocalGraph)
runTypedOptimization annotations exprTypes canModule =
    let
        -- Run PostSolve to fix Group B types and compute kernel env
        postSolveResult =
            PostSolve.postSolve annotations canModule exprTypes

        fixedNodeTypes =
            postSolveResult.nodeTypes

        kernelEnv =
            postSolveResult.kernelEnv

        typedModule =
            TCan.fromCanonical canModule fixedNodeTypes
    in
    case Result.run (TypedOptimize.optimizeTyped annotations fixedNodeTypes kernelEnv typedModule) of
        ( _, Ok graph ) ->
            Ok graph

        ( _, Err _ ) ->
            Err "Typed optimization produced an error"



-- ============================================================================
-- GRAPH CONVERSION
-- ============================================================================


{-| Convert a LocalGraph to a GlobalGraph for monomorphization.

The LocalGraph contains the module's definitions. We wrap it into a GlobalGraph
which is the input format for monomorphization.

-}
localGraphToGlobalGraph : (TOpt.LocalGraph) -> (TOpt.GlobalGraph)
localGraphToGlobalGraph localGraph =
    TOpt.addLocalGraph localGraph TOpt.emptyGlobalGraph



-- ============================================================================
-- MONOMORPHIZATION (test-specific entry point finder)
-- ============================================================================


{-| Monomorphize using the first defined function as entry point.

This is useful for testing when the entry point name is not known in advance.
Test modules use various names like "testValue", "dup", "capture", etc.

-}
monomorphizeAny : (TOpt.GlobalGraph) -> Result String Mono.MonoGraph
monomorphizeAny (TOpt.GlobalGraph nodes _ _) =
    case findAnyEntryPoint nodes of
        Nothing ->
            Err "No function found in graph"

        Just ( TOpt.Global _ name, _ ) ->
            Monomorphize.monomorphize name TypeEnv.emptyGlobal (TOpt.GlobalGraph nodes Dict.empty Dict.empty)


{-| Find any entry point in the global graph (the first defined function).
-}
findAnyEntryPoint : Dict (List String) TOpt.Global (TOpt.Node) -> Maybe ( TOpt.Global, Can.Type )
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



-- ============================================================================
-- VERIFICATION
-- ============================================================================


{-| Verify that the monomorphized graph has the expected structure.

Currently checks:

  - The graph has a main entry point
  - The graph has at least one node

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
