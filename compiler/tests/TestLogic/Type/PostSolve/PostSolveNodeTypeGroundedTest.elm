module TestLogic.Type.PostSolve.PostSolveNodeTypeGroundedTest exposing (suite)

{-| Runs the POST\_010 check over the standard catalogue of test programs, so
that a PostSolve which leaves an expression with a type variable that no
enclosing type scheme accounts for is caught.

PostSolve rewrites some of the _node types_ the solver produced, the types
recorded for each expression and pattern. POST\_010 is the rule that every type
variable in an expression's type after PostSolve is either bound by a
definition or a destructuring `let` enclosing the expression, or is a
type-class variable. The check
itself, including which expressions it looks at and which variables a
definition binds, belongs to
`TestLogic.Type.PostSolve.PostSolveNodeTypeGrounded`.

The fixture is every program that `SourceIR.Suite.StandardTestSuites.expectSuite`
hands to its expectation. Each is compiled through PostSolve by
`TestLogic.Type.PostSolve.CompileThroughPostSolve.compileToPostSolve`, which
gives the canonical module, the solver's annotations of its top-level values,
and its node types from before and after PostSolve.

What the tests establish:

  - `suite`: for each program that canonicalizes and type checks,
    `PostSolveNodeTypeGrounded.check` reports no violation.

Among what is not tested:

  - A program that fails to canonicalize or type check. It passes without
    being checked.
  - The expressions `PostSolveNodeTypeGrounded` does not check itself, such as
    variables, accessors, list, record and tuple literals, and lambdas, and
    every pattern.
  - Record extension variables, which the check does not collect, and any
    type variable whose name starts with `number`, `comparable`, `appendable`
    or `compappend`.

-}

import Compiler.AST.Source as Src
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveNodeTypeGrounded as Grounded


{-| The POST\_010 check, run on the programs of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "POST_010: All node type TVars come from enclosing type schemes"
        [ StandardTestSuites.expectSuite expectGrounded "node types grounded"
        ]


{-| Passes when `srcModule` has no POST\_010 violation after PostSolve, or when
it fails to canonicalize or type check. Otherwise it fails with the violations
as `PostSolveNodeTypeGrounded.formatViolations` lists them.
-}
expectGrounded : Src.Module -> Expect.Expectation
expectGrounded srcModule =
    case Compile.compileToPostSolve srcModule of
        Err _ ->
            Expect.pass

        Ok artifacts ->
            case Grounded.check artifacts.canonical artifacts.annotations artifacts.nodeTypesPre artifacts.nodeTypesPost of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (Grounded.formatViolations violations)
