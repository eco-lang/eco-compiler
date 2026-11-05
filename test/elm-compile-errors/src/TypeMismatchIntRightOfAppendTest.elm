module TypeMismatchIntRightOfAppendTest exposing (..)

{-| TYPE MISMATCH: Int right of ++.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of ++
-- CHECK: -- TYPE MISMATCH -
-- CHECK: I thought I was appending String values here, not Int values

n : Int
n = 1

x = "a" ++ n
