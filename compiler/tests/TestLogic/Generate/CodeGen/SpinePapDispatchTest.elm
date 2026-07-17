module TestLogic.Generate.CodeGen.SpinePapDispatchTest exposing (suite)

{-| LSS_013 spine injection — transport pin.

Fixture (mirrors `test/elm/src/HofPapPrefixDispatchTest.elm` in the SourceIR
DSL): a capture-carrying 2-param lambda literal flows into a recursion-
protected HOF `applyPartial` (never inlined — SCC recursion guard). Inside,
`let g = f 10` is a PARTIAL application of that lambda.

What spine injection delivers, and what this pins: the lambda's member id lands
on the INNER arrow of its type (spine injection), and the call `f 10` peels one
arrow so its result — the let-binding `g` — carries `LSet [m]`. Without spine
injection the inner arrow stays `LTop`, so `g`'s type would be `LTop`. This test
therefore asserts: SOME function-typed let-binding in the solver+LSS graph
carries a SINGLETON `LSet` head annotation. RED under head-only injection,
GREEN with spine injection + the indirect-call-result transport
(`Translate.indirectResultAnno`).

NOTE — the E2 fast-dispatch STAMP does NOT yet fire on this shape: `g` is a
function-typed (local-multi) let, whose USE sites are classified independently
of the def (design §8.4 / plan E4a — the local-multi use-transport gap), so
`g acc` sees `LTop` even though `g`'s def carries the set. Spine injection is one
necessary link of a three-link transport chain (spine -> call result -> local-
multi use); E4a is the remaining co-requisite for E2 activation. This pin guards
the two links spine injection is responsible for.

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
    Test.describe "LSS_013: spine injection transports members to inner (PAP) arrows"
        [ Test.test "a partial-application let-binding carries a singleton lambda set (solver+LSS)" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        if hasSingletonFnLetDef optimizedMonoGraph then
                            Expect.pass

                        else
                            Expect.fail
                                ("no function-typed let-binding carries a singleton LSet — spine "
                                    ++ "injection + call-result transport did not reach `let g = f 10`"
                                )
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


intT : Src.Type
intT =
    tType "Int" []


int1T : Src.Type
int1T =
    tLambda intT intT


int2T : Src.Type
int2T =
    tLambda intT int1T


fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefs "Test" [ applyPartialDef, testValueDef ]


{-| applyPartial f n acc =
        if n <= 0 then acc
        else let g = f 10 in applyPartial f (n - 1) (g acc + g 1)
-}
applyPartialDef : TypedDef
applyPartialDef =
    { name = "applyPartial"
    , args = [ pVar "f", pVar "n", pVar "acc" ]
    , tipe = tLambda int2T (tLambda intT (tLambda intT intT))
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (varExpr "acc")
            (letExpr
                [ define "g" [] (callExpr (varExpr "f") [ intExpr 10 ]) ]
                (callExpr (varExpr "applyPartial")
                    [ varExpr "f"
                    , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , binopsExpr
                        [ ( callExpr (varExpr "g") [ varExpr "acc" ], "+" ) ]
                        (callExpr (varExpr "g") [ intExpr 1 ])
                    ]
                )
            )
    }


{-| testValue = let step = 7 in applyPartial (\a b -> a*100 + b*10 + step) 2 3 -}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = intT
    , body =
        letExpr
            [ define "step" [] (intExpr 7) ]
            (callExpr (varExpr "applyPartial")
                [ lambdaExpr [ pVar "a", pVar "b" ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 100), "+" )
                        , ( binopsExpr [ ( varExpr "b", "*" ) ] (intExpr 10), "+" )
                        ]
                        (varExpr "step")
                    )
                , intExpr 2
                , intExpr 3
                ]
            )
    }



-- GRAPH WALK ----------------------------------------------------------------


hasSingletonFnLetDef : Mono.MonoGraph -> Bool
hasSingletonFnLetDef (Mono.MonoGraph data) =
    Array.foldl (\mn found -> found || List.any exprHasSingletonFnLet (nodeExprs mn)) False data.nodes


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


exprHasSingletonFnLet : Mono.MonoExpr -> Bool
exprHasSingletonFnLet expr =
    MonoTraverse.foldExpr
        (\e acc ->
            acc
                || (case e of
                        Mono.MonoLet (Mono.MonoDef _ rhs) _ _ ->
                            case Mono.typeOf rhs of
                                Mono.MFunction (Mono.LSet [ _ ]) _ _ ->
                                    True

                                _ ->
                                    False

                        _ ->
                            False
                   )
        )
        False
        expr
