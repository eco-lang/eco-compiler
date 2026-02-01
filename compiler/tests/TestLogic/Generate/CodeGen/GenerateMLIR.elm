module TestLogic.Generate.CodeGen.GenerateMLIR exposing
    ( expectMLIRGeneration
    , compileToMlirModule
    , CompileResult
    )

{-| Test infrastructure for verifying that monomorphized code can be compiled to MLIR.

This module runs the full typed compilation pipeline through MLIR code generation:

1.  Source AST
2.  Canonical AST (with expression IDs)
3.  Type checking (with ID tracking)
4.  TypedCanonical
5.  TypedOptimized (LocalGraph)
6.  GlobalGraph (for monomorphization)
7.  Monomorphized (MonoGraph)
8.  MLIR code generation

The test verifies that MLIR generation completes successfully and produces output.


# Test Functions

@docs expectMLIRGeneration


# Compilation for Invariant Testing

@docs compileToMlirModule, CompileResult

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedCanonical as TCan
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
import Compiler.Generate.Monomorphize as Monomorphize
import Compiler.Optimize.Typed.Module as TypedOptimize
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Data.Map as Dict exposing (Dict)
import Expect
import Mlir.Mlir exposing (MlirModule)
import System.TypeCheck.IO as IO


{-| Verify that a source module can be successfully compiled to MLIR.

This runs the full typed compilation pipeline through MLIR code generation and
verifies that it completes without errors and produces non-empty output.

-}
expectMLIRGeneration : Src.Module -> Expect.Expectation
expectMLIRGeneration srcModule =
    let
        canonResult =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule
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
                            -- Convert to GlobalGraph and run monomorphization
                            let
                                globalGraph =
                                    localGraphToGlobalGraph localGraph

                                -- Build GlobalTypeEnv from the canonical module
                                globalTypeEnv =
                                    buildGlobalTypeEnv canModule
                            in
                            case monomorphizeAny globalTypeEnv globalGraph of
                                Err monoErr ->
                                    Expect.fail ("Monomorphization failed: " ++ monoErr)

                                Ok monoGraph ->
                                    -- Run MLIR code generation
                                    case runMLIRGeneration globalTypeEnv monoGraph of
                                        Err mlirErr ->
                                            Expect.fail
                                                ("MLIR generation failed: " ++ mlirErr)

                                        Ok output ->
                                            verifyMLIROutput monoGraph output



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


runTypedOptimization : Dict String Name.Name Can.Annotation -> Dict Int Int Can.Type -> Can.Module -> Result String TOpt.LocalGraph
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
-}
localGraphToGlobalGraph : TOpt.LocalGraph -> TOpt.GlobalGraph
localGraphToGlobalGraph localGraph =
    TOpt.addLocalGraph localGraph TOpt.emptyGlobalGraph



-- ============================================================================
-- TYPE ENVIRONMENT
-- ============================================================================


{-| Build a GlobalTypeEnv from a canonical module and test interfaces.

This extracts the union and alias definitions from:

1.  The test module itself (e.g., Array with its Node, Builder types)
2.  All test interfaces (Basics, List, Maybe, JsArray, etc.)

Both are needed for monomorphization to find all referenced types.

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



-- ============================================================================
-- MONOMORPHIZATION
-- ============================================================================


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



-- ============================================================================
-- MLIR CODE GENERATION
-- ============================================================================


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
-- VERIFICATION
-- ============================================================================


{-| Verify that the MLIR output has expected structure.

Currently checks:

  - The output is non-empty
  - The output contains at least one MLIR operation

-}
verifyMLIROutput : Mono.MonoGraph -> String -> Expect.Expectation
verifyMLIROutput monoGraph output =
    if String.isEmpty output then
        Expect.fail
            "MLIR output is empty\n\nMonomorphized IR:\n"

    else if not (String.contains "func.func" output || String.contains "eco." output) then
        Expect.fail
            "MLIR output doesn't contain expected operations\n\nMonomorphized IR:\n"

    else
        Expect.pass



-- ============================================================================
-- MLIR MODULE COMPILATION FOR INVARIANT TESTING
-- ============================================================================


{-| Result of compiling to MlirModule.
-}
type alias CompileResult =
    { mlirModule : MlirModule
    , monoGraph : Mono.MonoGraph
    }


{-| Compile a source module to MlirModule for invariant testing.

Returns the MlirModule and MonoGraph on success, or an error message on failure.

-}
compileToMlirModule : Src.Module -> Result String CompileResult
compileToMlirModule srcModule =
    let
        canonResult =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule
    in
    case Result.run canonResult of
        ( _, Err errors ) ->
            let
                errorCount =
                    OneOrMore.destruct (::) errors |> List.length
            in
            Err ("Canonicalization failed with " ++ String.fromInt errorCount ++ " error(s)")

        ( _, Ok canModule ) ->
            let
                typeCheckResult =
                    IO.unsafePerformIO (runWithIdsTypeCheck canModule)
            in
            case typeCheckResult of
                Err errCount ->
                    Err ("Type checking failed with " ++ String.fromInt errCount ++ " error(s)")

                Ok typedData ->
                    case runTypedOptimization typedData.annotations typedData.nodeTypes canModule of
                        Err optErr ->
                            Err ("Typed optimization failed: " ++ optErr)

                        Ok localGraph ->
                            let
                                globalGraph =
                                    localGraphToGlobalGraph localGraph

                                globalTypeEnv =
                                    buildGlobalTypeEnv canModule
                            in
                            case monomorphizeAny globalTypeEnv globalGraph of
                                Err monoErr ->
                                    Err ("Monomorphization failed: " ++ monoErr)

                                Ok monoGraph ->
                                    let
                                        mlirModule =
                                            MLIR.generateMlirModule (Mode.Dev Nothing) globalTypeEnv monoGraph
                                    in
                                    Ok { mlirModule = mlirModule, monoGraph = monoGraph }
