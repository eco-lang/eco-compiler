module TestLogic.Reporting.ExpectedRejectionTest exposing (suite)

{-| Runs every program of the negative catalogue through the compiler and
checks that it is rejected as its case records, so that a compiler which
accepts an invalid program, rejects it at the wrong stage, or tells the user
something other than the recorded error fails a test.

The catalogue is `SourceIR.Suite.RejectedSuites`: one case module per stage
that can reject a program, each case recording the title of the first report
and, for errors that share a title, a fragment of the report's text.
`TestLogic.Reporting.ExpectedRejection.expectRejected` owns the check: the
program is compiled as `eco make` compiles it, pattern-match checking
included, and must be rejected by the stage of its case's module, with that
first title and fragment.

Among what is not checked: reports after the first, apart from the fragment,
which may be in any of them; the regions a report points at, since a test
program has no source text to quote; and errors that only a project or source
text can produce (syntax, imports, `--optimize`, documentation).

-}

import SourceIR.Suite.RejectedSuites as RejectedSuites
import Test exposing (Test)
import TestLogic.Reporting.ExpectedRejection exposing (expectRejected)


{-| The negative catalogue, each program checked by `expectRejected`.
-}
suite : Test
suite =
    RejectedSuites.expectSuite expectRejected "is rejected as recorded"
