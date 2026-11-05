module TypeMismatchCharUnderIntTest exposing (..)

{-| TYPE MISMATCH: char under Int.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, char under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = 'c'
