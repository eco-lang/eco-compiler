module TestLogic.Type.PostSolve.PostSolveGroupBStructuralTypesTest exposing (suite)

{-| `Compiler.Type.PostSolve` overwrites the type the solver recorded for each
string, character and float literal and each unit with `String`, `Char`,
`Float` or `()`. These tests check, on the standard case programs, that every
such literal comes out of PostSolve with the type its form implies, and that
the solver had already given it that same type (POST\_001).

The terms are those of `Compiler.Type.PostSolve`. A _Group B_ node is one whose
recorded type is a _synthetic placeholder_: a fresh type variable that
constraint generation allocates for the node and ties to the type its context
expects. The literals are the Group B forms PostSolve types structurally; the
others, `Shader` and variable references, keep the solver's type.

The fixture is every program of the case modules that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers, each compiled through
PostSolve by `TestLogic.Type.PostSolve.CompileThroughPostSolve.compileToPostSolve`
and checked by `TestLogic.Type.PostSolve.GroupBTypes.checkGroupBLiterals`:

  - The program must canonicalize and type check; an error fails the test.
  - Every `Str`, `Chr`, `Float` and `Unit` expression must have exactly its
    form's type after PostSolve, and, where the solver recorded a type for it,
    that same type before.

A program with no such literal passes once it compiles.

Among what is not tested: `Shader` nodes and variable references.

-}

import Compiler.AST.Source as Src
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.GroupBTypes as GroupBTypes


{-| The test group that runs `expectGroupBStructuralTypes` over every standard
case program.
-}
suite : Test
suite =
    Test.describe "POST_001: Group B Structural Types"
        [ StandardTestSuites.expectSuite expectGroupBStructuralTypes "group-b-structural"
        ]


{-| Expects `srcModule` to compile through PostSolve and every literal in it to
pass `GroupBTypes.checkGroupBLiterals`.

A compile error fails with its message; violations fail with one line each.

-}
expectGroupBStructuralTypes : Src.Module -> Expect.Expectation
expectGroupBStructuralTypes srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            case GroupBTypes.checkGroupBLiterals artifacts.canonical artifacts.nodeTypesPre artifacts.nodeTypesPost of
                [] ->
                    Expect.pass

                issues ->
                    Expect.fail ("POST_001 violations:\n" ++ String.join "\n" issues)
