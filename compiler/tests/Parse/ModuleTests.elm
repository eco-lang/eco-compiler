module Parse.ModuleTests exposing (suite)

{-| A test that pins the whole `Compiler.AST.Source.Module` that
`Compiler.Parse.Module.fromByteString` produces for one small module, so that a
change to the regions the parser records for a module header, an import, or a
simple value declaration, or to which default imports it adds to an application
module and in what order, shows up as a failing test.

The fixture is a source string parsed as an `Application`. Its line 1 is
`module Hello exposing (..)`, line 3 is `import Html exposing (text)`, line 6
is `main =`, and line 7 is `text "Hello!"` indented by two spaces. Lines 2, 4
and 5 are empty.

A position is a row and a column, both counted from 1. The region pinned for a
name or an expression in the fixture runs from the position of its first
character to the position just after its last. The region pinned for the
`Html` import's exposing list `(text)` does not: it begins after the `(` and
ends after the `)`.

The one test, "Hello!", checks with a single `Expect.equal` that the result is
`Ok` and equal to the expected module in every part:

  - The name `Hello` and the exposing list `(..)`, each with its region, and a
    `NoDocs` whose region runs from the end of the header to the start of the
    `import` line, with no declaration doc comments.
  - The imports: the eleven default imports, each with the zero region, from
    `Platform.Sub` first to `Basics` last, which is the reverse of the order in
    `Compiler.Elm.Compiler.Imports.defaults`, followed by the `Html` import with
    its source regions.
  - The single value `main`, with no arguments and no annotation, whose body is
    `text` applied to the string literal `"Hello!"`, and no unions, aliases,
    infixes or effects.

Among what is not tested: `port module` and `effect module` headers, a file
with no header, a module doc comment, type annotations, more than one
declaration of a kind (so the order in which the module lists declarations is
not exercised), parsing as a package or kernel application, and any source
that fails to parse or fails the module checks.

-}

import Compiler.AST.Source as S
import Compiler.Parse.Module as M
import Compiler.Reporting.Annotation as A
import Expect
import Test exposing (Test)


{-| The tests for `Compiler.Parse.Module.fromByteString`: one test that parses
the fixture source and compares the result with the full expected module.
-}
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
