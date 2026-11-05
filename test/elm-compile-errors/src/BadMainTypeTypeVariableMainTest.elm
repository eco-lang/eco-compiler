module BadMainTypeTypeVariableMainTest exposing (..)

{-| BAD MAIN TYPE: type variable main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, type variable main
-- CHECK: -- BAD MAIN TYPE -
-- CHECK: The type of `main` value I am seeing is:
-- CHECK: List a
-- CHECK: I only know how to handle

main = []
