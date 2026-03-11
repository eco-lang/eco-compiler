module SourceIR.TailRecCaseCases exposing (expectSuite)

{-| Tests for tail-recursive functions with case expressions.

These exercise TailRec.compileCaseStep, compileDestructStep, and
compileCaseFanOutStep — the paths that caused the
mkCaseRegionFromDecider crash (CGEN_028 violation).

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pList
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tail-recursive case expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Tail-rec foldl with case on list", run = tailRecFoldl expectFn }
    , { label = "Tail-rec contains with if in case branch", run = tailRecContains expectFn }
    , { label = "Tail-rec sum with custom type", run = tailRecCustomTypeSum expectFn }
    , { label = "Tail-rec with nested case", run = tailRecNestedCase expectFn }
    , { label = "Tail-rec with wildcard destruct", run = tailRecWildcardDestruct expectFn }
    ]


{-| myFoldl func acc list = case list of [] -> acc; x :: xs -> myFoldl func (func x acc) xs
-}
tailRecFoldl : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecFoldl expectFn _ =
    let
        -- myFoldl f acc list = case list of [] -> acc ; x :: xs -> myFoldl f (f x acc) xs
        body =
            caseExpr (varExpr "list")
                [ ( pList [], varExpr "acc" )
                , ( pCons (pVar "x") (pVar "xs")
                  , callExpr (varExpr "myFoldl")
                        [ varExpr "f"
                        , callExpr (varExpr "f") [ varExpr "x", varExpr "acc" ]
                        , varExpr "xs"
                        ]
                  )
                ]

        myFoldl =
            define "myFoldl" [ pVar "f", pVar "acc", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ myFoldl ]
                    (callExpr (varExpr "myFoldl")
                        [ lambdaExpr [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                        , intExpr 0
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| contains target list = case list of [] -> False; x :: rest -> if x == target then True else contains target rest
-}
tailRecContains : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecContains expectFn _ =
    let
        body =
            caseExpr (varExpr "list")
                [ ( pList [], ctorExpr "False" )
                , ( pCons (pVar "x") (pVar "rest")
                  , ifExpr
                        (binopsExpr [ ( varExpr "x", "==" ) ] (varExpr "target"))
                        (ctorExpr "True")
                        (callExpr (varExpr "contains") [ varExpr "target", varExpr "rest" ])
                  )
                ]

        containsFn =
            define "contains" [ pVar "target", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ containsFn ]
                    (callExpr (varExpr "contains") [ intExpr 3, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ])
                )
    in
    expectFn modul


{-| Custom type: type MyList a = Nil | Cons a (MyList a)
sumMyList acc list = case list of Nil -> acc; Cons x rest -> sumMyList (acc + x) rest
-}
tailRecCustomTypeSum : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecCustomTypeSum expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "MyList"
              , args = [ "a" ]
              , ctors =
                    [ { name = "Empty", args = [] }
                    , { name = "Node", args = [ tVar "a", tType "MyList" [ tVar "a" ] ] }
                    ]
              }
            ]

        typedDefs : List TypedDef
        typedDefs =
            [ { name = "sumMyList"
              , tipe = tLambda (tType "Int" []) (tLambda (tType "MyList" [ tType "Int" [] ]) (tType "Int" []))
              , args = [ pVar "acc", pVar "list" ]
              , body =
                    caseExpr (varExpr "list")
                        [ ( pCtor "Empty" [], varExpr "acc" )
                        , ( pCtor "Node" [ pVar "x", pVar "rest" ]
                          , callExpr (varExpr "sumMyList")
                                [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "x")
                                , varExpr "rest"
                                ]
                          )
                        ]
              }
            ]

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumMyList")
                    [ intExpr 0
                    , callExpr (ctorExpr "Node")
                        [ intExpr 1
                        , callExpr (ctorExpr "Node")
                            [ intExpr 2
                            , ctorExpr "Empty"
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                (typedDefs ++ [ testValueDef ])
                unions
                []
    in
    expectFn modul


{-| Nested case: tail-rec with case in both outer and inner branches.
-}
tailRecNestedCase : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecNestedCase expectFn _ =
    let
        -- myLast default list = case list of [] -> default; x :: rest -> case rest of [] -> x; _ -> myLast default rest
        body =
            caseExpr (varExpr "list")
                [ ( pList [], varExpr "default" )
                , ( pCons (pVar "x") (pVar "rest")
                  , caseExpr (varExpr "rest")
                        [ ( pList [], varExpr "x" )
                        , ( pAnything
                          , callExpr (varExpr "myLast") [ varExpr "default", varExpr "rest" ]
                          )
                        ]
                  )
                ]

        myLast =
            define "myLast" [ pVar "default", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ myLast ]
                    (callExpr (varExpr "myLast") [ intExpr 0, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ])
                )
    in
    expectFn modul


{-| Tail-rec with wildcard pattern that discards head: count acc list = case list of [] -> acc; _ :: rest -> count (acc + 1) rest
-}
tailRecWildcardDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecWildcardDestruct expectFn _ =
    let
        body =
            caseExpr (varExpr "list")
                [ ( pList [], varExpr "acc" )
                , ( pCons pAnything (pVar "rest")
                  , callExpr (varExpr "count")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1)
                        , varExpr "rest"
                        ]
                  )
                ]

        countFn =
            define "count" [ pVar "acc", pVar "list" ] body

        modul =
            makeModule "testValue"
                (letExpr [ countFn ]
                    (callExpr (varExpr "count") [ intExpr 0, listExpr [ intExpr 10, intExpr 20, intExpr 30 ] ])
                )
    in
    expectFn modul
