module TypeMismatchAliasWhereARecordTest exposing (..)

{-| A value of a record alias used where a record with a differently typed field is expected is rejected with a TYPE MISMATCH.

`p` has type `P`, an alias of `{ a : Int }`, and `x` is annotated `{ a : String }` but defined as `p`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, alias where a record
-- CHECK: -- TYPE MISMATCH -

type alias P = { a : Int }

p : P
p = { a = 1 }

x : { a : String }
x = p
