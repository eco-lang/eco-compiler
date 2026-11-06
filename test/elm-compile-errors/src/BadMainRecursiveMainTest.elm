module BadMainRecursiveMainTest exposing (..)

{-| An annotated `main` that is mutually recursive with another function is rejected with a BAD MAIN error.

`main : Int -> Int` calls `f`, and `f` calls `main`.

-}

-- COMPILE-ERROR: BAD MAIN, recursive main
-- CHECK: -- BAD MAIN -

main : Int -> Int
main x = f x

f : Int -> Int
f x = main x
