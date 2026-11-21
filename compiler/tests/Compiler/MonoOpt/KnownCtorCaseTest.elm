module Compiler.MonoOpt.KnownCtorCaseTest exposing (suite)

{-| Tests for `Compiler.MonoOpt.KnownCtorCase` (plans/constructor-representation-levels.md
§8, K0 and K1), on a program monomorphized with the representation passes off:

    type Work = WorkA Int | WorkB Int Int | Idle
    type Holder = Full Work | Empty

    direct x = let w = WorkA x in case w of WorkA n -> n ; _ -> 0
    callArg x = let w = WorkB (x * 3) 1 in case w of WorkB a _ -> a ; _ -> 0
    nested x = let m = Full (WorkA x) in case m of Full (WorkA n) -> n ; _ -> 0
    enum x = let w = Idle in case w of Idle -> x ; _ -> 0
    wrapped x = let w = (let a = x + 1 in WorkB a a) in case w of WorkB p _ -> p ; _ -> 0

A local `Holder` stands in for `Maybe`: in this test pipeline the elm/core
constructors are externs (interfaces only), with no constructor node to know.

The tests establish:

  - the census (`fold = False`) counts every `case` on a let-bound constructor
    value, how many have only trivial arguments, and how many are decided by
    root tests alone, and changes nothing;
  - with `fold = True` the sites with trivial arguments and root-only tests are
    folded (`direct`, `enum` and `wrapped`), and their bindings, used by nothing
    else after the fold, are dropped; `callArg` (an argument that is a call) and
    `nested` (a test on a field) are left alone;
  - a constructor call at the end of a `let` chain, the shape inlining a function that builds
    the value leaves (`wrapped`), is a site: the chain's bindings are floated above the
    constructor's binding;
  - after the fold no `case` in the graph still scrutinizes a folded binding.

-}

import Array
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as Traverse
import Compiler.IR.Source as Src
import Compiler.MonoOpt.KnownCtorCase as KnownCtorCase
import Expect
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


tInt : Src.Type
tInt =
    tType "Int" []


program : Src.Module
program =
    let
        work : UnionDef
        work =
            { name = "Work"
            , args = []
            , ctors =
                [ { name = "WorkA", args = [ tInt ] }
                , { name = "WorkB", args = [ tInt, tInt ] }
                , { name = "Idle", args = [] }
                ]
            }

        holder : UnionDef
        holder =
            { name = "Holder"
            , args = []
            , ctors = [ { name = "Full", args = [ tType "Work" [] ] }, { name = "Empty", args = [] } ]
            }

        fn name body =
            { name = name, args = [ pVar "x" ], tipe = tLambda tInt tInt, body = body }

        direct : TypedDef
        direct =
            fn "direct"
                (letExpr [ define "w" [] (callExpr (ctorExpr "WorkA") [ varExpr "x" ]) ]
                    (caseExpr (varExpr "w") [ ( pCtor "WorkA" [ pVar "n" ], varExpr "n" ), ( pAnything, intExpr 0 ) ])
                )

        callArg : TypedDef
        callArg =
            fn "callArg"
                (letExpr [ define "w" [] (callExpr (ctorExpr "WorkB") [ binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 3), intExpr 1 ]) ]
                    (caseExpr (varExpr "w") [ ( pCtor "WorkB" [ pVar "a", pAnything ], varExpr "a" ), ( pAnything, intExpr 0 ) ])
                )

        nested : TypedDef
        nested =
            fn "nested"
                (letExpr [ define "m" [] (callExpr (ctorExpr "Full") [ callExpr (ctorExpr "WorkA") [ varExpr "x" ] ]) ]
                    (caseExpr (varExpr "m") [ ( pCtor "Full" [ pCtor "WorkA" [ pVar "n" ] ], varExpr "n" ), ( pAnything, intExpr 0 ) ])
                )

        enum : TypedDef
        enum =
            fn "enum"
                (letExpr [ define "w" [] (ctorExpr "Idle") ]
                    (caseExpr (varExpr "w") [ ( pCtor "Idle" [], varExpr "x" ), ( pAnything, intExpr 0 ) ])
                )

        wrapped : TypedDef
        wrapped =
            fn "wrapped"
                (letExpr
                    [ define "w"
                        []
                        (letExpr [ define "a" [] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)) ]
                            (callExpr (ctorExpr "WorkB") [ varExpr "a", varExpr "a" ])
                        )
                    ]
                    (caseExpr (varExpr "w") [ ( pCtor "WorkB" [ pVar "p", pAnything ], varExpr "p" ), ( pAnything, intExpr 0 ) ])
                )

        testValue : TypedDef
        testValue =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                binopsExpr
                    [ ( callExpr (varExpr "direct") [ intExpr 1 ], "+" )
                    , ( callExpr (varExpr "callArg") [ intExpr 2 ], "+" )
                    , ( callExpr (varExpr "nested") [ intExpr 3 ], "+" )
                    , ( callExpr (varExpr "wrapped") [ intExpr 5 ], "+" )
                    ]
                    (callExpr (varExpr "enum") [ intExpr 4 ])
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod" [ direct, callArg, nested, enum, wrapped, testValue ] [ work, holder ] []


graph : () -> Result String Mono.MonoGraph
graph _ =
    Pipeline.runToMonoWith (Pipeline.withoutReprPasses Pipeline.productionConfig) program
        |> Result.map .monoGraph


{-| The names every `case` in the graph scrutinizes.
-}
scrutinees : Mono.MonoGraph -> List String
scrutinees (Mono.MonoGraph g) =
    Array.toList g.nodes
        |> List.filterMap identity
        |> List.concatMap
            (\node ->
                case node of
                    Mono.MonoDefine e _ ->
                        Traverse.foldExpr
                            (\sub acc ->
                                case sub of
                                    Mono.MonoCase _ x _ _ _ ->
                                        x :: acc

                                    _ ->
                                        acc
                            )
                            []
                            e

                    _ ->
                        []
            )


suite : Test
suite =
    describe "Compiler.MonoOpt.KnownCtorCase"
        [ test "the census counts the sites and changes nothing" <|
            \_ ->
                case graph () of
                    Err msg ->
                        Expect.fail msg

                    Ok g ->
                        let
                            ( g1, stats ) =
                                KnownCtorCase.run { fold = False } g
                        in
                        Expect.all
                            [ \_ -> Expect.equal stats.sites 5
                            , \_ -> Expect.equal stats.trivialArgs 3
                            , \_ -> Expect.equal stats.rootOnly 4
                            , \_ -> Expect.equal stats.folded 0
                            , \_ -> Expect.equal (scrutinees g1) (scrutinees g)
                            ]
                            ()
        , test "the fold takes the trivial, root-only sites and drops their bindings" <|
            \_ ->
                case graph () of
                    Err msg ->
                        Expect.fail msg

                    Ok g ->
                        let
                            ( g1, stats ) =
                                KnownCtorCase.run { fold = True } g
                        in
                        Expect.all
                            [ \_ -> Expect.equal stats.folded 3
                            , \_ -> Expect.equal stats.bindingsDropped 3
                            , \_ -> Expect.equal (List.length (scrutinees g1)) (List.length (scrutinees g) - 3)
                            ]
                            ()
        ]
