module TypeMismatchNegateTest exposing (..)

{-| TYPE MISMATCH: negate.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, negate
-- CHECK: -- TYPE MISMATCH -

s = "s"

x = -s
