module Compiler.LetTests exposing (expectSuite)

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
        , tuple3Expr
        , tupleExpr
        , unitExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Let expressions " ++ condStr)
        [ simpleLetTests expectFn condStr
        , multipleBindingsTests expectFn condStr
        , nestedLetTests expectFn condStr
        , letWithFunctionsTests expectFn condStr
        , letWithComplexExpressionsTests expectFn condStr
        ]



-- ============================================================================
-- SIMPLE LET (6 tests)
-- ============================================================================


simpleLetTests : (Src.Module -> Expectation) -> String -> Test
simpleLetTests expectFn condStr =
    Test.describe ("Simple let expressions " ++ condStr)
        [ Test.test ("Let with single int binding " ++ condStr) (letWithSingleIntBinding expectFn)
        , Test.test ("Let with int binding " ++ condStr) (letWithIntBinding expectFn)
        , Test.test ("Let with string binding " ++ condStr) (letWithStringBinding expectFn)
        , Test.test ("Let with unit body " ++ condStr) (letWithUnitBody expectFn)
        , Test.test ("Let with tuple body " ++ condStr) (letWithTupleBody expectFn)
        , Test.test ("Let with list body " ++ condStr) (letWithListBody expectFn)
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


letWithIntBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithIntBinding expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


letWithStringBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithStringBinding expectFn _ =
    let
        def =
            define "x" [] (strExpr "hello")

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


letWithTupleBody : (Src.Module -> Expectation) -> (() -> Expectation)
letWithTupleBody expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "x") (varExpr "x")))
    in
    expectFn modul


letWithListBody : (Src.Module -> Expectation) -> (() -> Expectation)
letWithListBody expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] (listExpr [ varExpr "x" ]))
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE BINDINGS (6 tests)
-- ============================================================================


multipleBindingsTests : (Src.Module -> Expectation) -> String -> Test
multipleBindingsTests expectFn condStr =
    Test.describe ("Multiple let bindings " ++ condStr)
        [ Test.test ("Let with two bindings " ++ condStr) (letWithTwoBindings expectFn)
        , Test.test ("Let with three bindings " ++ condStr) (letWithThreeBindings expectFn)
        , Test.test ("Let with two int bindings " ++ condStr) (letWithTwoIntBindings expectFn)
        , Test.test ("Let with binding using previous binding " ++ condStr) (letWithBindingUsingPrevious expectFn)
        , Test.test ("Let with five bindings " ++ condStr) (letWithFiveBindings expectFn)
        , Test.test ("Let with chained references " ++ condStr) (letWithChainedReferences expectFn)
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


letWithThreeBindings : (Src.Module -> Expectation) -> (() -> Expectation)
letWithThreeBindings expectFn _ =
    let
        def1 =
            define "a" [] (intExpr 1)

        def2 =
            define "b" [] (intExpr 2)

        def3 =
            define "c" [] (intExpr 3)

        modul =
            makeModule "testValue"
                (letExpr [ def1, def2, def3 ]
                    (listExpr [ varExpr "a", varExpr "b", varExpr "c" ])
                )
    in
    expectFn modul


letWithTwoIntBindings : (Src.Module -> Expectation) -> (() -> Expectation)
letWithTwoIntBindings expectFn _ =
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


letWithFiveBindings : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFiveBindings expectFn _ =
    let
        defs =
            List.map (\i -> define ("v" ++ String.fromInt i) [] (intExpr i)) (List.range 1 5)

        modul =
            makeModule "testValue"
                (letExpr defs
                    (listExpr (List.map (\i -> varExpr ("v" ++ String.fromInt i)) (List.range 1 5)))
                )
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
-- NESTED LET (6 tests)
-- ============================================================================


nestedLetTests : (Src.Module -> Expectation) -> String -> Test
nestedLetTests expectFn condStr =
    Test.describe ("Nested let expressions " ++ condStr)
        [ Test.test ("Let inside let " ++ condStr) (letInsideLet expectFn)
        , Test.test ("Deeply nested let " ++ condStr) (deeplyNestedLet expectFn)
        , Test.test ("Let in binding value " ++ condStr) (letInBindingValue expectFn)
        , Test.test ("Multiple nested lets " ++ condStr) (multipleNestedLets expectFn)
        , Test.test ("Nested let with int value " ++ condStr) (nestedLetWithIntValue expectFn)
        , Test.test ("Let inside list inside let " ++ condStr) (letInsideListInsideLet expectFn)
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


deeplyNestedLet : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedLet expectFn _ =
    let
        innermost =
            letExpr [ define "z" [] (intExpr 3) ] (varExpr "z")

        middle =
            letExpr [ define "y" [] (intExpr 2) ] innermost

        modul =
            makeModule "testValue" (letExpr [ define "x" [] (intExpr 1) ] middle)
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


nestedLetWithIntValue : (Src.Module -> Expectation) -> (() -> Expectation)
nestedLetWithIntValue expectFn _ =
    let
        innerLet =
            letExpr [ define "y" [] (intExpr 42) ] (varExpr "y")

        def =
            define "x" [] innerLet

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
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
-- LET WITH FUNCTIONS (6 tests)
-- ============================================================================


letWithFunctionsTests : (Src.Module -> Expectation) -> String -> Test
letWithFunctionsTests expectFn condStr =
    Test.describe ("Let with function definitions " ++ condStr)
        [ Test.test ("Let with function " ++ condStr) (letWithFunction expectFn)
        , Test.test ("Let with two-arg function " ++ condStr) (letWithTwoArgFunction expectFn)
        , Test.test ("Let with lambda binding " ++ condStr) (letWithLambdaBinding expectFn)
        , Test.test ("Let with multiple functions " ++ condStr) (letWithMultipleFunctions expectFn)
        , Test.test ("Let with function calling another function " ++ condStr) (letWithFunctionCallingAnother expectFn)
        , Test.test ("Let with function using int value " ++ condStr) (letWithFunctionUsingIntValue expectFn)
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


letWithTwoArgFunction : (Src.Module -> Expectation) -> (() -> Expectation)
letWithTwoArgFunction expectFn _ =
    let
        fn =
            define "add" [ pVar "x", pVar "y" ] (tupleExpr (varExpr "x") (varExpr "y"))

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "add") [ intExpr 1, intExpr 2 ]))
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


letWithFunctionUsingIntValue : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFunctionUsingIntValue expectFn _ =
    let
        fn =
            define "addN" [ pVar "x" ] (tupleExpr (varExpr "x") (intExpr 42))

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "addN") [ intExpr 0 ]))
    in
    expectFn modul



-- ============================================================================
-- LET WITH COMPLEX EXPRESSIONS (4 tests)
-- ============================================================================


letWithComplexExpressionsTests : (Src.Module -> Expectation) -> String -> Test
letWithComplexExpressionsTests expectFn condStr =
    Test.describe ("Let with complex expressions " ++ condStr)
        [ Test.test ("Let with record binding " ++ condStr) (letWithRecordBinding expectFn)
        , Test.test ("Let with tuple binding " ++ condStr) (letWithTupleBinding expectFn)
        , Test.test ("Let with list binding " ++ condStr) (letWithListBinding expectFn)
        , Test.test ("Let with all complex types " ++ condStr) (letWithAllComplexTypes expectFn)
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


letWithAllComplexTypes : (Src.Module -> Expectation) -> (() -> Expectation)
letWithAllComplexTypes expectFn _ =
    let
        recDef =
            define "rec" [] (recordExpr [ ( "a", intExpr 1 ) ])

        tupleDef =
            define "tup" [] (tupleExpr (intExpr 2) (intExpr 3))

        listDef =
            define "lst" [] (listExpr [ intExpr 4, intExpr 5 ])

        body =
            tuple3Expr (varExpr "rec") (varExpr "tup") (varExpr "lst")

        modul =
            makeModule "testValue" (letExpr [ recDef, tupleDef, listDef ] body)
    in
    expectFn modul
