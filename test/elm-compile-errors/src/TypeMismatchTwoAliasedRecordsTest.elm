module TypeMismatchTwoAliasedRecordsTest exposing (..)

{-| A value of one record alias annotated as a different record alias is rejected with a TYPE MISMATCH.

`P` is `{ a : Int }` and `Q` is `{ b : Int }`; `x : Q` is defined as the `P` value `p`, and the two records have different fields.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two aliased records
-- CHECK: -- TYPE MISMATCH -

type alias P = { a : Int }

type alias Q = { b : Int }

p : P
p = { a = 1 }

x : Q
x = p
