module TypeMismatchRecordWhereEmptyClosedRecordTest exposing (..)

{-| TYPE MISMATCH: record where empty closed record.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record where empty closed record
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The body is a record of type:

x : {}
x = { a = 1 }
