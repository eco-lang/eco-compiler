module TypeMismatchFloatComparedForEqualityTest exposing (..)

{-| TYPE MISMATCH: Float compared for equality.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Float compared for equality
-- CHECK: -- TYPE MISMATCH -

x = 1.5 == "a"
