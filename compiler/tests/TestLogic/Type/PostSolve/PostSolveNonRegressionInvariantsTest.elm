module TestLogic.Type.PostSolve.PostSolveNonRegressionInvariantsTest exposing (suite)

{-| Runs the POST\_005 and POST\_006 checks over the standard catalogue of test
programs, so that a PostSolve which overwrites a type the solver had already
worked out, or adds type variables to it, is caught.

PostSolve rewrites some of the _node types_ the solver produced, the types
recorded for each expression and pattern. Both checks concern only nodes whose
type before PostSolve is _structured_, meaning anything other than a bare type
variable. POST\_005 requires such a node to keep an alpha-equivalent type
after PostSolve, and POST\_006 requires its type after PostSolve to name no type
variable that its type before did not. The checks, the exempted kinds of node
and the alpha-equivalence POST\_005 uses belong to
`TestLogic.Type.PostSolve.PostSolveNonRegressionInvariants`.

The fixture is every program that `SourceIR.Suite.StandardTestSuites.expectSuite`
hands to its expectation. Each is compiled through PostSolve by
`TestLogic.Type.PostSolve.CompileThroughPostSolve.compileToPostSolve`, which
gives the canonical module and its node types from before and after PostSolve.

What the tests establish:

  - `suite`: for each program, compilation through PostSolve succeeds, and
    neither `checkPost005` nor `checkPost006` reports a violation.

Among what is not tested:

  - A PostSolve that consistently renames the type variables of a structured
    type, such as swapping two of them throughout.
  - Nodes whose type before PostSolve is missing or a bare type variable.
  - Kernel references, which both checks skip, and record accessors, which
    POST\_006 skips.

-}

import Compiler.AST.Source as Src
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveNonRegressionInvariants as Invariants


{-| The POST\_005 and POST\_006 checks, run on the programs of the standard
catalogue.
-}
suite : Test
suite =
    Test.describe "POST_005/POST_006: PostSolve Non-Regression"
        [ StandardTestSuites.expectSuite expectNonRegression "non-regression"
        ]


{-| Passes when `srcModule` compiles through PostSolve and neither POST\_005
nor POST\_006 finds a violation in it.

A program that fails to canonicalize or type check fails with the message
`compileToPostSolve` gives. Violations fail with the list
`PostSolveNonRegressionInvariants.formatViolations` gives, the POST\_005 ones
first.

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

                nodeTypesPreMap =
                    artifacts.nodeTypesPre

                v5 =
                    Invariants.checkPost005 nodeKinds nodeTypesPreMap artifacts.nodeTypesPost

                v6 =
                    Invariants.checkPost006 nodeKinds nodeTypesPreMap artifacts.nodeTypesPost
            in
            case v5 ++ v6 of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (Invariants.formatViolations violations)
