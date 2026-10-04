module TestLogic.Generate.CodeGen.PartialApplicationRoutingTest exposing (suite)

{-| Runs the partial-application routing check on every program in the
standard catalogue of `SourceIR` test programs.

The check is meant to catch a call that supplies fewer arguments than its
function takes being emitted as an `eco.call`, rather than building a closure
with `eco.papCreate` or adding arguments to one with `eco.papExtend`. As
`TestLogic.Generate.CodeGen.PartialApplicationRouting` explains, it cannot
currently fire, because the code generator gives a function value the type
`!eco.value`. In practice this suite checks that each program compiles to MLIR.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites` runs.

For each program, `suite` checks that:

  - `TestLogic.TestPipeline.runToMlir` compiles it to MLIR without an error;
  - no `eco.call` with exactly one result has a result of MLIR function type.

Among what is not tested: `eco.call` ops with no result or several results,
and whether an `eco.call` supplies as many arguments as its callee takes.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PartialApplicationRouting exposing (expectPartialApplicationRouting)


{-| The test suite: every program in the standard catalogue, each checked with
`expectPartialApplicationRouting`.
-}
suite : Test
suite =
    Test.describe "CGEN_002: Partial Application Routing"
        [ StandardTestSuites.expectSuite expectPartialApplicationRouting "passes partial application routing invariant"
        ]
