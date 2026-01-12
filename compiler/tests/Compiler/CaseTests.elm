module Compiler.CaseTests exposing (expectSuite)

{-| Tests for case expressions and pattern matching.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionCtor
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAlias
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pRecord
        , pStr
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Case expressions " ++ condStr)
        [ simpleCaseTests expectFn condStr
        , literalPatternTests expectFn condStr
        , tuplePatternTests expectFn condStr
        , listPatternTests expectFn condStr
        , recordPatternTests expectFn condStr
        , aliasPatternTests expectFn condStr
        , nestedCaseTests expectFn condStr
        , customTypePatternTests expectFn condStr
        , caseFuzzTests expectFn condStr
        ]



-- ============================================================================
-- SIMPLE CASE (6 tests)
-- ============================================================================


simpleCaseTests : (Src.Module -> Expectation) -> String -> Test
simpleCaseTests expectFn condStr =
    Test.describe ("Simple case expressions " ++ condStr)
        [ Test.test ("Case on variable with wildcard " ++ condStr) (caseOnVariableWithWildcard expectFn)
        , Test.test ("Case with single variable pattern " ++ condStr) (caseWithSingleVarPattern expectFn)
        , Test.test ("Case with two branches " ++ condStr) (caseWithTwoBranches expectFn)
        , Test.test ("Case with three branches " ++ condStr) (caseWithThreeBranches expectFn)

        -- Moved to TypeCheckFails.elm: , Test.test ("Case on unit " ++ condStr) (caseOnUnit expectFn)
        , Test.test ("Case returning complex expression " ++ condStr) (caseReturningComplexExpr expectFn)
        ]


caseOnVariableWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnVariableWithWildcard expectFn _ =
    let
        subject =
            intExpr 42

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x") [ ( pAnything, intExpr 0 ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


caseWithSingleVarPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithSingleVarPattern expectFn _ =
    let
        subject =
            intExpr 42

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x") [ ( pVar "y", varExpr "y" ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


caseWithTwoBranches : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithTwoBranches expectFn _ =
    let
        subject =
            intExpr 1

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x")
                [ ( pInt 0, strExpr "zero" )
                , ( pAnything, strExpr "other" )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


caseWithThreeBranches : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithThreeBranches expectFn _ =
    let
        subject =
            intExpr 1

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x")
                [ ( pInt 0, strExpr "zero" )
                , ( pInt 1, strExpr "one" )
                , ( pAnything, strExpr "other" )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


caseReturningComplexExpr : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturningComplexExpr expectFn _ =
    let
        subject =
            intExpr 1

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x")
                [ ( pVar "n", tupleExpr (varExpr "n") (listExpr [ varExpr "n" ]) )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul



-- ============================================================================
-- LITERAL PATTERNS (6 tests)
-- ============================================================================


literalPatternTests : (Src.Module -> Expectation) -> String -> Test
literalPatternTests expectFn condStr =
    Test.describe ("Literal pattern matching " ++ condStr)
        [ Test.test ("Case on int literals " ++ condStr) (caseOnIntLiterals expectFn)
        , Test.test ("Case on string literals " ++ condStr) (caseOnStringLiterals expectFn)

        -- Moved to TypeCheckFails.elm: , Test.fuzz Fuzz.int ("Case on fuzzed int " ++ condStr) (caseOnFuzzedInt expectFn)
        , Test.test ("Case with many int branches " ++ condStr) (caseWithManyIntBranches expectFn)
        , Test.fuzz Fuzz.string ("Case on fuzzed string " ++ condStr) (caseOnFuzzedString expectFn)
        , Test.test ("Case with negative int patterns " ++ condStr) (caseWithNegativeIntPatterns expectFn)
        ]


caseOnIntLiterals : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnIntLiterals expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 5)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pInt 5, strExpr "five" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul


caseOnStringLiterals : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnStringLiterals expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (strExpr "hello")
                    [ ( pStr "hello", intExpr 1 )
                    , ( pStr "world", intExpr 2 )
                    , ( pAnything, intExpr 0 )
                    ]
                )
    in
    expectFn modul


caseWithManyIntBranches : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithManyIntBranches expectFn _ =
    let
        branches =
            List.map (\i -> ( pInt i, intExpr (i * 10) )) (List.range 0 9)
                ++ [ ( pAnything, intExpr -1 ) ]

        modul =
            makeModule "testValue" (caseExpr (intExpr 5) branches)
    in
    expectFn modul


caseOnFuzzedString : (Src.Module -> Expectation) -> (String -> Expectation)
caseOnFuzzedString expectFn s =
    let
        modul =
            makeModule "testValue"
                (caseExpr (strExpr s)
                    [ ( pStr "", intExpr 0 )
                    , ( pVar "x", intExpr 1 )
                    ]
                )
    in
    expectFn modul


caseWithNegativeIntPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithNegativeIntPatterns expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr -5)
                    [ ( pInt -1, strExpr "minus one" )
                    , ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERNS (4 tests)
-- ============================================================================


tuplePatternTests : (Src.Module -> Expectation) -> String -> Test
tuplePatternTests expectFn condStr =
    Test.describe ("Tuple pattern matching " ++ condStr)
        [ Test.test ("Case on tuple with var patterns " ++ condStr) (caseOnTupleWithVarPatterns expectFn)
        , Test.test ("Case on tuple with literal patterns " ++ condStr) (caseOnTupleWithLiteralPatterns expectFn)
        , Test.fuzz2 Fuzz.int Fuzz.int ("Case on fuzzed tuple " ++ condStr) (caseOnFuzzedTuple expectFn)
        , Test.test ("Case on nested tuples " ++ condStr) (caseOnNestedTuples expectFn)
        ]


caseOnTupleWithVarPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnTupleWithVarPatterns expectFn _ =
    let
        subject =
            tupleExpr (intExpr 1) (intExpr 2)

        case_ =
            caseExpr subject
                [ ( pTuple (pVar "a") (pVar "b"), tupleExpr (varExpr "b") (varExpr "a") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnTupleWithLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnTupleWithLiteralPatterns expectFn _ =
    let
        subject =
            tupleExpr (intExpr 0) (intExpr 1)

        case_ =
            caseExpr subject
                [ ( pTuple (pInt 0) (pInt 0), strExpr "both zero" )
                , ( pTuple (pInt 0) (pVar "y"), strExpr "first zero" )
                , ( pTuple (pVar "x") (pInt 0), strExpr "second zero" )
                , ( pAnything, strExpr "neither" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnFuzzedTuple : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
caseOnFuzzedTuple expectFn a b =
    let
        subject =
            tupleExpr (intExpr a) (intExpr b)

        case_ =
            caseExpr subject
                [ ( pTuple (pVar "x") (pVar "y"), tupleExpr (varExpr "y") (varExpr "x") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnNestedTuples : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnNestedTuples expectFn _ =
    let
        subject =
            tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (intExpr 3)

        case_ =
            caseExpr subject
                [ ( pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c"), varExpr "a" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- LIST PATTERNS (4 tests)
-- ============================================================================


listPatternTests : (Src.Module -> Expectation) -> String -> Test
listPatternTests expectFn condStr =
    Test.describe ("List pattern matching " ++ condStr)
        [ Test.test ("Case on empty list pattern " ++ condStr) (caseOnEmptyListPattern expectFn)
        , Test.test ("Case on cons pattern " ++ condStr) (caseOnConsPattern expectFn)
        , Test.test ("Case on fixed-length list pattern " ++ condStr) (caseOnFixedLengthListPattern expectFn)
        , Test.test ("Case with nested cons patterns " ++ condStr) (caseWithNestedConsPatterns expectFn)
        ]


caseOnEmptyListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnEmptyListPattern expectFn _ =
    let
        subject =
            listExpr []

        case_ =
            caseExpr subject
                [ ( pList [], strExpr "empty" )
                , ( pAnything, strExpr "not empty" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnConsPattern expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2 ]

        case_ =
            caseExpr subject
                [ ( pCons (pVar "head") (pVar "tail"), varExpr "head" )
                , ( pList [], intExpr 0 )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnFixedLengthListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnFixedLengthListPattern expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        case_ =
            caseExpr subject
                [ ( pList [ pVar "a", pVar "b", pVar "c" ], varExpr "b" )
                , ( pAnything, intExpr 0 )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseWithNestedConsPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithNestedConsPatterns expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        case_ =
            caseExpr subject
                [ ( pCons (pVar "a") (pCons (pVar "b") (pVar "rest")), varExpr "b" )
                , ( pAnything, intExpr 0 )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- RECORD PATTERNS (4 tests)
-- ============================================================================


recordPatternTests : (Src.Module -> Expectation) -> String -> Test
recordPatternTests expectFn condStr =
    Test.describe ("Record pattern matching " ++ condStr)
        [ Test.test ("Case on single-field record pattern " ++ condStr) (caseOnSingleFieldRecordPattern expectFn)
        , Test.test ("Case on multi-field record pattern " ++ condStr) (caseOnMultiFieldRecordPattern expectFn)
        , Test.fuzz Fuzz.int ("Case on fuzzed record " ++ condStr) (caseOnFuzzedRecord expectFn)
        , Test.test ("Case on partial record pattern " ++ condStr) (caseOnPartialRecordPattern expectFn)
        ]


caseOnSingleFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnSingleFieldRecordPattern expectFn _ =
    let
        subject =
            recordExpr [ ( "x", intExpr 10 ) ]

        case_ =
            caseExpr subject
                [ ( pRecord [ "x" ], varExpr "x" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnMultiFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnMultiFieldRecordPattern expectFn _ =
    let
        subject =
            recordExpr [ ( "x", intExpr 10 ), ( "y", intExpr 20 ) ]

        case_ =
            caseExpr subject
                [ ( pRecord [ "x", "y" ], tupleExpr (varExpr "x") (varExpr "y") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnFuzzedRecord : (Src.Module -> Expectation) -> (Int -> Expectation)
caseOnFuzzedRecord expectFn n =
    let
        subject =
            recordExpr [ ( "value", intExpr n ) ]

        case_ =
            caseExpr subject
                [ ( pRecord [ "value" ], varExpr "value" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseOnPartialRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnPartialRecordPattern expectFn _ =
    let
        subject =
            recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ) ]

        case_ =
            caseExpr subject
                [ ( pRecord [ "a", "c" ], tupleExpr (varExpr "a") (varExpr "c") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- ALIAS PATTERNS (4 tests)
-- ============================================================================


aliasPatternTests : (Src.Module -> Expectation) -> String -> Test
aliasPatternTests expectFn condStr =
    Test.describe ("Alias pattern matching " ++ condStr)
        [ Test.test ("Case with simple alias pattern " ++ condStr) (caseWithSimpleAliasPattern expectFn)
        , Test.test ("Case with tuple alias pattern " ++ condStr) (caseWithTupleAliasPattern expectFn)
        , Test.test ("Case with list alias pattern " ++ condStr) (caseWithListAliasPattern expectFn)
        , Test.fuzz Fuzz.int ("Case with fuzzed alias pattern " ++ condStr) (caseWithFuzzedAliasPattern expectFn)
        ]


caseWithSimpleAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithSimpleAliasPattern expectFn _ =
    let
        subject =
            intExpr 42

        case_ =
            caseExpr subject
                [ ( pAlias (pVar "x") "whole", tupleExpr (varExpr "x") (varExpr "whole") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseWithTupleAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithTupleAliasPattern expectFn _ =
    let
        subject =
            tupleExpr (intExpr 1) (intExpr 2)

        case_ =
            caseExpr subject
                [ ( pAlias (pTuple (pVar "a") (pVar "b")) "pair", varExpr "pair" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseWithListAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithListAliasPattern expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2 ]

        case_ =
            caseExpr subject
                [ ( pAlias (pCons (pVar "h") (pVar "t")) "list", varExpr "list" )
                , ( pList [], listExpr [] )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseWithFuzzedAliasPattern : (Src.Module -> Expectation) -> (Int -> Expectation)
caseWithFuzzedAliasPattern expectFn n =
    let
        subject =
            intExpr n

        case_ =
            caseExpr subject
                [ ( pAlias (pVar "x") "y", tupleExpr (varExpr "x") (varExpr "y") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- NESTED CASE (2 tests)
-- ============================================================================


nestedCaseTests : (Src.Module -> Expectation) -> String -> Test
nestedCaseTests expectFn condStr =
    Test.describe ("Nested case expressions " ++ condStr)
        [ Test.test ("Case inside case " ++ condStr) (caseInsideCase expectFn)
        , Test.test ("Case in branch body " ++ condStr) (caseInBranchBody expectFn)
        ]


caseInsideCase : (Src.Module -> Expectation) -> (() -> Expectation)
caseInsideCase expectFn _ =
    let
        innerCase =
            caseExpr (intExpr 1)
                [ ( pInt 0, strExpr "zero" )
                , ( pAnything, strExpr "other" )
                ]

        outerCase =
            caseExpr (intExpr 2)
                [ ( pInt 0, strExpr "outer zero" )
                , ( pAnything, innerCase )
                ]

        modul =
            makeModule "testValue" outerCase
    in
    expectFn modul


caseInBranchBody : (Src.Module -> Expectation) -> (() -> Expectation)
caseInBranchBody expectFn _ =
    let
        case_ =
            caseExpr (tupleExpr (intExpr 1) (intExpr 2))
                [ ( pTuple (pVar "a") (pVar "b")
                  , caseExpr (varExpr "a")
                        [ ( pInt 0, varExpr "b" )
                        , ( pAnything, varExpr "a" )
                        ]
                  )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- CUSTOM TYPE PATTERNS (2 tests)
-- ============================================================================


customTypePatternTests : (Src.Module -> Expectation) -> String -> Test
customTypePatternTests expectFn condStr =
    Test.describe ("Custom type pattern matching " ++ condStr)
        [ Test.test ("Case on custom type with multiple constructors " ++ condStr) (caseOnCustomTypeMultipleConstructors expectFn)
        , Test.test ("Case on custom type with payload extraction " ++ condStr) (caseOnCustomTypePayloadExtraction expectFn)
        ]


{-| Tests case expression on a custom type with multiple constructors.
Corresponds to E2E test: CaseCustomTypeTest.elm

    type Shape
        = Circle Int
        | Rectangle Int Int

    area shape =
        case shape of
            Circle r -> r * r
            Rectangle w h -> w * h

-}
caseOnCustomTypeMultipleConstructors : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnCustomTypeMultipleConstructors expectFn _ =
    let
        -- Define the Shape union type
        shapeUnion : UnionDef
        shapeUnion =
            { name = "Shape"
            , args = []
            , ctors =
                [ { name = "Circle", args = [ tType "Int" [] ] }
                , { name = "Rectangle", args = [ tType "Int" [], tType "Int" [] ] }
                ]
            }

        -- Define the area function
        -- area : Shape -> Int
        -- area shape = case shape of ...
        areaFn : TypedDef
        areaFn =
            { name = "area"
            , args = [ pVar "shape" ]
            , tipe = tLambda (tType "Shape" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "shape")
                    [ ( pCtor "Circle" [ pVar "r" ]
                      , binopsExpr [ ( varExpr "r", "*" ) ] (varExpr "r")
                      )
                    , ( pCtor "Rectangle" [ pVar "w", pVar "h" ]
                      , binopsExpr [ ( varExpr "w", "*" ) ] (varExpr "h")
                      )
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ areaFn ] [ shapeUnion ] []
    in
    expectFn modul


{-| Tests case expression that extracts values from a custom type.
Similar to the area function but focused on extraction.
-}
caseOnCustomTypePayloadExtraction : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnCustomTypePayloadExtraction expectFn _ =
    let
        -- Define a simple wrapper type
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors =
                [ { name = "Wrap", args = [ tType "Int" [] ] }
                ]
            }

        -- Define the unwrap function
        -- unwrap : Wrapper -> Int
        -- unwrap w = case w of Wrap x -> x
        unwrapFn : TypedDef
        unwrapFn =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrapper" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pVar "x" ], varExpr "x" )
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ unwrapFn ] [ wrapperUnion ] []
    in
    expectFn modul



-- ============================================================================
-- FUZZ TESTS (2 tests)
-- ============================================================================


caseFuzzTests : (Src.Module -> Expectation) -> String -> Test
caseFuzzTests expectFn condStr =
    Test.describe ("Fuzzed case tests " ++ condStr)
        [ Test.fuzz2 Fuzz.int Fuzz.int ("Case with fuzzed tuple values " ++ condStr) (caseWithFuzzedTupleValues expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Case with fuzzed list values " ++ condStr) (caseWithFuzzedListValues expectFn)
        ]


caseWithFuzzedTupleValues : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
caseWithFuzzedTupleValues expectFn a b =
    let
        case_ =
            caseExpr (tupleExpr (intExpr a) (intExpr b))
                [ ( pTuple (pVar "x") (pVar "y"), tupleExpr (varExpr "y") (varExpr "x") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


caseWithFuzzedListValues : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
caseWithFuzzedListValues expectFn a b c =
    let
        case_ =
            caseExpr (listExpr [ intExpr a, intExpr b, intExpr c ])
                [ ( pCons (pVar "h") (pVar "t"), varExpr "h" )
                , ( pList [], intExpr 0 )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul
