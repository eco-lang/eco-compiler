module Compiler.Reporting.Render.TypeLayoutReportTest exposing (suite)

{-| Checks how type error reports lay out record and tuple types, by compiling
erroneous programs through the front end (`TestLogic.Reporting.CompileReport`)
and comparing the report with what Elm 0.19.1 prints for the same program.

Each expected text is copied from the report of `elm make` 0.19.1. Today they
fail because of bugs in `Compiler.Reporting.Render.Type`:

  - `record` with an extension prints `{  r |x : Int, y : Int }` (two spaces
    after the brace, none after the bar) instead of `{ r | x : Int, y : Int }`.
  - `record` and `tuple` interleave the separators as documents of their own
    inside `D.cat`, so when the type does not fit on a line every `{`, `(` and
    `,` goes on a line of its own instead of starting the next field's line.
  - `vrecord` (the record of nearby fields in a "does not have a field"
    report) puts the brace, each field, each comma and a single space each on
    a line of their own; with an extension it prints `a {` and a line
    `| alpha : Int , beta : Int` instead of `{ a` and `| alpha : Int, beta : Int`.
  - `vrecordSnippet` (more than four fields) has no comma before the second
    field and puts each comma and a single space on a line of their own.
  - `srcToDoc` keeps a function type that was written in parentheses with a
    comment inside, as the result of another function type, as a separate
    parenthesised type: `Int -> ({- c -} Int -> R)` prints as
    `Int -> (Int -> R)` instead of `Int -> Int -> R`.

The last case is not about `Render.Type`: the recursive-alias suggestion of
`Compiler.Reporting.Error.Canonicalize.aliasToUnionDoc` prints the alias's
parameters after the `=` and in reverse (`type  R = b a`) instead of
`type R a b =`.

-}

import Test exposing (Test)
import TestLogic.Reporting.CompileReport as CompileReport


extensibleRecord : String
extensibleRecord =
    """module Main exposing (main)


f : { r | x : Int, y : Int } -> Int
f r =
    r.x


main =
    f 5
"""


wideRecord : String
wideRecord =
    """module Main exposing (main)


f : { alphabetical : Int, betaversion : Int, gammaradiation : Int, deltafunction : Int } -> Int
f r =
    r.alphabetical


main =
    f 5
"""


wideTuple : String
wideTuple =
    """module Main exposing (main)


f : ( { alphabetical : Int, betaversion : Int }, { gammaradiation : Int, deltafunction : Int }, Int ) -> Int
f r =
    0


main =
    f 5
"""


misspeltFieldFew : String
misspeltFieldFew =
    """module Main exposing (main)


r1 =
    { alpha = 1, beta = 2 }


main =
    r1.alpah
"""


misspeltFieldMany : String
misspeltFieldMany =
    """module Main exposing (main)


r1 =
    { alpha = 1, beta = 2, gamma = 3, delta = 4, epsilon = 5 }


main =
    r1.alpah
"""


misspeltFieldExtensible : String
misspeltFieldExtensible =
    """module Main exposing (main)


g : { a | alpha : Int, beta : Int } -> Int
g r =
    r.alpah


main =
    g { alpha = 1, beta = 2 }
"""


aliasWithCommentedParens : String
aliasWithCommentedParens =
    """module Main exposing (main)


type alias R =
    { f : Int -> ({- c -} Int -> R) }


main =
    0
"""


aliasWithParameters : String
aliasWithParameters =
    """module Main exposing (main)


type alias R a b =
    { f : a -> b -> R a b }


main =
    0
"""


suite : Test
suite =
    Test.describe "Type layout in error reports"
        [ Test.test "an extensible record prints as { r | x : Int, y : Int }" <|
            \_ ->
                extensibleRecord
                    |> CompileReport.expectReportContains
                        "\n    { r | x : Int, y : Int }\n"
        , Test.test "a record too wide for a line puts each field on a line starting with { or ," <|
            \_ ->
                wideRecord
                    |> CompileReport.expectReportContains
                        (String.join "\n"
                            [ "    { alphabetical : Int"
                            , "    , betaversion : Int"
                            , "    , deltafunction : Int"
                            , "    , gammaradiation : Int"
                            , "    }"
                            ]
                        )
        , Test.test "a tuple too wide for a line puts each element on a line starting with ( or ," <|
            \_ ->
                wideTuple
                    |> CompileReport.expectReportContains
                        (String.join "\n"
                            [ "    ( { alphabetical : Int, betaversion : Int }"
                            , "    , { deltafunction : Int, gammaradiation : Int }"
                            , "    , Int"
                            , "    )"
                            ]
                        )
        , Test.test "the nearby fields of a small record print one field per line" <|
            \_ ->
                misspeltFieldFew
                    |> CompileReport.expectReportContains
                        (String.join "\n"
                            [ "    { alpha : number"
                            , "    , beta : number1"
                            , "    }"
                            ]
                        )
        , Test.test "the nearby fields of a large record print as an excerpt with commas" <|
            \_ ->
                misspeltFieldMany
                    |> CompileReport.expectReportContains
                        (String.join "\n"
                            [ "    { alpha : number"
                            , "    , beta : number1"
                            , "    , delta : number2"
                            , "    , gamma : number4"
                            , "    , ..."
                            , "    }"
                            ]
                        )
        , Test.test "the nearby fields of an extensible record start with { a" <|
            \_ ->
                misspeltFieldExtensible
                    |> CompileReport.expectReportContains
                        (String.join "\n"
                            [ "    { a"
                            , "        | alpha : Int, beta : Int"
                            , "    }"
                            ]
                        )
        , Test.test "a parenthesised function type with a comment joins the arrow chain" <|
            \_ ->
                aliasWithCommentedParens
                    |> CompileReport.expectReportContains "{ f : Int -> Int -> R }"
        , Test.test "the recursive-alias suggestion keeps the parameters after the name" <|
            \_ ->
                aliasWithParameters
                    |> CompileReport.expectReportContains "    type R a b =\n"
        ]
