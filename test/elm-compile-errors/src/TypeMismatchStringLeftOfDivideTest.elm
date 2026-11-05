module TypeMismatchStringLeftOfDivideTest exposing (..)

{-| TYPE MISMATCH: String left of /.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, String left of /
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert a String into a Float? Use the String.

x = "a" / 2
