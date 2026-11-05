module TypeMismatchUpdateOfAnEmptyRecordTest exposing (..)

{-| TYPE MISMATCH: update of an empty record.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update of an empty record
-- CHECK: -- TYPE MISMATCH -
-- CHECK: record does not have a `x` field:
-- CHECK: is a record with NO fields!

r = {}

y = { r | x = 1 }
