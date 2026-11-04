module Compiler.GenerateMlir.BackendNoMainTest exposing (suite)

{-| Generates MLIR, with `Compiler.GenerateMlir.Backend.generateMlirModule`,
for a monomorphized graph that has no `main`, which no source program gives
it: the test pipeline always adds a `main` that uses `testValue`, and `eco
make` refuses a program without one before code generation. The graph is the
optimized graph of a small program with its `main` removed.

The test passes when the generated module has no function named `main`.

-}

import Compiler.Config as Config
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.GenerateMlir.Backend as Backend
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect
import Mlir.Mlir exposing (MlirAttr(..))
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The one test, under a label that contains "coverage run" so that the
coverage loop's quick run includes it.
-}
suite : Test
suite =
    Test.describe "Backend without main (coverage run)"
        [ Test.test "generates no main function" <|
            \_ ->
                case Parse.fromByteString Parse.Application source of
                    Ok (Src.Module m) ->
                        case Pipeline.runToGlobalOpt (Src.Module { m | imports = List.filter isMockImport m.imports }) of
                            Ok artifacts ->
                                let
                                    (Mono.MonoGraph g) =
                                        artifacts.optimizedMonoGraph

                                    mlirModule =
                                        Backend.generateMlirModule Config.default (Mono.MonoGraph { g | main = Nothing })

                                    names =
                                        List.filterMap
                                            (\op ->
                                                case Dict.get "sym_name" op.attrs of
                                                    Just (StringAttr name) ->
                                                        Just name

                                                    _ ->
                                                        Nothing
                                            )
                                            mlirModule.body
                                in
                                Expect.equal False (List.member "main" names)

                            Err message ->
                                Expect.fail message

                    Err _ ->
                        Expect.fail "fixture failed to parse"
        ]


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The program's source text.
-}
source : String
source =
    """module Test exposing (..)


testValue =
    1
"""
