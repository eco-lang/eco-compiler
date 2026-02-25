module SourceIR.LetCases exposing (expectSuite)

{-| Tests for let expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pVar
        , recordExpr
        , strExpr
        , tupleExpr
        , unitExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    simpleLetCases expectFn
        ++ multipleBindingsCases expectFn
        ++ nestedLetCases expectFn
        ++ letWithFunctionsCases expectFn
        ++ letWithComplexExpressionsCases expectFn



-- ============================================================================
-- SIMPLE LET
-- ============================================================================


simpleLetCases : (Src.Module -> Expectation) -> List TestCase
simpleLetCases expectFn =
    [ { label = "Let with single int binding", run = letWithSingleIntBinding expectFn }
    , { label = "Let with unit body", run = letWithUnitBody expectFn }
    ]


letWithSingleIntBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithSingleIntBinding expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


letWithUnitBody : (Src.Module -> Expectation) -> (() -> Expectation)
letWithUnitBody expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] unitExpr)
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE BINDINGS
-- ============================================================================


multipleBindingsCases : (Src.Module -> Expectation) -> List TestCase
multipleBindingsCases expectFn =
    [ { label = "Let with two bindings", run = letWithTwoBindings expectFn }
    , { label = "Let with binding using previous binding", run = letWithBindingUsingPrevious expectFn }
    , { label = "Let with chained references", run = letWithChainedReferences expectFn }
    ]


letWithTwoBindings : (Src.Module -> Expectation) -> (() -> Expectation)
letWithTwoBindings expectFn _ =
    let
        def1 =
            define "x" [] (intExpr 1)

        def2 =
            define "y" [] (intExpr 2)

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


letWithBindingUsingPrevious : (Src.Module -> Expectation) -> (() -> Expectation)
letWithBindingUsingPrevious expectFn _ =
    let
        def1 =
            define "x" [] (intExpr 1)

        def2 =
            define "y" [] (tupleExpr (varExpr "x") (intExpr 2))

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (varExpr "y"))
    in
    expectFn modul


letWithChainedReferences : (Src.Module -> Expectation) -> (() -> Expectation)
letWithChainedReferences expectFn _ =
    let
        def1 =
            define "a" [] (intExpr 1)

        def2 =
            define "b" [] (varExpr "a")

        def3 =
            define "c" [] (varExpr "b")

        modul =
            makeModule "testValue" (letExpr [ def1, def2, def3 ] (varExpr "c"))
    in
    expectFn modul



-- ============================================================================
-- NESTED LET
-- ============================================================================


nestedLetCases : (Src.Module -> Expectation) -> List TestCase
nestedLetCases expectFn =
    [ { label = "Let inside let", run = letInsideLet expectFn }
    , { label = "Let in binding value", run = letInBindingValue expectFn }
    , { label = "Multiple nested lets", run = multipleNestedLets expectFn }
    , { label = "Let inside list inside let", run = letInsideListInsideLet expectFn }
    ]


letInsideLet : (Src.Module -> Expectation) -> (() -> Expectation)
letInsideLet expectFn _ =
    let
        innerLet =
            letExpr [ define "y" [] (intExpr 2) ] (varExpr "y")

        def =
            define "x" [] (intExpr 1)

        modul =
            makeModule "testValue" (letExpr [ def ] innerLet)
    in
    expectFn modul


letInBindingValue : (Src.Module -> Expectation) -> (() -> Expectation)
letInBindingValue expectFn _ =
    let
        innerLet =
            letExpr [ define "inner" [] (intExpr 42) ] (varExpr "inner")

        def =
            define "x" [] innerLet

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


multipleNestedLets : (Src.Module -> Expectation) -> (() -> Expectation)
multipleNestedLets expectFn _ =
    let
        let1 =
            letExpr [ define "a" [] (intExpr 1) ] (varExpr "a")

        let2 =
            letExpr [ define "b" [] (intExpr 2) ] (varExpr "b")

        modul =
            makeModule "testValue" (tupleExpr let1 let2)
    in
    expectFn modul


letInsideListInsideLet : (Src.Module -> Expectation) -> (() -> Expectation)
letInsideListInsideLet expectFn _ =
    let
        innerLet =
            letExpr [ define "y" [] (intExpr 2) ] (varExpr "y")

        list =
            listExpr [ intExpr 1, innerLet, intExpr 3 ]

        modul =
            makeModule "testValue" (letExpr [ define "x" [] (intExpr 0) ] list)
    in
    expectFn modul



-- ============================================================================
-- LET WITH FUNCTIONS
-- ============================================================================


letWithFunctionsCases : (Src.Module -> Expectation) -> List TestCase
letWithFunctionsCases expectFn =
    [ { label = "Let with function", run = letWithFunction expectFn }
    , { label = "Let with lambda binding", run = letWithLambdaBinding expectFn }
    , { label = "Let with multiple functions", run = letWithMultipleFunctions expectFn }
    , { label = "Let with function calling another function", run = letWithFunctionCallingAnother expectFn }
    ]


letWithFunction : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFunction expectFn _ =
    let
        fn =
            define "f" [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 42 ]))
    in
    expectFn modul


letWithLambdaBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithLambdaBinding expectFn _ =
    let
        fn =
            define "f" [] (lambdaExpr [ pVar "x" ] (varExpr "x"))

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 42 ]))
    in
    expectFn modul


letWithMultipleFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
letWithMultipleFunctions expectFn _ =
    let
        fn1 =
            define "identity" [ pVar "x" ] (varExpr "x")

        fn2 =
            define "const" [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ fn1, fn2 ]
                    (tupleExpr
                        (callExpr (varExpr "identity") [ intExpr 1 ])
                        (callExpr (varExpr "const") [ intExpr 2, intExpr 3 ])
                    )
                )
    in
    expectFn modul


letWithFunctionCallingAnother : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFunctionCallingAnother expectFn _ =
    let
        fn1 =
            define "double" [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "x"))

        fn2 =
            define "doubleTwice" [ pVar "y" ] (callExpr (varExpr "double") [ callExpr (varExpr "double") [ varExpr "y" ] ])

        modul =
            makeModule "testValue"
                (letExpr [ fn1, fn2 ]
                    (callExpr (varExpr "doubleTwice") [ intExpr 1 ])
                )
    in
    expectFn modul



-- ============================================================================
-- LET WITH COMPLEX EXPRESSIONS
-- ============================================================================


letWithComplexExpressionsCases : (Src.Module -> Expectation) -> List TestCase
letWithComplexExpressionsCases expectFn =
    [ { label = "Let with record binding", run = letWithRecordBinding expectFn }
    , { label = "Let with tuple binding", run = letWithTupleBinding expectFn }
    , { label = "Let with list binding", run = letWithListBinding expectFn }
    ]


letWithRecordBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithRecordBinding expectFn _ =
    let
        def =
            define "r" [] (recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ])

        modul =
            makeModule "testValue" (letExpr [ def ] (accessExpr (varExpr "r") "x"))
    in
    expectFn modul


letWithTupleBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithTupleBinding expectFn _ =
    let
        def =
            define "pair" [] (tupleExpr (intExpr 1) (strExpr "one"))

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "pair"))
    in
    expectFn modul


letWithListBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithListBinding expectFn _ =
    let
        def =
            define "items" [] (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "items"))
    in
    expectFn modul
