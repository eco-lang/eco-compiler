module TypeMismatchFloatUnderIntTest exposing (..)

{-| TYPE MISMATCH: float under Int.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, float under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = 1.5
