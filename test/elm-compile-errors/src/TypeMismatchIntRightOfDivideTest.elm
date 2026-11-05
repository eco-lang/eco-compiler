module TypeMismatchIntRightOfDivideTest exposing (..)

{-| TYPE MISMATCH: Int right of /.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of /
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Note: Read <https://elm-lang.org/0.19.1/implicit-casts> to l

n : Int
n = 1

x = 2 / n
