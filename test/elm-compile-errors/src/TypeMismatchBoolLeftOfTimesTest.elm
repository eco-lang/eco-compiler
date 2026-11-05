module TypeMismatchBoolLeftOfTimesTest exposing (..)

{-| TYPE MISMATCH: Bool left of *.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool left of *
-- CHECK: -- TYPE MISMATCH -

x = True * 2
