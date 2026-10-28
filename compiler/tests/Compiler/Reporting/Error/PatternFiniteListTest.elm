module Compiler.Reporting.Error.PatternFiniteListTest exposing (suite)

{-| Reproduces two bugs in how `Compiler.Reporting.Error.Pattern` prints a
missing finite-list pattern such as `[1, 2]`:

  - `delist` returns `FiniteList revEntries` without reversing it (the
    `Conses` branch does reverse), so entries are in reverse order;
  - the entries are joined with `D.hcat`, which keeps only the last document.

Today the missing pattern prints as `[1]`; it should print `[1,2]`.

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, Part 5); the tests pin
the fix.

-}

import Compiler.AST.Canonical as Can
import Compiler.Nitpick.PatternMatches as P
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error.Pattern as Pattern
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Report as Report
import Expect
import Test exposing (Test)


listUnion : Can.Union
listUnion =
    Can.Union { vars = [ "a" ], alts = [], numAlts = 2, opts = Can.Normal }


cons : P.Pattern -> P.Pattern -> P.Pattern
cons hd tl =
    P.Ctor listUnion "::" [ hd, tl ]


nil : P.Pattern
nil =
    P.Ctor listUnion "[]" []


rendered : String
rendered =
    let
        region =
            A.Region (A.Position 1 1) (A.Position 1 5)

        (Report.Report props) =
            Pattern.toReport (Code.toSource "case xs of")
                (P.Incomplete region P.BadCase [ cons (P.Literal (P.Int 1)) (cons (P.Literal (P.Int 2)) nil) ])
    in
    D.toString props.doc


suite : Test
suite =
    Test.describe "Error.Pattern finite list"
        [ Test.test "a missing [1, 2] prints both entries in order" <|
            \_ ->
                rendered
                    |> String.contains "[1,2]"
                    |> Expect.equal True
        ]
