module TypeMismatchTwoComparableVarsTest exposing (..)

{-| A list mixing tuples whose first components have different custom types is rejected with a TYPE MISMATCH.

`f a b` compares each argument with `<` (so both are `comparable`) and returns `[ ( A, a ), ( B, b ) ]`. The first components have types `A` and `B`, so the two tuples cannot share a list.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two comparable vars
-- CHECK: -- TYPE MISMATCH -

type A = A

type B = B

f a b = if a < a && b < b then [ ( A, a ), ( B, b ) ] else []
