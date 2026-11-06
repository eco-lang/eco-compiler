module BadMainTypeAliasMainTest exposing (..)

{-| A `main` whose type is a record type alias is rejected with a BAD MAIN TYPE error.

`main` has type `M`, an alias for `{ a : Int }`, which is not a type `main` may have.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, alias main
-- CHECK: -- BAD MAIN TYPE -

type alias M = { a : Int }

main : M
main = { a = 1 }
