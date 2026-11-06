module TypeMismatchDifferentlyNamedComparableVarsTest exposing (..)

{-| A list of two tuples whose first components are values of different custom types is rejected with a TYPE MISMATCH, where the second components are functions annotated with differently named `comparable` variables.

The entries are `( A, lex )` and `( B, lex2 )`, with `lex : comparable -> comparable` and
`lex2 : comparable2 -> comparable2`. `A` and `B` belong to the distinct types `A` and `B`, so the
entries cannot agree. The two functions alone could, since each use of an annotated top-level
function gets fresh type variables.

-}

-- COMPILE-ERROR: TYPE MISMATCH, differently named comparable vars
-- CHECK: -- TYPE MISMATCH -

type A = A

type B = B

lex : comparable -> comparable
lex v = v

lex2 : comparable2 -> comparable2
lex2 v = v

x = [ ( A, lex ), ( B, lex2 ) ]
