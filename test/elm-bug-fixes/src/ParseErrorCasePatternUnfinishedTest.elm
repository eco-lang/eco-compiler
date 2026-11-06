module ParseErrorCasePatternUnfinishedTest exposing (..)

{-| UNFINISHED PARENTHESES: a case pattern with an unclosed parenthesis.

Fixed in Elm 0.19.2. Elm 0.19.1 reports this as UNEXPECTED SYMBOL, pointing at the `->`
rather than at the missing `)`.

-}

-- COMPILE-ERROR: UNFINISHED PARENTHESES
-- CHECK: -- UNFINISHED PARENTHESES -
f n =
    case n of
        (1 ->
            0

        _ ->
            1
