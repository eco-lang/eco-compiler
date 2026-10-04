module TestLogic.Type.NodeVarConstrainedTest exposing (suite)

{-| Runs the TYPE\_007 check on the standard catalogue of `SourceIR` test
programs, so that a solver variable the type checker records for an expression
and then never constrains does not go unnoticed. Solving leaves such a variable
free, and the expression's type can then come out as a type variable that
belongs to no enclosing definition. The check, including which expression kinds
it examines and which variables it accepts, is
`TestLogic.Type.NodeVarConstrained.check`. It reads the _node types_: the type
recorded for each node of the program, indexed by node id.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from its case modules, some of them fuzzed, as that module describes.

The tests establish:

  - For each program, `expectNodeVarsConstrained` runs it through
    `TestLogic.TestPipeline.runToPostSolve` and gives `check` the canonical
    module, the annotations, and the node types as type checking left them,
    before PostSolve. The test fails, listing the violations, if `check`
    reports any.

Among what is not tested:

  - A program that fails to canonicalize or to type check. Its test passes.
  - The node types after PostSolve. PostSolve is run, but nothing it produces
    is checked.

-}

import Compiler.AST.Source as Src
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline
import TestLogic.Type.NodeVarConstrained as NodeVarConstrained


{-| The TYPE\_007 tests: `expectNodeVarsConstrained` applied to the standard
`SourceIR` programs, in one group named for the invariant.
-}
suite : Test
suite =
    Test.describe "TYPE_007: Recorded node variables are constrained"
        [ StandardTestSuites.expectSuite expectNodeVarsConstrained "node vars constrained"
        ]


{-| Returns a passing expectation when `check` finds no violation in
`srcModule`'s node types before PostSolve, and a failure whose message lists
the violations otherwise. A program that fails to canonicalize or to type check
passes.
-}
expectNodeVarsConstrained : Src.Module -> Expect.Expectation
expectNodeVarsConstrained srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err _ ->
            Expect.pass

        Ok artifacts ->
            case NodeVarConstrained.check artifacts.canonical artifacts.annotations artifacts.nodeTypesPre of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (NodeVarConstrained.formatViolations violations)
