module UnsafePatternAllDestructPatternsEdgeCaseCasesTest exposing (..)

{-| A `let` that destructures a list with `(h :: t) = [ 4, 5 ]` is rejected with an UNSAFE
PATTERN error.

A pattern in a `let` must match every value of its type. The same `let` also destructures a
tuple, a record and an `as` alias, which always match; the cons pattern does not, because
it fails on the empty list.

-}

-- COMPILE-ERROR: UNSAFE PATTERN, All destruct patterns (EdgeCaseCases)
-- CHECK: -- UNSAFE PATTERN -

testValue =
    let
        ( a, b ) =
            ( 1, 2 )

        { x } =
            { x = 3 }

        (h :: t) =
            [ 4, 5 ]

        (v as w) =
            6
    in
    [ a, x, h, v ]
