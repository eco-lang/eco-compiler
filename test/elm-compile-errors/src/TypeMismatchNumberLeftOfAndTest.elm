module TypeMismatchNumberLeftOfAndTest exposing (..)

{-| TYPE MISMATCH: number left of &&.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number left of &&
-- CHECK: -- TYPE MISMATCH -

x = 1 && True
