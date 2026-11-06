module TypeMismatchConsedOntoAMaybeTest exposing (..)

{-| `1 :: Just 1` is rejected with a TYPE MISMATCH, because the right side of `::` must be a list and `Just 1` is a `Maybe`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, consed onto a Maybe
-- CHECK: -- TYPE MISMATCH -

x = 1 :: Just 1
