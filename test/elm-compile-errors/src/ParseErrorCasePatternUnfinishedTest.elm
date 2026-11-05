module ParseErrorCasePatternUnfinishedTest exposing (..)

{-| UNEXPECTED SYMBOL: case pattern unfinished.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: UNEXPECTED SYMBOL
-- CHECK: -- UNEXPECTED SYMBOL -
f n =
    case n of
        (1 ->
            0

        _ ->
            1
