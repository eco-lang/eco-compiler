module TestLogic.Generate.CodeGen.SpinePapDispatchTest exposing (suite)

{-| LSS_013 spine injection + E4a local-multi use transport — activation pins.

Fixture (mirrors `test/elm/src/HofPapPrefixDispatchTest.elm` in the SourceIR
DSL): a capture-carrying 2-param lambda literal flows into a recursion-
protected HOF `applyPartial` (never inlined — SCC recursion guard). Inside,
`let g = f 10` is a PARTIAL application of that lambda.

The transport chain (plan §S.9) has three links, each pinned here:

1. SPINE (LSS_013): the lambda's member lands on the INNER arrow of its type,
   so the call `f 10` peels one arrow and its result — the let-binding `g` —
   carries `LSet [m]`. Pinned by the letdef assertion (RED under head-only
   injection).
2. INDIRECT-CALL-RESULT transport (`Translate.indirectResultAnno`): part of
   the same letdef assertion (the set must survive the `f 10` call boundary).
3. E4a local-multi USE transport (`Translate.enrichLocalMultiUses`, plan
   §9.1): `g` is a function-typed (local-multi) let, whose use sites are
   emitted from fresh all-`LTop` instantiations; E4a overlays the instance
   def's annos back onto them. Pinned by the use-site assertion (a call whose
   CALLEE `MonoVarLocal` carries a singleton `LSet` head) and by the STAMP
   assertion (`callInfo.fastPapPrefix == Just 1` — the E2 StampPap fired on
   `g acc`/`g 1`; the pipeline output is post-AbiCloning so stamps are
   visible). Both RED without E4a, GREEN with it.

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
    Test.describe "LSS_013 spine + E4a use transport activate PAP fast dispatch"
        [ Test.test "a partial-application let-binding carries a singleton lambda set (spine + call-result transport)" <|
            \_ ->
                expectOnGraph hasSingletonFnLetDef
                    "no function-typed let-binding carries a singleton LSet — spine injection + call-result transport did not reach `let g = f 10`"
        , Test.test "a use-site callee carries the singleton lambda set (E4a local-multi use transport)" <|
            \_ ->
                expectOnGraph hasSingletonCalleeUse
                    "no call's MonoVarLocal callee carries a singleton LSet head — E4a did not transport the def's set to the use sites"
        , Test.test "the PAP-consuming call is StampPap'd (fastPapPrefix = Just 1)" <|
            \_ ->
                expectOnGraph hasPapPrefixStamp
                    "no call carries callInfo.fastPapPrefix == Just 1 — the E2 StampPap did not fire on `g acc`"
        ]


expectOnGraph : (Mono.MonoGraph -> Bool) -> String -> Expect.Expectation
expectOnGraph predicate failureMsg =
    case Pipeline.runToGlobalOptLssOn fixtureModule of
        Err e ->
            Expect.fail ("solver+LSS pipeline failed: " ++ e)

        Ok { optimizedMonoGraph } ->
            if predicate optimizedMonoGraph then
                Expect.pass

            else
                Expect.fail failureMsg



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



-- GRAPH WALKS ---------------------------------------------------------------


anyGraphExpr : (Mono.MonoExpr -> Bool) -> Mono.MonoGraph -> Bool
anyGraphExpr predicate (Mono.MonoGraph data) =
    Array.foldl
        (\mn found ->
            found
                || List.any
                    (\e -> MonoTraverse.foldExpr (\sub acc -> acc || predicate sub) False e)
                    (nodeExprs mn)
        )
        False
        data.nodes


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


hasSingletonFnLetDef : Mono.MonoGraph -> Bool
hasSingletonFnLetDef =
    anyGraphExpr
        (\e ->
            case e of
                Mono.MonoLet (Mono.MonoDef _ rhs) _ _ ->
                    isSingletonFn (Mono.typeOf rhs)

                _ ->
                    False
        )


hasSingletonCalleeUse : Mono.MonoGraph -> Bool
hasSingletonCalleeUse =
    -- Specifically the PAP-CONSUMING shape (`g acc`): singleton callee whose
    -- result is GROUND. The `f 10` site also has a singleton callee (M3 arg
    -- transport, pre-E4a) but its result is a function — excluded here so this
    -- pin is RED without E4a.
    anyGraphExpr
        (\e ->
            case e of
                Mono.MonoCall _ (Mono.MonoVarLocal _ t) _ _ _ ->
                    case t of
                        Mono.MFunction (Mono.LSet [ _ ]) _ ret ->
                            not (isFn ret)

                        _ ->
                            False

                _ ->
                    False
        )


hasPapPrefixStamp : Mono.MonoGraph -> Bool
hasPapPrefixStamp =
    anyGraphExpr
        (\e ->
            case e of
                Mono.MonoCall _ _ _ _ callInfo ->
                    callInfo.fastPapPrefix == Just 1

                _ ->
                    False
        )


isSingletonFn : Mono.MonoType -> Bool
isSingletonFn t =
    case t of
        Mono.MFunction (Mono.LSet [ _ ]) _ _ ->
            True

        _ ->
            False


isFn : Mono.MonoType -> Bool
isFn t =
    case t of
        Mono.MFunction _ _ _ ->
            True

        _ ->
            False
