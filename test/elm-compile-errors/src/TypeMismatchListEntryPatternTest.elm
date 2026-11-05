module TypeMismatchListEntryPatternTest exposing (..)

{-| TYPE MISMATCH: list entry pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, list entry pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case [ 1 ] of
        [ 1, "a" ] ->
            1

        _ ->
            2
