module TypeMismatchNumberListEntryWithAnAliasTest exposing (..)

{-| A list literal holding a number and a value of the record alias `N` (`[ 1, n ]`) is rejected with a TYPE MISMATCH error.

All entries of a list share one type, and the record `{ y : Int }` that `N` names is not a `number`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number list entry with an alias
-- CHECK: -- TYPE MISMATCH -

type alias N = { y : Int }

n : N
n = { y = 1 }

x = [ 1, n ]
