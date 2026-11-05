module TypeMismatchNumberIntoNotWithPipeLeftTest exposing (..)

{-| TYPE MISMATCH: number into not with <|.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number into not with <|
-- CHECK: -- TYPE MISMATCH -

x = not <| 1
