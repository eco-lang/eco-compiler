module TestLogic.Nitpick.PatternMatchesPass exposing (expectPatternMatchesPass)

{-| The check that a program gets through pattern-match checking, the phase of
`Compiler.Compile` that rejects a `case` missing a pattern, a redundant
branch, and a destructuring or argument pattern that can fail
(`Compiler.Nitpick.PatternMatches`).

The `runTo*` runners of `TestLogic.TestPipeline` do not run that phase, so a
program can pass every other check and still be rejected by `eco make`.
`expectPatternMatchesPass` runs a program through
`TestLogic.TestPipeline.runToReportsThrough PatternMatch`: canonicalization,
type checking and pattern-match checking, as a build runs them. It passes when
all three accept the program, and otherwise fails with the stage that rejected
it and the reports it rendered.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline exposing (Outcome(..), Stage(..))


{-| Returns an expectation that `program` gets through pattern-match checking,
as the module docstring describes.
-}
expectPatternMatchesPass : Src.Module -> Expectation
expectPatternMatchesPass program =
    case Pipeline.runToReportsThrough PatternMatch program of
        Accepted ->
            Expect.pass

        Rejected reports ->
            Expect.fail
                (Pipeline.stageName reports.stage
                    ++ " rejected the program, which eco make would refuse to compile:\n"
                    ++ reports.text
                )
