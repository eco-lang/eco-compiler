module Compiler.Reporting.Error.SyntaxRegionReportTest exposing (suite)

{-| Checks which columns syntax error reports underline, by compiling erroneous
programs through the front end (`TestLogic.Reporting.CompileReport`) and
comparing the report with what Elm 0.19.1 prints for the same program.

Each expected text is copied from the report of `elm make` 0.19.1. Today they
fail:

  - A float literal in a pattern (`Compiler.Parse.Pattern`) is underlined for
    `String.length (String.fromFloat value)` columns ending where the literal
    ends, not for the literal's source text: `1e3` gets four carets starting
    one column early, and `1.50` gets three starting one column late.
  - An invalid Unicode escape is underlined one column short: `"\u{12"` gets
    `\u{1` instead of `\u{12`, and `"\u{041}"` gets `\u{041` instead of
    `\u{041}`.
  - "WEIRD ELSE BRANCH" (`IfIndentElse`) underlines the `else` at the column
    `Compiler.Reporting.Render.Code.nextLineStartsWithKeyword` returns, one
    more than the length of the line without its indentation, instead of the
    column where `else` starts.

-}

import Test exposing (Test)
import TestLogic.Reporting.CompileReport as CompileReport


floatPatternWithExponent : String
floatPatternWithExponent =
    """module Main exposing (main)


f x =
    case x of
        1e3 ->
            1

        _ ->
            2


main =
    f 2
"""


floatPatternWithTrailingZero : String
floatPatternWithTrailingZero =
    """module Main exposing (main)


f x =
    case x of
        1.50 ->
            1

        _ ->
            2


main =
    f 2
"""


unclosedUnicodeEscape : String
unclosedUnicodeEscape =
    """module Main exposing (main)


main =
    "\\u{12"
"""


shortUnicodeEscape : String
shortUnicodeEscape =
    """module Main exposing (main)


main =
    "\\u{041}"
"""


elseNotIndented : String
elseNotIndented =
    """module Main exposing (main)


main =
    let
        y =
            if True then
                1
        else
                2
    in
    y
"""


suite : Test
suite =
    Test.describe "Regions of syntax error reports"
        [ Test.test "a float pattern 1e3 is underlined where it is written" <|
            \_ ->
                floatPatternWithExponent
                    |> CompileReport.expectReportContains "6|         1e3 ->\n           ^^^\n"
        , Test.test "a float pattern 1.50 is underlined where it is written" <|
            \_ ->
                floatPatternWithTrailingZero
                    |> CompileReport.expectReportContains "6|         1.50 ->\n           ^^^^\n"
        , Test.test "an unclosed Unicode escape is underlined up to its last digit" <|
            \_ ->
                unclosedUnicodeEscape
                    |> CompileReport.expectReportContains "5|     \"\\u{12\"\n        ^^^^^\n"
        , Test.test "a too-short Unicode escape is underlined up to its closing brace" <|
            \_ ->
                shortUnicodeEscape
                    |> CompileReport.expectReportContains "5|     \"\\u{041}\"\n        ^^^^^^^\n"
        , Test.test "an else that is not indented enough is underlined where it starts" <|
            \_ ->
                elseNotIndented
                    |> CompileReport.expectReportContains "9|         else\n           ^^^^\n"
        ]
