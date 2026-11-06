module TypeMismatchUnknownTypesOnBothSidesTest exposing (..)

{-| A list of pairs `( h, 1 )` and `( h, "a" )`, built inside a case on `[ 1, "a" ]`, is
rejected with a TYPE MISMATCH error.

The scrutinee already mixes a number with a `String`, so the type of `h` is unknown; it is
the same on both sides, and the second components, a number and a `String`, also clash.
The test checks only that a TYPE MISMATCH is reported.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unknown types on both sides
-- CHECK: -- TYPE MISMATCH -

x =
    case [ 1, "a" ] of
        h :: _ ->
            [ ( h, 1 ), ( h, "a" ) ]

        [] ->
            []
