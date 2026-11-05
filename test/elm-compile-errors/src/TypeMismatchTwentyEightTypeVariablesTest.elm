module TypeMismatchTwentyEightTypeVariablesTest exposing (main)

{-| TYPE MISMATCH: twenty eight type variables.

From `Compiler.Reporting.TypeVariableNameReportTest` (`twentyEightParameters`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH
-- CHECK: -- TYPE MISMATCH -
-- CHECK: Addition does not work with this value:
-- CHECK: This `f` value is a:
-- CHECK: a


f p0 p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12 p13 p14 p15 p16 p17 p18 p19 p20 p21 p22 p23 p24 p25 p26 p27 =
    0


main =
    f + 1
