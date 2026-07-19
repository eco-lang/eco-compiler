module TestLogic.Generate.CodeGen.E92ConsDevirtTest exposing (suite)

{-| E9.2 / LSS_016 kernel devirtualization — activation pin.

Fixture: `(::)` — the kernel value `TOpt.VarKernel "List" "cons"` after the
optimizer's cons special-casing — passed as a function value to a
recursion-protected HOF:

    applyCons f n = if n <= 0 then f (n + 3) [] else applyCons f (n - 1)
    testValue = applyCons (::) 2

The `f (n+3) []` site is an indirect call whose callee var carries the
singleton {k|List.cons}; E9.2 rewrites it to the direct kernel call form a
written-out `x :: xs` produces. The pin asserts BOTH directions: no
`MonoVarLocal`-callee call remains, and a `MonoVarKernel List cons`-callee
call EXISTS (the rewrite landed; the site did not merely vanish). RED with
`devirtKernelTarget` neutralized. The kernel arg is not a lambda literal,
so H5 loopification never applies (tail recursion is safe here).

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
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , opExpr
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Data.Map
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "E9.2: (::) passed as function devirtualizes to a direct kernel call"
        [ Test.test "the f-site became a direct List.cons kernel call" <|
            \_ ->
                case Pipeline.runToGlobalOptLssOn fixtureModule of
                    Err e ->
                        Expect.fail ("solver+LSS pipeline failed: " ++ e)

                    Ok { optimizedMonoGraph, globalGraph } ->
                        case ( indirectCallCount optimizedMonoGraph, kernelConsCallCount optimizedMonoGraph ) of
                            ( 0, 0 ) ->
                                Expect.fail "no VarLocal-callee call remains, but no List.cons kernel call either — the site vanished instead of devirtualizing"

                            ( 0, _ ) ->
                                Expect.pass

                            ( n, _ ) ->
                                Expect.fail
                                    (String.fromInt n
                                        ++ " VarLocal-callee call(s) remain — E9.2 did not devirtualize `f (n+3) []`; callee annos: "
                                        ++ String.join ", " (indirectCalleeAnnos optimizedMonoGraph)
                                        ++ "; cons node keys: "
                                        ++ String.join " | " (consNodeKeys globalGraph)
                                    )
        ]



-- FIXTURE (DSL) -------------------------------------------------------------


intT : Src.Type
intT =
    tType "Int" []


listIntT : Src.Type
listIntT =
    tType "List" [ intT ]


fixtureModule : Src.Module
fixtureModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ applyConsDef, testValueDef ]
        []
        []


{-| applyCons f n = if n <= 0 then f (n + 3) [] else applyCons f (n - 1) -}
applyConsDef : TypedDef
applyConsDef =
    { name = "applyCons"
    , args = [ pVar "f", pVar "n" ]
    , tipe = tLambda (tLambda intT (tLambda listIntT listIntT)) (tLambda intT listIntT)
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (callExpr (varExpr "f")
                [ binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 3)
                , listExpr []
                ]
            )
            (callExpr (varExpr "applyCons")
                [ varExpr "f"
                , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                ]
            )
    }


{-| testValue = applyCons (::) 2 -}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = listIntT
    , body = callExpr (varExpr "applyCons") [ opExpr "::", intExpr 2 ]
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


{-| Diagnostic for the failure message: the head annotation of every
surviving VarLocal-callee, rendered.
-}
indirectCalleeAnnos : Mono.MonoGraph -> List String
indirectCalleeAnnos (Mono.MonoGraph data) =
    Array.foldl
        (\mn acc ->
            List.foldl
                (\e a -> MonoTraverse.foldExpr collectCalleeAnno a e)
                acc
                (nodeExprs mn)
        )
        []
        data.nodes


collectCalleeAnno : Mono.MonoExpr -> List String -> List String
collectCalleeAnno e acc =
    case e of
        Mono.MonoCall _ (Mono.MonoVarLocal name t) _ _ _ ->
            (name ++ ":" ++ renderAnno (Mono.headAnno t)) :: acc

        _ ->
            acc


{-| Diagnostic: every node key mentioning "cons" in the assembled
GlobalGraph (is the synthesized kernel-alias node present, and under which
comparable-Global key?).
-}
consNodeKeys : TOpt.GlobalGraph n -> List String
consNodeKeys (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl (\_ _ -> EQ) (\g _ acc -> TOpt.toComparableGlobal g :: acc) [] nodes
        |> List.filter (String.contains "cons")


renderAnno : Mono.LambdaSetAnno -> String
renderAnno anno =
    case anno of
        Mono.LTop ->
            "LTop"

        Mono.LSet ms ->
            "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"


kernelConsCallCount : Mono.MonoGraph -> Int
kernelConsCallCount (Mono.MonoGraph data) =
    Array.foldl
        (\mn acc ->
            List.foldl
                (\e a -> MonoTraverse.foldExpr countKernelCons a e)
                acc
                (nodeExprs mn)
        )
        0
        data.nodes


countKernelCons : Mono.MonoExpr -> Int -> Int
countKernelCons e acc =
    case e of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ home name _) _ _ _ ->
            if home == "List" && name == "cons" then
                acc + 1

            else
                acc

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
