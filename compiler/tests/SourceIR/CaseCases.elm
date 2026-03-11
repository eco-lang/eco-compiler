module SourceIR.CaseCases exposing (expectSuite)

{-| Tests for case expressions and pattern matching.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
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
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Case expressions " ++ condStr) (\() -> bulkCheck (testCases expectFn))


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    simpleCaseCases expectFn
        ++ literalPatternCases expectFn
        ++ tuplePatternCases expectFn
        ++ listPatternCases expectFn
        ++ recordPatternCases expectFn
        ++ aliasPatternCases expectFn
        ++ nestedCaseCases expectFn
        ++ customTypePatternCases expectFn
        ++ stringChainKernelAbiCases expectFn



-- ============================================================================
-- SIMPLE CASE (6 tests)
-- ============================================================================


simpleCaseCases : (Src.Module -> Expectation) -> List TestCase
simpleCaseCases expectFn =
    [ { label = "Case on variable with wildcard", run = caseOnVariableWithWildcard expectFn }
    , { label = "Case with single variable pattern", run = caseWithSingleVarPattern expectFn }
    , { label = "Case with two branches", run = caseWithTwoBranches expectFn }
    , { label = "Case with three branches", run = caseWithThreeBranches expectFn }

    -- Moved to TypeCheckFails.elm: , { label = "Case on unit", run = caseOnUnit expectFn }
    , { label = "Case returning complex expression", run = caseReturningComplexExpr expectFn }
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


literalPatternCases : (Src.Module -> Expectation) -> List TestCase
literalPatternCases expectFn =
    [ { label = "Case on int literals", run = caseOnIntLiterals expectFn }
    , { label = "Case on string literals", run = caseOnStringLiterals expectFn }

    -- Moved to TypeCheckFails.elm: , { label = "Case on fuzzed int", run = caseOnFuzzedInt expectFn }
    , { label = "Case with many int branches", run = caseWithManyIntBranches expectFn }
    , { label = "Case on string", run = caseOnString expectFn }
    , { label = "Case with negative int patterns", run = caseWithNegativeIntPatterns expectFn }
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


caseOnString : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnString expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (strExpr "hello")
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


tuplePatternCases : (Src.Module -> Expectation) -> List TestCase
tuplePatternCases expectFn =
    [ { label = "Case on tuple with var patterns", run = caseOnTupleWithVarPatterns expectFn }
    , { label = "Case on tuple with literal patterns", run = caseOnTupleWithLiteralPatterns expectFn }
    , { label = "Case on nested tuples", run = caseOnNestedTuples expectFn }
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


listPatternCases : (Src.Module -> Expectation) -> List TestCase
listPatternCases expectFn =
    [ { label = "Case on empty list pattern", run = caseOnEmptyListPattern expectFn }
    , { label = "Case on cons pattern", run = caseOnConsPattern expectFn }
    , { label = "Case on fixed-length list pattern", run = caseOnFixedLengthListPattern expectFn }
    , { label = "Case with nested cons patterns", run = caseWithNestedConsPatterns expectFn }
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


recordPatternCases : (Src.Module -> Expectation) -> List TestCase
recordPatternCases expectFn =
    [ { label = "Case on single-field record pattern", run = caseOnSingleFieldRecordPattern expectFn }
    , { label = "Case on multi-field record pattern", run = caseOnMultiFieldRecordPattern expectFn }
    , { label = "Case on partial record pattern", run = caseOnPartialRecordPattern expectFn }
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


aliasPatternCases : (Src.Module -> Expectation) -> List TestCase
aliasPatternCases expectFn =
    [ { label = "Case with simple alias pattern", run = caseWithSimpleAliasPattern expectFn }
    , { label = "Case with tuple alias pattern", run = caseWithTupleAliasPattern expectFn }
    , { label = "Case with list alias pattern", run = caseWithListAliasPattern expectFn }
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



-- ============================================================================
-- NESTED CASE (2 tests)
-- ============================================================================


nestedCaseCases : (Src.Module -> Expectation) -> List TestCase
nestedCaseCases expectFn =
    [ { label = "Case inside case", run = caseInsideCase expectFn }
    , { label = "Case in branch body", run = caseInBranchBody expectFn }
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


customTypePatternCases : (Src.Module -> Expectation) -> List TestCase
customTypePatternCases expectFn =
    [ { label = "Case on custom type with multiple constructors", run = caseOnCustomTypeMultipleConstructors expectFn }
    , { label = "Case on custom type with payload extraction", run = caseOnCustomTypePayloadExtraction expectFn }
    ]


{-| Tests case expression on a custom type with multiple constructors.
Corresponds to E2E test: CaseCustomTypeTest.elm

    type Shape
        = Circle Int
        | Rectangle Int Int

    area shape =
        case shape of
            Circle r ->
                r * r

            Rectangle w h ->
                w * h

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

        -- testValue : Int
        -- testValue = area (Circle 5)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "area") [ callExpr (ctorExpr "Circle") [ intExpr 5 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ areaFn, testValueDef ] [ shapeUnion ] []
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

        -- testValue : Int
        -- testValue = unwrap (Wrap 99)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "unwrap") [ callExpr (ctorExpr "Wrap") [ intExpr 99 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ unwrapFn, testValueDef ] [ wrapperUnion ] []
    in
    expectFn modul



-- ============================================================================
-- STRING CHAIN + KERNEL ABI (CGEN_038 regression)
-- ============================================================================


stringChainKernelAbiCases : (Src.Module -> Expectation) -> List TestCase
stringChainKernelAbiCases expectFn =
    [ { label = "String chain in tuple case with string equality (CGEN_038)", run = stringChainWithStringEquality expectFn }
    ]


{-| Regression test for CGEN\_038 / KERN\_006: Kernel ABI consistency.

When a case on (String, Bool) matches string+bool patterns, the decision tree
produces a Chain with IsStr test that calls Patterns.generateTest, which
calls Utils\_equal with i1 return. If the same module also uses (==) on
strings/lists, that registers Utils\_equal with eco.value return via the
AllBoxed kernel ABI path. The two registrations must not conflict.

Elm equivalent:

    testValue x =
        let
            eq = x == "world"
            r = case ( x, True ) of
                    ( "foo", True ) -> 1
                    ( "bar", False ) -> 2
                    \_ -> 0
        in
        if eq then r else 0

-}
stringChainWithStringEquality : (Src.Module -> Expectation) -> (() -> Expectation)
stringChainWithStringEquality expectFn _ =
    let
        eqDef =
            define "eq"
                []
                (binopsExpr [ ( varExpr "x", "==" ) ] (strExpr "world"))

        rDef =
            define "r"
                []
                (caseExpr (tupleExpr (varExpr "x") (boolExpr True))
                    [ ( pTuple (pStr "foo") (pCtor "True" []), intExpr 1 )
                    , ( pTuple (pStr "bar") (pCtor "False" []), intExpr 2 )
                    , ( pAnything, intExpr 0 )
                    ]
                )

        body =
            ifExpr (varExpr "eq") (varExpr "r") (intExpr 0)

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn"
                  , [ pVar "x" ]
                  , letExpr [ eqDef, rDef ] body
                  )
                , ( "testValue"
                  , []
                  , callExpr (varExpr "testFn") [ strExpr "hello" ]
                  )
                ]
    in
    expectFn modul
