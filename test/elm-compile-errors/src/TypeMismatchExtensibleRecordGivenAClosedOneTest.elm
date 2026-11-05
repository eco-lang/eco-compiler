module TypeMismatchExtensibleRecordGivenAClosedOneTest exposing (..)

{-| TYPE MISMATCH: extensible record given a closed one.

From `SourceIR.TypeCheckFailsCases` (`recordFieldCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, extensible record given a closed one
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> { r | name : Int }
g r = { name = 1 }
