module TestLogic.Generate.CodeGen.E2V2StagedDispatchTest exposing (suite)

{-| E2.7 / LSS_014 staged stamping — activation pin.

Fixture: a CURRIED lambda literal (`\a -> \b -> a*10 + b`, stage arities
[1,1]) flows into a recursion-protected HOF whose body OVER-applies it:

    applyStaged f n acc = if n <= 0 then acc else f 10 (applyStaged f (n-1) acc)
    testValue = applyStaged (\a -> \b -> a*10 + b) 2 3

The site `f 10 (…)` applies 2 args over the instance's 1-param first stage —
v1 declines it (`declinedShapeArityOver`); E2.7 stamps it (same fields as the
exact arm, `fastPapPrefix` absent) and emission splits fast-batch-1 +
generic remainder. NON-TAIL recursion on purpose (the E5-pin lesson: a
tail-recursive HOF with a saturated closure-param call is H5-loopified and
no dispatch survives).

The pin asserts a stamped call whose arg count EXCEEDS its captureAbi's
param count — the staged-stamp signature. RED before E2.7, GREEN after.

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


suite : Test
suite =
    Test.describe "E2.7: staged stamp fires on an over-applied singleton"
        [ Test.test "the over-apply site carries a staged stamp (args > captureAbi params)" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        if hasStagedStamp optimizedMonoGraph then
                            Expect.pass

                        else
                            Expect.fail
                                "no call carries a staged stamp (fastEvaluator set, |args| > |captureAbi.paramTypes|) — E2.7 did not fire on `f 10 (…)`"
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
    makeModuleWithTypedDefs "Test" [ applyStagedDef, testValueDef ]


{-| applyStaged f n acc = if n <= 0 then acc else f 10 (applyStaged f (n-1) acc) -}
applyStagedDef : TypedDef
applyStagedDef =
    { name = "applyStaged"
    , args = [ pVar "f", pVar "n", pVar "acc" ]
    , tipe = tLambda (tLambda intT int1T) (tLambda intT (tLambda intT intT))
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (varExpr "acc")
            (callExpr (varExpr "f")
                [ intExpr 10
                , callExpr (varExpr "applyStaged")
                    [ varExpr "f"
                    , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , varExpr "acc"
                    ]
                ]
            )
    }


{-| testValue = applyStaged (\a -> \b -> a*10 + b) 2 3 -}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = intT
    , body =
        callExpr (varExpr "applyStaged")
            [ lambdaExpr [ pVar "a" ]
                (lambdaExpr [ pVar "b" ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 10), "+" ) ]
                        (varExpr "b")
                    )
                )
            , intExpr 2
            , intExpr 3
            ]
    }



-- GRAPH WALK ----------------------------------------------------------------


hasStagedStamp : Mono.MonoGraph -> Bool
hasStagedStamp (Mono.MonoGraph data) =
    Array.foldl
        (\mn found ->
            found
                || List.any
                    (\e -> MonoTraverse.foldExpr (\sub acc -> acc || isStagedStampedCall sub) False e)
                    (nodeExprs mn)
        )
        False
        data.nodes


isStagedStampedCall : Mono.MonoExpr -> Bool
isStagedStampedCall e =
    case e of
        Mono.MonoCall _ _ args _ callInfo ->
            case ( callInfo.fastEvaluator, callInfo.captureAbi ) of
                ( Just _, Just abi ) ->
                    List.length args > List.length abi.paramTypes

                _ ->
                    False

        _ ->
            False


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
