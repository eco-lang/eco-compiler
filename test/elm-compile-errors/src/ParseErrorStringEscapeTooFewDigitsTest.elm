module ParseErrorStringEscapeTooFewDigitsTest exposing (..)

{-| BAD UNICODE ESCAPE: string escape too few digits.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: BAD UNICODE ESCAPE
-- CHECK: -- BAD UNICODE ESCAPE -
-- CHECK: Every code point needs at least four digits:
-- CHECK: Try \u{0041} instead?
x =
    "\u{41}"
