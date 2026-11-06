module UnsafePatternDestructFixedListPatternLetDestructCasesTest exposing (..)

{-| A `let` that destructures a list with the fixed-length pattern `[ a, b ] = [ 1, 2 ]` is
rejected with an UNSAFE PATTERN error.

A pattern in a `let` must match every value of its type, and `[ a, b ]` matches only lists
of exactly two elements.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, Destruct fixed list pattern (LetDestructCases)
-- CHECK: -- UNSAFE PATTERN -

testValue =
    let
        [ a, b ] =
            [ 1, 2 ]
    in
    ( a, b )
