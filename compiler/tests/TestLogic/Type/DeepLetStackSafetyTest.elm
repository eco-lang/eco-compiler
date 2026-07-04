module TestLogic.Type.DeepLetStackSafetyTest exposing (suite)

{-| Stack-safety guard for constraint generation over deep `let` chains.

The Erased constraint generator used to recurse into a `let` body in `andThen`
subject position, which builds the `Prog` value on the Elm/JS call stack one
frame per `let` level (a construction-time overflow risk for deeply nested or
machine-generated code). The body recursion is now deferred behind a `Step`, so
a deep chain is walked one level per interpreter iteration. This test drives a
deeply nested `let` chain through the erased type-check path and asserts it
type-checks without overflowing.

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


{-| A right-nested chain of `n` `let`s ending in `0`:

    let x1 = 1 in let x2 = 2 in ... let xn = n in 0

-}
deepLet : Int -> Src.Expr
deepLet n =
    List.foldl
        (\i body -> SB.letExpr [ SB.define ("x" ++ String.fromInt i) [] (SB.intExpr i) ] body)
        (SB.intExpr 0)
        (List.range 1 n)


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


canonicalizeModule : Src.Module -> Result String Can.Module
canonicalizeModule srcModule =
    case Result.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        ( _, Ok modul ) ->
            Ok modul

        ( _, Err _ ) ->
            Err "canonicalization failed"
