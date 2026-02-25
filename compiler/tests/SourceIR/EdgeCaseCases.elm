module SourceIR.EdgeCaseCases exposing (expectSuite)

{-| Tests for edge cases and special constructs.
These test various edge cases, parens, deep nesting, and complex expression
combinations in the canonicalizer.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , accessorExpr
        , binopsExpr
        , boolExpr
        , caseExpr
        , define
        , destruct
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , pAlias
        , pAnything
        , pCons
        , pRecord
        , pTuple
        , pVar
        , parensExpr
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , unitExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Edge case and special expression tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ parensCases expectFn
        , complexExpressionCases expectFn
        , edgeCaseCases expectFn
        , deepNestingCases expectFn
        , expressionCombinationCases expectFn
        , edgeCaseFixedCases expectFn
        ]



-- ============================================================================
-- PARENS TESTS (4 tests)
-- ============================================================================


parensCases : (Src.Module -> Expectation) -> List TestCase
parensCases expectFn =
    [ { label = "Parens around literal", run = parensAroundLiteral expectFn }
    , { label = "Parens around binop", run = parensAroundBinop expectFn }
    , { label = "Nested parens", run = nestedParens expectFn }
    , { label = "Parens around lambda", run = parensAroundLambda expectFn }
    ]


parensAroundLiteral : (Src.Module -> Expectation) -> (() -> Expectation)
parensAroundLiteral expectFn _ =
    let
        modul =
            makeModule "testValue" (parensExpr (intExpr 42))
    in
    expectFn modul


parensAroundBinop : (Src.Module -> Expectation) -> (() -> Expectation)
parensAroundBinop expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( parensExpr (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2)), "*" ) ]
                    (intExpr 3)
                )
    in
    expectFn modul


nestedParens : (Src.Module -> Expectation) -> (() -> Expectation)
nestedParens expectFn _ =
    let
        modul =
            makeModule "testValue" (parensExpr (parensExpr (parensExpr (intExpr 1))))
    in
    expectFn modul


parensAroundLambda : (Src.Module -> Expectation) -> (() -> Expectation)
parensAroundLambda expectFn _ =
    let
        modul =
            makeModule "testValue" (parensExpr (lambdaExpr [ pVar "x" ] (varExpr "x")))
    in
    expectFn modul



-- ============================================================================
-- COMPLEX EXPRESSIONS (6 tests)
-- ============================================================================


complexExpressionCases : (Src.Module -> Expectation) -> List TestCase
complexExpressionCases expectFn =
    [ { label = "Nested record updates", run = nestedRecordUpdates expectFn }
    , { label = "Lambda in record update", run = lambdaInRecordUpdate expectFn }
    , { label = "Case in if", run = caseInIf expectFn }
    , { label = "If in case", run = ifInCase expectFn }
    , { label = "Multiple accessors in list", run = multipleAccessorsInList expectFn }
    ]


nestedRecordUpdates : (Src.Module -> Expectation) -> (() -> Expectation)
nestedRecordUpdates expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]

        def =
            define "r" [] record

        update1 =
            updateExpr (varExpr "r") [ ( "x", intExpr 10 ) ]

        def2 =
            define "r2" [] update1

        update2 =
            updateExpr (varExpr "r2") [ ( "y", intExpr 20 ) ]

        modul =
            makeModule "testValue" (letExpr [ def, def2 ] update2)
    in
    expectFn modul


lambdaInRecordUpdate : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaInRecordUpdate expectFn _ =
    let
        record =
            recordExpr [ ( "fn", lambdaExpr [ pVar "x" ] (intExpr 0) ) ]

        def =
            define "r" [] record

        newFn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        update =
            updateExpr (varExpr "r") [ ( "fn", newFn ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul


caseInIf : (Src.Module -> Expectation) -> (() -> Expectation)
caseInIf expectFn _ =
    let
        cond =
            boolExpr True

        thenBranch =
            caseExpr (intExpr 1)
                [ ( pVar "n", varExpr "n" )
                ]

        elseBranch =
            intExpr 0

        modul =
            makeModule "testValue" (ifExpr cond thenBranch elseBranch)
    in
    expectFn modul


ifInCase : (Src.Module -> Expectation) -> (() -> Expectation)
ifInCase expectFn _ =
    let
        case_ =
            caseExpr (intExpr 1)
                [ ( pVar "n"
                  , ifExpr (boolExpr True) (varExpr "n") (intExpr 0)
                  )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


multipleAccessorsInList : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAccessorsInList expectFn _ =
    let
        modul =
            makeModule "testValue"
                (listExpr
                    [ accessorExpr "a"
                    , accessorExpr "b"
                    , accessorExpr "c"
                    , accessorExpr "d"
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- EDGE CASES (4 tests)
-- ============================================================================


edgeCaseCases : (Src.Module -> Expectation) -> List TestCase
edgeCaseCases expectFn =
    [ { label = "Empty record", run = emptyRecord expectFn }
    , { label = "Empty list", run = emptyListExpr expectFn }
    , { label = "Unit expression", run = unitExpression expectFn }
    ]


emptyRecord : (Src.Module -> Expectation) -> (() -> Expectation)
emptyRecord expectFn _ =
    let
        modul =
            makeModule "testValue" (recordExpr [])
    in
    expectFn modul


emptyListExpr : (Src.Module -> Expectation) -> (() -> Expectation)
emptyListExpr expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [])
    in
    expectFn modul


unitExpression : (Src.Module -> Expectation) -> (() -> Expectation)
unitExpression expectFn _ =
    let
        modul =
            makeModule "testValue" unitExpr
    in
    expectFn modul



-- ============================================================================
-- DEEP NESTING (4 tests)
-- ============================================================================


deepNestingCases : (Src.Module -> Expectation) -> List TestCase
deepNestingCases expectFn =
    [ { label = "Deeply nested lists", run = deeplyNestedLists expectFn }
    , { label = "Deeply nested tuples", run = deeplyNestedTuples expectFn }
    , { label = "Deeply nested lets", run = deeplyNestedLets expectFn }
    , { label = "Deeply nested records", run = deeplyNestedRecords expectFn }
    ]


deeplyNestedLists : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedLists expectFn _ =
    let
        level4 =
            listExpr [ intExpr 1 ]

        level3 =
            listExpr [ level4 ]

        level2 =
            listExpr [ level3 ]

        level1 =
            listExpr [ level2 ]

        modul =
            makeModule "testValue" level1
    in
    expectFn modul


deeplyNestedTuples : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedTuples expectFn _ =
    let
        level4 =
            tupleExpr (intExpr 1) (intExpr 2)

        level3 =
            tupleExpr level4 (intExpr 3)

        level2 =
            tupleExpr level3 (intExpr 4)

        level1 =
            tupleExpr level2 (intExpr 5)

        modul =
            makeModule "testValue" level1
    in
    expectFn modul


deeplyNestedLets : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedLets expectFn _ =
    let
        inner3 =
            letExpr [ define "d" [] (intExpr 4) ] (varExpr "d")

        inner2 =
            letExpr [ define "c" [] (intExpr 3) ] inner3

        inner1 =
            letExpr [ define "b" [] (intExpr 2) ] inner2

        modul =
            makeModule "testValue" (letExpr [ define "a" [] (intExpr 1) ] inner1)
    in
    expectFn modul


deeplyNestedRecords : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedRecords expectFn _ =
    let
        level4 =
            recordExpr [ ( "value", intExpr 1 ) ]

        level3 =
            recordExpr [ ( "nested", level4 ) ]

        level2 =
            recordExpr [ ( "nested", level3 ) ]

        level1 =
            recordExpr [ ( "nested", level2 ) ]

        modul =
            makeModule "testValue" level1
    in
    expectFn modul



-- ============================================================================
-- EXPRESSION COMBINATIONS (4 tests)
-- ============================================================================


expressionCombinationCases : (Src.Module -> Expectation) -> List TestCase
expressionCombinationCases expectFn =
    [ -- Moved to TypeCheckFails.elm: Test.test ("All expression types in one module " ++ condStr) (allExpressionTypesInOneModule expectFn)
      { label = "Multiple pattern types in one function", run = multiplePatternTypesInOneFunction expectFn }
    , { label = "All destruct patterns", run = allDestructPatterns expectFn }
    , { label = "Multiple definitions with various patterns", run = multipleDefinitionsWithVariousPatterns expectFn }
    ]


multiplePatternTypesInOneFunction : (Src.Module -> Expectation) -> (() -> Expectation)
multiplePatternTypesInOneFunction expectFn _ =
    let
        fn =
            define "complex"
                [ pVar "a"
                , pTuple (pVar "b") (pVar "c")
                , pRecord [ "d", "e" ]
                , pCons (pVar "f") pAnything
                , pAlias (pVar "g") "h"
                ]
                (listExpr [ varExpr "a", varExpr "b", varExpr "d", varExpr "f", varExpr "g" ])

        modul =
            makeModule "testValue" (letExpr [ fn ] (varExpr "complex"))
    in
    expectFn modul


allDestructPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
allDestructPatterns expectFn _ =
    let
        def1 =
            destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 1) (intExpr 2))

        def2 =
            destruct (pRecord [ "x" ]) (recordExpr [ ( "x", intExpr 3 ) ])

        def3 =
            destruct (pCons (pVar "h") (pVar "t")) (listExpr [ intExpr 4, intExpr 5 ])

        def4 =
            destruct (pAlias (pVar "v") "w") (intExpr 6)

        modul =
            makeModule "testValue"
                (letExpr [ def1, def2, def3, def4 ]
                    (listExpr [ varExpr "a", varExpr "x", varExpr "h", varExpr "v" ])
                )
    in
    expectFn modul


multipleDefinitionsWithVariousPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleDefinitionsWithVariousPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "f1", [ pVar "x" ], varExpr "x" )
                , ( "f2", [ pTuple (pVar "a") (pVar "b") ], varExpr "a" )
                , ( "f3", [ pRecord [ "name" ] ], varExpr "name" )
                , ( "f4", [ pAnything ], intExpr 0 )
                , ( "f5", [ pVar "a", pVar "b", pVar "c" ], varExpr "b" )
                ]
    in
    expectFn modul



-- ============================================================================
-- FIXED VALUE TESTS (2 tests, converted from fuzz tests)
-- ============================================================================


edgeCaseFixedCases : (Src.Module -> Expectation) -> List TestCase
edgeCaseFixedCases expectFn =
    [ { label = "Complex expression with fixed values", run = complexExpressionWithFixedValues expectFn }
    , { label = "Mixed types with fixed values", run = mixedTypesWithFixedValues expectFn }
    ]


complexExpressionWithFixedValues : (Src.Module -> Expectation) -> (() -> Expectation)
complexExpressionWithFixedValues expectFn _ =
    let
        a =
            1

        b =
            2

        c =
            3

        list =
            listExpr [ intExpr a, intExpr b, intExpr c ]

        record =
            recordExpr [ ( "values", list ) ]

        tuple =
            tuple3Expr (intExpr a) (intExpr b) (intExpr c)

        modul =
            makeModule "testValue" (tupleExpr record tuple)
    in
    expectFn modul


mixedTypesWithFixedValues : (Src.Module -> Expectation) -> (() -> Expectation)
mixedTypesWithFixedValues expectFn _ =
    let
        s =
            "hello"

        n =
            42

        record =
            recordExpr
                [ ( "name", strExpr s )
                , ( "count", intExpr n )
                ]

        def =
            define "r" [] record

        result =
            tupleExpr
                (accessExpr (varExpr "r") "name")
                (accessExpr (varExpr "r") "count")

        modul =
            makeModule "testValue" (letExpr [ def ] result)
    in
    expectFn modul
