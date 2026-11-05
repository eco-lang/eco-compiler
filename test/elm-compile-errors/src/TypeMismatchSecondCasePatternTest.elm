module TypeMismatchSecondCasePatternTest exposing (..)

{-| TYPE MISMATCH: second case pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, second case pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case "s" of
        "a" ->
            1

        'c' ->
            2

        _ ->
            3
