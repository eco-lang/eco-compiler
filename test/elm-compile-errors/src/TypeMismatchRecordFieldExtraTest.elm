module TypeMismatchRecordFieldExtraTest exposing (..)

{-| TYPE MISMATCH: record field extra.

From `SourceIR.TypeCheckFailsCases` (`recordFieldCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, record field extra
-- CHECK: -- TYPE MISMATCH -

f : { name : Int } -> Int
f r = r.name

x = f { name = 1, age = 2 }
