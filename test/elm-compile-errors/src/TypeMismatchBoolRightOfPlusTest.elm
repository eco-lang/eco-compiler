module TypeMismatchBoolRightOfPlusTest exposing (..)

{-| `1 + True` is rejected with a TYPE MISMATCH, because `+` takes two numbers and `True` is a `Bool`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool right of +
-- CHECK: -- TYPE MISMATCH -

x = 1 + True
