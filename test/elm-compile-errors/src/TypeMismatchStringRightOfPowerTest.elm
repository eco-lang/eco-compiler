module TypeMismatchStringRightOfPowerTest exposing (..)

{-| A `String` as the right operand of `^` is rejected with a TYPE MISMATCH.

`2 ^ "a"`: `^` takes two numbers.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string right of ^
-- CHECK: -- TYPE MISMATCH -

x = 2 ^ "a"
