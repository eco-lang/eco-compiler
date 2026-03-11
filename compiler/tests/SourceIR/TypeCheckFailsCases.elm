module SourceIR.TypeCheckFailsCases exposing (expectSuite)

{-| Tests for cases where type checking fails in the constrainWithIds path.
These are test cases that produce type errors in both the standard and
experimental constraint generation paths.
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
        , pInt
        , pList
        , pRecord
        , pTuple
        , pUnit
        , pVar
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Type check failure tests " ++ condStr) (\() -> bulkCheck (testCases expectFn))


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    asPatternCases expectFn
        ++ caseCases expectFn
        ++ edgeCaseCases expectFn
        ++ higherOrderCases expectFn
        ++ letDestructCases expectFn
        ++ letRecCases expectFn
        ++ recordCases expectFn



-- ============================================================================
-- FROM AsPatternTests.elm
-- ============================================================================


asPatternCases : (Src.Module -> Expectation) -> List TestCase
asPatternCases expectFn =
    [ { label = "Alias everywhere", run = aliasEverywhere expectFn }
    , { label = "Multiple aliases in recursive function", run = multipleAliasesInRecursiveFunction expectFn }
    ]


aliasEverywhere : (Src.Module -> Expectation) -> (() -> Expectation)
aliasEverywhere expectFn _ =
    let
        pattern =
            pAlias
                (pTuple
                    (pAlias (pVar "a") "first")
                    (pAlias (pVar "b") "second")
                )
                "whole"

        modul =
            makeModuleWithDefs "Test"
                [ ( "allAliased", [ pattern ], listExpr [ varExpr "whole", varExpr "first", varExpr "second" ] )
                , ( "testValue", [], callExpr (varExpr "allAliased") [ tupleExpr (intExpr 1) (intExpr 2) ] )
                ]
    in
    expectFn modul


multipleAliasesInRecursiveFunction : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAliasesInRecursiveFunction expectFn _ =
    let
        fn =
            define "go"
                [ pAlias (pVar "n") "count", pAlias (pVar "acc") "result" ]
                (ifExpr (boolExpr True)
                    (varExpr "result")
                    (callExpr (varExpr "go") [ intExpr 0, varExpr "count" ])
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "go") [ intExpr 5, listExpr [] ]))
    in
    expectFn modul



-- ============================================================================
-- FROM CaseTests.elm
-- ============================================================================


caseCases : (Src.Module -> Expectation) -> List TestCase
caseCases expectFn =
    [ { label = "Case on unit", run = caseOnUnit expectFn }
    , { label = "Case on int", run = caseOnInt expectFn }
    ]


caseOnUnit : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnUnit expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (tupleExpr (intExpr 1) (intExpr 1))
                    [ ( pUnit, intExpr 0 )
                    ]
                )
    in
    -- Note: This may fail if unit pattern doesn't match tuple - that's ok
    expectFn modul


caseOnInt : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnInt expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 42)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pVar "x", varExpr "x" )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- FROM EdgeCaseTests.elm
-- ============================================================================


edgeCaseCases : (Src.Module -> Expectation) -> List TestCase
edgeCaseCases expectFn =
    [ { label = "All expression types in one module", run = allExpressionTypesInOneModule expectFn }
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



-- ============================================================================
-- FROM HigherOrderTests.elm
-- ============================================================================


higherOrderCases : (Src.Module -> Expectation) -> List TestCase
higherOrderCases expectFn =
    [ { label = "Fold-like function", run = foldLikeFunction expectFn }
    ]


foldLikeFunction : (Src.Module -> Expectation) -> (() -> Expectation)
foldLikeFunction expectFn _ =
    let
        foldFn =
            define "myFold"
                [ pVar "f", pVar "init", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], varExpr "init" )
                    , ( pCons (pVar "h") (pVar "t")
                      , callExpr (varExpr "f") [ varExpr "h", varExpr "init" ]
                      )
                    ]
                )

        addFn =
            lambdaExpr [ pVar "a", pVar "b" ] (tupleExpr (varExpr "a") (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ foldFn ]
                    (callExpr (varExpr "myFold") [ addFn, intExpr 0, listExpr [ intExpr 1 ] ])
                )
    in
    expectFn modul



-- ============================================================================
-- FROM LetDestructTests.elm
-- ============================================================================


letDestructCases : (Src.Module -> Expectation) -> List TestCase
letDestructCases expectFn =
    [ { label = "Multiple aliases in destruct", run = multipleAliasesInDestruct expectFn }
    ]


multipleAliasesInDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAliasesInDestruct expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct
                (pAlias
                    (pTuple
                        (pAlias (pVar "a") "first")
                        (pAlias (pVar "b") "second")
                    )
                    "whole"
                )
                pair

        modul =
            makeModule "testValue"
                (letExpr [ def ]
                    (listExpr [ varExpr "whole", varExpr "first", varExpr "second", varExpr "a", varExpr "b" ])
                )
    in
    expectFn modul



-- ============================================================================
-- FROM LetRecTests.elm
-- ============================================================================


letRecCases : (Src.Module -> Expectation) -> List TestCase
letRecCases expectFn =
    [ { label = "Deeply recursive function", run = deeplyRecursiveFn expectFn }
    , { label = "Mutually recursive different types", run = mutuallyRecursiveDifferentTypes expectFn }
    , { label = "Recursive with record pattern", run = recursiveWithRecordPattern expectFn }
    , { label = "Recursive higher order", run = recursiveHigherOrder expectFn }
    ]


deeplyRecursiveFn : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyRecursiveFn expectFn _ =
    let
        fn =
            define "countdown"
                [ pVar "n" ]
                (caseExpr (varExpr "n")
                    [ ( pInt 0, listExpr [] )
                    , ( pVar "x", listExpr [ varExpr "x", callExpr (varExpr "countdown") [ intExpr 0 ] ] )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "countdown") [ intExpr 3 ]))
    in
    expectFn modul


mutuallyRecursiveDifferentTypes : (Src.Module -> Expectation) -> (() -> Expectation)
mutuallyRecursiveDifferentTypes expectFn _ =
    let
        toList =
            define "toList"
                [ pVar "n" ]
                (ifExpr (boolExpr True)
                    (listExpr [])
                    (listExpr [ callExpr (varExpr "toInt") [ intExpr 0 ] ])
                )

        toInt =
            define "toInt"
                [ pVar "xs" ]
                (caseExpr (varExpr "xs")
                    [ ( pList [], intExpr 0 )
                    , ( pAnything, intExpr 1 )
                    ]
                )

        modul =
            makeModule "testValue" (letExpr [ toList, toInt ] (callExpr (varExpr "toList") [ intExpr 3 ]))
    in
    expectFn modul


recursiveWithRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveWithRecordPattern expectFn _ =
    let
        fn =
            define "getValue"
                [ pRecord [ "value", "next" ] ]
                (ifExpr (boolExpr True)
                    (varExpr "value")
                    (callExpr (varExpr "getValue") [ varExpr "next" ])
                )

        arg =
            recordExpr
                [ ( "value", intExpr 1 )
                , ( "next", recordExpr [ ( "value", intExpr 2 ), ( "next", recordExpr [ ( "value", intExpr 3 ), ( "next", recordExpr [] ) ] ) ] )
                ]

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "getValue") [ arg ]))
    in
    expectFn modul


recursiveHigherOrder : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveHigherOrder expectFn _ =
    let
        fn =
            define "map"
                [ pVar "f", pVar "list" ]
                (caseExpr (varExpr "list")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "h") (pVar "t")
                      , listExpr
                            [ callExpr (varExpr "f") [ varExpr "h" ]
                            , callExpr (varExpr "map") [ varExpr "f", varExpr "t" ]
                            ]
                      )
                    ]
                )

        addOne =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ fn ]
                    (callExpr (varExpr "map") [ addOne, listExpr [ intExpr 1, intExpr 2 ] ])
                )
    in
    expectFn modul



-- ============================================================================
-- FROM RecordTests.elm
-- ============================================================================


recordCases : (Src.Module -> Expectation) -> List TestCase
recordCases expectFn =
    [ { label = "Update with computed value", run = updateWithComputedValue expectFn }
    ]


updateWithComputedValue : (Src.Module -> Expectation) -> (() -> Expectation)
updateWithComputedValue expectFn _ =
    let
        record =
            recordExpr [ ( "value", intExpr 10 ) ]

        def =
            define "r" [] record

        newValue =
            tupleExpr (intExpr 1) (intExpr 2)

        update =
            updateExpr (varExpr "r") [ ( "value", newValue ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] update)
    in
    expectFn modul
