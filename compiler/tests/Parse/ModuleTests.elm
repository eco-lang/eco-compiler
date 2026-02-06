module Parse.ModuleTests exposing (suite)

import Compiler.AST.Source as S
import Compiler.Parse.Module as M
import Compiler.Reporting.Annotation as A
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Parse.Module"
        [ Test.describe "fromByteString"
            [ (\_ ->
                M.fromByteString M.Application """module Hello exposing (..)

import Html exposing (text)


main =
  text "Hello!"
                    """
                    |> Expect.equal
                        (Ok
                            (S.Module
                                { name = Just (A.at (A.Position 1 8) (A.Position 1 13) "Hello")
                                , exports = A.at (A.Position 1 23) (A.Position 1 27) (S.Open [] [])
                                , docs = S.NoDocs (A.Region (A.Position 1 27) (A.Position 3 1)) []
                                , imports =
                                    [ S.Import ( [], A.At A.zero "Platform.Sub" ) (Just ( ( [], [] ), "Sub" )) ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Upper (A.At A.zero "Sub") ( [], S.Private ) ) ]) )
                                    , S.Import ( [], A.At A.zero "Platform.Cmd" ) (Just ( ( [], [] ), "Cmd" )) ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Upper (A.At A.zero "Cmd") ( [], S.Private ) ) ]) )
                                    , S.Import ( [], A.At A.zero "Platform" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Upper (A.At A.zero "Program") ( [], S.Private ) ) ]) )
                                    , S.Import ( [], A.At A.zero "Tuple" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero []) )
                                    , S.Import ( [], A.At A.zero "Char" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Upper (A.At A.zero "Char") ( [], S.Private ) ) ]) )
                                    , S.Import ( [], A.At A.zero "String" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Upper (A.At A.zero "String") ( [], S.Private ) ) ]) )
                                    , S.Import ( [], A.At A.zero "Result" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Upper (A.At A.zero "Result") ( [], S.Public (A.Region (A.Position 0 0) (A.Position 0 0)) ) ) ]) )
                                    , S.Import ( [], A.At A.zero "Maybe" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Upper (A.At A.zero "Maybe") ( [], S.Public (A.Region (A.Position 0 0) (A.Position 0 0)) ) ) ]) )
                                    , S.Import ( [], A.At A.zero "List" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero [ ( ( [], [] ), S.Operator (A.Region (A.Position 0 0) (A.Position 0 0)) "::" ) ]) )
                                    , S.Import ( [], A.At A.zero "Debug" ) Nothing ( ( [], [] ), S.Explicit (A.At A.zero []) )
                                    , S.Import ( [], A.At A.zero "Basics" ) Nothing ( ( [], [] ), S.Open [] [] )
                                    , S.Import ( [], A.at (A.Position 3 8) (A.Position 3 12) "Html" ) Nothing ( ( [], [] ), S.Explicit (A.at (A.Position 3 23) (A.Position 3 28) [ ( ( [], [] ), S.Lower (A.at (A.Position 3 23) (A.Position 3 27) "text") ) ]) )
                                    ]
                                , values =
                                    [ A.at (A.Position 6 1)
                                        (A.Position 7 16)
                                        (S.Value
                                            { comments = []
                                            , name = ( [], A.at (A.Position 6 1) (A.Position 6 5) "main" )
                                            , args = []
                                            , body =
                                                ( []
                                                , A.at (A.Position 7 3)
                                                    (A.Position 7 16)
                                                    (S.Call (A.at (A.Position 7 3) (A.Position 7 7) (S.Var S.LowVar "text"))
                                                        [ ( [], A.at (A.Position 7 8) (A.Position 7 16) (S.Str "Hello!" False) )
                                                        ]
                                                    )
                                                )
                                            , tipe = Nothing
                                            }
                                        )
                                    ]
                                , unions = []
                                , aliases = []
                                , infixes = []
                                , effects = S.NoEffects
                                }
                            )
                        )
              )
                |> Test.test "Hello!"
            ]
        ]
