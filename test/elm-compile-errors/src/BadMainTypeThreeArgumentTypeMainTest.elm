module BadMainTypeThreeArgumentTypeMainTest exposing (..)

{-| A `main` whose type is a custom type with three type parameters is rejected with a BAD MAIN TYPE error.

`main` is `T 1 2 3`, of type `T Int Int Int`.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, three-argument type main
-- CHECK: -- BAD MAIN TYPE -

type T a b c = T a b c

main : T Int Int Int
main = T 1 2 3
