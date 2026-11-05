module TypeMismatchIntWhereFloatTest exposing (..)

{-| TYPE MISMATCH: Int where Float.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int where Float
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l

n : Int
n = 1

x : Float
x = n
