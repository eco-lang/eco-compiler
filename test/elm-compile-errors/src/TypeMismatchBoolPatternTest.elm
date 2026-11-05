module TypeMismatchBoolPatternTest exposing (..)

{-| TYPE MISMATCH: bool pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, bool pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case 1 of
        True ->
            1

        _ ->
            2
