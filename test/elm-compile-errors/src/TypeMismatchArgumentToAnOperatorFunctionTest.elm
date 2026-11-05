module TypeMismatchArgumentToAnOperatorFunctionTest exposing (..)

{-| TYPE MISMATCH: argument to an operator function.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, argument to an operator function
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Try using String.toInt to convert it to an integer?

x = (+) "a" 1
