module BadMainTypeThreeArgumentTypeMainTest exposing (..)

{-| BAD MAIN TYPE: three-argument type main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, three-argument type main
-- CHECK: -- BAD MAIN TYPE -
-- CHECK: The type of `main` value I am seeing is:
-- CHECK: T Int Int Int
-- CHECK: I only know how to handle

type T a b c = T a b c

main : T Int Int Int
main = T 1 2 3
