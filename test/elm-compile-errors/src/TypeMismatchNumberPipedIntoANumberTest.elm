module TypeMismatchNumberPipedIntoANumberTest exposing (..)

{-| TYPE MISMATCH: number piped into a number.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number piped into a number
-- CHECK: -- TYPE MISMATCH -

x = 1 |> 2
