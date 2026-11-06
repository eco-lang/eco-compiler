module TypeMismatchNumberPlusAppendableTest exposing (..)

{-| Appending to the result of an addition (`(a + 1) ++ b`) is rejected with a TYPE MISMATCH error.

`a + 1` must be a `number` and the left operand of `++` an `appendable`, and no type is both.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number plus appendable
-- CHECK: -- TYPE MISMATCH -

g a b = (a + 1) ++ b
