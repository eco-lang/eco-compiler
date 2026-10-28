module Compiler.Reporting.Render.CodeWhatIsNextTest exposing (suite)

{-| Reproduces a bug in `Compiler.Reporting.Render.Code.whatIsNext` /
`detectKeywords`: they `List.filter` the whole rest of the line instead of
taking the leading run (upstream uses `takeWhile`), so `if x then` at the `i`
gives `Lower 'i' "ifxthen"` instead of `Keyword "if"`, and `|> f <| g` gives
`Operator "|><|"`. Syntax reports then name the wrong text.

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, Part 5); the tests pin
the fix.

-}

import Compiler.Reporting.Render.Code as Code
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Code.whatIsNext takes the leading run"
        [ Test.test "keyword followed by more words" <|
            \_ ->
                Code.whatIsNext (Code.toSource "if x then") 1 1
                    |> Expect.equal (Code.Keyword "if")
        , Test.test "words separated by a space are not merged" <|
            \_ ->
                Code.whatIsNext (Code.toSource "i f") 1 1
                    |> Expect.equal (Code.Lower 'i' "i")
        , Test.test "operator followed by another operator later" <|
            \_ ->
                Code.whatIsNext (Code.toSource "|> f <| g") 1 1
                    |> Expect.equal (Code.Operator "|>")
        , Test.test "upper name followed by more words" <|
            \_ ->
                Code.whatIsNext (Code.toSource "Html exposing") 1 1
                    |> Expect.equal (Code.Upper 'H' "tml")
        ]
