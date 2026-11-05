module TypeMismatchIntWhereFloatTest exposing (..)

{-| TYPE MISMATCH: Int where Float.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int where Float
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x : Float
x = n
