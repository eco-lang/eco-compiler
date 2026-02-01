module TestLogic.Type.PostSolve.PostSolveNonRegressionInvariantsTest exposing (suite)

{-| Test suite for invariants POST\_005 and POST\_006.

POST\_005: PostSolve does not rewrite solver-structured node types
POST\_006: PostSolve does not introduce new free type variables

-}

import Compiler.AST.Source as Src
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveNonRegressionInvariants as Invariants
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "POST_005/POST_006: PostSolve Non-Regression"
        [ StandardTestSuites.expectSuite expectNonRegression "non-regression"
        ]


{-| Check that a module passes both POST\_005 and POST\_006.
-}
expectNonRegression : Src.Module -> Expect.Expectation
expectNonRegression srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                nodeKinds =
                    Invariants.collectNodeKinds artifacts.canonical

                v5 =
                    Invariants.checkPost005 nodeKinds artifacts.nodeTypesPre artifacts.nodeTypesPost

                v6 =
                    Invariants.checkPost006 nodeKinds artifacts.nodeTypesPre artifacts.nodeTypesPost
            in
            case v5 ++ v6 of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (Invariants.formatViolations violations)
