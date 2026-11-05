module UnexpectedPatternFloatWithExponentTest exposing (main)

{-| UNEXPECTED PATTERN: float with exponent.

From `Compiler.Reporting.SyntaxRegionReportTest` (`floatPatternWithExponent`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: UNEXPECTED PATTERN
-- CHECK: -- UNEXPECTED PATTERN -


f x =
    case x of
        1e3 ->
            1

        _ ->
            2


main =
    f 2
