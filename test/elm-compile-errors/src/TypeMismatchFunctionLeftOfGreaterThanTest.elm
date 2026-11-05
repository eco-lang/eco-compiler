module TypeMismatchFunctionLeftOfGreaterThanTest exposing (..)

{-| TYPE MISMATCH: function left of >.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, function left of >
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: I only know how to compare ints, floats, chars, string

x = not > not
