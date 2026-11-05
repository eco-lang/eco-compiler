module TypeMismatchNumberPipedIntoNotTest exposing (..)

{-| TYPE MISMATCH: number piped into not.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number piped into not
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x = 1 |> not
