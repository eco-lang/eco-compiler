module TypeMismatchFloatLeftOfIntDivideTest exposing (..)

{-| TYPE MISMATCH: Float left of //.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Float left of //
-- CHECK: -- TYPE MISMATCH -

x = 1.5 // 2
