module TypeMismatchStringLeftOfLessThanTest exposing (..)

{-| Comparing a `String` with a number using `<` is rejected with a TYPE MISMATCH.

In `"a" < 1` both operands of `<` must have the same `comparable` type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string left of <
-- CHECK: -- TYPE MISMATCH -

x = "a" < 1
