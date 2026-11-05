module TypeMismatchExtensibleRecordMissingAFieldTest exposing (..)

{-| TYPE MISMATCH: extensible record missing a field.

From `SourceIR.TypeCheckFailsCases` (`recordFieldCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, extensible record missing a field
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Seems like a record field typo. Maybe name should be a

g : { r | name : Int } -> Int
g r = r.name

x = g { age = 1 }
