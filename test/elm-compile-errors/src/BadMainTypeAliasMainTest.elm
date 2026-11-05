module BadMainTypeAliasMainTest exposing (..)

{-| BAD MAIN TYPE: alias main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, alias main
-- CHECK: -- BAD MAIN TYPE -
-- CHECK: The type of `main` value I am seeing is:
-- CHECK: M
-- CHECK: I only know how to handle

type alias M = { a : Int }

main : M
main = { a = 1 }
