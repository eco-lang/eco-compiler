module TypeMismatchLambdaArgumentPatternTest exposing (..)

{-| TYPE MISMATCH: lambda argument pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, lambda argument pattern
-- CHECK: -- TYPE MISMATCH -

x = (\( a, b ) -> a) 1
