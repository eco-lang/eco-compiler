module TypeMismatchStringLeftOfIntDivideTest exposing (..)

{-| TYPE MISMATCH: String left of //.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, String left of //
-- CHECK: -- TYPE MISMATCH -

x = "a" // 2
