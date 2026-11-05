module TypeMismatchAccessorUnderIntTest exposing (..)

{-| TYPE MISMATCH: accessor under Int.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, accessor under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = .name
