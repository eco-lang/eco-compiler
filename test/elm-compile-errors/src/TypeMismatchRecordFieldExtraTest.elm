module TypeMismatchRecordFieldExtraTest exposing (..)

{-| Passing the record `{ name = 1, age = 2 }` to a function annotated to take exactly `{ name : Int }` is rejected with a TYPE MISMATCH error.

The annotation is a closed record type, so a record with the extra field `age` does not match it.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record field extra
-- CHECK: -- TYPE MISMATCH -

f : { name : Int } -> Int
f r = r.name

x = f { name = 1, age = 2 }
