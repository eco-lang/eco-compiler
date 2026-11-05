module AliasProblemRecursiveAliasWithCommentedParensTest exposing (main)

{-| ALIAS PROBLEM: recursive alias with commented parens.

From `Compiler.Reporting.Render.TypeLayoutReportTest` (`aliasWithCommentedParens`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: ALIAS PROBLEM
-- CHECK: -- ALIAS PROBLEM -


type alias R =
    { f : Int -> ({- c -} Int -> R) }


main =
    0
