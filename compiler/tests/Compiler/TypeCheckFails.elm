module Compiler.TypeCheckFails exposing (expectSuite)

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
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Type check failure tests " ++ condStr)
        [ Test.test ("Alias everywhere " ++ condStr) (aliasEverywhere expectFn)
        , Test.test ("Multiple aliases in recursive function " ++ condStr) (multipleAliasesInRecursiveFunction expectFn)
        , Test.test ("Case on unit " ++ condStr) (caseOnUnit expectFn)
        , Test.fuzz Fuzz.int ("Case on fuzzed int " ++ condStr) (caseOnFuzzedInt expectFn)
        , Test.test ("All expression types in one module " ++ condStr) (allExpressionTypesInOneModule expectFn)
        , Test.test ("Fold-like function " ++ condStr) (foldLikeFunction expectFn)
        , Test.test ("Multiple aliases in destruct " ++ condStr) (multipleAliasesInDestruct expectFn)
        , Test.test ("Deeply recursive function " ++ condStr) (deeplyRecursiveFn expectFn)
        , Test.test ("Mutually recursive different types " ++ condStr) (mutuallyRecursiveDifferentTypes expectFn)
        , Test.test ("Recursive with record pattern " ++ condStr) (recursiveWithRecordPattern expectFn)
        , Test.test ("Recursive higher order " ++ condStr) (recursiveHigherOrder expectFn)
        , Test.test ("Update with computed value " ++ condStr) (updateWithComputedValue expectFn)
        ]



-- ============================================================================
-- FROM AsPatternTests.elm
-- ============================================================================


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
            makeModuleWithDefs
                [ ( "allAliased", [ pattern ], listExpr [ varExpr "whole", varExpr "first", varExpr "second" ] )
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


caseOnFuzzedInt : (Src.Module -> Expectation) -> (Int -> Expectation)
caseOnFuzzedInt expectFn n =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr n)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pVar "x", varExpr "x" )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- FROM EdgeCaseTests.elm
-- ============================================================================


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
