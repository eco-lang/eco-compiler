module TypeMismatchListRightOfTimesTest exposing (..)

{-| TYPE MISMATCH: list right of *.

From `SourceIR.TypeCheckFailsCases` (`operatorCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list right of *
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Maybe you want List.repeat to build a list of repeated

x = 2 * [ 1 ]
