module TypeMismatchIntRightOfTimesWithFloatTest exposing (..)

{-| TYPE MISMATCH: Int right of * with Float.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of * with Float
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l

f : Float
f = 1.5

n : Int
n = 1

x = f * n
