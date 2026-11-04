module TestLogic.Type.NodeTypeVarNamesDistinctTest exposing (suite)

{-| Tests, on the standard catalogue of test programs, that within one
top-level definition one type variable name in the solver's node types stands
for one solver variable, so that monomorphization, which identifies type
variables by name within a definition, never confuses two of them.

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is type
checked with `TestLogic.TestPipeline.runToTypeCheck`, and
`TestLogic.Type.NodeTypeVarNamesDistinct.nameCollisions` lists every name
that, within one top-level definition, is the bare type of nodes whose solver
variables have different union-find roots. A program that fails to type check
fails.

"let helper's number variable named apart from the enclosing argument's" pins
a fixed compiler bug: type checking gave
the generalized `number` variable of a let-bound helper the same name as a
`number` variable of the enclosing definition's annotation, as in
`f x = let h y z = y * z in ( x * 1, h 4 5 )`. Both variables were instantiated
from `(*)`'s annotation and so carried its name `number`, and
`Compiler.Type.Type.toCanTypeBatch` did not check the helper's against the
annotation's, whose variable `toAnnotation` had already marked. Six catalogue
programs had such a collision. It was not harmless:
`Compiler.Type.NodeTypeVarNamesDistinctTest` pins that the substitution engine
specialized the helper at `Float`, the enclosing argument's type, although it
is called with `Int` literals.

A group of three unannotated, mutually recursive functions, `f x = g x`,
`g x = h x` and `h x = f x`, had in `g` and in `h` an argument pattern `x` and a
use of `x` that were different solver variables, both named `a`: constraint
generation (`Compiler.Type.Constrain.Typed.Expression.recDefsHelpWithIds`, as
in stock Elm 0.19.1) declared an earlier member's variables in the next
member's `CLet`, which generalized them. They are now declared once for the
group (finding B3 of plans/sourceir-catalogue-test-logic.md, which also made
type checking accept ill-typed groups), and the test "unannotated recursive
group of three" keeps it that way.

The catalogue includes `SourceIR.LetPolyNameCases`, the let-polymorphism
programs this check was first written for.

Among what is not tested: node types that are not a bare type variable, and
names across definitions.

It also runs over the programs of `SourceIR.MainFailsCases`, which typed
optimization rejects, and those of `SourceIR.MonoFailsCases`
(`expectBeforeMonoSuite`), which monomorphization rejects: every stage this
check looks at accepts them, and they hold what the standard catalogue cannot,
such as polymorphic recursion over a non-regular type.

-}

import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import SourceIR.MainFailsCases as MainFailsCases
import SourceIR.MonoFailsCases as MonoFailsCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.NodeTypeVarNamesDistinct exposing (expectNamesDistinct)


{-| `expectNamesDistinct` over every program of the standard catalogue, the
fixed `number` collision, and the recursive group of three.
-}
suite : Test
suite =
    Test.describe "Node type variable names are unique per solver variable"
        [ StandardTestSuites.expectSuite expectNamesDistinct "gives one solver variable per type variable name"
        , MainFailsCases.expectSuite expectNamesDistinct "gives one solver variable per type variable name"
        , MonoFailsCases.expectBeforeMonoSuite expectNamesDistinct "gives one solver variable per type variable name"
        , Test.test "let helper's number variable named apart from the enclosing argument's" <|
            \_ -> runSource expectNamesDistinct letHelperNumberSource
        , Test.test "unannotated recursive group of three" <|
            \_ -> runSource expectNamesDistinct "f x =\n    g x\n\n\ng x =\n    h x\n\n\nh x =\n    f x\n"
        ]


{-| The minimal program of the fixed `number` name collision.
-}
letHelperNumberSource : String
letHelperNumberSource =
    """wrapInt x =
    let
        h y z =
            y * z
    in
    ( x * 1, h 4 5 )


testValue =
    wrapInt 2.5
"""


{-| Runs `expectFn` on the module `Test` whose declarations are `body`, parsed
as a module of elm/core importing `Basics`, or fails when it does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn body =
    case Parse.fromByteString (Parse.Package Pkg.core) ("module Test exposing (..)\n\nimport Basics exposing (..)\n\n\n" ++ body) of
        Ok modul ->
            expectFn modul

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ body)
