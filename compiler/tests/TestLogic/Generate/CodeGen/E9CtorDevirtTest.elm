module TestLogic.Generate.CodeGen.E9CtorDevirtTest exposing (suite)

{-| E9 / LSS_015 ctor devirtualization — activation pin.

Fixture: a `Can.Normal` two-arg ctor (the `List.::` analog — general ctors
become `VarGlobal`/"g|" members, NOT VarEnum/VarBox) passed as a function
value to a recursion-protected HOF:

    type Pair = P Int Int | Q
    applyP f n = if n <= 0 then f (n + 3) (n + 4) else applyP f (n - 1)
    testValue = unwrap (applyP P 2)

The `f (n+3) (n+4)` site is an indirect call whose callee var carries the
singleton {g|Test.P}; E9 rewrites the callee to the ctor reference, so the
graph's ONLY VarLocal-callee call disappears (the dispatch is REMOVED — the
call becomes a direct `MonoVarGlobal` ctor call). The pin asserts NO
MonoCall with a `MonoVarLocal` callee remains. RED with the devirt
neutralized. The ctor arg is not a lambda literal, so H5 loopification
never applies (tail recursion is safe here).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , ifExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
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
    Test.describe "E9: ctor passed as function devirtualizes to a direct call"
        [ Test.test "no VarLocal-callee call remains (the f-site became a direct ctor call)" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph } ->
                        case indirectCallCount optimizedMonoGraph of
                            0 ->
                                Expect.pass

                            n ->
                                Expect.fail
                                    (String.fromInt n
                                        ++ " VarLocal-callee call(s) remain — E9 did not devirtualize `f (n+3) (n+4)`"
                                    )
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


intT : Src.Type
intT =
    tType "Int" []


pairT : Src.Type
pairT =
    tType "Pair" []


fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ applyPDef, testValueDef ]
        [ { name = "Pair"
          , args = []
          , ctors =
                [ { name = "P", args = [ intT, intT ] }
                , { name = "Q", args = [] }
                ]
          }
        ]
        []


{-| applyP f n = if n <= 0 then f (n + 3) (n + 4) else applyP f (n - 1) -}
applyPDef : TypedDef
applyPDef =
    { name = "applyP"
    , args = [ pVar "f", pVar "n" ]
    , tipe = tLambda (tLambda intT (tLambda intT pairT)) (tLambda intT pairT)
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (callExpr (varExpr "f")
                [ binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 3)
                , binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 4)
                ]
            )
            (callExpr (varExpr "applyP")
                [ varExpr "f"
                , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                ]
            )
    }


{-| testValue = case applyP P 2 of P a b -> a + b; Q -> 0 - 1 -}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = intT
    , body =
        caseExpr (callExpr (varExpr "applyP") [ ctorExpr "P", intExpr 2 ])
            [ ( pCtor "P" [ pVar "a", pVar "b" ]
              , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
              )
            , ( pCtor "Q" []
              , binopsExpr [ ( intExpr 0, "-" ) ] (intExpr 1)
              )
            ]
    }



-- GRAPH WALK ----------------------------------------------------------------


indirectCallCount : Mono.MonoGraph -> Int
indirectCallCount (Mono.MonoGraph data) =
    Array.foldl
        (\mn acc ->
            List.foldl
                (\e a -> MonoTraverse.foldExpr countIndirect a e)
                acc
                (nodeExprs mn)
        )
        0
        data.nodes


countIndirect : Mono.MonoExpr -> Int -> Int
countIndirect e acc =
    case e of
        Mono.MonoCall _ (Mono.MonoVarLocal _ _) _ _ _ ->
            acc + 1

        _ ->
            acc


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
