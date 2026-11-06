module TypeMismatchRecordFieldsMissingTest exposing (..)

{-| Passing the record `{ name = 1 }` to a function annotated to take `{ name : Int, age : Int, size : Int }` is rejected with a TYPE MISMATCH error, because the fields `age` and `size` are missing.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record fields missing
-- CHECK: -- TYPE MISMATCH -

f : { name : Int, age : Int, size : Int } -> Int
f r = r.name

x = f { name = 1 }
