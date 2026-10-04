module TestLogic.Generate.CodeGen.PapExtendSaturatedResultTypeTest exposing (suite)

{-| Runs the saturated `eco.papExtend` result-type check on every program in
the standard catalogue, so that a saturated `eco.papExtend` the checker can
trace to its function, given a result type other than the one that function
returns, fails a test.

A _partial application_ (PAP) is a function value together with the arguments
it has been given so far, and an `eco.papExtend` op gives a PAP more arguments.
An extend is _saturated_ when it supplies at least as many arguments as the PAP
still needs, so that the function the PAP was made from runs. Which extends
can be traced to that function, and which are skipped, is set out in
`TestLogic.Generate.CodeGen.PapExtendSaturatedResultType`.

The programs are the Elm source programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers from its case modules.

`suite` establishes, for each of those programs, that it compiles to MLIR and
that every saturated `eco.papExtend` carrying a `remaining_arity` attribute,
whose PAP the checker can trace to a top-level `func.func` with a result type,
has that function's first result type as its own result type.

Among what is not tested: extends without `remaining_arity`, extends of a PAP
made in another top-level op or by `eco.papCreateGroup`, and the result types
of extends that leave arguments remaining.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendSaturatedResultType exposing (expectPapExtendSaturatedResultType)


{-| The saturated `eco.papExtend` result-type check applied to every program in
the standard catalogue, as one group of tests.
-}
suite : Test
suite =
    Test.describe "CGEN_056: Saturated PapExtend Result Type"
        [ StandardTestSuites.expectSuite expectPapExtendSaturatedResultType "passes saturated papExtend result type invariant"
        ]
