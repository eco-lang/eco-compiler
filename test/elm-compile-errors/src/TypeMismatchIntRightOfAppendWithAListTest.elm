module TypeMismatchIntRightOfAppendWithAListTest exposing (..)

{-| TYPE MISMATCH: Int right of ++ with a list.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Int right of ++ with a list
-- CHECK: -- TYPE MISMATCH -
-- CHECK: I thought I was appending List values here, not Int values l

n : Int
n = 1

x = [ 1 ] ++ n
