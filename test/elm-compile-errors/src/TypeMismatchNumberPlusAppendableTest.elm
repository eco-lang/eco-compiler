module TypeMismatchNumberPlusAppendableTest exposing (..)

{-| TYPE MISMATCH: number plus appendable.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number plus appendable
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The (++) operator can append List and String values, but not

g a b = (a + 1) ++ b
