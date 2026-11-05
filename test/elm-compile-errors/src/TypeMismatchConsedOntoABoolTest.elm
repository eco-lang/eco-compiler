module TypeMismatchConsedOntoABoolTest exposing (..)

{-| TYPE MISMATCH: consed onto a Bool.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, consed onto a Bool
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This `True` value is a:

x = 1 :: True
