module UnexpectedPatternFloatWithExponentTest exposing (main)

{-| UNEXPECTED PATTERN: float with exponent.

From `Compiler.Reporting.SyntaxRegionReportTest` (`floatPatternWithExponent`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: UNEXPECTED PATTERN
-- CHECK: -- UNEXPECTED PATTERN -
-- CHECK: I cannot pattern match with floating point numbers:
-- CHECK: Equality on floats can be unreliable, so you usually want to check that they are
-- CHECK: nearby with some sort of (abs (actual - expected) < 0.001) check.


f x =
    case x of
        1e3 ->
            1

        _ ->
            2


main =
    f 2
