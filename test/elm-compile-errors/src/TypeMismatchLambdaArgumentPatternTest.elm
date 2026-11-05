module TypeMismatchLambdaArgumentPatternTest exposing (..)

{-| TYPE MISMATCH: lambda argument pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, lambda argument pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x = (\( a, b ) -> a) 1
