module TestLogic.Type.PostSolve.PostSolveNodeTypeGroundedTest exposing (suite)

{-| Test suite for invariant POST\_010: All node type TVars come from enclosing
type schemes.

For every non-kernel expression node, every Can.TVar in its post-PostSolve
type must be traceable to a binder in an enclosing type scheme (from annotations
or solver let-generalization), or be a type-class variable.

-}

import Compiler.AST.Source as Src
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveNodeTypeGrounded as Grounded


suite : Test
suite =
    Test.describe "POST_010: All node type TVars come from enclosing type schemes"
        [ StandardTestSuites.expectSuite expectGrounded "node types grounded"
        ]


{-| Check that a module passes POST\_010.
-}
expectGrounded : Src.Module -> Expect.Expectation
expectGrounded srcModule =
    case Compile.compileToPostSolve srcModule of
        Err _ ->
            -- Compilation failure is not our concern; skip
            Expect.pass

        Ok artifacts ->
            case Grounded.check artifacts.canonical artifacts.annotations artifacts.nodeTypesPre artifacts.nodeTypesPost of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (Grounded.formatViolations violations)
