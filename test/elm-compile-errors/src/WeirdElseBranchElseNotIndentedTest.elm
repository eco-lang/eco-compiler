module WeirdElseBranchElseNotIndentedTest exposing (main)

{-| WEIRD ELSE BRANCH: else not indented.

From `Compiler.Reporting.SyntaxRegionReportTest` (`elseNotIndented`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: WEIRD ELSE BRANCH
-- CHECK: -- WEIRD ELSE BRANCH -


main =
    let
        y =
            if True then
                1
        else
                2
    in
    y
