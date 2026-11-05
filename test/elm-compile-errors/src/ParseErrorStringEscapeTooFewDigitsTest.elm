module ParseErrorStringEscapeTooFewDigitsTest exposing (..)

{-| BAD UNICODE ESCAPE: string escape too few digits.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: BAD UNICODE ESCAPE
-- CHECK: -- BAD UNICODE ESCAPE -
x =
    "\u{41}"
