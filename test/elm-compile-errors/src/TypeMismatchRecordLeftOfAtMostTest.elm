module TypeMismatchRecordLeftOfAtMostTest exposing (..)

{-| TYPE MISMATCH: record left of <=.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record left of <=
-- CHECK: -- TYPE MISMATCH -

x = { a = 1 } <= { a = 1 }
