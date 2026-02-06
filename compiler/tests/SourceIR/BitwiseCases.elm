module SourceIR.BitwiseCases exposing (expectSuite, suite, testCases)

{-| Test cases for Bitwise operations in MLIR codegen.

These tests cover:

  - MLIR.Intrinsics.bitwiseIntrinsic (0% coverage)
  - Bitwise.and, Bitwise.or, Bitwise.xor, Bitwise.complement
  - Bitwise.shiftLeftBy, Bitwise.shiftRightBy, Bitwise.shiftRightZfBy

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliasesExtended
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


suite : Test
suite =
    Test.describe "Bitwise operations coverage"
        [ expectSuite expectMonomorphization "monomorphizes bitwise ops"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Bitwise operations " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ basicBitwiseCases expectFn
        , shiftCases expectFn
        , combinedBitwiseCases expectFn
        , bitwiseInFunctionsCases expectFn
        ]



-- ============================================================================
-- BASIC BITWISE TESTS
-- ============================================================================


basicBitwiseCases : (Src.Module -> Expectation) -> List TestCase
basicBitwiseCases expectFn =
    [ { label = "Bitwise.and", run = bitwiseAndTest expectFn }
    , { label = "Bitwise.or", run = bitwiseOrTest expectFn }
    , { label = "Bitwise.xor", run = bitwiseXorTest expectFn }
    , { label = "Bitwise.complement", run = bitwiseComplementTest expectFn }
    ]


{-| Test Bitwise.and operation.
-}
bitwiseAndTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseAndTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.and 0xFF00 0x0F0F
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "and")
                    [ intExpr 0xFF00
                    , intExpr 0x0F0F
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test Bitwise.or operation.
-}
bitwiseOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseOrTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.or 0xF0 0x0F
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "or")
                    [ intExpr 0xF0
                    , intExpr 0x0F
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test Bitwise.xor operation.
-}
bitwiseXorTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseXorTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.xor 0xFF 0x0F
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "xor")
                    [ intExpr 0xFF
                    , intExpr 0x0F
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test Bitwise.complement operation.
-}
bitwiseComplementTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseComplementTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.complement 0
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "complement")
                    [ intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- SHIFT TESTS
-- ============================================================================


shiftCases : (Src.Module -> Expectation) -> List TestCase
shiftCases expectFn =
    [ { label = "Bitwise.shiftLeftBy", run = shiftLeftByTest expectFn }
    , { label = "Bitwise.shiftRightBy", run = shiftRightByTest expectFn }
    , { label = "Bitwise.shiftRightZfBy", run = shiftRightZfByTest expectFn }
    , { label = "Multiple shifts", run = multipleShiftsTest expectFn }
    ]


{-| Test Bitwise.shiftLeftBy operation.
-}
shiftLeftByTest : (Src.Module -> Expectation) -> (() -> Expectation)
shiftLeftByTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.shiftLeftBy 4 1
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "shiftLeftBy")
                    [ intExpr 4
                    , intExpr 1
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test Bitwise.shiftRightBy operation.
-}
shiftRightByTest : (Src.Module -> Expectation) -> (() -> Expectation)
shiftRightByTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.shiftRightBy 2 16
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "shiftRightBy")
                    [ intExpr 2
                    , intExpr 16
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test Bitwise.shiftRightZfBy operation (zero-fill right shift).
-}
shiftRightZfByTest : (Src.Module -> Expectation) -> (() -> Expectation)
shiftRightZfByTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.shiftRightZfBy 2 (-8)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "shiftRightZfBy")
                    [ intExpr 2
                    , intExpr -8
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test multiple shift operations combined.
-}
multipleShiftsTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleShiftsTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.shiftRightBy 2 (Bitwise.shiftLeftBy 4 1)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "shiftRightBy")
                    [ intExpr 2
                    , callExpr (qualVarExpr "Bitwise" "shiftLeftBy")
                        [ intExpr 4
                        , intExpr 1
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- COMBINED BITWISE TESTS
-- ============================================================================


combinedBitwiseCases : (Src.Module -> Expectation) -> List TestCase
combinedBitwiseCases expectFn =
    [ { label = "And with Or", run = andWithOrTest expectFn }
    , { label = "Xor with complement", run = xorWithComplementTest expectFn }
    , { label = "Complex bitwise expression", run = complexBitwiseTest expectFn }
    , { label = "Mask extraction pattern", run = maskExtractionTest expectFn }
    ]


{-| Test Bitwise.and combined with Bitwise.or.
-}
andWithOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
andWithOrTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.and (Bitwise.or 0xF0 0x0F) 0xFF
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "and")
                    [ callExpr (qualVarExpr "Bitwise" "or")
                        [ intExpr 0xF0
                        , intExpr 0x0F
                        ]
                    , intExpr 0xFF
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test Bitwise.xor combined with Bitwise.complement.
-}
xorWithComplementTest : (Src.Module -> Expectation) -> (() -> Expectation)
xorWithComplementTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.xor 0xFF (Bitwise.complement 0)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "xor")
                    [ intExpr 0xFF
                    , callExpr (qualVarExpr "Bitwise" "complement")
                        [ intExpr 0 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test complex bitwise expression with multiple operations.
-}
complexBitwiseTest : (Src.Module -> Expectation) -> (() -> Expectation)
complexBitwiseTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.and (Bitwise.or 0xF0 0x0F) (Bitwise.complement 0x00)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "and")
                    [ callExpr (qualVarExpr "Bitwise" "or")
                        [ intExpr 0xF0
                        , intExpr 0x0F
                        ]
                    , callExpr (qualVarExpr "Bitwise" "complement")
                        [ intExpr 0x00 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test mask extraction pattern using shifts and and.
-}
maskExtractionTest : (Src.Module -> Expectation) -> (() -> Expectation)
maskExtractionTest expectFn _ =
    let
        -- testValue : Int
        -- testValue = Bitwise.and (Bitwise.shiftRightBy 4 0xABCD) 0x000F
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "Bitwise" "and")
                    [ callExpr (qualVarExpr "Bitwise" "shiftRightBy")
                        [ intExpr 4
                        , intExpr 0xABCD
                        ]
                    , intExpr 0x0F
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- BITWISE IN FUNCTIONS TESTS
-- ============================================================================


bitwiseInFunctionsCases : (Src.Module -> Expectation) -> List TestCase
bitwiseInFunctionsCases expectFn =
    [ { label = "setBit function", run = setBitFunctionTest expectFn }
    , { label = "clearBit function", run = clearBitFunctionTest expectFn }
    , { label = "toggleBit function", run = toggleBitFunctionTest expectFn }
    , { label = "testBit function", run = testBitFunctionTest expectFn }
    , { label = "Bitwise with conditional", run = bitwiseWithConditionalTest expectFn }
    , { label = "Rotate left pattern", run = rotateLeftTest expectFn }
    , { label = "Extract byte pattern", run = extractByteTest expectFn }
    , { label = "Pack bytes pattern", run = packBytesTest expectFn }
    ]


{-| Test setBit function using bitwise ops.
-}
setBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
setBitFunctionTest expectFn _ =
    let
        -- setBit : Int -> Int -> Int
        -- setBit bit n = Bitwise.or n (Bitwise.shiftLeftBy bit 1)
        setBitDef : TypedDef
        setBitDef =
            { name = "setBit"
            , args = [ pVar "bit", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Bitwise" "or")
                    [ varExpr "n"
                    , callExpr (qualVarExpr "Bitwise" "shiftLeftBy")
                        [ varExpr "bit"
                        , intExpr 1
                        ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "setBit") [ intExpr 3, intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ setBitDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test clearBit function using bitwise ops.
-}
clearBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
clearBitFunctionTest expectFn _ =
    let
        -- clearBit : Int -> Int -> Int
        -- clearBit bit n = Bitwise.and n (Bitwise.complement (Bitwise.shiftLeftBy bit 1))
        clearBitDef : TypedDef
        clearBitDef =
            { name = "clearBit"
            , args = [ pVar "bit", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Bitwise" "and")
                    [ varExpr "n"
                    , callExpr (qualVarExpr "Bitwise" "complement")
                        [ callExpr (qualVarExpr "Bitwise" "shiftLeftBy")
                            [ varExpr "bit"
                            , intExpr 1
                            ]
                        ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "clearBit") [ intExpr 3, intExpr 0xFF ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ clearBitDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test toggleBit function using bitwise ops.
-}
toggleBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
toggleBitFunctionTest expectFn _ =
    let
        -- toggleBit : Int -> Int -> Int
        -- toggleBit bit n = Bitwise.xor n (Bitwise.shiftLeftBy bit 1)
        toggleBitDef : TypedDef
        toggleBitDef =
            { name = "toggleBit"
            , args = [ pVar "bit", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Bitwise" "xor")
                    [ varExpr "n"
                    , callExpr (qualVarExpr "Bitwise" "shiftLeftBy")
                        [ varExpr "bit"
                        , intExpr 1
                        ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "toggleBit") [ intExpr 3, intExpr 0xFF ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ toggleBitDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test testBit function using bitwise ops (returns Int 0 or 1).
-}
testBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
testBitFunctionTest expectFn _ =
    let
        -- testBit : Int -> Int -> Int
        -- testBit bit n = Bitwise.and (Bitwise.shiftRightBy bit n) 1
        testBitDef : TypedDef
        testBitDef =
            { name = "testBit"
            , args = [ pVar "bit", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Bitwise" "and")
                    [ callExpr (qualVarExpr "Bitwise" "shiftRightBy")
                        [ varExpr "bit"
                        , varExpr "n"
                        ]
                    , intExpr 1
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "testBit") [ intExpr 3, intExpr 0xFF ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ testBitDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test bitwise operations with conditional.
-}
bitwiseWithConditionalTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseWithConditionalTest expectFn _ =
    let
        -- conditionalBit : Int -> Int -> Int
        -- conditionalBit flag n = if flag > 0 then Bitwise.or n 1 else Bitwise.and n (Bitwise.complement 1)
        conditionalBitDef : TypedDef
        conditionalBitDef =
            { name = "conditionalBit"
            , args = [ pVar "flag", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "flag", ">" ) ] (intExpr 0))
                    (callExpr (qualVarExpr "Bitwise" "or")
                        [ varExpr "n", intExpr 1 ]
                    )
                    (callExpr (qualVarExpr "Bitwise" "and")
                        [ varExpr "n"
                        , callExpr (qualVarExpr "Bitwise" "complement")
                            [ intExpr 1 ]
                        ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "conditionalBit") [ intExpr 1, intExpr 0xFE ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ conditionalBitDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test rotate left pattern using bitwise ops.
-}
rotateLeftTest : (Src.Module -> Expectation) -> (() -> Expectation)
rotateLeftTest expectFn _ =
    let
        -- rotateLeft8 : Int -> Int -> Int
        -- rotateLeft8 n amount =
        --     Bitwise.or
        --         (Bitwise.and (Bitwise.shiftLeftBy amount n) 0xFF)
        --         (Bitwise.shiftRightZfBy (8 - amount) (Bitwise.and n 0xFF))
        rotateLeft8Def : TypedDef
        rotateLeft8Def =
            { name = "rotateLeft8"
            , args = [ pVar "n", pVar "amount" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Bitwise" "or")
                    [ callExpr (qualVarExpr "Bitwise" "and")
                        [ callExpr (qualVarExpr "Bitwise" "shiftLeftBy")
                            [ varExpr "amount", varExpr "n" ]
                        , intExpr 0xFF
                        ]
                    , callExpr (qualVarExpr "Bitwise" "shiftRightZfBy")
                        [ binopsExpr [ ( intExpr 8, "-" ) ] (varExpr "amount")
                        , callExpr (qualVarExpr "Bitwise" "and")
                            [ varExpr "n", intExpr 0xFF ]
                        ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "rotateLeft8") [ intExpr 0x81, intExpr 1 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ rotateLeft8Def, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test extract byte pattern.
-}
extractByteTest : (Src.Module -> Expectation) -> (() -> Expectation)
extractByteTest expectFn _ =
    let
        -- extractByte : Int -> Int -> Int
        -- extractByte byteIndex n = Bitwise.and (Bitwise.shiftRightBy (byteIndex * 8) n) 0xFF
        extractByteDef : TypedDef
        extractByteDef =
            { name = "extractByte"
            , args = [ pVar "byteIndex", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Bitwise" "and")
                    [ callExpr (qualVarExpr "Bitwise" "shiftRightBy")
                        [ binopsExpr [ ( varExpr "byteIndex", "*" ) ] (intExpr 8)
                        , varExpr "n"
                        ]
                    , intExpr 0xFF
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "extractByte") [ intExpr 1, intExpr 0xABCD ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ extractByteDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test pack bytes pattern.
-}
packBytesTest : (Src.Module -> Expectation) -> (() -> Expectation)
packBytesTest expectFn _ =
    let
        -- packBytes : Int -> Int -> Int
        -- packBytes high low = Bitwise.or (Bitwise.shiftLeftBy 8 (Bitwise.and high 0xFF)) (Bitwise.and low 0xFF)
        packBytesDef : TypedDef
        packBytesDef =
            { name = "packBytes"
            , args = [ pVar "high", pVar "low" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                callExpr (qualVarExpr "Bitwise" "or")
                    [ callExpr (qualVarExpr "Bitwise" "shiftLeftBy")
                        [ intExpr 8
                        , callExpr (qualVarExpr "Bitwise" "and")
                            [ varExpr "high", intExpr 0xFF ]
                        ]
                    , callExpr (qualVarExpr "Bitwise" "and")
                        [ varExpr "low", intExpr 0xFF ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "packBytes") [ intExpr 0xAB, intExpr 0xCD ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliasesExtended "Test"
                [ packBytesDef, testValueDef ]
                []
                []
    in
    expectFn modul
