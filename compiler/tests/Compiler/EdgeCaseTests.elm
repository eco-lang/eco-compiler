module Compiler.EdgeCaseTests exposing (expectSuite)

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
        , callExpr
        , caseExpr
        , chrExpr
        , define
        , destruct
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , negateExpr
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
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Edge case and special expression tests " ++ condStr)
        [ parensTests expectFn condStr
        , complexExpressionTests expectFn condStr
        , edgeCaseTests expectFn condStr
        , deepNestingTests expectFn condStr
        , expressionCombinationTests expectFn condStr
        , edgeCaseFuzzTests expectFn condStr
        ]



-- ============================================================================
-- PARENS TESTS (4 tests)
-- ============================================================================


parensTests : (Src.Module -> Expectation) -> String -> Test
parensTests expectFn condStr =
    Test.describe ("Parenthesized expressions " ++ condStr)
        [ Test.test ("Parens around literal " ++ condStr) (parensAroundLiteral expectFn)
        , Test.test ("Parens around binop " ++ condStr) (parensAroundBinop expectFn)
        , Test.test ("Nested parens " ++ condStr) (nestedParens expectFn)
        , Test.test ("Parens around lambda " ++ condStr) (parensAroundLambda expectFn)
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


complexExpressionTests : (Src.Module -> Expectation) -> String -> Test
complexExpressionTests expectFn condStr =
    Test.describe ("Complex expression combinations " ++ condStr)
        [ Test.test ("Record access in binop " ++ condStr) (recordAccessInBinop expectFn)
        , Test.test ("Nested record updates " ++ condStr) (nestedRecordUpdates expectFn)
        , Test.test ("Lambda in record update " ++ condStr) (lambdaInRecordUpdate expectFn)
        , Test.test ("Case in if " ++ condStr) (caseInIf expectFn)
        , Test.test ("If in case " ++ condStr) (ifInCase expectFn)
        , Test.test ("Multiple accessors in list " ++ condStr) (multipleAccessorsInList expectFn)
        ]


recordAccessInBinop : (Src.Module -> Expectation) -> (() -> Expectation)
recordAccessInBinop expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]

        def =
            define "r" [] record

        binop =
            binopsExpr
                [ ( accessExpr (varExpr "r") "x", "+" ) ]
                (accessExpr (varExpr "r") "y")

        modul =
            makeModule "testValue" (letExpr [ def ] binop)
    in
    expectFn modul


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


edgeCaseTests : (Src.Module -> Expectation) -> String -> Test
edgeCaseTests expectFn condStr =
    Test.describe ("Edge cases " ++ condStr)
        [ Test.test ("Empty record " ++ condStr) (emptyRecord expectFn)
        , Test.test ("Empty list " ++ condStr) (emptyListExpr expectFn)
        , Test.test ("Unit expression " ++ condStr) (unitExpression expectFn)
        , Test.test ("Lambda with no body complexity " ++ condStr) (lambdaWithNoBodyComplexity expectFn)
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


lambdaWithNoBodyComplexity : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithNoBodyComplexity expectFn _ =
    let
        modul =
            makeModule "testValue" (lambdaExpr [ pVar "x" ] (varExpr "x"))
    in
    expectFn modul



-- ============================================================================
-- DEEP NESTING (4 tests)
-- ============================================================================


deepNestingTests : (Src.Module -> Expectation) -> String -> Test
deepNestingTests expectFn condStr =
    Test.describe ("Deep nesting " ++ condStr)
        [ Test.test ("Deeply nested lists " ++ condStr) (deeplyNestedLists expectFn)
        , Test.test ("Deeply nested tuples " ++ condStr) (deeplyNestedTuples expectFn)
        , Test.test ("Deeply nested lets " ++ condStr) (deeplyNestedLets expectFn)
        , Test.test ("Deeply nested records " ++ condStr) (deeplyNestedRecords expectFn)
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


expressionCombinationTests : (Src.Module -> Expectation) -> String -> Test
expressionCombinationTests expectFn condStr =
    Test.describe ("Expression combinations " ++ condStr)
        [ -- Moved to TypeCheckFails.elm: Test.test ("All expression types in one module " ++ condStr) (allExpressionTypesInOneModule expectFn)
          Test.test ("Multiple pattern types in one function " ++ condStr) (multiplePatternTypesInOneFunction expectFn)
        , Test.test ("All destruct patterns " ++ condStr) (allDestructPatterns expectFn)
        , Test.test ("Multiple definitions with various patterns " ++ condStr) (multipleDefinitionsWithVariousPatterns expectFn)
        ]


allExpressionTypesInOneModule : (Src.Module -> Expectation) -> (() -> Expectation)
allExpressionTypesInOneModule expectFn _ =
    let
        -- Int, Float, String, Char
        literals =
            listExpr [ intExpr 1, floatExpr 2.0, strExpr "s", chrExpr "c" ]

        -- Tuple, Record
        containers =
            tupleExpr
                (recordExpr [ ( "x", intExpr 1 ) ])
                (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3))

        -- Lambda, Call
        functions =
            letExpr
                [ define "f" [ pVar "x" ] (varExpr "x") ]
                (callExpr (varExpr "f") [ intExpr 0 ])

        -- If, Case
        control =
            ifExpr (boolExpr True)
                (caseExpr (intExpr 1) [ ( pVar "n", varExpr "n" ) ])
                (intExpr 0)

        -- Binop, Negate
        operators =
            binopsExpr
                [ ( negateExpr (intExpr 1), "+" ) ]
                (intExpr 2)

        -- Accessor, Access, Update
        records =
            letExpr
                [ define "r" [] (recordExpr [ ( "x", intExpr 1 ) ]) ]
                (tupleExpr
                    (accessExpr (varExpr "r") "x")
                    (accessorExpr "x")
                )

        modul =
            makeModule "testValue"
                (listExpr [ literals, containers, functions, control, operators, records ])
    in
    expectFn modul


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
-- FUZZ TESTS (2 tests)
-- ============================================================================


edgeCaseFuzzTests : (Src.Module -> Expectation) -> String -> Test
edgeCaseFuzzTests expectFn condStr =
    Test.describe ("Fuzzed edge case tests " ++ condStr)
        [ Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Complex expression with fuzzed values " ++ condStr) (complexExpressionWithFuzzedValues expectFn)
        , Test.fuzz2 Fuzz.string Fuzz.int ("Mixed types with fuzzed values " ++ condStr) (mixedTypesWithFuzzedValues expectFn)
        ]


complexExpressionWithFuzzedValues : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
complexExpressionWithFuzzedValues expectFn a b c =
    let
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


mixedTypesWithFuzzedValues : (Src.Module -> Expectation) -> (String -> Int -> Expectation)
mixedTypesWithFuzzedValues expectFn s n =
    let
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
