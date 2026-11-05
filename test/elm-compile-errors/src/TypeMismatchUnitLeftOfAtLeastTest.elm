module TypeMismatchUnitLeftOfAtLeastTest exposing (..)

{-| TYPE MISMATCH: unit left of >=.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unit left of >=
-- CHECK: -- TYPE MISMATCH -

x = () >= ()
