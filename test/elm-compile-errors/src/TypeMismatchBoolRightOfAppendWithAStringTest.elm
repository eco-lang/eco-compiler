module TypeMismatchBoolRightOfAppendWithAStringTest exposing (..)

{-| TYPE MISMATCH: Bool right of ++ with a string.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, Bool right of ++ with a string
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Elm does not have “truthiness” such that ints and stri

x = "a" ++ True
