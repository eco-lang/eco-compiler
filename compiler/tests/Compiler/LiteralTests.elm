module Compiler.LiteralTests exposing (expectSuite)

{-| Tests for literal expressions: Int, Float, String, Char, Unit, Bool.
These tests verify that the canonicalizer assigns unique IDs to literal expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , charFuzzer
        , chrExpr
        , floatExpr
        , intExpr
        , makeModule
        , strExpr
        , unitExpr
        )
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Literal expressions " ++ condStr)
        [ intLiteralTests expectFn condStr
        , floatLiteralTests expectFn condStr
        , stringLiteralTests expectFn condStr
        , charLiteralTests expectFn condStr
        , unitTests expectFn condStr
        , boolTests expectFn condStr
        , combinedLiteralTests expectFn condStr
        ]



-- ============================================================================
-- INT LITERALS (8 tests)
-- ============================================================================


intLiteralTests : (Src.Module -> Expectation) -> String -> Test
intLiteralTests expectFn condStr =
    Test.describe ("Int literals " ++ condStr)
        [ Test.fuzz Fuzz.int ("Random int " ++ condStr) (randomInt expectFn)
        , Test.test ("Zero " ++ condStr) (zeroInt expectFn)
        , Test.test ("Positive int " ++ condStr) (positiveInt expectFn)
        , Test.test ("Negative int " ++ condStr) (negativeInt expectFn)
        , Test.test ("Large positive int " ++ condStr) (largePositiveInt expectFn)
        , Test.test ("Large negative int " ++ condStr) (largeNegativeInt expectFn)
        , Test.test ("Int 1 " ++ condStr) (intOne expectFn)
        , Test.test ("Int -1 " ++ condStr) (intNegativeOne expectFn)
        ]


randomInt : (Src.Module -> Expectation) -> (Int -> Expectation)
randomInt expectFn n =
    let
        modul =
            makeModule "testValue" (intExpr n)
    in
    expectFn modul


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


largePositiveInt : (Src.Module -> Expectation) -> (() -> Expectation)
largePositiveInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 2147483647)
    in
    expectFn modul


largeNegativeInt : (Src.Module -> Expectation) -> (() -> Expectation)
largeNegativeInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr -2147483648)
    in
    expectFn modul


intOne : (Src.Module -> Expectation) -> (() -> Expectation)
intOne expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 1)
    in
    expectFn modul


intNegativeOne : (Src.Module -> Expectation) -> (() -> Expectation)
intNegativeOne expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr -1)
    in
    expectFn modul



-- ============================================================================
-- FLOAT LITERALS (8 tests)
-- ============================================================================


floatLiteralTests : (Src.Module -> Expectation) -> String -> Test
floatLiteralTests expectFn condStr =
    Test.describe ("Float literals " ++ condStr)
        [ Test.fuzz Fuzz.float ("Random float " ++ condStr) (randomFloat expectFn)
        , Test.test ("Zero float " ++ condStr) (zeroFloat expectFn)
        , Test.test ("Small positive float " ++ condStr) (smallPositiveFloat expectFn)
        , Test.test ("Large float " ++ condStr) (largeFloat expectFn)
        , Test.test ("Negative float " ++ condStr) (negativeFloat expectFn)
        , Test.test ("Pi " ++ condStr) (piFloat expectFn)
        , Test.test ("Scientific notation positive " ++ condStr) (scientificPositive expectFn)
        , Test.test ("Scientific notation negative exponent " ++ condStr) (scientificNegativeExponent expectFn)
        ]


randomFloat : (Src.Module -> Expectation) -> (Float -> Expectation)
randomFloat expectFn f =
    let
        modul =
            makeModule "testValue" (floatExpr f)
    in
    expectFn modul


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


largeFloat : (Src.Module -> Expectation) -> (() -> Expectation)
largeFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 1.0e10)
    in
    expectFn modul


negativeFloat : (Src.Module -> Expectation) -> (() -> Expectation)
negativeFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr -3.14)
    in
    expectFn modul


piFloat : (Src.Module -> Expectation) -> (() -> Expectation)
piFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 3.14159265359)
    in
    expectFn modul


scientificPositive : (Src.Module -> Expectation) -> (() -> Expectation)
scientificPositive expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 1.5e8)
    in
    expectFn modul


scientificNegativeExponent : (Src.Module -> Expectation) -> (() -> Expectation)
scientificNegativeExponent expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 1.5e-8)
    in
    expectFn modul



-- ============================================================================
-- STRING LITERALS (8 tests)
-- ============================================================================


stringLiteralTests : (Src.Module -> Expectation) -> String -> Test
stringLiteralTests expectFn condStr =
    Test.describe ("String literals " ++ condStr)
        [ Test.fuzz Fuzz.string ("Random string " ++ condStr) (randomString expectFn)
        , Test.test ("Empty string " ++ condStr) (emptyString expectFn)
        , Test.test ("Single char string " ++ condStr) (singleCharString expectFn)
        , Test.test ("Hello world " ++ condStr) (helloWorld expectFn)
        , Test.test ("String with escapes " ++ condStr) (stringWithEscapes expectFn)
        , Test.test ("Unicode string " ++ condStr) (unicodeString expectFn)
        , Test.test ("String with quotes " ++ condStr) (stringWithQuotes expectFn)
        , Test.test ("Long string " ++ condStr) (longString expectFn)
        ]


randomString : (Src.Module -> Expectation) -> (String -> Expectation)
randomString expectFn s =
    let
        modul =
            makeModule "testValue" (strExpr s)
    in
    expectFn modul


emptyString : (Src.Module -> Expectation) -> (() -> Expectation)
emptyString expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "")
    in
    expectFn modul


singleCharString : (Src.Module -> Expectation) -> (() -> Expectation)
singleCharString expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "a")
    in
    expectFn modul


helloWorld : (Src.Module -> Expectation) -> (() -> Expectation)
helloWorld expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "Hello, World!")
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


stringWithQuotes : (Src.Module -> Expectation) -> (() -> Expectation)
stringWithQuotes expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "He said \"hello\"")
    in
    expectFn modul


longString : (Src.Module -> Expectation) -> (() -> Expectation)
longString expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr (String.repeat 100 "a"))
    in
    expectFn modul



-- ============================================================================
-- CHAR LITERALS (6 tests)
-- ============================================================================


charLiteralTests : (Src.Module -> Expectation) -> String -> Test
charLiteralTests expectFn condStr =
    Test.describe ("Char literals " ++ condStr)
        [ Test.fuzz charFuzzer ("Random char " ++ condStr) (randomChar expectFn)
        , Test.test ("Letter char " ++ condStr) (letterChar expectFn)
        , Test.test ("Digit char " ++ condStr) (digitChar expectFn)
        , Test.test ("Symbol char " ++ condStr) (symbolChar expectFn)
        , Test.test ("Space char " ++ condStr) (spaceChar expectFn)
        , Test.test ("Uppercase char " ++ condStr) (uppercaseChar expectFn)
        ]


randomChar : (Src.Module -> Expectation) -> (String -> Expectation)
randomChar expectFn c =
    let
        modul =
            makeModule "testValue" (chrExpr c)
    in
    expectFn modul


letterChar : (Src.Module -> Expectation) -> (() -> Expectation)
letterChar expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "a")
    in
    expectFn modul


digitChar : (Src.Module -> Expectation) -> (() -> Expectation)
digitChar expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "5")
    in
    expectFn modul


symbolChar : (Src.Module -> Expectation) -> (() -> Expectation)
symbolChar expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "@")
    in
    expectFn modul


spaceChar : (Src.Module -> Expectation) -> (() -> Expectation)
spaceChar expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr " ")
    in
    expectFn modul


uppercaseChar : (Src.Module -> Expectation) -> (() -> Expectation)
uppercaseChar expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "Z")
    in
    expectFn modul



-- ============================================================================
-- UNIT (2 tests)
-- ============================================================================


unitTests : (Src.Module -> Expectation) -> String -> Test
unitTests expectFn condStr =
    Test.describe ("Unit " ++ condStr)
        [ Test.test ("Unit expression " ++ condStr) (unitExpression expectFn)
        , Test.test ("Multiple unit modules each " ++ condStr) (multipleUnitModules expectFn)
        ]


unitExpression : (Src.Module -> Expectation) -> (() -> Expectation)
unitExpression expectFn _ =
    let
        modul =
            makeModule "testValue" unitExpr
    in
    expectFn modul


multipleUnitModules : (Src.Module -> Expectation) -> (() -> Expectation)
multipleUnitModules expectFn _ =
    let
        modul1 =
            makeModule "testValue1" unitExpr

        modul2 =
            makeModule "testValue2" unitExpr
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()



-- ============================================================================
-- BOOL (4 tests)
-- ============================================================================


boolTests : (Src.Module -> Expectation) -> String -> Test
boolTests expectFn condStr =
    Test.describe ("Bool literals " ++ condStr)
        [ Test.test ("True " ++ condStr) (trueExpr expectFn)
        , Test.test ("False " ++ condStr) (falseExpr expectFn)
        , Test.fuzz Fuzz.bool ("Random bool " ++ condStr) (randomBool expectFn)
        , Test.fuzz2 Fuzz.bool Fuzz.bool ("Two bools in different modules " ++ condStr) (twoBoolsInModules expectFn)
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


randomBool : (Src.Module -> Expectation) -> (Bool -> Expectation)
randomBool expectFn b =
    let
        modul =
            makeModule "testValue" (boolExpr b)
    in
    expectFn modul


twoBoolsInModules : (Src.Module -> Expectation) -> (Bool -> Bool -> Expectation)
twoBoolsInModules expectFn b1 b2 =
    let
        modul1 =
            makeModule "testValue1" (boolExpr b1)

        modul2 =
            makeModule "testValue2" (boolExpr b2)
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()



-- ============================================================================
-- COMBINED LITERALS (4 tests)
-- ============================================================================


combinedLiteralTests : (Src.Module -> Expectation) -> String -> Test
combinedLiteralTests expectFn condStr =
    Test.describe ("Combined literals " ++ condStr)
        [ Test.fuzz2 Fuzz.int Fuzz.float ("Int and float in separate modules " ++ condStr) (intAndFloatInModules expectFn)
        , Test.fuzz2 Fuzz.string charFuzzer ("String and char in separate modules " ++ condStr) (stringAndCharInModules expectFn)
        , Test.fuzz Fuzz.int ("Int with unit in separate modules " ++ condStr) (intWithUnitInModules expectFn)
        , Test.test ("All literal types " ++ condStr) (allLiteralTypes expectFn)
        ]


intAndFloatInModules : (Src.Module -> Expectation) -> (Int -> Float -> Expectation)
intAndFloatInModules expectFn n f =
    let
        modul1 =
            makeModule "intValue" (intExpr n)

        modul2 =
            makeModule "floatValue" (floatExpr f)
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()


stringAndCharInModules : (Src.Module -> Expectation) -> (String -> String -> Expectation)
stringAndCharInModules expectFn s c =
    let
        modul1 =
            makeModule "strValue" (strExpr s)

        modul2 =
            makeModule "chrValue" (chrExpr c)
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()


intWithUnitInModules : (Src.Module -> Expectation) -> (Int -> Expectation)
intWithUnitInModules expectFn n =
    let
        modul1 =
            makeModule "intValue" (intExpr n)

        modul2 =
            makeModule "unitValue" unitExpr
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()


allLiteralTypes : (Src.Module -> Expectation) -> (() -> Expectation)
allLiteralTypes expectFn _ =
    let
        modulInt =
            makeModule "intVal" (intExpr 42)

        modulFloat =
            makeModule "floatVal" (floatExpr 3.14)

        modulStr =
            makeModule "strVal" (strExpr "hello")

        modulChr =
            makeModule "chrVal" (chrExpr "x")

        modulUnit =
            makeModule "unitVal" unitExpr

        modulBool =
            makeModule "boolVal" (boolExpr True)
    in
    Expect.all
        [ \_ -> expectFn modulInt
        , \_ -> expectFn modulFloat
        , \_ -> expectFn modulStr
        , \_ -> expectFn modulChr
        , \_ -> expectFn modulUnit
        , \_ -> expectFn modulBool
        ]
        ()
