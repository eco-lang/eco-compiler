module TestLogic.Generate.CodeGen.PartialApplicationRoutingTest exposing (suite)

{-| Runs the partial-application routing check on every program in the
standard catalogue of `SourceIR` test programs.

The check catches a call that supplies fewer arguments than its function
takes being emitted as an `eco.call`, rather than building a closure with
`eco.papCreate` or adding arguments to one with `eco.papExtend`, by comparing
each direct `eco.call` with the `function_type` of the `func.func` it names.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites` runs.

For each program, `suite` checks that:

  - `TestLogic.TestPipeline.runToMlir` compiles it to MLIR without an error;
  - every `eco.call` whose callee is a top-level `func.func` of the module
    passes exactly as many arguments (GC root hints aside) as the callee takes
    and has exactly the callee's result types.

Among what is not tested: calls to symbols with no `func.func` in the module.

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
