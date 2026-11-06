module TypeMismatchParameterisedAliasTest exposing (..)

{-| Giving a `Box Int` where a `Box String` is annotated is rejected with a TYPE MISMATCH error.

`Box a` is a record alias `{ v : a }`, so the two instances are records whose `v` fields have different types.

-}

-- COMPILE-ERROR: TYPE MISMATCH, parameterised alias
-- CHECK: -- TYPE MISMATCH -

type alias Box a = { v : a }

b : Box Int
b = { v = 1 }

x : Box String
x = b
