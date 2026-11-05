module TypeMismatchNumberIntoNotWithPipeLeftTest exposing (..)

{-| TYPE MISMATCH: number into not with <|.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number into not with <|
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x = not <| 1
