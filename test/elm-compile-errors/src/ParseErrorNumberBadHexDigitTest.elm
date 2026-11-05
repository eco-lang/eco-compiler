module ParseErrorNumberBadHexDigitTest exposing (..)

{-| WEIRD HEXIDECIMAL: number bad hex digit.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: WEIRD HEXIDECIMAL
-- CHECK: -- WEIRD HEXIDECIMAL -
-- CHECK: I thought I was reading a hexidecimal number until I got here:
-- CHECK: Valid hexidecimal digits include 0123456789abcdefABCDEF, so I can only recognize
-- CHECK: things like this:
x =
    0x1g
