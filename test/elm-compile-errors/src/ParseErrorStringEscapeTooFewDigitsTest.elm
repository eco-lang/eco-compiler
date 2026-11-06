module ParseErrorStringEscapeTooFewDigitsTest exposing (..)

{-| A Unicode escape in a string with only two hex digits, `"\u{41}"`, is rejected with a BAD UNICODE ESCAPE syntax error.

Elm requires four to six hex digits between the braces of a `\u{...}` escape.

-}

-- COMPILE-ERROR: BAD UNICODE ESCAPE
-- CHECK: -- BAD UNICODE ESCAPE -
x =
    "\u{41}"
