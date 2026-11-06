module TypeMismatchFieldAccessUnderIntTest exposing (..)

{-| A value annotated `Int` but defined as a `String` field of a record, `r.name`, is rejected with a TYPE MISMATCH.

-}

-- COMPILE-ERROR: TYPE MISMATCH, field access under Int
-- CHECK: -- TYPE MISMATCH -

r = { name = "a" }

x : Int
x = r.name
