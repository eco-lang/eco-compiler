module Builder.Reporting.ExitDocsDataTest exposing (suite)

{-| Regression test for `Builder.Reporting.Exit.toDocsProblemReport`: the
`DP_Data` report once said "The response body contains " ++ body ++ " bytes",
inserting the body text where its length belongs. It now uses
`String.fromInt (String.length body)`, as `RP_Data` does.
-}

import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Expect
import Test exposing (Test)


render : Exit.DocsProblem -> String
render problem =
    Exit.diffToReport (Exit.DiffDocsProblem V.one problem)
        |> Help.reportToDoc
        |> D.toString
        |> String.words
        |> String.join " "


suite : Test
suite =
    Test.describe "Builder.Reporting.Exit DP_Data report"
        [ Test.test "states the body length, not the body" <|
            \_ ->
                render (Exit.DP_Data "https://example.com/docs.json" "QQQQQ")
                    |> String.contains "contains 5 bytes"
                    |> Expect.equal True
        ]
