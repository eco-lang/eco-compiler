module TypeMismatchStringRightOfPlusTest exposing (..)

{-| A `String` as the right operand of `+` is rejected with a TYPE MISMATCH.

`1 + "a"`: `+` takes two numbers, and strings are joined with `++` instead.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string right of +
-- CHECK: -- TYPE MISMATCH -

x = 1 + "a"
