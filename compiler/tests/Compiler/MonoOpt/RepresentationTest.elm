module Compiler.MonoOpt.RepresentationTest exposing (suite)

{-| Tests for `Compiler.MonoOpt.Representation`, the one-loop node rewrite of
the representation passes (plans/constructor-representation-levels.md §13,
R3).

The tests establish, on a program with a wrapper inside a `Maybe` (`type W = W
{ n : Int }`, a `case` on `Just (W r)`, built with `Just (W ...)` and
`Nothing`):

  - `Representation.run` with the erasure plan and the nullable choice gives
    the same nodes, the same nullable table and the same counts as
    `EraseWrappers.erase` followed by `NullableMaybe.run` on the erased graph;
  - it erases `W`, makes the `Maybe` nullable and rewrites at least one
    decision-tree test, so the comparison is not between two graphs left
    alone;
  - a function that mentions neither an erased nor a nullable type (`inc :
    Int -> Int`) is not visited (R4), and every node the loop does not visit
    is returned as the same value.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , accessExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Array
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Compiler.MonoOpt.EraseWrappers as EraseWrappers
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Compiler.MonoOpt.Representation as Representation
import Compiler.Monomorphize.RepresentationMeets as RepresentationMeets
import Expect
import Set
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    describe "Compiler.MonoOpt.Representation"
        [ test "one loop gives what erase then the nullable pass give" <|
            \_ ->
                case Pipeline.runToMonoWith (Pipeline.withoutReprPasses Pipeline.productionConfig) program of
                    Err msg ->
                        Expect.fail ("Compilation failed: " ++ msg)

                    Ok { globalTypeEnv, monoGraph } ->
                        let
                            kv =
                                KernelVisible.compute globalTypeEnv monoGraph

                            meets =
                                RepresentationMeets.collect monoGraph

                            opts =
                                { allowUnboxed = False, meetsOk = identity, meets = meets }

                            nullOpts =
                                { userTypes = False }

                            -- Two passes, one after the other.
                            ( erased, eraseStats1, e ) =
                                EraseWrappers.eraseKeeping opts kv monoGraph

                            kvErased =
                                EraseWrappers.translateKv e kv

                            meetsErased =
                                RepresentationMeets.translate (EraseWrappers.eraseType e) meets

                            ( Mono.MonoGraph sequential, nullStats1 ) =
                                NullableMaybe.run nullOpts kvErased meetsErased erased

                            -- One loop.
                            plan =
                                EraseWrappers.plan opts kv monoGraph

                            ( Mono.MonoGraph fused, eraseStats2, nullStats2 ) =
                                Representation.run plan (Just (NullableMaybe.choose nullOpts kvErased meetsErased plan.ctorShapes)) monoGraph

                            nullableKeys g =
                                Mono.layoutMapFoldl (\t _ acc -> Mono.toComparableLayoutType t :: acc) [] g.repr.nullable
                        in
                        Expect.all
                            [ \_ -> Expect.equal eraseStats1.erasedCtors 1
                            , \_ -> Expect.equal (List.length (nullableKeys fused)) 1
                            , \_ -> Expect.equal (Maybe.map (\s -> s.testsRewritten > 0) nullStats2) (Just True)
                            , \_ -> Expect.equal eraseStats2 eraseStats1
                            , \_ -> Expect.equal nullStats2 (Just nullStats1)
                            , \_ -> Expect.equal (nullableKeys fused) (nullableKeys sequential)
                            , \_ -> Expect.equal fused.nodes sequential.nodes
                            , \_ -> Expect.equal fused.callEdges sequential.callEdges
                            , \_ -> Expect.equal fused.nextLambdaIndex sequential.nextLambdaIndex
                            ]
                            ()
        , test "a node that mentions no affected type is not visited, and comes back the same" <|
            \_ ->
                case Pipeline.runToMonoWith (Pipeline.withoutReprPasses Pipeline.productionConfig) program of
                    Err msg ->
                        Expect.fail ("Compilation failed: " ++ msg)

                    Ok { globalTypeEnv, monoGraph } ->
                        let
                            kv =
                                KernelVisible.compute globalTypeEnv monoGraph

                            meets =
                                RepresentationMeets.collect monoGraph

                            plan =
                                EraseWrappers.plan { allowUnboxed = False, meetsOk = identity, meets = meets } kv monoGraph

                            rewritten =
                                EraseWrappers.rewriteNodes plan (\_ -> False) (\x _ -> ( Nothing, x )) () monoGraph

                            (Mono.MonoGraph g) =
                                monoGraph

                            -- The SpecIds of the defined functions whose type is `Int -> Int`: `inc`.
                            incSpecs =
                                Array.toIndexedList g.nodes
                                    |> List.filterMap
                                        (\( i, n ) ->
                                            case n of
                                                Just (Mono.MonoDefine _ (Mono.MFunction _ _ [ Mono.MInt ] Mono.MInt)) ->
                                                    Just i

                                                _ ->
                                                    Nothing
                                        )

                            unvisitedSame =
                                Array.toIndexedList g.nodes
                                    |> List.all
                                        (\( i, n ) ->
                                            Set.member i rewritten.visited || Array.get i rewritten.nodes == Just n
                                        )
                        in
                        Expect.all
                            [ \_ -> Expect.equal (Set.isEmpty rewritten.visited) False
                            , \_ -> Expect.notEqual incSpecs []
                            , \_ -> Expect.equal (List.filter (\i -> Set.member i rewritten.visited) incSpecs) []
                            , \_ -> Expect.equal unvisitedSame True
                            ]
                            ()
        ]


{-| `type W = W { n : Int }`, `get : Maybe W -> Int` (a case on `Just (W r)`),
`inc : Int -> Int`, `testValue = get (Just (W { n = 1 })) + inc 2`.
-}
program : Src.Module
program =
    let
        tW =
            tType "W" []

        get : TypedDef
        get =
            { name = "get"
            , args = [ pVar "m" ]
            , tipe = tLambda (tType "Maybe" [ tW ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Just" [ pCtor "W" [ pVar "r" ] ], accessExpr (varExpr "r") "n" )
                    , ( pAnything, intExpr 0 )
                    ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ get
        , { name = "inc"
          , args = [ pVar "x" ]
          , tipe = tLambda (tType "Int" []) (tType "Int" [])
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "get")
                            [ callExpr (ctorExpr "Just") [ callExpr (ctorExpr "W") [ recordExpr [ ( "n", intExpr 1 ) ] ] ] ]
                      , "+"
                      )
                    ]
                    (callExpr (varExpr "inc") [ intExpr 2 ])
          }
        ]
        [ { name = "W", args = [], ctors = [ { name = "W", args = [ tRecord [ ( "n", tType "Int" [] ) ] ] } ] } ]
        []
