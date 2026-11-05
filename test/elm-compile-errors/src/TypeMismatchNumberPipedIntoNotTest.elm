module TypeMismatchNumberPipedIntoNotTest exposing (..)

{-| TYPE MISMATCH: number piped into not.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number piped into not
-- CHECK: -- TYPE MISMATCH -

x = 1 |> not
