module TypeMismatchConstructorPatternTest exposing (..)

{-| TYPE MISMATCH: constructor pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, constructor pattern
-- CHECK: -- TYPE MISMATCH -

x =
    case 1 of
        Just a ->
            1

        _ ->
            2
