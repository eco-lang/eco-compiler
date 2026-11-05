module BadMainTypeUnitMainTest exposing (..)

{-| BAD MAIN TYPE: unit main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, unit main
-- CHECK: -- BAD MAIN TYPE -

main : ()
main = ()
