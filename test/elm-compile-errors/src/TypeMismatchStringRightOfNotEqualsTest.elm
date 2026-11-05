module TypeMismatchStringRightOfNotEqualsTest exposing (..)

{-| TYPE MISMATCH: string right of /=.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string right of /=
-- CHECK: -- TYPE MISMATCH -

x = 1 /= "a"
