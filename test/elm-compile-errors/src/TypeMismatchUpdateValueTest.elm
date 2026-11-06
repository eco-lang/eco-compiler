module TypeMismatchUpdateValueTest exposing (..)

{-| A record update that gives an `Int` field a `String`, `{ r | x = "s" }` with
`r : { x : Int }`, is rejected with a TYPE MISMATCH error.

A record update keeps the record's type, so the new value of `x` must still be an `Int`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update value
-- CHECK: -- TYPE MISMATCH -

f : { x : Int } -> { x : Int }
f r = { r | x = "s" }
