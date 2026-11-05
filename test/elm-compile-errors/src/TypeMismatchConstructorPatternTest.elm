module TypeMismatchConstructorPatternTest exposing (..)

{-| TYPE MISMATCH: constructor pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, constructor pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The first pattern is trying to match `Just` values of type:
-- CHECK: These can never match! Is the pattern the problem? Or is it the expression?

x =
    case 1 of
        Just a ->
            1

        _ ->
            2
