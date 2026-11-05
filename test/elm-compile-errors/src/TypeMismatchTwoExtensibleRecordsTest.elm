module TypeMismatchTwoExtensibleRecordsTest exposing (..)

{-| TYPE MISMATCH: two extensible records.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two extensible records
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> { s | name : Int }
g r = r
