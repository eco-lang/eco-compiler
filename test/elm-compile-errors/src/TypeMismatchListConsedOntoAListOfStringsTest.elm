module TypeMismatchListConsedOntoAListOfStringsTest exposing (..)

{-| TYPE MISMATCH: list consed onto a list of strings.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list consed onto a list of strings
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] :: [ "a" ]
