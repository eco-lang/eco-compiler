module TestLogic.Generate.CodeGen.E5KeyedDispatchTest exposing (suite)

{-| E5 selective keyed fan-out (plan §10) — activation pin.

Fixture: a recursion-protected HOF `applyBoth` (SCC guard blocks inlining)
called with TWO different lambda literals at the SAME type:

    applyBoth f n acc =
        if n <= 0 then
            acc

        else
            applyBoth f (n - 1) (f acc)

    testValue =
        applyBoth (\a -> a * 2) 2 1 + applyBoth (\b -> b + 7) 2 1

Keying makes the annotated demand key the registry, so a call site's lambda
can mint its own spec whose `f` is a SINGLETON and whose `f acc` exact-stamps
(`callInfo.fastEvaluator = Just <that lambda>`). Without it both call sites
demand one spec at the shared type, the spec's `f` carries the JOINED 2-member
set, and nothing stamps.

WHAT THIS PIN USED TO BE, and why it is weaker now (2026-09-18). It was a
RED/GREEN pair on `lss.keyed`: the keyed arm asserted TWO DISTINCT stamped
fast evaluators (per-site fan-out, not one lucky stamp) and the unkeyed arm
asserted NONE. Both flags it rested on were fixed at their defaults and
removed — `lss.keyed`, so there is no unkeyed arm to compare against, and
`lss.arrowIdentity`, which this harness had pinned OFF.

Arrow identity is what costs the second stamp: with it ON — the shipping
default, and now unconditional — the two call sites' arrows share one set
slot, so keying fans out ONE stamped evaluator on this fixture rather than
two. That is slot sharing working as designed (LSS\_006 per-load
fragmentation is what it removes), not a lost stamp: the 633-workload
emission rail is byte-identical across the whole removal.

What survives is the claim the fixture can still make at shipping defaults —
a JOINED 2-member set stamps nothing, so any stamp here at all is keying's
doing.

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


suite : Test
suite =
    Test.describe "keying a global fans out singleton specs that stamp"
        [ Test.test "applyBoth: keying makes the site stamp at all" <|
            \_ ->
                case Pipeline.runToGlobalOptLssAllKeyedOn fixtureModule of
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


{-| testValue = applyBoth (\\a -> a\*2) 2 1 + applyBoth (\\b -> b+7) 2 1
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
