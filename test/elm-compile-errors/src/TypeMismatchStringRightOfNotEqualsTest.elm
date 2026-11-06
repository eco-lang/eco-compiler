module TypeMismatchStringRightOfNotEqualsTest exposing (..)

{-| Comparing a number with a `String` using `/=` is rejected with a TYPE MISMATCH.

In `1 /= "a"` both operands of `/=` must have the same type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string right of /=
-- CHECK: -- TYPE MISMATCH -

x = 1 /= "a"
