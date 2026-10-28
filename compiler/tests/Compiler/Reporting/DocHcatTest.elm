module Compiler.Reporting.DocHcatTest exposing (suite)

{-| Reproduces a bug in `Compiler.Reporting.Doc.hcat` (passed through from
`Text.PrettyPrint.ANSI.Leijen.hcat`): for two or more documents it returns only
the last one instead of concatenating them, so callers such as the finite-list
printing in `Compiler.Reporting.Error.Pattern` lose content.

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, Part 5); the tests pin
the fix.

-}

import Compiler.Reporting.Doc as D
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Doc.hcat"
        [ Test.test "concatenates every document" <|
            \_ ->
                D.hcat [ D.fromChars "a", D.fromChars "b", D.fromChars "c" ]
                    |> D.toString
                    |> Expect.equal "abc"
        ]
