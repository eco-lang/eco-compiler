module BadMainTypeTypeVariableMainTest exposing (..)

{-| BAD MAIN TYPE: type variable main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, type variable main
-- CHECK: -- BAD MAIN TYPE -

main = []
