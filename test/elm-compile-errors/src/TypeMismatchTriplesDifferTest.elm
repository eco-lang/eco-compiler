module TypeMismatchTriplesDifferTest exposing (..)

{-| TYPE MISMATCH: triples differ.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, triples differ
-- CHECK: -- TYPE MISMATCH -

x : ( Int, Int, Int )
x = ( 1, 2, "a" )
