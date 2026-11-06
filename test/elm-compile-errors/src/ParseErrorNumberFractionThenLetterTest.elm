module ParseErrorNumberFractionThenLetterTest exposing (..)

{-| A float literal followed directly by a letter, `1.5a`, is rejected with a WEIRD NUMBER syntax error.

-}

-- COMPILE-ERROR: WEIRD NUMBER
-- CHECK: -- WEIRD NUMBER -
x =
    1.5a
