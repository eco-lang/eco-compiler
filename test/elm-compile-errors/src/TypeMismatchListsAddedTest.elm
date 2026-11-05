module TypeMismatchListsAddedTest exposing (..)

{-| TYPE MISMATCH: lists added.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, lists added
-- CHECK: -- TYPE MISMATCH -

x = [ 1 ] + [ 2 ]
