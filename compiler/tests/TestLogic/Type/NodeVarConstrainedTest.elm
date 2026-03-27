module TestLogic.Type.NodeVarConstrainedTest exposing (suite)

{-| Test suite for invariant TYPE\_007: Recorded node variables are constrained.

Every If or Case expression's node type, after type solving, must be grounded
in the enclosing annotation's binders. A bare TVar not in the binders indicates
a solver variable that was recorded (via NodeIds.recordNodeVar) but never
constrained via CEqual.

-}

import Compiler.AST.Source as Src
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline
import TestLogic.Type.NodeVarConstrained as NodeVarConstrained


suite : Test
suite =
    Test.describe "TYPE_007: Recorded node variables are constrained"
        [ StandardTestSuites.expectSuite expectNodeVarsConstrained "node vars constrained"
        ]


{-| Check that a module passes TYPE\_007.
-}
expectNodeVarsConstrained : Src.Module -> Expect.Expectation
expectNodeVarsConstrained srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err _ ->
            -- Type check failure is not our concern; skip
            Expect.pass

        Ok artifacts ->
            case NodeVarConstrained.check artifacts.canonical artifacts.annotations artifacts.nodeTypesPre of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (NodeVarConstrained.formatViolations violations)
