module SourceIR.AsPatternCases exposing (expectSuite)

{-| Tests for as-patterns (alias patterns).
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , caseExpr
        , define
        , destruct
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , pAlias
        , pAnything
        , pCons
        , pList
        , pRecord
        , pTuple
        , pTuple3
        , pVar
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("As-pattern tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ simpleAliasCases expectFn
        , tupleAliasCases expectFn
        , recordAliasCases expectFn
        , listAliasCases expectFn
        , nestedAliasCases expectFn
        , aliasInFunctionsCases expectFn
        , aliasAdditionalCases expectFn
        ]



-- ============================================================================
-- SIMPLE ALIAS (4 tests)
-- ============================================================================


simpleAliasCases : (Src.Module -> Expectation) -> List TestCase
simpleAliasCases expectFn =
    [ { label = "Alias on variable", run = aliasOnVariable expectFn }
    , { label = "Alias on wildcard", run = aliasOnWildcard expectFn }
    , { label = "Multiple aliases", run = multipleAliases expectFn }
    , { label = "Alias in lambda", run = aliasInLambda expectFn }
    ]


aliasOnVariable : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "dup", [ pAlias (pVar "x") "y" ], tupleExpr (varExpr "x") (varExpr "y") )
                , ( "testValue", [], callExpr (varExpr "dup") [ intExpr 1 ] )
                ]
    in
    expectFn modul


aliasOnWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnWildcard expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "capture", [ pAlias pAnything "x" ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "capture") [ intExpr 1 ] )
                ]
    in
    expectFn modul


multipleAliases : (Src.Module -> Expectation) -> (() -> Expectation)
multipleAliases expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "both"
                  , [ pAlias (pVar "a") "x", pAlias (pVar "b") "y" ]
                  , tupleExpr (varExpr "x") (varExpr "y")
                  )
                , ( "testValue", [], callExpr (varExpr "both") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


aliasInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pAlias (pVar "x") "whole" ] (tupleExpr (varExpr "x") (varExpr "whole"))

        modul =
            makeModule "testValue" (callExpr fn [ intExpr 1 ])
    in
    expectFn modul



-- ============================================================================
-- TUPLE ALIAS (4 tests)
-- ============================================================================


tupleAliasCases : (Src.Module -> Expectation) -> List TestCase
tupleAliasCases expectFn =
    [ { label = "Alias on 2-tuple", run = aliasOn2Tuple expectFn }
    , { label = "Alias on 3-tuple", run = aliasOn3Tuple expectFn }
    , { label = "Nested alias in tuple", run = nestedAliasInTuple expectFn }
    , { label = "Alias on nested tuple", run = aliasOnNestedTuple expectFn }
    ]


aliasOn2Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOn2Tuple expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withPair"
                  , [ pAlias (pTuple (pVar "a") (pVar "b")) "pair" ]
                  , tupleExpr (varExpr "pair") (varExpr "a")
                  )
                , ( "testValue", [], callExpr (varExpr "withPair") [ tupleExpr (intExpr 1) (strExpr "a") ] )
                ]
    in
    expectFn modul


aliasOn3Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOn3Tuple expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withTriple"
                  , [ pAlias (pTuple3 (pVar "a") (pVar "b") (pVar "c")) "triple" ]
                  , varExpr "triple"
                  )
                , ( "testValue", [], callExpr (varExpr "withTriple") [ tuple3Expr (intExpr 1) (strExpr "a") (intExpr 2) ] )
                ]
    in
    expectFn modul


nestedAliasInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
nestedAliasInTuple expectFn _ =
    let
        pattern =
            pTuple (pAlias (pVar "x") "first") (pAlias (pVar "y") "second")

        modul =
            makeModuleWithDefs "Test"
                [ ( "parts", [ pattern ], listExpr [ varExpr "first", varExpr "second" ] )
                , ( "testValue", [], callExpr (varExpr "parts") [ tupleExpr (intExpr 1) (intExpr 2) ] )
                ]
    in
    expectFn modul


aliasOnNestedTuple : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnNestedTuple expectFn _ =
    let
        pattern =
            pAlias (pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c")) "whole"

        modul =
            makeModuleWithDefs "Test"
                [ ( "deep", [ pattern ], varExpr "whole" )
                , ( "testValue", [], callExpr (varExpr "deep") [ tupleExpr (tupleExpr (intExpr 1) (strExpr "a")) (intExpr 2) ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- RECORD ALIAS (4 tests)
-- ============================================================================


recordAliasCases : (Src.Module -> Expectation) -> List TestCase
recordAliasCases expectFn =
    [ { label = "Alias on record pattern", run = aliasOnRecordPattern expectFn }
    , { label = "Multiple record aliases", run = multipleRecordAliases expectFn }
    , { label = "Alias on record with many fields", run = aliasOnRecordWithManyFields expectFn }
    ]


aliasOnRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnRecordPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withRecord"
                  , [ pAlias (pRecord [ "x", "y" ]) "point" ]
                  , tupleExpr (varExpr "point") (varExpr "x")
                  )
                , ( "testValue", [], callExpr (varExpr "withRecord") [ recordExpr [ ( "x", intExpr 1 ), ( "y", strExpr "a" ) ] ] )
                ]
    in
    expectFn modul


multipleRecordAliases : (Src.Module -> Expectation) -> (() -> Expectation)
multipleRecordAliases expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "combine"
                  , [ pAlias (pRecord [ "a" ]) "r1", pAlias (pRecord [ "b" ]) "r2" ]
                  , tupleExpr (varExpr "r1") (varExpr "r2")
                  )
                , ( "testValue", [], callExpr (varExpr "combine") [ recordExpr [ ( "a", intExpr 1 ) ], recordExpr [ ( "b", strExpr "a" ) ] ] )
                ]
    in
    expectFn modul


aliasOnRecordWithManyFields : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnRecordWithManyFields expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "allFields"
                  , [ pAlias (pRecord [ "a", "b", "c", "d" ]) "rec" ]
                  , varExpr "rec"
                  )
                , ( "testValue", [], callExpr (varExpr "allFields") [ recordExpr [ ( "a", intExpr 1 ), ( "b", strExpr "a" ), ( "c", intExpr 2 ), ( "d", strExpr "b" ) ] ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- LIST ALIAS (4 tests)
-- ============================================================================


listAliasCases : (Src.Module -> Expectation) -> List TestCase
listAliasCases expectFn =
    [ { label = "Alias on cons pattern", run = aliasOnConsPattern expectFn }
    , { label = "Alias on fixed list pattern", run = aliasOnFixedListPattern expectFn }
    , { label = "Nested alias in list", run = nestedAliasInList expectFn }
    , { label = "Alias on nested cons", run = aliasOnNestedCons expectFn }
    ]


aliasOnConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnConsPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "withList"
                  , [ pAlias (pCons (pVar "h") (pVar "t")) "list" ]
                  , tupleExpr (varExpr "list") (varExpr "h")
                  )
                , ( "testValue", [], callExpr (varExpr "withList") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


aliasOnFixedListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnFixedListPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "pairList"
                  , [ pAlias (pList [ pVar "a", pVar "b" ]) "both" ]
                  , varExpr "both"
                  )
                , ( "testValue", [], callExpr (varExpr "pairList") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


nestedAliasInList : (Src.Module -> Expectation) -> (() -> Expectation)
nestedAliasInList expectFn _ =
    let
        pattern =
            pCons (pAlias (pVar "h") "head") (pAlias (pVar "t") "tail")

        modul =
            makeModuleWithDefs "Test"
                [ ( "parts", [ pattern ], tupleExpr (varExpr "head") (varExpr "tail") )
                , ( "testValue", [], callExpr (varExpr "parts") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


aliasOnNestedCons : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnNestedCons expectFn _ =
    let
        pattern =
            pAlias (pCons (pVar "a") (pCons (pVar "b") (pVar "rest"))) "list"

        modul =
            makeModuleWithDefs "Test"
                [ ( "twoOrMore", [ pattern ], varExpr "list" )
                , ( "testValue", [], callExpr (varExpr "twoOrMore") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- NESTED ALIAS (4 tests)
-- ============================================================================


nestedAliasCases : (Src.Module -> Expectation) -> List TestCase
nestedAliasCases expectFn =
    [ { label = "Multiple levels of alias", run = multipleLevelsOfAlias expectFn }
    , { label = "Alias in deeply nested structure", run = aliasInDeeplyNestedStructure expectFn }

    -- Moved to TypeCheckFails.elm: , { label = "Alias everywhere", run = aliasEverywhere expectFn }
    , { label = "Mixed nested aliases", run = mixedNestedAliases expectFn }
    ]


multipleLevelsOfAlias : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLevelsOfAlias expectFn _ =
    let
        pattern =
            pAlias (pAlias (pVar "x") "inner") "outer"

        modul =
            makeModuleWithDefs "Test"
                [ ( "levels", [ pattern ], listExpr [ varExpr "x", varExpr "inner", varExpr "outer" ] )
                , ( "testValue", [], callExpr (varExpr "levels") [ intExpr 1 ] )
                ]
    in
    expectFn modul


aliasInDeeplyNestedStructure : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInDeeplyNestedStructure expectFn _ =
    let
        pattern =
            pTuple
                (pAlias (pTuple (pVar "a") (pVar "b")) "inner")
                (pVar "c")

        modul =
            makeModuleWithDefs "Test"
                [ ( "deep", [ pattern ], tupleExpr (varExpr "inner") (varExpr "a") )
                , ( "testValue", [], callExpr (varExpr "deep") [ tupleExpr (tupleExpr (intExpr 1) (strExpr "a")) (intExpr 2) ] )
                ]
    in
    expectFn modul


mixedNestedAliases : (Src.Module -> Expectation) -> (() -> Expectation)
mixedNestedAliases expectFn _ =
    let
        pattern =
            pAlias
                (pTuple
                    (pRecord [ "x" ])
                    (pAlias (pCons (pVar "h") pAnything) "list")
                )
                "all"

        modul =
            makeModuleWithDefs "Test"
                [ ( "mixed", [ pattern ], varExpr "all" )
                , ( "testValue", [], callExpr (varExpr "mixed") [ tupleExpr (recordExpr [ ( "x", intExpr 1 ) ]) (listExpr [ intExpr 1, intExpr 2 ]) ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- ALIAS IN FUNCTIONS (4 tests)
-- ============================================================================


aliasInFunctionsCases : (Src.Module -> Expectation) -> List TestCase
aliasInFunctionsCases expectFn =
    [ { label = "Alias in let destruct", run = aliasInLetDestruct expectFn }
    , { label = "Alias used in function body", run = aliasUsedInFunctionBody expectFn }

    -- Moved to TypeCheckFails.elm: , { label = "Multiple alias patterns in recursive function", run = multipleAliasesInRecursiveFunction expectFn }
    ]


aliasInLetDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInLetDestruct expectFn _ =
    let
        def =
            destruct (pAlias (pTuple (pVar "a") (pVar "b")) "pair") (tupleExpr (intExpr 1) (intExpr 2))

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "pair"))
    in
    expectFn modul


aliasUsedInFunctionBody : (Src.Module -> Expectation) -> (() -> Expectation)
aliasUsedInFunctionBody expectFn _ =
    let
        fn =
            define "process"
                [ pAlias (pVar "x") "original" ]
                (tupleExpr (varExpr "original") (varExpr "x"))

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "process") [ intExpr 42 ]))
    in
    expectFn modul



-- ============================================================================
-- ADDITIONAL ALIAS TESTS (2 tests)
-- ============================================================================


aliasAdditionalCases : (Src.Module -> Expectation) -> List TestCase
aliasAdditionalCases expectFn =
    [ { label = "Alias with value", run = aliasWithValue expectFn }
    ]


aliasWithValue : (Src.Module -> Expectation) -> (() -> Expectation)
aliasWithValue expectFn _ =
    let
        case_ =
            caseExpr (intExpr 42)
                [ ( pAlias (pVar "x") "val", tupleExpr (varExpr "x") (varExpr "val") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul
