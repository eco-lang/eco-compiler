module TypeMismatchStringLeftOfPlusTest exposing (..)

{-| A `String` as the left operand of `+` is rejected with a TYPE MISMATCH.

`"a" + 1`: `+` takes two numbers, and strings are joined with `++` instead.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string left of +
-- CHECK: -- TYPE MISMATCH -

x = "a" + 1
