module TypeMismatchConsedOntoAMaybeTest exposing (..)

{-| TYPE MISMATCH: consed onto a Maybe.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, consed onto a Maybe
-- CHECK: -- TYPE MISMATCH -

x = 1 :: Just 1
