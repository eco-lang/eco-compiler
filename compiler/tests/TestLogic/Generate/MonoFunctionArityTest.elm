module TestLogic.Generate.MonoFunctionArityTest exposing (suite)

{-| Runs the function arity check over the standard catalogue of test
programs, so that a function whose parameters disagree with the arity of its
type after global optimization is looked for in all of those programs rather
than in a hand-picked few.

The check is `TestLogic.Generate.MonoFunctionArity.expectFunctionArityMatches`.
That module's docstring defines the _stage arity_ (the parameter count of a
function type's outermost stage) and the _flattened arity_ (the parameter
count of all its stages together), and lists the mismatches it reports. It
compiles each program through the global optimizer
(`TestLogic.TestPipeline.runToGlobalOpt`) and fails on a pipeline error or on
any mismatch it finds.

The fixture is the set of programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` includes.

What `suite` establishes, for each program those case modules hand to the
check:

  - that it compiles through the global optimizer without an error;
  - that, in the nodes and expressions the check walks, no closure's parameter
    count differs from the stage arity of its type, no tail function node's
    parameter count differs from the flattened arity of its type, and no call
    whose callee's type has a flattened arity above 0 passes more arguments
    than that arity.

Among what is not tested: the parameters of a `MonoTailDef` in a `let`, a call
with fewer arguments than its callee's arity, which is accepted as a partial
application, and nodes other than defines, tail functions and ports.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoFunctionArity exposing (expectFunctionArityMatches)


{-| The test group that applies `expectFunctionArityMatches` to the standard
catalogue of test programs.
-}
suite : Test
suite =
    Test.describe "Function arity matches (MONO_012)"
        [ StandardTestSuites.expectSuite expectFunctionArityMatches "has matching function arity"
        ]
