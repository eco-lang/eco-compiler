module TypeMismatchRecordPatternTest exposing (..)

{-| TYPE MISMATCH: record pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record pattern
-- CHECK: -- TYPE MISMATCH -

f : Int -> Int
f { a } = a
