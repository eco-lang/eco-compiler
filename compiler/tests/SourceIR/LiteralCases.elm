module SourceIR.LiteralCases exposing (expectSuite)

{-| Tests for literal expressions: Int, Float, String, Char, Unit, Bool.
These tests verify that the canonicalizer assigns unique IDs to literal expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , chrExpr
        , floatExpr
        , intExpr
        , makeModule
        , strExpr
        , unitExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Literal expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ intLiteralCases expectFn
        , floatLiteralCases expectFn
        , stringLiteralCases expectFn
        , charLiteralCases expectFn
        , unitCases expectFn
        , boolCases expectFn
        ]



-- ============================================================================
-- INT LITERALS
-- ============================================================================


intLiteralCases : (Src.Module -> Expectation) -> List TestCase
intLiteralCases expectFn =
    [ { label = "Zero", run = zeroInt expectFn }
    , { label = "Positive int", run = positiveInt expectFn }
    , { label = "Negative int", run = negativeInt expectFn }
    ]


zeroInt : (Src.Module -> Expectation) -> (() -> Expectation)
zeroInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 0)
    in
    expectFn modul


positiveInt : (Src.Module -> Expectation) -> (() -> Expectation)
positiveInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 42)
    in
    expectFn modul


negativeInt : (Src.Module -> Expectation) -> (() -> Expectation)
negativeInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr -42)
    in
    expectFn modul



-- ============================================================================
-- FLOAT LITERALS
-- ============================================================================


floatLiteralCases : (Src.Module -> Expectation) -> List TestCase
floatLiteralCases expectFn =
    [ { label = "Zero float", run = zeroFloat expectFn }
    , { label = "Small positive float", run = smallPositiveFloat expectFn }
    , { label = "Negative float", run = negativeFloat expectFn }
    ]


zeroFloat : (Src.Module -> Expectation) -> (() -> Expectation)
zeroFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 0.0)
    in
    expectFn modul


smallPositiveFloat : (Src.Module -> Expectation) -> (() -> Expectation)
smallPositiveFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 0.001)
    in
    expectFn modul


negativeFloat : (Src.Module -> Expectation) -> (() -> Expectation)
negativeFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr -3.14)
    in
    expectFn modul



-- ============================================================================
-- STRING LITERALS
-- ============================================================================


stringLiteralCases : (Src.Module -> Expectation) -> List TestCase
stringLiteralCases expectFn =
    [ { label = "Empty string", run = emptyString expectFn }
    , { label = "String with escapes", run = stringWithEscapes expectFn }
    , { label = "Unicode string", run = unicodeString expectFn }
    ]


emptyString : (Src.Module -> Expectation) -> (() -> Expectation)
emptyString expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "")
    in
    expectFn modul


stringWithEscapes : (Src.Module -> Expectation) -> (() -> Expectation)
stringWithEscapes expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "hello\\nworld\\ttab")
    in
    expectFn modul


unicodeString : (Src.Module -> Expectation) -> (() -> Expectation)
unicodeString expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "hello 世界")
    in
    expectFn modul



-- ============================================================================
-- CHAR LITERALS
-- ============================================================================


charLiteralCases : (Src.Module -> Expectation) -> List TestCase
charLiteralCases expectFn =
    [ { label = "Letter char", run = letterChar expectFn }
    ]


letterChar : (Src.Module -> Expectation) -> (() -> Expectation)
letterChar expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "a")
    in
    expectFn modul



-- ============================================================================
-- UNIT
-- ============================================================================


unitCases : (Src.Module -> Expectation) -> List TestCase
unitCases expectFn =
    [ { label = "Unit expression", run = unitExpression expectFn }
    ]


unitExpression : (Src.Module -> Expectation) -> (() -> Expectation)
unitExpression expectFn _ =
    let
        modul =
            makeModule "testValue" unitExpr
    in
    expectFn modul



-- ============================================================================
-- BOOL
-- ============================================================================


boolCases : (Src.Module -> Expectation) -> List TestCase
boolCases expectFn =
    [ { label = "True", run = trueExpr expectFn }
    , { label = "False", run = falseExpr expectFn }
    ]


trueExpr : (Src.Module -> Expectation) -> (() -> Expectation)
trueExpr expectFn _ =
    let
        modul =
            makeModule "testValue" (boolExpr True)
    in
    expectFn modul


falseExpr : (Src.Module -> Expectation) -> (() -> Expectation)
falseExpr expectFn _ =
    let
        modul =
            makeModule "testValue" (boolExpr False)
    in
    expectFn modul
