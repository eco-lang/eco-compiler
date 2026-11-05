module WeirdElseBranchElseNotIndentedTest exposing (main)

{-| WEIRD ELSE BRANCH: else not indented.

From `Compiler.Reporting.SyntaxRegionReportTest` (`elseNotIndented`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: WEIRD ELSE BRANCH
-- CHECK: -- WEIRD ELSE BRANCH -
-- CHECK: I was partway through an `if` expression when I got stuck here:
-- CHECK: I think this else keyword needs to be indented more. Try adding some spaces
-- CHECK: before it.


main =
    let
        y =
            if True then
                1
        else
                2
    in
    y
