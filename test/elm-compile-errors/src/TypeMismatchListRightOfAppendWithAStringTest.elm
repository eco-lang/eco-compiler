module TypeMismatchListRightOfAppendWithAStringTest exposing (..)

{-| TYPE MISMATCH: list right of ++ with a string.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list right of ++ with a string
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The (++) operator needs the same type of value on both sides

x = "a" ++ [ 1 ]
