module ParseErrorStringEscapeUnclosedTest exposing (..)

{-| A Unicode escape in a string with no closing brace, `"\u{12"`, is rejected with a BAD UNICODE ESCAPE syntax error.

-}

-- COMPILE-ERROR: BAD UNICODE ESCAPE
-- CHECK: -- BAD UNICODE ESCAPE -
x =
    "\u{12"
