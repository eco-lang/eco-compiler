module TypeMismatchBoolPatternTest exposing (..)

{-| A `True` pattern in a `case` on a number is rejected with a TYPE MISMATCH.

`x` matches the number `1` against the `Bool` pattern `True`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, bool pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case 1 of
        True ->
            1

        _ ->
            2
