module ParseErrorNumberFractionThenLetterTest exposing (..)

{-| WEIRD NUMBER: number fraction then letter.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: WEIRD NUMBER
-- CHECK: -- WEIRD NUMBER -
x =
    1.5a
