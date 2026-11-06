module ParseErrorNumberBadHexDigitTest exposing (..)

{-| A hexadecimal literal containing a non-hex digit, `0x1g`, is rejected with a WEIRD HEXIDECIMAL syntax error.

The expected heading keeps the spelling "HEXIDECIMAL" used in Elm's own error message.

-}

-- COMPILE-ERROR: WEIRD HEXIDECIMAL
-- CHECK: -- WEIRD HEXIDECIMAL -
x =
    0x1g
