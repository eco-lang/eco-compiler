module SourceIR.ClosureAbiBranchCases exposing (expectSuite)

{-| Test cases targeting MonoGlobalOptimize ABI rewriting paths.

Exercises higher-order functions called with different closure shapes
at different call sites, which triggers the ABI normalization system.
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
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , recordExpr
        , strExpr
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
    Test.test ("Closure ABI branch " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Apply different lambdas", run = applyDifferentLambdas expectFn }
    , { label = "Case returning lambdas", run = caseReturningLambdas expectFn }
    , { label = "Higher-order called at multiple sites", run = higherOrderMultiSite expectFn }
    , { label = "Lambda capturing different vars", run = lambdaCapturingDifferent expectFn }
    , { label = "If returning closures", run = ifReturningClosures expectFn }
    , { label = "Custom type with function field", run = customTypeWithFnField expectFn }
    ]


applyDifferentLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
applyDifferentLambdas expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "apply"
                  , args = [ pVar "f", pVar "x" ]
                  , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tLambda (tType "Int" []) (tType "Int" []))
                  , body = callExpr (varExpr "f") [ varExpr "x" ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "a" [] (callExpr (varExpr "apply") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)), intExpr 5 ])
                            , define "b" [] (callExpr (varExpr "apply") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "*" ) ] (intExpr 2)), intExpr 5 ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
    in
    expectFn modul


caseReturningLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturningLambdas expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "picker"
                  , args = [ pVar "b" ]
                  , tipe = tLambda (tType "Bool" []) (tLambda (tType "Int" []) (tType "Int" []))
                  , body =
                        ifExpr (varExpr "b")
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 10)))
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 10)))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "f" [] (callExpr (varExpr "picker") [ ctorExpr "True" ]) ]
                            (callExpr (varExpr "f") [ intExpr 3 ])
                  }
                ]
    in
    expectFn modul


higherOrderMultiSite : (Src.Module -> Expectation) -> (() -> Expectation)
higherOrderMultiSite expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "applyTwice"
                  , args = [ pVar "f", pVar "x" ]
                  , tipe = tLambda (tLambda (tType "Int" []) (tType "Int" [])) (tLambda (tType "Int" []) (tType "Int" []))
                  , body = callExpr (varExpr "f") [ callExpr (varExpr "f") [ varExpr "x" ] ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "a" [] (callExpr (varExpr "applyTwice") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)), intExpr 0 ])
                            , define "b" [] (callExpr (varExpr "applyTwice") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "*" ) ] (intExpr 3)), intExpr 1 ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
    in
    expectFn modul


lambdaCapturingDifferent : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaCapturingDifferent expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "makeAdder"
                  , args = [ pVar "n" ]
                  , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
                  , body = lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "n"))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "add1" [] (callExpr (varExpr "makeAdder") [ intExpr 1 ])
                            , define "add10" [] (callExpr (varExpr "makeAdder") [ intExpr 10 ])
                            , define "a" [] (callExpr (varExpr "add1") [ intExpr 5 ])
                            , define "b" [] (callExpr (varExpr "add10") [ intExpr 5 ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
    in
    expectFn modul


ifReturningClosures : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningClosures expectFn _ =
    let
        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "choose"
                  , args = [ pVar "flag", pVar "a", pVar "b" ]
                  , tipe = tLambda (tType "Bool" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))))
                  , body =
                        ifExpr (varExpr "flag")
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "a")))
                            (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "b")))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        callExpr (callExpr (varExpr "choose") [ ctorExpr "True", intExpr 100, intExpr 200 ]) [ intExpr 5 ]
                  }
                ]
    in
    expectFn modul


customTypeWithFnField : (Src.Module -> Expectation) -> (() -> Expectation)
customTypeWithFnField expectFn _ =
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "runOp"
                  , args = [ pVar "op" ]
                  , tipe = tLambda (tType "Op" []) (tType "Int" [])
                  , body =
                        caseExpr (varExpr "op")
                            [ ( pCtor "Op" [ pVar "f" ], callExpr (varExpr "f") [ intExpr 10 ] ) ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body =
                        letExpr
                            [ define "a" [] (callExpr (varExpr "runOp") [ callExpr (ctorExpr "Op") [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)) ] ])
                            , define "b" [] (callExpr (varExpr "runOp") [ callExpr (ctorExpr "Op") [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2)) ] ])
                            ]
                            (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"))
                  }
                ]
                [ { name = "Op", args = [], ctors = [ { name = "Op", args = [ tLambda (tType "Int" []) (tType "Int" []) ] } ] } ]
                []
    in
    expectFn modul
