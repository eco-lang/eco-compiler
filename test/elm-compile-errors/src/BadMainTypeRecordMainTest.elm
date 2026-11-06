module BadMainTypeRecordMainTest exposing (..)

{-| A `main` of record type `{ a : Int, b : ( Int, Int, Int ) }` is rejected with a BAD MAIN TYPE error.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, record main
-- CHECK: -- BAD MAIN TYPE -

main : { a : Int, b : ( Int, Int, Int ) }
main = { a = 1, b = ( 1, 2, 3 ) }
