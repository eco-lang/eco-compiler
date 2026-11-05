module TypeMismatchAccessOnAnEmptyRecordTest exposing (..)

{-| TYPE MISMATCH: access on an empty record.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, access on an empty record
-- CHECK: -- TYPE MISMATCH -

r = {}

x = r.foo
