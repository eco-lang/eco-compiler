module TypeMismatchListPatternTest exposing (..)

{-| TYPE MISMATCH: list pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Only Int and Float values work as numbers.

x =
    case 1 of
        [] ->
            1

        _ ->
            2
