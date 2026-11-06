module TypeMismatchListEntryPatternTest exposing (..)

{-| A list pattern whose entries have different types is rejected with a TYPE MISMATCH.

The `case` branch pattern `[ 1, "a" ]` mixes a number pattern and a string pattern
in one list, and all entries of a list must share one type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list entry pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case [ 1 ] of
        [ 1, "a" ] ->
            1

        _ ->
            2
