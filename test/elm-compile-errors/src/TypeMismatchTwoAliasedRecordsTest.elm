module TypeMismatchTwoAliasedRecordsTest exposing (..)

{-| TYPE MISMATCH: two aliased records.

From `SourceIR.TypeCheckFailsCases` (`recordFieldCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, two aliased records
-- CHECK: -- TYPE MISMATCH -

type alias P = { a : Int }

type alias Q = { b : Int }

p : P
p = { a = 1 }

x : Q
x = p
