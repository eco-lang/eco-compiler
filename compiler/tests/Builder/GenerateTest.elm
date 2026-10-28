module Builder.GenerateTest exposing (suite)

{-| Regression test for Builder.Generate.validateStageArityLimit: a program
whose closure exceeds the stage arity limit (a condition of the program, not a
compiler fault) is thrown as `GenerateMonomorphizationError` with a message
starting "STAGE ARITY LIMIT". `toGenerateReport` once spared only messages
starting "specialization ", so the report told the user "This is likely a
compiler bug"; it now gives that message a STAGE ARITY LIMIT report.

The message is built exactly as `Compiler.Pipeline.Steps.checkStageArity`
builds it.

-}

import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Compiler.Reporting.Doc as D
import Expect
import Test exposing (Test, test)


suite : Test
suite =
    test "STAGE ARITY LIMIT is not reported as a likely compiler bug" <|
        \_ ->
            Exit.makeToReport (Exit.MakeBadGenerate (Exit.GenerateMonomorphizationError ("STAGE ARITY LIMIT\n" ++ "Main.f: closure stage needs 2100 slots")))
                |> Help.reportToDoc
                |> D.toString
                |> String.contains "compiler bug"
                |> Expect.equal False
                |> Expect.onFail "a program condition (stage arity limit) is reported as a likely compiler bug"
