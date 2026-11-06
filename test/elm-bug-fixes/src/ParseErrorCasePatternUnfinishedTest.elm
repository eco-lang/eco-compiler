module ParseErrorCasePatternUnfinishedTest exposing (..)

{-| A case pattern with an unclosed parenthesis, `(1 ->`, is reported as UNFINISHED PARENTHESES.

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
