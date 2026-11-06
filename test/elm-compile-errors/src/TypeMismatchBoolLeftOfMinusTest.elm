module TypeMismatchBoolLeftOfMinusTest exposing (..)

{-| A `Bool` on the left of `-` is rejected with a TYPE MISMATCH.

`x = True - 1`: `-` needs numbers, and `True` is a `Bool`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool left of -
-- CHECK: -- TYPE MISMATCH -

x = True - 1
