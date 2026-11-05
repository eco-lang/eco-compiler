module TypeMismatchStringRightOfPowerTest exposing (..)

{-| TYPE MISMATCH: string right of ^.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string right of ^
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Try using String.toInt to convert it to an integer?

x = 2 ^ "a"
