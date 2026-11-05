module TypeMismatchListMultipliedTest exposing (..)

{-| TYPE MISMATCH: list multiplied.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list multiplied
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] * 2
