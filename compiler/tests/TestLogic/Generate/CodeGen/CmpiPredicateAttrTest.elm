module TestLogic.Generate.CodeGen.CmpiPredicateAttrTest exposing (suite)

{-| Test suite for arith.cmpi predicate attribute invariant.

Every `arith.cmpi` operation requires a `predicate` attribute. This test
catches the bug where char equality comparisons (i16) emit `arith.cmpi`
via `ecoBinaryOp` (which only sets `_operand_types`) instead of using
`arithCmpI` (which correctly sets both `_operand_types` and `predicate`).

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , caseExpr
        , chrExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pChr
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPredicateAttr)


suite : Test
suite =
    Test.describe "arith.cmpi predicate attribute"
        [ Test.test "Char case expression emits arith.cmpi with predicate" <|
            \_ -> bulkCheck (testCases expectCmpiPredicateAttr)
        ]


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Simple char case", run = simpleCharCaseTest expectFn }
    , { label = "Multi-branch char case", run = multiBranchCharCaseTest expectFn }
    ]


{-| Minimal reproduction: a case expression matching on a Char value.
The compiler emits arith.cmpi for each char literal branch, but uses
ecoBinaryOp instead of arithCmpI, so the predicate attribute is missing.

    classify : Char -> Int
    classify c =
        case c of
            'a' ->
                1

            _ ->
                0

-}
simpleCharCaseTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCharCaseTest expectFn _ =
    let
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "a", intExpr 1 )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "classify") [ chrExpr "a" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Multiple char branches -- each generates its own arith.cmpi.

    describeChar : Char -> String
    describeChar c =
        case c of
            ',' ->
                "comma"

            '{' ->
                "open brace"

            '}' ->
                "close brace"

            _ ->
                "other"

-}
multiBranchCharCaseTest : (Src.Module -> Expectation) -> (() -> Expectation)
multiBranchCharCaseTest expectFn _ =
    let
        describeCharDef : TypedDef
        describeCharDef =
            { name = "describeChar"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "String" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr ",", strExpr "comma" )
                    , ( pChr "{", strExpr "open brace" )
                    , ( pChr "}", strExpr "close brace" )
                    , ( pVar "_", strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "describeChar") [ chrExpr "," ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ describeCharDef, testValueDef ]
                []
                []
    in
    expectFn modul
