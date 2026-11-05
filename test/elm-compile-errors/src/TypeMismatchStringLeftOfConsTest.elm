module TypeMismatchStringLeftOfConsTest exposing (..)

{-| TYPE MISMATCH: string left of ::.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string left of ::
-- CHECK: -- TYPE MISMATCH -

x = "a" :: [ 1 ]
