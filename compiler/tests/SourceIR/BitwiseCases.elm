module SourceIR.BitwiseCases exposing (expectSuite, suite)

{-| Source programs that call the functions of the `Bitwise` module, as user
code does, so that the tests built on `SourceIR.Suite.StandardTestSuites` are
run over `Bitwise` calls. They are the only `SourceIR` cases that do;
`SourceIR.KernelIntrinsicCases` calls the `Elm.Kernel.Bitwise` kernels directly
instead.

The module only builds programs. Each case builds one module and hands it to
`expectFn`, an expectation function supplied by the caller, which decides which
compiler stage the module is run through and what counts as passing.
`SourceIR.Suite.StandardTestSuites.expectSuite` calls `expectSuite` with the
expectation function its own caller supplies. `suite` runs the same cases with
`TestLogic.TestPipeline.expectMonomorphization`.

Every program is a module named `Test`, built by
`makeModuleWithTypedDefsUnionsAliasesExtended`, which imports `Bitwise` on top
of the standard set that `Compiler.AST.SourceBuilder` lists, each import
exposing everything. `Bitwise` resolves against the
mock interface in `Compiler.Elm.Interface.Basic.testIfaces`, which types
`complement` as `Int -> Int` and the other six functions as `Int -> Int -> Int`.
Every definition is annotated: `testValue` as `Int`, and each helper function as
`Int -> Int -> Int`. Every `Bitwise` call is given all its arguments. The
programs are written below as Elm source, but the built tree has no
`Src.Parens` node where the source has parentheses.

The cases, in the order they run:

  - Basic: `testValue` is one call of `and`, `or`, `xor` or `complement` on
    integer literals.
  - Shifts: `testValue` is one call of `shiftLeftBy`, `shiftRightBy` or
    `shiftRightZfBy` on integer literals, or a `shiftLeftBy` call as an
    argument of a `shiftRightBy`.
  - Combined: `testValue` is a `Bitwise` call with another `Bitwise` call as an
    argument: `or` in `and`, `complement` in `xor`, `or` and `complement` in
    `and`, and `shiftRightBy` in `and`.
  - In functions: a top-level helper applies `Bitwise` functions to its
    parameters, and `testValue` calls it on two integer literals. The helpers
    set, clear, toggle and test one bit, choose between `or` and `and` with an
    `if` on `flag > 0`, rotate the low eight bits with a shift by `8 - amount`,
    extract a byte with a shift by `byteIndex * 8`, and pack two bytes.

Among what is not tested:

  - The value any program computes. No case states one, and what is checked
    about a module is up to `expectFn`.
  - A `Bitwise` function given fewer than all its arguments, or passed as a
    value.
  - A shift by 32 or more, or by a negative amount.

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


{-| The cases as one standalone test, each checked with
`TestLogic.TestPipeline.expectMonomorphization`.
-}
suite : Test
suite =
    Test.describe "Bitwise operations coverage"
        [ expectSuite expectMonomorphization "monomorphizes bitwise ops"
        ]


{-| Creates one test, named `"Bitwise operations "` followed by `condStr`, that
passes when `expectFn` passes on the module of every case.

The cases run through `Compiler.BulkCheck.bulkCheck`, so a failure names only
the first case that fails, by its label, and the cases after it do not run.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Bitwise operations " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, built with `expectFn`, in the order they
run: the basic, shift, combined and in-function groups.
-}
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


{-| Returns the four cases that each call `and`, `or`, `xor` or `complement`
once, on integer literals.
-}
basicBitwiseCases : (Src.Module -> Expectation) -> List TestCase
basicBitwiseCases expectFn =
    [ { label = "Bitwise.and", run = bitwiseAndTest expectFn }
    , { label = "Bitwise.or", run = bitwiseOrTest expectFn }
    , { label = "Bitwise.xor", run = bitwiseXorTest expectFn }
    , { label = "Bitwise.complement", run = bitwiseComplementTest expectFn }
    ]


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.and 0xFF00 0x0F0F`.
-}
bitwiseAndTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseAndTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.or 0xF0 0x0F`.
-}
bitwiseOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseOrTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.xor 0xFF 0x0F`.
-}
bitwiseXorTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseXorTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.complement 0`.
-}
bitwiseComplementTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseComplementTest expectFn _ =
    let
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


{-| Returns the four shift cases: one call each of `shiftLeftBy`,
`shiftRightBy` and `shiftRightZfBy`, then one shift nested in another.
-}
shiftCases : (Src.Module -> Expectation) -> List TestCase
shiftCases expectFn =
    [ { label = "Bitwise.shiftLeftBy", run = shiftLeftByTest expectFn }
    , { label = "Bitwise.shiftRightBy", run = shiftRightByTest expectFn }
    , { label = "Bitwise.shiftRightZfBy", run = shiftRightZfByTest expectFn }
    , { label = "Multiple shifts", run = multipleShiftsTest expectFn }
    ]


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.shiftLeftBy 4 1`.
-}
shiftLeftByTest : (Src.Module -> Expectation) -> (() -> Expectation)
shiftLeftByTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.shiftRightBy 2 16`.
-}
shiftRightByTest : (Src.Module -> Expectation) -> (() -> Expectation)
shiftRightByTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.shiftRightZfBy 2 (-8)`.

The `-8` is built as one negative integer literal. Source text cannot write
that, since the parser reads a number only from a digit, so a parsed `(-8)` is a
negation of `8` instead.

-}
shiftRightZfByTest : (Src.Module -> Expectation) -> (() -> Expectation)
shiftRightZfByTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.shiftRightBy 2 (Bitwise.shiftLeftBy 4 1)`.
-}
multipleShiftsTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleShiftsTest expectFn _ =
    let
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


{-| Returns the four cases whose `testValue` has a `Bitwise` call as an argument
of another `Bitwise` call.
-}
combinedBitwiseCases : (Src.Module -> Expectation) -> List TestCase
combinedBitwiseCases expectFn =
    [ { label = "And with Or", run = andWithOrTest expectFn }
    , { label = "Xor with complement", run = xorWithComplementTest expectFn }
    , { label = "Complex bitwise expression", run = complexBitwiseTest expectFn }
    , { label = "Mask extraction pattern", run = maskExtractionTest expectFn }
    ]


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.and (Bitwise.or 0xF0 0x0F) 0xFF`.
-}
andWithOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
andWithOrTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.xor 0xFF (Bitwise.complement 0)`.
-}
xorWithComplementTest : (Src.Module -> Expectation) -> (() -> Expectation)
xorWithComplementTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.and (Bitwise.or 0xF0 0x0F) (Bitwise.complement 0x00)`.
-}
complexBitwiseTest : (Src.Module -> Expectation) -> (() -> Expectation)
complexBitwiseTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module whose one definition is `testValue : Int`,
defined as `Bitwise.and (Bitwise.shiftRightBy 4 0xABCD) 0x0F`.
-}
maskExtractionTest : (Src.Module -> Expectation) -> (() -> Expectation)
maskExtractionTest expectFn _ =
    let
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


{-| Returns the eight cases in which a top-level helper function applies
`Bitwise` functions to its parameters and `testValue` calls it.
-}
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


{-| Runs `expectFn` on a module that defines

    setBit : Int -> Int -> Int
    setBit bit n =
        Bitwise.or n (Bitwise.shiftLeftBy bit 1)

    testValue : Int
    testValue =
        setBit 3 0

-}
setBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
setBitFunctionTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module that defines

    clearBit : Int -> Int -> Int
    clearBit bit n =
        Bitwise.and n (Bitwise.complement (Bitwise.shiftLeftBy bit 1))

    testValue : Int
    testValue =
        clearBit 3 0xFF

-}
clearBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
clearBitFunctionTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module that defines

    toggleBit : Int -> Int -> Int
    toggleBit bit n =
        Bitwise.xor n (Bitwise.shiftLeftBy bit 1)

    testValue : Int
    testValue =
        toggleBit 3 0xFF

-}
toggleBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
toggleBitFunctionTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module that defines

    testBit : Int -> Int -> Int
    testBit bit n =
        Bitwise.and (Bitwise.shiftRightBy bit n) 1

    testValue : Int
    testValue =
        testBit 3 0xFF

-}
testBitFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
testBitFunctionTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module that defines

    conditionalBit : Int -> Int -> Int
    conditionalBit flag n =
        if flag > 0 then
            Bitwise.or n 1

        else
            Bitwise.and n (Bitwise.complement 1)

    testValue : Int
    testValue =
        conditionalBit 1 0xFE

-}
bitwiseWithConditionalTest : (Src.Module -> Expectation) -> (() -> Expectation)
bitwiseWithConditionalTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module that defines

    rotateLeft8 : Int -> Int -> Int
    rotateLeft8 n amount =
        Bitwise.or
            (Bitwise.and (Bitwise.shiftLeftBy amount n) 0xFF)
            (Bitwise.shiftRightZfBy (8 - amount) (Bitwise.and n 0xFF))

    testValue : Int
    testValue =
        rotateLeft8 0x81 1

-}
rotateLeftTest : (Src.Module -> Expectation) -> (() -> Expectation)
rotateLeftTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module that defines

    extractByte : Int -> Int -> Int
    extractByte byteIndex n =
        Bitwise.and (Bitwise.shiftRightBy (byteIndex * 8) n) 0xFF

    testValue : Int
    testValue =
        extractByte 1 0xABCD

-}
extractByteTest : (Src.Module -> Expectation) -> (() -> Expectation)
extractByteTest expectFn _ =
    let
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


{-| Runs `expectFn` on a module that defines

    packBytes : Int -> Int -> Int
    packBytes high low =
        Bitwise.or (Bitwise.shiftLeftBy 8 (Bitwise.and high 0xFF)) (Bitwise.and low 0xFF)

    testValue : Int
    testValue =
        packBytes 0xAB 0xCD

-}
packBytesTest : (Src.Module -> Expectation) -> (() -> Expectation)
packBytesTest expectFn _ =
    let
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
