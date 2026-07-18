module TestLogic.Generate.CodeGen.E5KeyedDispatchTest exposing (suite)

{-| E5 selective keyed fan-out (plan §10) — activation pin.

Fixture: a recursion-protected HOF `applyBoth` (SCC guard blocks inlining)
called with TWO different lambda literals at the SAME type:

    applyBoth f n acc = if n <= 0 then acc else applyBoth f (n-1) (f acc)
    testValue = applyBoth (\a -> a*2) 2 1 + applyBoth (\b -> b+7) 2 1

UNKEYED (plain solver+LSS): both call sites demand one spec of `applyBoth`
at the shared type; the spec's `f` param carries the JOINED 2-member set —
`f acc` is not a singleton, nothing stamps. KEYED on
`eco/example:Test.applyBoth` (the TestLogic fixture package/module): the
annotated demand keys the registry, so each call site's lambda mints its own
spec — each spec's `f` is a singleton and `f acc` exact-Stamps
(`callInfo.fastEvaluator = Just <that lambda>`). The pin asserts TWO
DISTINCT stamped fast evaluators (per-site fan-out, not just one lucky
stamp), and that the unkeyed run stamps NONE (RED/GREEN by keying alone).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
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


keyedTarget : String
keyedTarget =
    "eco/example:Test.applyBoth"


suite : Test
suite =
    Test.describe "E5: keying a global fans out singleton specs that stamp"
        [ Test.test "keyed on applyBoth: two distinct fast evaluators are stamped" <|
            \_ ->
                case Pipeline.runToGlobalOptLssKeyedOn [ keyedTarget ] fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS keyed pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        let
                            n =
                                distinctFastEvaluators optimizedMonoGraph
                        in
                        if n >= 2 then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected >= 2 distinct stamped fast evaluators (one per keyed spec), got "
                                    ++ String.fromInt n
                                    ++ " (keyed nodes="
                                    ++ String.fromInt (nodeCount optimizedMonoGraph)
                                    ++ ", unkeyed nodes="
                                    ++ (case Pipeline.runToGlobalOptLssOn fixtureModule of
                                            Ok a ->
                                                String.fromInt (nodeCount a.optimizedMonoGraph)

                                            Err _ ->
                                                "?"
                                       )
                                    ++ ")"
                                )
        , Test.test "unkeyed: the joined 2-member set stamps nothing (the E5 premise)" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        let
                            n =
                                distinctFastEvaluators optimizedMonoGraph
                        in
                        if n == 0 then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected 0 stamped fast evaluators unkeyed, got "
                                    ++ String.fromInt n
                                    ++ " — the fixture no longer isolates keying"
                                )
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


intT : Src.Type
intT =
    tType "Int" []


int1T : Src.Type
int1T =
    tLambda intT intT


fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefs "Test" [ applyBothDef, testValueDef ]


{-| applyBoth f n acc = if n <= 0 then acc else f (applyBoth f (n - 1) acc)

NON-TAIL recursion on purpose: a tail-recursive spec whose closure param is
called saturated is H5-LOOPIFIABLE — `loopifyCall` beta-inlines the call-site
lambda into a local loop and NO dispatch remains to stamp (this is why the
E4a fixture under-applies its param instead). Putting the recursive call in
`f`'s argument keeps the def out of the tail-func/loopify path while the SCC
guard still blocks inlining, so the `f …` dispatch site survives to
AbiCloning.

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


{-| testValue = applyBoth (\a -> a*2) 2 1 + applyBoth (\b -> b+7) 2 1 -}
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


{-| Count DISTINCT `callInfo.fastEvaluator` lambda ids across all stamped
calls in the graph.
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


nodeCount : Mono.MonoGraph -> Int
nodeCount (Mono.MonoGraph data) =
    Array.length data.nodes


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
