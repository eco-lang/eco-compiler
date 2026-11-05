module TypeMismatchUpdateValueTest exposing (..)

{-| TYPE MISMATCH: update value.

From `SourceIR.TypeCheckFailsCases` (`contextCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, update value
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Note: The record update syntax does not allow you to change

f : { x : Int } -> { x : Int }
f r = { r | x = "s" }
