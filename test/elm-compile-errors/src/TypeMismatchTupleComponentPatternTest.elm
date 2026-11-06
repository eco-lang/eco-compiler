module TypeMismatchTupleComponentPatternTest exposing (..)

{-| A tuple pattern whose first component is a `String` literal, matched against a tuple of numbers, is rejected with a TYPE MISMATCH.

The pattern `( "a", b )` is used in a `case` on `( 1, 2 )`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, tuple component pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case ( 1, 2 ) of
        ( "a", b ) ->
            1

        _ ->
            2
