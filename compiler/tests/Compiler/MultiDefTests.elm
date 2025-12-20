module Compiler.MultiDefTests exposing (expectSuite)

{-| Tests for modules with multiple top-level definitions.

These tests verify that the ID builder does not reset between top-level
definitions, ensuring all expression and pattern IDs are unique across
the entire module.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (..)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Multiple top-level definitions " ++ condStr)
        [ basicMultiDefTests expectFn condStr
        , complexMultiDefTests expectFn condStr
        ]


basicMultiDefTests : (Src.Module -> Expectation) -> String -> Test
basicMultiDefTests expectFn condStr =
    Test.describe ("Basic multi-definition modules " ++ condStr)
        [ Test.test ("Two identical structure definitions " ++ condStr) (twoIdenticalStructureDefinitions expectFn)
        , Test.test ("Three simple value definitions " ++ condStr) (threeSimpleValueDefinitions expectFn)
        , Test.test ("Multiple function definitions with same arity " ++ condStr) (multipleFunctionsSameArity expectFn)
        , Test.test ("Multiple function definitions with different arities " ++ condStr) (multipleFunctionsDifferentArities expectFn)
        , Test.test ("Functions that call each other " ++ condStr) (functionsCallEachOther expectFn)
        , Test.test ("Multiple definitions with let expressions " ++ condStr) (multipleDefsWithLet expectFn)
        , Test.test ("Multiple definitions with case expressions " ++ condStr) (multipleDefsWithCase expectFn)
        , Test.test ("Multiple definitions with if expressions " ++ condStr) (multipleDefsWithIf expectFn)
        , Test.test ("Multiple definitions with lambdas " ++ condStr) (multipleDefsWithLambdas expectFn)
        , Test.test ("Multiple definitions with records " ++ condStr) (multipleDefsWithRecords expectFn)
        , Test.test ("Multiple definitions with binary operators " ++ condStr) (multipleDefsWithBinops expectFn)
        , Test.test ("Large module with many definitions " ++ condStr) (largeModuleManyDefs expectFn)
        ]


complexMultiDefTests : (Src.Module -> Expectation) -> String -> Test
complexMultiDefTests expectFn condStr =
    Test.describe ("Complex multi-definition scenarios " ++ condStr)
        [ Test.test ("Definitions with nested lets " ++ condStr) (nestedLetsMultipleDefs expectFn)
        , Test.test ("Definitions with tuple patterns " ++ condStr) (tuplePatternMultipleDefs expectFn)
        , Test.test ("Definitions with list patterns " ++ condStr) (listPatternMultipleDefs expectFn)
        , Test.test ("Definitions with record patterns " ++ condStr) (recordPatternMultipleDefs expectFn)
        , Test.test ("Mixed expressions and patterns across definitions " ++ condStr) (mixedExpressionsAndPatterns expectFn)
        ]


twoIdenticalStructureDefinitions : (Src.Module -> Expectation) -> (() -> Expectation)
twoIdenticalStructureDefinitions expectFn _ =
    -- a = 1 + 2
    -- b = 1 + 2
    -- If IDs reset, both would have the same IDs
    let
        modul =
            makeModuleWithDefs
                [ ( "a", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                , ( "b", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                ]
    in
    expectFn modul


threeSimpleValueDefinitions : (Src.Module -> Expectation) -> (() -> Expectation)
threeSimpleValueDefinitions expectFn _ =
    -- a = 1
    -- b = 2
    -- c = 3
    let
        modul =
            makeModuleWithDefs
                [ ( "a", [], intExpr 1 )
                , ( "b", [], intExpr 2 )
                , ( "c", [], intExpr 3 )
                ]
    in
    expectFn modul


multipleFunctionsSameArity : (Src.Module -> Expectation) -> (() -> Expectation)
multipleFunctionsSameArity expectFn _ =
    -- f x = x + 1
    -- g y = y * 2
    let
        modul =
            makeModuleWithDefs
                [ ( "f", [ pVar "x" ], binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) )
                , ( "g", [ pVar "y" ], binopsExpr [ ( varExpr "y", "*" ) ] (intExpr 2) )
                ]
    in
    expectFn modul


multipleFunctionsDifferentArities : (Src.Module -> Expectation) -> (() -> Expectation)
multipleFunctionsDifferentArities expectFn _ =
    -- a = 42
    -- f x = x
    -- g x y = x + y
    -- h x y z = x + y + z
    let
        modul =
            makeModuleWithDefs
                [ ( "a", [], intExpr 42 )
                , ( "f", [ pVar "x" ], varExpr "x" )
                , ( "g", [ pVar "x", pVar "y" ], binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y") )
                , ( "h"
                  , [ pVar "x", pVar "y", pVar "z" ]
                  , binopsExpr [ ( varExpr "x", "+" ), ( varExpr "y", "+" ) ] (varExpr "z")
                  )
                ]
    in
    expectFn modul


functionsCallEachOther : (Src.Module -> Expectation) -> (() -> Expectation)
functionsCallEachOther expectFn _ =
    -- f x = g x
    -- g y = y + 1
    let
        modul =
            makeModuleWithDefs
                [ ( "f", [ pVar "x" ], callExpr (varExpr "g") [ varExpr "x" ] )
                , ( "g", [ pVar "y" ], binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 1) )
                ]
    in
    expectFn modul


multipleDefsWithLet : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithLet expectFn _ =
    -- a = let x = 1 in x
    -- b = let y = 2 in y
    let
        modul =
            makeModuleWithDefs
                [ ( "a", [], letExpr [ define "x" [] (intExpr 1) ] (varExpr "x") )
                , ( "b", [], letExpr [ define "y" [] (intExpr 2) ] (varExpr "y") )
                ]
    in
    expectFn modul


multipleDefsWithCase : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithCase expectFn _ =
    -- f x = case x of { 0 -> 1; _ -> 2 }
    -- g y = case y of { 0 -> 3; _ -> 4 }
    let
        modul =
            makeModuleWithDefs
                [ ( "f"
                  , [ pVar "x" ]
                  , caseExpr (varExpr "x")
                        [ ( pInt 0, intExpr 1 )
                        , ( pAnything, intExpr 2 )
                        ]
                  )
                , ( "g"
                  , [ pVar "y" ]
                  , caseExpr (varExpr "y")
                        [ ( pInt 0, intExpr 3 )
                        , ( pAnything, intExpr 4 )
                        ]
                  )
                ]
    in
    expectFn modul


multipleDefsWithIf : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithIf expectFn _ =
    -- a = if True then 1 else 2
    -- b = if True then 3 else 4
    -- c = if True then 5 else 6
    let
        modul =
            makeModuleWithDefs
                [ ( "a", [], ifExpr (boolExpr True) (intExpr 1) (intExpr 2) )
                , ( "b", [], ifExpr (boolExpr True) (intExpr 3) (intExpr 4) )
                , ( "c", [], ifExpr (boolExpr True) (intExpr 5) (intExpr 6) )
                ]
    in
    expectFn modul


multipleDefsWithLambdas : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithLambdas expectFn _ =
    -- f = \x -> x
    -- g = \y -> y + 1
    -- h = \a b -> a + b
    let
        modul =
            makeModuleWithDefs
                [ ( "f", [], lambdaExpr [ pVar "x" ] (varExpr "x") )
                , ( "g", [], lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 1)) )
                , ( "h", [], lambdaExpr [ pVar "a", pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")) )
                ]
    in
    expectFn modul


multipleDefsWithRecords : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithRecords expectFn _ =
    -- a = { x = 1 }
    -- b = { y = 2, z = 3 }
    -- c = { p = 4, q = 5, r = 6 }
    let
        modul =
            makeModuleWithDefs
                [ ( "a", [], recordExpr [ ( "x", intExpr 1 ) ] )
                , ( "b", [], recordExpr [ ( "y", intExpr 2 ), ( "z", intExpr 3 ) ] )
                , ( "c", [], recordExpr [ ( "p", intExpr 4 ), ( "q", intExpr 5 ), ( "r", intExpr 6 ) ] )
                ]
    in
    expectFn modul


multipleDefsWithBinops : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefsWithBinops expectFn _ =
    -- a = 1 + 2
    -- b = 3 * 4
    -- c = 5 - 6
    -- d = 7 / 8
    let
        modul =
            makeModuleWithDefs
                [ ( "a", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                , ( "b", [], binopsExpr [ ( intExpr 3, "*" ) ] (intExpr 4) )
                , ( "c", [], binopsExpr [ ( intExpr 5, "-" ) ] (intExpr 6) )
                , ( "d", [], binopsExpr [ ( intExpr 7, "/" ) ] (intExpr 8) )
                ]
    in
    expectFn modul


largeModuleManyDefs : (Src.Module -> Expectation) -> (() -> Expectation)
largeModuleManyDefs expectFn _ =
    -- 15 definitions to stress test
    let
        modul =
            makeModuleWithDefs
                [ ( "def1", [], intExpr 1 )
                , ( "def2", [], intExpr 2 )
                , ( "def3", [], intExpr 3 )
                , ( "def4", [], binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2) )
                , ( "def5", [], binopsExpr [ ( intExpr 3, "*" ) ] (intExpr 4) )
                , ( "def6", [ pVar "x" ], varExpr "x" )
                , ( "def7", [ pVar "x" ], binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) )
                , ( "def8", [], letExpr [ define "a" [] (intExpr 1) ] (varExpr "a") )
                , ( "def9", [], ifExpr (boolExpr True) (intExpr 1) (intExpr 2) )
                , ( "def10", [], recordExpr [ ( "x", intExpr 1 ) ] )
                , ( "def11", [], tupleExpr (intExpr 1) (intExpr 2) )
                , ( "def12", [], listExpr [ intExpr 1, intExpr 2, intExpr 3 ] )
                , ( "def13", [], lambdaExpr [ pVar "n" ] (varExpr "n") )
                , ( "def14", [ pVar "a", pVar "b" ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                , ( "def15", [], strExpr "hello" )
                ]
    in
    expectFn modul


nestedLetsMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLetsMultipleDefs expectFn _ =
    -- a = let x = let y = 1 in y in x
    -- b = let p = let q = 2 in q in p
    let
        modul =
            makeModuleWithDefs
                [ ( "a"
                  , []
                  , letExpr [ define "x" [] (letExpr [ define "y" [] (intExpr 1) ] (varExpr "y")) ]
                        (varExpr "x")
                  )
                , ( "b"
                  , []
                  , letExpr [ define "p" [] (letExpr [ define "q" [] (intExpr 2) ] (varExpr "q")) ]
                        (varExpr "p")
                  )
                ]
    in
    expectFn modul


tuplePatternMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
tuplePatternMultipleDefs expectFn _ =
    -- f (a, b) = a + b
    -- g (x, y) = x * y
    let
        modul =
            makeModuleWithDefs
                [ ( "f", [ pTuple (pVar "a") (pVar "b") ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                , ( "g", [ pTuple (pVar "x") (pVar "y") ], binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "y") )
                ]
    in
    expectFn modul


listPatternMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
listPatternMultipleDefs expectFn _ =
    -- f [a] = a
    -- g [x, y] = x + y
    let
        modul =
            makeModuleWithDefs
                [ ( "f", [ pList [ pVar "a" ] ], varExpr "a" )
                , ( "g", [ pList [ pVar "x", pVar "y" ] ], binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y") )
                ]
    in
    expectFn modul


recordPatternMultipleDefs : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternMultipleDefs expectFn _ =
    -- f { x } = x
    -- g { a, b } = a + b
    let
        modul =
            makeModuleWithDefs
                [ ( "f", [ pRecord [ "x" ] ], varExpr "x" )
                , ( "g", [ pRecord [ "a", "b" ] ], binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") )
                ]
    in
    expectFn modul


mixedExpressionsAndPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
mixedExpressionsAndPatterns expectFn _ =
    -- Complex mix of all features
    let
        modul =
            makeModuleWithDefs
                [ ( "value", [], intExpr 42 )
                , ( "func", [ pVar "x" ], binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) )
                , ( "withLet"
                  , []
                  , letExpr [ define "a" [] (intExpr 1) ] (varExpr "a")
                  )
                , ( "withCase"
                  , [ pVar "n" ]
                  , caseExpr (varExpr "n")
                        [ ( pInt 0, intExpr 0 )
                        , ( pAnything, intExpr 1 )
                        ]
                  )
                , ( "withIf"
                  , [ pVar "b" ]
                  , ifExpr (varExpr "b") (intExpr 1) (intExpr 2)
                  )
                , ( "withLambda"
                  , []
                  , lambdaExpr [ pVar "x", pVar "y" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
                  )
                , ( "withRecord"
                  , []
                  , recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]
                  )
                , ( "withTuple"
                  , [ pTuple (pVar "a") (pVar "b") ]
                  , tupleExpr (varExpr "a") (varExpr "b")
                  )
                ]
    in
    expectFn modul
