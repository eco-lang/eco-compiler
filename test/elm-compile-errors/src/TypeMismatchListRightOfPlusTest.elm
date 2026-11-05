module TypeMismatchListRightOfPlusTest exposing (..)

{-| TYPE MISMATCH: list right of +.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list right of +
-- CHECK: -- TYPE MISMATCH -

x = 1 + [ 2 ]
