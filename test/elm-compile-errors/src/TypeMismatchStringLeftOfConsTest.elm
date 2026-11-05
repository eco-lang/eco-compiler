module TypeMismatchStringLeftOfConsTest exposing (..)

{-| TYPE MISMATCH: string left of ::.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string left of ::
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Try using String.toInt to convert it to an integer?

x = "a" :: [ 1 ]
