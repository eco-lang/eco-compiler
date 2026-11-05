module TypeMismatchNumberLeftOfPipeLeftTest exposing (..)

{-| TYPE MISMATCH: number left of <|.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number left of <|
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x = 1 <| 2
