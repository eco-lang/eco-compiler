module ParseErrorCasePatternUnfinishedTest exposing (..)

{-| UNEXPECTED SYMBOL: case pattern unfinished.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: UNEXPECTED SYMBOL
-- CHECK: -- UNEXPECTED SYMBOL -
-- CHECK: I ran into the -> symbol unexpectedly in this pattern:
-- CHECK: Only the :: symbol that works in patterns. It is useful if you are pattern
-- CHECK: matching on lists, trying to get the first element off the front. Did you want
f n =
    case n of
        (1 ->
            0

        _ ->
            1
