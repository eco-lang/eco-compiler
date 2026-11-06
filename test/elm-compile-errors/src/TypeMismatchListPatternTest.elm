module TypeMismatchListPatternTest exposing (..)

{-| Matching a number against a list pattern is rejected with a TYPE MISMATCH.

`case 1 of` scrutinises a number, but its first branch uses the empty-list
pattern `[]`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case 1 of
        [] ->
            1

        _ ->
            2
