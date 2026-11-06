module AliasProblemRecursiveAliasWithCommentedParensTest exposing (main)

{-| A record type alias that refers to itself is rejected with an ALIAS PROBLEM.

The field `f` of `R` has type `Int -> (Int -> R)`, with a block comment inside the
parentheses. A type alias cannot be recursive, so the compiler must report it.

-}

-- COMPILE-ERROR: ALIAS PROBLEM
-- CHECK: -- ALIAS PROBLEM -


type alias R =
    { f : Int -> ({- c -} Int -> R) }


main =
    0
