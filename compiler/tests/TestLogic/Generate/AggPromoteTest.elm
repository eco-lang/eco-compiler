module TestLogic.Generate.AggPromoteTest exposing (suite)

{-| U-T1.3.1 aggregate promotion (`plans/opt-tier1-aggregate-promotion.md`):
unit gate for the per-def escape walk `Expr.tupleBinderPromotable`.

Source-first fixtures (SourceBuilder → full pipeline → GlobalOpt): a def
with a promotable let-bound tuple (only destructured), one whose tuple
escapes via return, and one whose tuple escapes into a call. The verdicts
are checked on the real post-GlobalOpt AST — the same shapes emission sees.
No `main`: all defs stay roots (BorrowTailCallEscapeTest idiom), so the
inliner cannot dissolve the fixtures.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.SourceBuilder as B
import Compiler.Generate.MLIR.Expr as Expr
import Expect
import Dict
import Set
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "U-T1.3.1 tupleBinderPromotable"
        [ Test.test "promotable: let-bound tuple only destructured" <|
            \_ ->
                expectVerdict "good" (Just True)
        , Test.test "escaping: let-bound tuple returned" <|
            \_ ->
                expectVerdict "bad" (Just False)
        , Test.test "escaping: let-bound tuple passed to a call" <|
            \_ ->
                expectVerdict "passed" (Just False)
        , Test.test "T1.3.1b promotable: tuple destructured via case scrutinee" <|
            \_ ->
                expectVerdict "caseGood" (Just True)
        , Test.test "T1.3.1b promotable: nested-pattern case (element test projects through the root)" <|
            \_ ->
                expectVerdict "caseNested" (Just True)
        , Test.test "T1.3.1b escaping: case-scrutinized tuple ALSO passed to a call" <|
            \_ ->
                expectVerdict "caseAndPass" (Just False)
        , Test.test "T1.3.2 promotable: single-ctor custom built and cased locally" <|
            \_ ->
                expectCtorVerdict "ctorGood" (Just True)
        , Test.test "T1.3.2 escaping: ctor call passed to a call" <|
            \_ ->
                expectCtorVerdict "ctorBad" (Just False)
        , Test.test "T1.3.2 escaping: multi-ctor candidate is rejected (tag dispatch on root)" <|
            \_ ->
                expectCtorVerdict "ctorMulti" (Just False)
        , Test.test "T1.3.2r escaping: ctor captured by a returned lambda" <|
            \_ ->
                expectCtorVerdict "ctorCap" (Just False)
        ]


{-| T1.3.2: find the def's first `MonoLet x (MonoCall ctor ...)` where the
callee resolves to a `MonoCtor` node, and run the kind-generic walker with
`CustomContainer <ctor>` (the same check `promotableCtorCall` performs).
-}
expectCtorVerdict : String -> Maybe Bool -> Expect.Expectation
expectCtorVerdict defName expected =
    case Pipeline.runToGlobalOpt fixtureModule of
        Err msg ->
            Expect.fail ("pipeline: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                (Mono.MonoGraph { nodes, registry }) =
                    optimizedMonoGraph

                ctorShapeOf specId =
                    case Array.get specId nodes of
                        Just (Just (Mono.MonoCtor shape _)) ->
                            Just shape

                        _ ->
                            Nothing

                verdict =
                    Array.foldl
                        (\( maybeName, maybeNode ) acc ->
                            case acc of
                                Just _ ->
                                    acc

                                Nothing ->
                                    case ( maybeName, maybeNode ) of
                                        ( Just ( g, _ ), Just node ) ->
                                            if String.contains defName (Mono.toComparableGlobal g) then
                                                nodeCtorVerdict ctorShapeOf node

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                        )
                        Nothing
                        (zipArrays registry.reverseMapping nodes)
            in
            verdict |> Expect.equal expected


nodeCtorVerdict : (Int -> Maybe Mono.CtorShape) -> Mono.MonoNode -> Maybe Bool
nodeCtorVerdict ctorShapeOf node =
    case node of
        Mono.MonoDefine body _ ->
            findCtorLet ctorShapeOf body

        Mono.MonoTailFunc _ body _ ->
            findCtorLet ctorShapeOf body

        _ ->
            Nothing


findCtorLet : (Int -> Maybe Mono.CtorShape) -> Mono.MonoExpr -> Maybe Bool
findCtorLet ctorShapeOf expr =
    case expr of
        Mono.MonoClosure _ inner _ ->
            findCtorLet ctorShapeOf inner

        Mono.MonoLet (Mono.MonoDef x (Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ _)) body _ ->
            case ctorShapeOf specId of
                Just shape ->
                    Just (Expr.aggBinderPromotableWith (Mono.CustomContainer shape.name) x body)

                Nothing ->
                    findCtorLet ctorShapeOf body

        Mono.MonoLet _ body _ ->
            findCtorLet ctorShapeOf body

        Mono.MonoDestruct _ body _ ->
            findCtorLet ctorShapeOf body

        _ ->
            Nothing


expectVerdict : String -> Maybe Bool -> Expect.Expectation
expectVerdict defName expected =
    case Pipeline.runToGlobalOpt fixtureModule of
        Err msg ->
            Expect.fail ("pipeline: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                (Mono.MonoGraph { nodes, registry }) =
                    optimizedMonoGraph

                -- specId → comparable global name (registry order = node order)
                verdict =
                    Array.foldl
                        (\( maybeName, maybeNode ) acc ->
                            case acc of
                                Just _ ->
                                    acc

                                Nothing ->
                                    case ( maybeName, maybeNode ) of
                                        ( Just ( g, _ ), Just node ) ->
                                            if String.contains defName (Mono.toComparableGlobal g) then
                                                nodeVerdict node

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                        )
                        Nothing
                        (zipArrays registry.reverseMapping nodes)
            in
            verdict |> Expect.equal expected


zipArrays : Array.Array a -> Array.Array b -> Array.Array ( a, b )
zipArrays xs ys =
    Array.indexedMap
        (\i x ->
            case Array.get i ys of
                Just y ->
                    Just ( x, y )

                Nothing ->
                    Nothing
        )
        xs
        |> Array.foldr
            (\m acc ->
                case m of
                    Just p ->
                        p :: acc

                    Nothing ->
                        acc
            )
            []
        |> Array.fromList


nodeVerdict : Mono.MonoNode -> Maybe Bool
nodeVerdict node =
    case node of
        Mono.MonoDefine body _ ->
            findTupleLet body

        Mono.MonoTailFunc _ body _ ->
            findTupleLet body

        _ ->
            Nothing


{-| First `MonoLet (MonoDef x (MonoTupleCreate ...)) body` in the def
(searching through the closure wrapper and let/destruct spine) → the
checker's verdict on it.
-}
findTupleLet : Mono.MonoExpr -> Maybe Bool
findTupleLet expr =
    case expr of
        Mono.MonoClosure _ inner _ ->
            findTupleLet inner

        Mono.MonoLet (Mono.MonoDef x (Mono.MonoTupleCreate _ _ tupleTy)) body _ ->
            Just (Expr.tupleBinderPromotable Dict.empty Dict.empty Set.empty x tupleTy body)

        Mono.MonoLet _ body _ ->
            findTupleLet body

        Mono.MonoDestruct _ body _ ->
            findTupleLet body

        _ ->
            Nothing


{-| good a b = let t = (a*2, b*3); (x, y) = t in x + y
bad a b = let t = (a*2, b*3) in t -- escapes via return
passed a b = let t = (a*2, b*3) in useTuple t -- escapes into a call
useTuple p = case p of (x, y) -> x + y
-}
fixtureModule =
    let
        intType =
            B.tType "Int" []

        tupleTy =
            B.tTuple intType intType

        mkTuple =
            B.tupleExpr
                (B.binopsExpr [ ( B.varExpr "a", "*" ) ] (B.intExpr 2))
                (B.binopsExpr [ ( B.varExpr "b", "*" ) ] (B.intExpr 3))

        goodBody =
            B.letExpr
                [ B.define "t" [] mkTuple
                , B.destruct (B.pTuple (B.pVar "x") (B.pVar "y")) (B.varExpr "t")
                ]
                (B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y"))

        badBody =
            B.letExpr [ B.define "t" [] mkTuple ] (B.varExpr "t")

        passedBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.callExpr (B.varExpr "useTuple") [ B.varExpr "t" ])

        useTupleBody =
            B.caseExpr (B.varExpr "p")
                [ ( B.pTuple (B.pVar "x") (B.pVar "y")
                  , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                  )
                ]

        caseGoodBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.caseExpr (B.varExpr "t")
                    [ ( B.pTuple (B.pVar "x") (B.pVar "y")
                      , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                      )
                    ]
                )

        caseNestedBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.caseExpr (B.varExpr "t")
                    [ ( B.pTuple (B.pInt 0) (B.pVar "y")
                      , B.varExpr "y"
                      )
                    , ( B.pTuple (B.pVar "x") B.pAnything
                      , B.varExpr "x"
                      )
                    ]
                )

        caseAndPassBody =
            B.letExpr [ B.define "t" [] mkTuple ]
                (B.binopsExpr
                    [ ( B.caseExpr (B.varExpr "t")
                            [ ( B.pTuple (B.pVar "x") B.pAnything
                              , B.varExpr "x"
                              )
                            ]
                      , "+"
                      )
                    ]
                    (B.callExpr (B.varExpr "useTuple") [ B.varExpr "t" ])
                )
        ctorGoodBody =
            B.letExpr [ B.define "p" [] (B.callExpr (B.ctorExpr "MkPair") [ B.varExpr "a", B.varExpr "b" ]) ]
                (B.caseExpr (B.varExpr "p")
                    [ ( B.pCtor "MkPair" [ B.pVar "x", B.pVar "y" ]
                      , B.binopsExpr [ ( B.varExpr "x", "+" ) ] (B.varExpr "y")
                      )
                    ]
                )

        ctorBadBody =
            B.letExpr [ B.define "p" [] (B.callExpr (B.ctorExpr "MkPair") [ B.varExpr "a", B.varExpr "b" ]) ]
                (B.callExpr (B.varExpr "usePair") [ B.varExpr "p" ])

        ctorMultiBody =
            B.letExpr [ B.define "m" [] (B.callExpr (B.ctorExpr "Yes") [ B.varExpr "a" ]) ]
                (B.caseExpr (B.varExpr "m")
                    [ ( B.pCtor "Yes" [ B.pVar "x" ], B.varExpr "x" )
                    , ( B.pCtor "No" [ B.pVar "y" ], B.varExpr "y" )
                    ]
                )

        ctorCapBody =
            B.letExpr [ B.define "p" [] (B.callExpr (B.ctorExpr "MkPair") [ B.varExpr "a", B.varExpr "b" ]) ]
                (B.lambdaExpr [ B.pVar "n" ]
                    (B.binopsExpr [ ( B.callExpr (B.varExpr "usePair") [ B.varExpr "p" ], "+" ) ] (B.varExpr "n"))
                )

        pairTy =
            B.tType "Pair" []

        unions =
            [ { name = "Pair"
              , args = []
              , ctors = [ { name = "MkPair", args = [ intType, intType ] } ]
              }
            , { name = "MB"
              , args = []
              , ctors =
                    [ { name = "Yes", args = [ intType ] }
                    , { name = "No", args = [ intType ] }
                    ]
              }
            ]
    in
    B.makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "good"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = goodBody
          }
        , { name = "bad"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType tupleTy)
          , body = badBody
          }
        , { name = "passed"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = passedBody
          }
        , { name = "useTuple"
          , args = [ B.pVar "p" ]
          , tipe = B.tLambda tupleTy intType
          , body = useTupleBody
          }
        , { name = "caseGood"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = caseGoodBody
          }
        , { name = "caseNested"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = caseNestedBody
          }
        , { name = "caseAndPass"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = caseAndPassBody
          }
        , { name = "ctorGood"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = ctorGoodBody
          }
        , { name = "ctorBad"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType intType)
          , body = ctorBadBody
          }
        , { name = "usePair"
          , args = [ B.pVar "q" ]
          , tipe = B.tLambda pairTy intType
          , body =
                B.caseExpr (B.varExpr "q")
                    [ ( B.pCtor "MkPair" [ B.pVar "ux", B.pVar "uy" ]
                      , B.binopsExpr [ ( B.varExpr "ux", "+" ) ] (B.varExpr "uy")
                      )
                    ]
          }
        , { name = "ctorMulti"
          , args = [ B.pVar "a" ]
          , tipe = B.tLambda intType intType
          , body = ctorMultiBody
          }
        , { name = "ctorCap"
          , args = [ B.pVar "a", B.pVar "b" ]
          , tipe = B.tLambda intType (B.tLambda intType (B.tLambda intType intType))
          , body = ctorCapBody
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body =
                B.binopsExpr
                    [ ( B.callExpr (B.varExpr "good") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "passed") [ B.intExpr 3, B.intExpr 4 ], "+" )
                    , ( B.callExpr (B.varExpr "caseGood") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "caseNested") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "caseAndPass") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "ctorGood") [ B.intExpr 1, B.intExpr 2 ], "+" )
                    , ( B.callExpr (B.varExpr "ctorMulti") [ B.intExpr 3 ], "+" )
                    , ( B.callExpr (B.varExpr "ctorBad") [ B.intExpr 4, B.intExpr 5 ], "+" )
                    , ( B.callExpr (B.callExpr (B.varExpr "ctorCap") [ B.intExpr 1, B.intExpr 2 ]) [ B.intExpr 3 ], "+" )
                    ]
                    (B.callExpr (B.varExpr "useTuple") [ B.callExpr (B.varExpr "bad") [ B.intExpr 5, B.intExpr 6 ] ])
          }
        ]
        unions
        []
