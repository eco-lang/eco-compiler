module BadMainTypeAliasMainTest exposing (..)

{-| BAD MAIN TYPE: alias main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, alias main
-- CHECK: -- BAD MAIN TYPE -

type alias M = { a : Int }

main : M
main = { a = 1 }
