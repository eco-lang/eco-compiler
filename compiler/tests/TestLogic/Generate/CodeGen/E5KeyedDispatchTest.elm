module TestLogic.Generate.CodeGen.E5KeyedDispatchTest exposing (suite)

{-| Checks that, when a higher-order function is called with two different
lambdas at the same type, the optimised program still has at least one call
stamped for fast dispatch. A missing stamp does not change what the program
computes, only how the call is made, so losing one would not show up as a
wrong result.

Three terms are needed. A _lambda set_ is the annotation on a function type
naming which function values can flow through it. _Keying_ is how the solver
engine registers a specialisation of a global when lambda-set specialisation
is on and the global is under its specialisation budget: the registry key is
the demanded type with its lambda sets included, as
`Compiler.MonoSolver.Engine` describes, so two calls at the same type that pass
different lambdas can get separate specialisations. _Stamping_ is AbiCloning
writing a `fastEvaluator`, a lambda id naming the one function value the callee
must be, into a call's `CallInfo`; `Compiler.GlobalOpt.AbiCloning` stamps a
call only when its callee's lambda set has exactly one member.

The fixture is a module with two annotated values:

    applyBoth : (Int -> Int) -> Int -> Int -> Int
    applyBoth f n acc =
        if n <= 0 then
            acc

        else
            f (applyBoth f (n - 1) acc)

    testValue : Int
    testValue =
        applyBoth (\a -> a * 2) 2 1 + applyBoth (\b -> b + 7) 2 1

`applyBoth` is recursive, so the post-monomorphization inliner does not inline
it, and its recursive call is the argument of `f` rather than in tail position,
so it is not a tail function and loopification, which copies a tail function's
body into a call site that passes it a lambda, does not apply either. The call
of `f` therefore survives into global optimisation. With keying, a call site's
demand can mint its own specialisation of `applyBoth` in which `f` has a
one-member lambda set; if both sites shared one specialisation, `f` would carry
both lambdas and the call could not be stamped.

What the test establishes:

  - "applyBoth: keying makes the site stamp at all" runs the fixture through
    `TestLogic.TestPipeline.runToGlobalOpt` and passes when the
    optimised graph holds at least one call with a `fastEvaluator`. A pipeline
    failure fails the test.

Among what is not tested:

  - which call is stamped: every call in the graph is counted, so a stamp
    anywhere else would also pass;
  - that the two lambdas are stamped separately: one distinct fast evaluator is
    enough;
  - the outcome without keying: in the pipeline used, whose specialisation
    budget is unlimited, every demand is keyed, and the pipeline has no way to
    turn keying off.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The module's one test, which passes when the optimised fixture graph holds
at least one stamped call.
-}
suite : Test
suite =
    Test.describe "keying a global fans out singleton specs that stamp"
        [ Test.test "applyBoth: keying makes the site stamp at all" <|
            \_ ->
                case Pipeline.runToGlobalOpt fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS keyed pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        let
                            n =
                                distinctFastEvaluators optimizedMonoGraph
                        in
                        if n >= 1 then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a stamped fast evaluator under keying, got "
                                    ++ String.fromInt n
                                    ++ " (nodes="
                                    ++ String.fromInt (nodeCount optimizedMonoGraph)
                                    ++ ")"
                                )
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


{-| The source type `Int`.
-}
intT : Src.Type
intT =
    tType "Int" []


{-| The source type `Int -> Int`, the type of the function `applyBoth` takes.
-}
int1T : Src.Type
int1T =
    tLambda intT intT


{-| The test program: a module `Test` holding the annotated `applyBoth` and
`testValue` shown in the module docstring.
-}
fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefs "Test" [ applyBothDef, testValueDef ]


{-| The definition of `applyBoth`, which returns `acc` when `n <= 0` and
otherwise `f (applyBoth f (n - 1) acc)`.

The recursive call is the argument of `f`, not a tail call, so `applyBoth` is
not a tail function and loopification cannot copy its body into a call site;
being recursive, it is not inlined either. The call of `f` is left for
AbiCloning to stamp.

-}
applyBothDef : TypedDef
applyBothDef =
    { name = "applyBoth"
    , args = [ pVar "f", pVar "n", pVar "acc" ]
    , tipe = tLambda int1T (tLambda intT (tLambda intT intT))
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (varExpr "acc")
            (callExpr (varExpr "f")
                [ callExpr (varExpr "applyBoth")
                    [ varExpr "f"
                    , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , varExpr "acc"
                    ]
                ]
            )
    }


{-| The definition of `testValue`, which adds `applyBoth (\a -> a * 2) 2 1` to
`applyBoth (\b -> b + 7) 2 1`: two calls at the same type, each passing a
different lambda.
-}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = intT
    , body =
        binopsExpr
            [ ( callExpr (varExpr "applyBoth")
                    [ lambdaExpr [ pVar "a" ] (binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 2))
                    , intExpr 2
                    , intExpr 1
                    ]
              , "+"
              )
            ]
            (callExpr (varExpr "applyBoth")
                [ lambdaExpr [ pVar "b" ] (binopsExpr [ ( varExpr "b", "+" ) ] (intExpr 7))
                , intExpr 2
                , intExpr 1
                ]
            )
    }



-- GRAPH WALK ----------------------------------------------------------------


{-| Returns the number of distinct lambda ids found in the `fastEvaluator` of
calls anywhere in the graph's nodes, including calls nested inside closures and
`let` definitions.

A stamp on a partial application of a global carries a sentinel lambda id
rather than a closure's own (see `Compiler.GlobalOpt.AbiCloning`), and is
counted like any other.

-}
distinctFastEvaluators : Mono.MonoGraph -> Int
distinctFastEvaluators (Mono.MonoGraph data) =
    Array.foldl
        (\mn acc ->
            List.foldl
                (\e a -> MonoTraverse.foldExpr collectStamp a e)
                acc
                (nodeExprs mn)
        )
        []
        data.nodes
        |> dedupCount


{-| Adds the call's `fastEvaluator` to `acc` when `e` is a call that carries
one, and otherwise returns `acc` unchanged.
-}
collectStamp : Mono.MonoExpr -> List Mono.LambdaId -> List Mono.LambdaId
collectStamp e acc =
    case e of
        Mono.MonoCall _ _ _ _ callInfo ->
            case callInfo.fastEvaluator of
                Just lid ->
                    lid :: acc

                Nothing ->
                    acc

        _ ->
            acc


{-| Returns the number of node slots in the graph, empty slots included. The
test uses it only in its failure message.
-}
nodeCount : Mono.MonoGraph -> Int
nodeCount (Mono.MonoGraph data) =
    Array.length data.nodes


{-| Returns the number of distinct ids in `ids`.
-}
dedupCount : List Mono.LambdaId -> Int
dedupCount ids =
    List.foldl
        (\lid seen ->
            if List.member lid seen then
                seen

            else
                lid :: seen
        )
        []
        ids
        |> List.length


{-| Returns the expression a node slot holds: the expression of a define, tail
function or port, and nothing for an empty slot or a node with no expression.
-}
nodeExprs : Maybe Mono.MonoNode -> List Mono.MonoExpr
nodeExprs maybeNode =
    case maybeNode of
        Just (Mono.MonoDefine e _) ->
            [ e ]

        Just (Mono.MonoTailFunc _ e _) ->
            [ e ]

        Just (Mono.MonoPortIncoming e _) ->
            [ e ]

        Just (Mono.MonoPortOutgoing e _) ->
            [ e ]

        _ ->
            []
