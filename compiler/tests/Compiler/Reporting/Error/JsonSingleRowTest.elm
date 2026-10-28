module Compiler.Reporting.Error.JsonSingleRowTest exposing (suite)

{-| Reproduces a bug in `Compiler.Reporting.Error.Json.expectationToReport`: it
binds `region = if sr == er then crash "region" else A.Region start start`, so
any `Expecting` problem whose value lies on one row (the usual scalar case,
e.g. a number in elm.json where a string is wanted) crashes the compiler
instead of producing a report.

EXPECTED TO FAIL until the bug is fixed.

-}

import Builder.Reporting.Exit.Help as Help
import Compiler.Json.Decode as Decode
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error.Json as Json
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Error.Json single-row expectation"
        [ Test.test "a wrong-typed scalar on one row gives a report" <|
            \_ ->
                let
                    src =
                        "{\"name\": 1}"

                    problem =
                        Decode.Field "name"
                            (Decode.Expecting (A.Region (A.Position 1 10) (A.Position 1 11)) Decode.TString)

                    report =
                        Json.toReport "elm.json"
                            (Json.FailureToReport (\_ _ _ _ _ -> Help.report "UNUSED" Nothing "" []))
                            (Decode.DecodeProblem src problem)
                            (Json.ExplicitReason "I ran into a problem with your elm.json file.")
                in
                Help.reportToDoc report
                    |> D.toString
                    |> String.contains "elm.json"
                    |> Expect.equal True
        ]
