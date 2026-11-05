module TypeMismatchStringRightOfGreaterThanTest exposing (..)

{-| TYPE MISMATCH: string right of >.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, string right of >
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Try using String.fromInt to convert it to a string?

x = 1 > "a"
