module ParseErrorStringEscapeUnclosedTest exposing (..)

{-| BAD UNICODE ESCAPE: string escape unclosed.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: BAD UNICODE ESCAPE
-- CHECK: -- BAD UNICODE ESCAPE -
-- CHECK: I ran into an invalid Unicode escape:
-- CHECK: Here are some examples of valid Unicode escapes:
-- CHECK: \u{0041}
x =
    "\u{12"
