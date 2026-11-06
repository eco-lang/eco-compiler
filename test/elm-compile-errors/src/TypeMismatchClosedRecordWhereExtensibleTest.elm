module TypeMismatchClosedRecordWhereExtensibleTest exposing (..)

{-| Passing a record that lacks a field the result must have is rejected with a TYPE MISMATCH.

`g : { r | name : Int } -> { r | name : Int }` returns a record of the same type as its
argument, so annotating `x = g { name = 1 }` as `{ name : Int, age : Int }` requires the
argument to have an `age` field, which the record literal `{ name = 1 }` does not.

-}

-- COMPILE-ERROR: TYPE MISMATCH, closed record where extensible
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> { r | name : Int }
g r = r

x : { name : Int, age : Int }
x = g { name = 1 }
