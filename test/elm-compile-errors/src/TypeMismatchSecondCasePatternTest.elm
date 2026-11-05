module TypeMismatchSecondCasePatternTest exposing (..)

{-| TYPE MISMATCH: second case pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, second case pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Note: A `case` expression can only handle one type of value,

x =
    case "s" of
        "a" ->
            1

        'c' ->
            2

        _ ->
            3
