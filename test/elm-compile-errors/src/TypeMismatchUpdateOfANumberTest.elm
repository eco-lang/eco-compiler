module TypeMismatchUpdateOfANumberTest exposing (..)

{-| A record update applied to an `Int`, `{ n | x = 1 }` with `n : Int`, is rejected with a
TYPE MISMATCH error.

Only a record can be updated, and `n` is a number.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update of a number
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

y = { n | x = 1 }
