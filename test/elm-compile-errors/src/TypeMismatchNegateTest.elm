module TypeMismatchNegateTest exposing (..)

{-| TYPE MISMATCH: negate.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, negate
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Try using String.toInt to convert it to an integer?

s = "s"

x = -s
