module Text.PrettyPrint.ANSI.LeijenTest exposing (suite)

{-| Regression tests for `Text.PrettyPrint.ANSI.Leijen`, pinning two bugs fixed
2026-10-28 (plans/review-bug-triage-fixes.md, Part 5):

  - `hcatHelp`'s `[ doc ] -> doc` case discards the accumulator, so `hcat`
    keeps only the last document (`hcat [a, b, c]` renders `"c"`). This reaches
    `Compiler.Reporting.Error.Pattern`, which prints list patterns with `hcat`.
  - `renderPretty` writes no reset between adjacent styled strings nor after a
    final styled string, so the terminal stays styled after the output.

-}

import Expect
import Test exposing (Test)
import Text.PrettyPrint.ANSI.Leijen as L


render : L.Doc -> String
render doc =
    L.displayS (L.renderPretty 80 doc) ""


suite : Test
suite =
    Test.describe "Text.PrettyPrint.ANSI.Leijen"
        [ Test.test "hcat keeps every document" <|
            \_ ->
                render (L.hcat [ L.text "a", L.text "b", L.text "c" ])
                    |> Expect.equal "abc"
        , Test.test "a document ending in a styled string ends with a reset" <|
            \_ ->
                render (L.red (L.text "r"))
                    |> String.endsWith "\u{001B}[0m"
                    |> Expect.equal True
        , Test.test "underline does not carry over to the next styled string" <|
            \_ ->
                render (L.hcat [ L.underline (L.text "u"), L.red (L.text "r") ])
                    |> String.contains "u\u{001B}[0m"
                    |> Expect.equal True
        ]
