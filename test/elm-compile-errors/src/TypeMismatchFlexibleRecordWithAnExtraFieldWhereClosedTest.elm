module TypeMismatchFlexibleRecordWithAnExtraFieldWhereClosedTest exposing (..)

{-| The compiler rejects passing a record that must have an `age` field to a function that takes exactly `{ name : Int }`, with a TYPE MISMATCH error.

Inside `h`, `a.age` requires `a` to have an `age` field, and `g a` requires `a` to be the closed
record `{ name : Int }`, which has no such field.

-}

-- COMPILE-ERROR: TYPE MISMATCH, flexible record with an extra field where closed
-- CHECK: -- TYPE MISMATCH -

g : { name : Int } -> Int
g r = r.name

h a =
    let
        z = a.age
    in
    g a
