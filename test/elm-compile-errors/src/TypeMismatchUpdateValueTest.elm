module TypeMismatchUpdateValueTest exposing (..)

{-| TYPE MISMATCH: update value.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update value
-- CHECK: -- TYPE MISMATCH -

f : { x : Int } -> { x : Int }
f r = { r | x = "s" }
