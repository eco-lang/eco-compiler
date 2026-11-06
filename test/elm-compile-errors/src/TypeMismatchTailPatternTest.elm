module TypeMismatchTailPatternTest exposing (..)

{-| A list pattern whose tail is a `String` literal is rejected with a TYPE MISMATCH.

The pattern `a :: "s"` puts a string where the tail of the scrutinee `[ 1 ]` must be a list.

-}

-- COMPILE-ERROR: TYPE MISMATCH, tail pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case [ 1 ] of
        a :: "s" ->
            1

        _ ->
            2
