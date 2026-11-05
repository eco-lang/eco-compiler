module TypeMismatchBoolRightOfPlusTest exposing (..)

{-| TYPE MISMATCH: Bool right of +.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool right of +
-- CHECK: -- TYPE MISMATCH -

x = 1 + True
