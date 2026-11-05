module TypeMismatchIfUnderIntTest exposing (..)

{-| TYPE MISMATCH: if under Int.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, if under Int
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Want to convert a String into an Int? Use the String.t

x : Int
x = if True then "a" else "b"
