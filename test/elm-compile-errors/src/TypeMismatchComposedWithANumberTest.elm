module TypeMismatchComposedWithANumberTest exposing (..)

{-| `not >> 1` is rejected with a TYPE MISMATCH, because `>>` composes two functions and `1` is a number.

-}

-- COMPILE-ERROR: TYPE MISMATCH, composed with a number
-- CHECK: -- TYPE MISMATCH -

x = not >> 1
