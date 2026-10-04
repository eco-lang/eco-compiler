module TestLogic.Type.DeepLetStackSafetyTest exposing (suite)

{-| Checks that the erased type-check path can take a deeply nested `let` chain
without overflowing the JavaScript call stack. The erased path records no
types for individual expressions. Each `let` puts its body one level deeper, so
a step that used one stack frame per level would fail on a long enough chain.

The path is run here as three steps: `Compiler.Canonicalize.Module.canonicalize`,
then constraint generation with `Compiler.Type.Constrain.Erased.Module.constrain`,
then `Compiler.Type.Solve.run`. How the constraint generator walks a `let`
chain without a stack frame per level is described in
`Compiler.Type.Constrain.Typed.Expression`.

The fixture is one module, built with `Compiler.AST.SourceBuilder.makeModule`,
whose single top-level value `testValue` is `deepLet 1000`: a chain of 1000
nested `let`s, each binding one unused integer literal, ending in `0`. It is
canonicalized as a module of the package `eco/example` against
`Compiler.Elm.Interface.Basic.testIfaces`.

What the test establishes:

  - "deeply nested let chain type-checks without stack overflow":
    canonicalization succeeds, and constraint generation followed by solving
    returns `Ok`. It therefore also fails if the chain does not canonicalize
    or does not type-check.

Among what is not tested: chains of recursive (`LetRec`) or destructuring
(`LetDestruct`) `let`s, which the generator handles in cases of their own; the
typed path, which also records expression types; chains deeper than 1000;
and the types the solver infers.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Erased.Module as ErasedConstrain
import Compiler.Type.Solve as Solve
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


{-| Builds a chain of `n` nested `let`s ending in `0`, each binding one name to
an integer literal:

    let xn = n in ... let x2 = 2 in let x1 = 1 in 0

-}
deepLet : Int -> Src.Expr
deepLet n =
    List.foldl
        (\i body -> SB.letExpr [ SB.define ("x" ++ String.fromInt i) [] (SB.intExpr i) ] body)
        (SB.intExpr 0)
        (List.range 1 n)


{-| The single test, which runs a 1000-deep `let` chain through
canonicalization, erased constraint generation and solving, and expects it to
type-check.
-}
suite : Test
suite =
    Test.describe "Deep let-chain constraint generation is stack-safe (erased path)"
        [ Test.test "deeply nested let chain type-checks without stack overflow" <|
            \_ ->
                let
                    modul =
                        SB.makeModule "testValue" (deepLet 1000)
                in
                case canonicalizeModule modul of
                    Err msg ->
                        Expect.fail msg

                    Ok canonical ->
                        case IO.unsafePerformIO (ErasedConstrain.constrain canonical |> IO.andThen Solve.run) of
                            Ok _ ->
                                Expect.pass

                            Err _ ->
                                Expect.fail "expected the deep let chain to type-check"
        ]


{-| Canonicalizes `srcModule` as a module of the package `eco/example` against
`Basic.testIfaces`. Warnings are dropped, and any errors are replaced by the
message "canonicalization failed".
-}
canonicalizeModule : Src.Module -> Result String Can.Module
canonicalizeModule srcModule =
    case Result.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        ( _, Ok modul ) ->
            Ok modul

        ( _, Err _ ) ->
            Err "canonicalization failed"
