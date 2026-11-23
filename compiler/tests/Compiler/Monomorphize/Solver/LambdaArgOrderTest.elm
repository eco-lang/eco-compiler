module Compiler.Monomorphize.Solver.LambdaArgOrderTest exposing (suite)

{-| Checks that a lambda literal passed to a function sees, in the lambda sets
of its parameters, the function values that the call's other arguments add,
whatever the order of the arguments.

The fixture is a state monad over `Int` and a left fold over it:

    pure a = \s -> ( s, a )
    andThen f ma = \s -> let ( s1, x ) = ma s in f x s1
    myFoldl f acc xs = case xs of [] -> acc ; y :: ys -> myFoldl f (f y acc) ys
    steps action xs = myFoldl (\x ioAcc -> andThen (\_ -> action x) ioAcc) (pure ()) xs

The accumulator `ioAcc` is `pure ()` on the first step and the previous step's
result after that, so the lambda set on the `ma` parameter of the `andThen`
the step lambda calls must name both. Before the fix, the step lambda, the
first argument, was translated before the call `pure ()`, the second, whose
member then never reached the lambda's parameter types or the `andThen`
demand its body files: `ma`'s set held only the step lambda, global
optimization stamped `ma s` as a direct call to the step lambda, and the
first iteration ran the step lambda's code on `pure ()`'s closure, which
crashed (test/eco-elm/src/FoldPureAccumulatorTest.elm is the program). Lambda
literals are now translated after the call's other arguments
(`Translate.traverseLambdasLast`).

The test establishes that every specialization of `andThen` has a `ma`
parameter whose lambda set is not a set of exactly one member.

-}

import Array
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , destruct
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pAnything
        , pCons
        , pList
        , pTuple
        , pVar
        , tLambda
        , tTuple
        , tType
        , tUnit
        , tVar
        , tupleExpr
        , unitExpr
        , varExpr
        )
import Compiler.Config as Config
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The test of the fold-over-`pure ()` fixture.
-}
suite : Test
suite =
    Test.describe "Lambda arguments are translated after their sibling arguments"
        [ Test.test "andThen's ma set names pure () as well as the step lambda" <|
            \() ->
                let
                    d =
                        Config.defaultLss
                in
                case Pipeline.runSolverMonoWithReport Config.defaultLimits { d | enabled = True } fixture of
                    Err msg ->
                        Expect.fail msg

                    Ok ( graph, _ ) ->
                        case maAnnos graph of
                            [] ->
                                Expect.fail "no spec of andThen"

                            annos ->
                                Expect.all
                                    (List.map
                                        (\anno _ ->
                                            case anno of
                                                Mono.LSet [ m ] ->
                                                    Expect.fail ("andThen's ma set is the one-member set {" ++ String.fromInt m ++ "}")

                                                _ ->
                                                    Expect.pass
                                        )
                                        annos
                                    )
                                    ()
        ]


{-| Returns, for each spec of `andThen`, the annotation on its second
parameter, `ma`.
-}
maAnnos : Mono.MonoGraph -> List Mono.LambdaSetAnno
maAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ "andThen", t ) ->
                    case params 2 t of
                        [ _, Mono.MFunction _ anno _ _ ] ->
                            anno :: acc

                        _ ->
                            acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns the first `count` parameter types of `t`, across stages.
-}
params : Int -> Mono.MonoType -> List Mono.MonoType
params count t =
    if count <= 0 then
        []

    else
        case t of
            Mono.MFunction _ _ ps ret ->
                List.take count ps ++ params (count - List.length ps) ret

            _ ->
                []


{-| `Int -> ( Int, a )`.
-}
io : Src.Type -> Src.Type
io a =
    tLambda (tType "Int" []) (tTuple (tType "Int" []) a)


{-| The fixture described in the module documentation, with
`bump x s = ( s + x, () )` and `testValue` running `steps bump [ 1, 2, 3 ]`
from 0.
-}
fixture : Src.Module
fixture =
    makeModuleWithTypedDefs "Test"
        [ { name = "pure"
          , args = [ pVar "a" ]
          , tipe = tLambda (tVar "a") (io (tVar "a"))
          , body = lambdaExpr [ pVar "s" ] (tupleExpr (varExpr "s") (varExpr "a"))
          }
        , { name = "andThen"
          , args = [ pVar "f", pVar "ma" ]
          , tipe = tLambda (tLambda (tVar "a") (io (tVar "b"))) (tLambda (io (tVar "a")) (io (tVar "b")))
          , body =
                lambdaExpr [ pVar "s" ]
                    (letExpr [ destruct (pTuple (pVar "s1") (pVar "x")) (callExpr (varExpr "ma") [ varExpr "s" ]) ]
                        (callExpr (varExpr "f") [ varExpr "x", varExpr "s1" ])
                    )
          }
        , { name = "myFoldl"
          , args = [ pVar "f", pVar "acc", pVar "xs" ]
          , tipe =
                tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                    (tLambda (tVar "b") (tLambda (tType "List" [ tVar "a" ]) (tVar "b")))
          , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "y") (pVar "ys")
                      , callExpr (varExpr "myFoldl") [ varExpr "f", callExpr (varExpr "f") [ varExpr "y", varExpr "acc" ], varExpr "ys" ]
                      )
                    ]
          }
        , { name = "steps"
          , args = [ pVar "action", pVar "xs" ]
          , tipe = tLambda (tLambda (tType "Int" []) (io tUnit)) (tLambda (tType "List" [ tType "Int" [] ]) (io tUnit))
          , body =
                callExpr (varExpr "myFoldl")
                    [ lambdaExpr [ pVar "x", pVar "ioAcc" ]
                        (callExpr (varExpr "andThen") [ lambdaExpr [ pAnything ] (callExpr (varExpr "action") [ varExpr "x" ]), varExpr "ioAcc" ])
                    , callExpr (varExpr "pure") [ unitExpr ]
                    , varExpr "xs"
                    ]
          }
        , { name = "bump"
          , args = [ pVar "x", pVar "s" ]
          , tipe = tLambda (tType "Int" []) (io tUnit)
          , body = tupleExpr (binopsExpr [ ( varExpr "s", "+" ) ] (varExpr "x")) unitExpr
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ destruct (pTuple (pVar "r") pAnything)
                        (callExpr (varExpr "steps") [ varExpr "bump", listExpr [ intExpr 1, intExpr 2, intExpr 3 ], intExpr 0 ])
                    ]
                    (varExpr "r")
          }
        ]
