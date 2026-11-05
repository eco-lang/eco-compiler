module ParseErrorStringEscapeUnclosedTest exposing (..)

{-| BAD UNICODE ESCAPE: string escape unclosed.

A syntax error the parser must report.

-}

-- COMPILE-ERROR: BAD UNICODE ESCAPE
-- CHECK: -- BAD UNICODE ESCAPE -
x =
    "\u{12"
