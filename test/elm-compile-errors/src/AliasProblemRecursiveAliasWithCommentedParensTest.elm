module AliasProblemRecursiveAliasWithCommentedParensTest exposing (main)

{-| ALIAS PROBLEM: recursive alias with commented parens.

From `Compiler.Reporting.Render.TypeLayoutReportTest` (`aliasWithCommentedParens`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: ALIAS PROBLEM
-- CHECK: -- ALIAS PROBLEM -
-- CHECK: This type alias is recursive, forming an infinite type!
-- CHECK: When I expand a recursive type alias, it just keeps getting bigger and bigger.
-- CHECK: So dealiasing results in an infinitely large type! Try this instead:


type alias R =
    { f : Int -> ({- c -} Int -> R) }


main =
    0
