module TypeMismatchStringLeftOfIntDivideTest exposing (..)

{-| TYPE MISMATCH: String left of //.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, String left of //
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert a String into an Int? Use the String.t

x = "a" // 2
