module TypeMismatchFloatRightOfPlusWithIntTest exposing (..)

{-| TYPE MISMATCH: Float right of + with Int.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Float right of + with Int
-- CHECK: -- TYPE MISMATCH -

f : Float
f = 1.5

n : Int
n = 1

x = n + f
