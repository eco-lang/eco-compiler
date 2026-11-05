module TypeMismatchFloatRightOfIntDivideTest exposing (..)

{-| TYPE MISMATCH: Float right of //.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Float right of //
-- CHECK: -- TYPE MISMATCH -

x = 2 // 1.5
