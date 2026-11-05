module TypeMismatchRecordFieldsMissingTest exposing (..)

{-| TYPE MISMATCH: record fields missing.

From `SourceIR.TypeCheckFailsCases` (`recordFieldCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record fields missing
-- CHECK: -- TYPE MISMATCH -

f : { name : Int, age : Int, size : Int } -> Int
f r = r.name

x = f { name = 1 }
