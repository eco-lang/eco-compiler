module TypeMismatchUnitPatternTest exposing (..)

{-| TYPE MISMATCH: unit pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, unit pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The argument is a pattern that matches unit values:

f : Int -> Int
f () = 1
