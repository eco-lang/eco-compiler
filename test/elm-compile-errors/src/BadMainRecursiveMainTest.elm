module BadMainRecursiveMainTest exposing (..)

{-| BAD MAIN: recursive main.

From `SourceIR.MainFailsCases` (`cycleCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN, recursive main
-- CHECK: -- BAD MAIN -
-- CHECK: it is involved in
-- CHECK-NEXT: this cycle of definitions

main : Int -> Int
main x = f x

f : Int -> Int
f x = main x
