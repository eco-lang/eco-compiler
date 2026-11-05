module TypeMismatchClosedRecordWhereExtensibleTest exposing (..)

{-| TYPE MISMATCH: closed record where extensible.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, closed record where extensible
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Looks like the age field is missing.

g : { r | name : Int } -> { r | name : Int }
g r = r

x : { name : Int, age : Int }
x = g { name = 1 }
