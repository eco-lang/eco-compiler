module TypeMismatchUnitsOnBothSidesTest exposing (..)

{-| TYPE MISMATCH: units on both sides.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, units on both sides
-- CHECK: -- TYPE MISMATCH -

x = [ ( (), 1 ), ( (), "a" ) ]
