module TypeMismatchTwoExtensibleRecordsTest exposing (..)

{-| TYPE MISMATCH: two extensible records.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two extensible records
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Your type annotation uses `r` and `s` as separate type

g : { r | name : Int } -> { s | name : Int }
g r = r
