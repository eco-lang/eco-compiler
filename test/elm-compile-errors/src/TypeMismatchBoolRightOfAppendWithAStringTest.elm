module TypeMismatchBoolRightOfAppendWithAStringTest exposing (..)

{-| A `Bool` on the right of `++` after a `String` is rejected with a TYPE MISMATCH.

`x = "a" ++ True`: the left operand fixes the type to `String`, and `True` is a `Bool`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool right of ++ with a string
-- CHECK: -- TYPE MISMATCH -

x = "a" ++ True
