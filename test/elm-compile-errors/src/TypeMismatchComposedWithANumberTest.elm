module TypeMismatchComposedWithANumberTest exposing (..)

{-| TYPE MISMATCH: composed with a number.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, composed with a number
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: With operators like (>>) I always check the left side

x = not >> 1
