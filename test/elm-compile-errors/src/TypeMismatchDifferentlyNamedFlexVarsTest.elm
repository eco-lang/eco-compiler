module TypeMismatchDifferentlyNamedFlexVarsTest exposing (..)

{-| A list of two tuples whose first components are values of different custom types is rejected with a TYPE MISMATCH, where the second components are functions annotated with differently named type variables.

The entries are `( A, id1 )` and `( B, id2 )`, with `id1 : a -> a` and `id2 : b -> b`. `A` and
`B` belong to the distinct types `A` and `B`, so the entries cannot agree. The two functions
alone could, since each use of an annotated top-level function gets fresh type variables.

-}

-- COMPILE-ERROR: TYPE MISMATCH, differently named flex vars
-- CHECK: -- TYPE MISMATCH -

type A = A

type B = B

id1 : a -> a
id1 v = v

id2 : b -> b
id2 v = v

x = [ ( A, id1 ), ( B, id2 ) ]
