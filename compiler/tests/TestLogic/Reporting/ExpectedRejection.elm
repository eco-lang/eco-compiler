module TestLogic.Reporting.ExpectedRejection exposing (expectRejected)

{-| The check that a program of the negative catalogue is rejected as its case
records: by the right stage, with the right first report.

`expectRejected stage program rejection` runs `program` through
`TestLogic.TestPipeline.runToReports`, which compiles it as `eco make` does,
stage by stage, and renders the reports of the stage that rejects it with the
production reporters. It passes when:

  - the program is rejected, not compiled;
  - the stage that rejects it is `stage`, so every earlier stage accepted it;
  - the first report's title is `rejection.title`;
  - `rejection.fragment`, when given, appears in the rendered reports. The
    comparison collapses every run of white space to one space on both sides,
    so a fragment that the renderer wraps onto two lines still matches.

A report that crashes the renderer crashes the test, so a passing case also
shows that its reports render. A failure shows the rendered reports.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.Rejection exposing (Rejection)
import TestLogic.TestPipeline as Pipeline exposing (Outcome(..), Stage)


{-| Returns an expectation that `program` is rejected by `stage` with
`rejection`, as the module docstring describes.
-}
expectRejected : Stage -> Src.Module -> Rejection -> Expectation
expectRejected stage program rejection =
    case Pipeline.runToReports program of
        Accepted ->
            Expect.fail
                ("expected "
                    ++ Pipeline.stageName stage
                    ++ " to reject the program with "
                    ++ rejection.title
                    ++ ", but it compiled"
                )

        Rejected reports ->
            if reports.stage /= stage then
                Expect.fail
                    ("expected "
                        ++ Pipeline.stageName stage
                        ++ " to reject the program, but "
                        ++ Pipeline.stageName reports.stage
                        ++ " did:\n"
                        ++ reports.text
                    )

            else if List.head reports.titles /= Just rejection.title then
                Expect.fail
                    ("expected the first report to be "
                        ++ rejection.title
                        ++ ", but the reports are:\n"
                        ++ reports.text
                    )

            else
                case rejection.fragment of
                    Just fragment ->
                        if String.contains (collapseSpaces fragment) (collapseSpaces reports.text) then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected the reports to contain \""
                                    ++ fragment
                                    ++ "\", but they are:\n"
                                    ++ reports.text
                                )

                    Nothing ->
                        Expect.pass


{-| `text` with every run of white space replaced by one space.
-}
collapseSpaces : String -> String
collapseSpaces text =
    String.words text |> String.join " "
