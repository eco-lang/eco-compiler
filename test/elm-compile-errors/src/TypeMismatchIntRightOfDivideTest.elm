module TypeMismatchIntRightOfDivideTest exposing (..)

{-| TYPE MISMATCH: Int right of /.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of /
-- CHECK: -- TYPE MISMATCH -

n : Int
n = 1

x = 2 / n
