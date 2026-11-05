module TypeMismatchAliasedRecordFieldOfTheWrongTypeTest exposing (..)

{-| TYPE MISMATCH: aliased record field of the wrong type.

From `SourceIR.TypeCheckFailsCases` (`recordFieldCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, aliased record field of the wrong type
-- CHECK: -- TYPE MISMATCH -

type alias P = { a : Int }

x : P
x = { a = "s" }
