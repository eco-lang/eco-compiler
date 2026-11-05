module TypeMismatchTailPatternTest exposing (..)

{-| TYPE MISMATCH: tail pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, tail pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: The pattern after (::) is trying to match strings:

x =
    case [ 1 ] of
        a :: "s" ->
            1

        _ ->
            2
