module TypeMismatchTupleComponentPatternTest exposing (..)

{-| TYPE MISMATCH: tuple component pattern.

From `SourceIR.TypeCheckFailsCases` (`patternMismatchCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, tuple component pattern
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Hint: Try using String.toInt to convert it to an integer?

x =
    case ( 1, 2 ) of
        ( "a", b ) ->
            1

        _ ->
            2
