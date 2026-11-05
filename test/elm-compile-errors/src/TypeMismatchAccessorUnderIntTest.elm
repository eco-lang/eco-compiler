module TypeMismatchAccessorUnderIntTest exposing (..)

{-| TYPE MISMATCH: accessor under Int.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, accessor under Int
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This .name field access function has type:

x : Int
x = .name
