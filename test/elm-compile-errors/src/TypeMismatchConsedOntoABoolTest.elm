module TypeMismatchConsedOntoABoolTest exposing (..)

{-| `1 :: True` is rejected with a TYPE MISMATCH, because the right side of `::` must be a list and `True` is a `Bool`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, consed onto a Bool
-- CHECK: -- TYPE MISMATCH -

x = 1 :: True
