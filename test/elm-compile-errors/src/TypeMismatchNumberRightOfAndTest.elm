module TypeMismatchNumberRightOfAndTest exposing (..)

{-| TYPE MISMATCH: number right of &&.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number right of &&
-- CHECK: -- TYPE MISMATCH -

x = True && 1
