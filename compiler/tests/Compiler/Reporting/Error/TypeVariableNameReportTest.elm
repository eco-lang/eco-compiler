module Compiler.Reporting.Error.TypeVariableNameReportTest exposing (suite)

{-| Checks the names a type error report gives to type variables beyond the
26th, by compiling an erroneous program through the front end
(`TestLogic.Reporting.CompileReport`) and comparing the report with what Elm
0.19.1 prints for the same program.

Elm names the variables after `z` as `a1`, `b1`, ... (the number is the
quotient of the variable's index by 26). `Compiler.Data.Name.fromTypeVariableScheme`
uses the index less its remainder instead, so they print as `a26`, `b26`, ...
The expected text is copied from the report of `elm make` 0.19.1; today it fails.

-}

import Test exposing (Test)
import TestLogic.Reporting.CompileReport as CompileReport


twentyEightParameters : String
twentyEightParameters =
    """module Main exposing (main)


f p0 p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12 p13 p14 p15 p16 p17 p18 p19 p20 p21 p22 p23 p24 p25 p26 p27 =
    0


main =
    f + 1
"""


suite : Test
suite =
    Test.describe "Type variable names in error reports"
        [ Test.test "the 27th and 28th type variables are a1 and b1" <|
            \_ ->
                twentyEightParameters
                    |> CompileReport.expectReportContains "    -> z\n    -> a1\n    -> b1\n    -> number"
        ]
