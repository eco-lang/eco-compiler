module Compiler.AsPatternTests exposing (expectSuite)

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
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("As-pattern tests " ++ condStr)
        [ simpleAliasTests expectFn condStr
        , tupleAliasTests expectFn condStr
        , recordAliasTests expectFn condStr
        , listAliasTests expectFn condStr
        , nestedAliasTests expectFn condStr
        , aliasInFunctionsTests expectFn condStr
        , aliasAdditionalTests expectFn condStr
        ]



-- ============================================================================
-- SIMPLE ALIAS (4 tests)
-- ============================================================================


simpleAliasTests : (Src.Module -> Expectation) -> String -> Test
simpleAliasTests expectFn condStr =
    Test.describe ("Simple alias patterns " ++ condStr)
        [ Test.test ("Alias on variable " ++ condStr) (aliasOnVariable expectFn)
        , Test.test ("Alias on wildcard " ++ condStr) (aliasOnWildcard expectFn)
        , Test.test ("Multiple aliases " ++ condStr) (multipleAliases expectFn)
        , Test.test ("Alias in lambda " ++ condStr) (aliasInLambda expectFn)
        ]


aliasOnVariable : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "dup", [ pAlias (pVar "x") "y" ], tupleExpr (varExpr "x") (varExpr "y") )
                ]
    in
    expectFn modul


aliasOnWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnWildcard expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "capture", [ pAlias pAnything "x" ], varExpr "x" )
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
                ]
    in
    expectFn modul


aliasInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pAlias (pVar "x") "whole" ] (tupleExpr (varExpr "x") (varExpr "whole"))

        modul =
            makeModule "testValue" fn
    in
    expectFn modul



-- ============================================================================
-- TUPLE ALIAS (4 tests)
-- ============================================================================


tupleAliasTests : (Src.Module -> Expectation) -> String -> Test
tupleAliasTests expectFn condStr =
    Test.describe ("Tuple alias patterns " ++ condStr)
        [ Test.test ("Alias on 2-tuple " ++ condStr) (aliasOn2Tuple expectFn)
        , Test.test ("Alias on 3-tuple " ++ condStr) (aliasOn3Tuple expectFn)
        , Test.test ("Nested alias in tuple " ++ condStr) (nestedAliasInTuple expectFn)
        , Test.test ("Alias on nested tuple " ++ condStr) (aliasOnNestedTuple expectFn)
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
                ]
    in
    expectFn modul



-- ============================================================================
-- RECORD ALIAS (4 tests)
-- ============================================================================


recordAliasTests : (Src.Module -> Expectation) -> String -> Test
recordAliasTests expectFn condStr =
    Test.describe ("Record alias patterns " ++ condStr)
        [ Test.test ("Alias on record pattern " ++ condStr) (aliasOnRecordPattern expectFn)
        , Test.test ("Alias on single-field record " ++ condStr) (aliasOnSingleFieldRecord expectFn)
        , Test.test ("Multiple record aliases " ++ condStr) (multipleRecordAliases expectFn)
        , Test.test ("Alias on record with many fields " ++ condStr) (aliasOnRecordWithManyFields expectFn)
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
                ]
    in
    expectFn modul


aliasOnSingleFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
aliasOnSingleFieldRecord expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "getValue"
                  , [ pAlias (pRecord [ "value" ]) "wrapper" ]
                  , tupleExpr (varExpr "wrapper") (varExpr "value")
                  )
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
                ]
    in
    expectFn modul



-- ============================================================================
-- LIST ALIAS (4 tests)
-- ============================================================================


listAliasTests : (Src.Module -> Expectation) -> String -> Test
listAliasTests expectFn condStr =
    Test.describe ("List alias patterns " ++ condStr)
        [ Test.test ("Alias on cons pattern " ++ condStr) (aliasOnConsPattern expectFn)
        , Test.test ("Alias on fixed list pattern " ++ condStr) (aliasOnFixedListPattern expectFn)
        , Test.test ("Nested alias in list " ++ condStr) (nestedAliasInList expectFn)
        , Test.test ("Alias on nested cons " ++ condStr) (aliasOnNestedCons expectFn)
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
                ]
    in
    expectFn modul



-- ============================================================================
-- NESTED ALIAS (4 tests)
-- ============================================================================


nestedAliasTests : (Src.Module -> Expectation) -> String -> Test
nestedAliasTests expectFn condStr =
    Test.describe ("Nested alias patterns " ++ condStr)
        [ Test.test ("Multiple levels of alias " ++ condStr) (multipleLevelsOfAlias expectFn)
        , Test.test ("Alias in deeply nested structure " ++ condStr) (aliasInDeeplyNestedStructure expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Alias everywhere " ++ condStr) (aliasEverywhere expectFn)
        , Test.test ("Mixed nested aliases " ++ condStr) (mixedNestedAliases expectFn)
        ]


multipleLevelsOfAlias : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLevelsOfAlias expectFn _ =
    let
        pattern =
            pAlias (pAlias (pVar "x") "inner") "outer"

        modul =
            makeModuleWithDefs "Test"
                [ ( "levels", [ pattern ], listExpr [ varExpr "x", varExpr "inner", varExpr "outer" ] )
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
                ]
    in
    expectFn modul



-- ============================================================================
-- ALIAS IN FUNCTIONS (4 tests)
-- ============================================================================


aliasInFunctionsTests : (Src.Module -> Expectation) -> String -> Test
aliasInFunctionsTests expectFn condStr =
    Test.describe ("Alias in function contexts " ++ condStr)
        [ Test.test ("Alias in case branch " ++ condStr) (aliasInCaseBranch expectFn)
        , Test.test ("Alias in let destruct " ++ condStr) (aliasInLetDestruct expectFn)
        , Test.test ("Alias used in function body " ++ condStr) (aliasUsedInFunctionBody expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Multiple alias patterns in recursive function " ++ condStr) (multipleAliasesInRecursiveFunction expectFn)
        ]


aliasInCaseBranch : (Src.Module -> Expectation) -> (() -> Expectation)
aliasInCaseBranch expectFn _ =
    let
        case_ =
            caseExpr (tupleExpr (intExpr 1) (intExpr 2))
                [ ( pAlias (pTuple (pVar "a") (pVar "b")) "pair", varExpr "pair" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


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


aliasAdditionalTests : (Src.Module -> Expectation) -> String -> Test
aliasAdditionalTests expectFn condStr =
    Test.describe ("Additional alias tests " ++ condStr)
        [ Test.test ("Alias pattern with tuple values " ++ condStr) (aliasPatternWithTupleValues expectFn)
        , Test.test ("Alias with value " ++ condStr) (aliasWithValue expectFn)
        ]


aliasPatternWithTupleValues : (Src.Module -> Expectation) -> (() -> Expectation)
aliasPatternWithTupleValues expectFn _ =
    let
        fn =
            define "f"
                [ pAlias (pTuple (pVar "x") (pVar "y")) "pair" ]
                (tupleExpr (varExpr "pair") (varExpr "x"))

        call =
            callExpr (varExpr "f") [ tupleExpr (intExpr 1) (intExpr 2) ]

        modul =
            makeModule "testValue" (letExpr [ fn ] call)
    in
    expectFn modul


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
