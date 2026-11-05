module TypeMismatchFieldAccessUnderIntTest exposing (..)

{-| TYPE MISMATCH: field access under Int.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, field access under Int
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert a String into an Int? Use the String.t

r = { name = "a" }

x : Int
x = r.name
