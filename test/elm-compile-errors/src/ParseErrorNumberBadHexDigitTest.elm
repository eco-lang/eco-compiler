module ParseErrorNumberBadHexDigitTest exposing (..)

{-| WEIRD HEXIDECIMAL: number bad hex digit.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: WEIRD HEXIDECIMAL
-- CHECK: -- WEIRD HEXIDECIMAL -
x =
    0x1g
