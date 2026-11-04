module TestLogic.Nitpick.PatternMatchesPassTest exposing (suite)

{-| Runs pattern-match checking on every program of the standard catalogue,
so that a catalogue program which `eco make` would reject for a missing or
redundant pattern fails a test. The other checks over the catalogue compile
through `TestLogic.TestPipeline`'s `runTo*` runners, which skip this phase, so
without this suite such a program would pass them all.

`TestLogic.Nitpick.PatternMatchesPass.expectPatternMatchesPass` owns the
check: canonicalization, type checking and pattern-match checking, run as a
build runs them, must all accept the program. A program rejected earlier fails
too, since every catalogue program must compile.

The check found 21 catalogue programs that `eco make` rejected with an
`UNSAFE PATTERN`: they matched a list or a literal in a function or lambda
argument or a `let` destructuring (in `PatternArgCases`, `AsPatternCases`,
`LetDestructCases`, `EdgeCaseCases`, `MultiDefCases` and `HigherOrderCases`).
Each now matches the pattern in a `case`, and its earlier form is a rejected
case of `SourceIR.PatternFailsCases`.

Among what is not tested: the programs of the negative catalogue
(`SourceIR.Suite.RejectedSuites`), whose `SourceIR.PatternFailsCases` must
fail this phase and are checked by
`TestLogic.Reporting.ExpectedRejectionTest`.

-}

import SourceIR.MainFailsCases as MainFailsCases
import SourceIR.MonoFailsCases as MonoFailsCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Nitpick.PatternMatchesPass exposing (expectPatternMatchesPass)


{-| Every program of the standard catalogue, and those of
`SourceIR.MainFailsCases` and `SourceIR.MonoFailsCases`, which later stages
reject, checked by `expectPatternMatchesPass`.
-}
suite : Test
suite =
    Test.describe "Pattern-match checking passes"
        [ StandardTestSuites.expectSuite expectPatternMatchesPass "passes pattern-match checking"
        , MainFailsCases.expectSuite expectPatternMatchesPass "passes pattern-match checking"
        , MonoFailsCases.expectBeforeMonoSuite expectPatternMatchesPass "passes pattern-match checking"
        ]
