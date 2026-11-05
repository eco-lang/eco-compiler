module TypeMismatchAliasWhereARecordTest exposing (..)

{-| TYPE MISMATCH: alias where a record.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, alias where a record
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert an Int into a String? Use the String.f

type alias P = { a : Int }

p : P
p = { a = 1 }

x : { a : String }
x = p
