module TypeMismatchUpdateOfANearFieldTest exposing (..)

{-| TYPE MISMATCH: update of a near field.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update of a near field
-- CHECK: -- TYPE MISMATCH -

r = { count = 1 }

y = { r | cuont = 2 }
