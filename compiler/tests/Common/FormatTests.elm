module Common.FormatTests exposing (suite)

import Common.Format
import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as M
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Common.Format.format"
        [ Test.describe "fromByteString"
            [ (\_ ->
                Common.Format.format (M.Package Pkg.core) (generateModule defaultModule)
                    |> Expect.equal (Ok "module Main exposing (..)\n\n\nfn =\n    ()\n")
              )
                |> Test.test "Header"
            , (\_ ->
                Common.Format.format
                    (M.Package Pkg.core)
                    (generateModule
                        { defaultModule
                            | declarations =
                                [ "fn = { {- C1 -} a {- C2 -} = {- C3 -} 1 {- C4 -}, {- C5 -} b {- C6 -} = {- C7 -} 2 {- C8 -} }"
                                ]
                        }
                    )
                    |> Expect.equal (Ok "module Main exposing (..)\n\n\nfn =\n    { {- C1 -} a {- C2 -} = {- C3 -} 1\n\n    {- C4 -}\n    , {- C5 -} b {- C6 -} = {- C7 -} 2\n\n    {- C8 -}\n    }\n")
              )
                |> Test.test "Records"
            ]
        ]


type alias GenerateModuleConfig =
    { header : String
    , docs : String
    , imports : List String
    , infixes : List String
    , declarations : List String
    }


defaultModule : GenerateModuleConfig
defaultModule =
    { header = "module Main exposing (..)"
    , docs = ""
    , imports = []
    , infixes = []
    , declarations = [ "fn = ()" ]
    }


generateModule : GenerateModuleConfig -> String
generateModule { header, docs, imports, infixes, declarations } =
    String.join "\n"
        [ header
        , docs
        , String.join "\n" imports
        , String.join "\n" infixes
        , String.join "\n" declarations
        ]
