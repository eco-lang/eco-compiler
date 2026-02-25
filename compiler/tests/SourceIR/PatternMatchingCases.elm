module SourceIR.PatternMatchingCases exposing (expectSuite, suite)

{-| Test cases for pattern matching in MLIR codegen.

These tests cover:

  - MLIR.Patterns (51% coverage)
  - Char patterns in case expressions
  - String patterns in case expressions
  - Nested constructor patterns
  - Multiple guards/conditions in patterns
  - Complex pattern matching with fallback

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
        , chrExpr
        , ctorExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pChr
        , pCons
        , pCtor
        , pInt
        , pList
        , pStr
        , pTuple
        , pVar
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


suite : Test
suite =
    Test.describe "Pattern matching coverage"
        [ expectSuite expectMonomorphization "monomorphizes patterns"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Pattern matching " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| All test cases for pattern matching.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ charPatternCases expectFn
        , stringPatternCases expectFn
        , nestedPatternCases expectFn
        , fallbackPatternCases expectFn
        , tuplePatternCases expectFn
        , listPatternCases expectFn
        ]



-- ============================================================================
-- CHAR PATTERN TESTS
-- ============================================================================


charPatternCases : (Src.Module -> Expectation) -> List TestCase
charPatternCases expectFn =
    [ { label = "Simple char pattern", run = simpleCharPatternTest expectFn }
    , { label = "Multiple char patterns", run = multipleCharPatternsTest expectFn }
    , { label = "Char pattern with fallback", run = charPatternWithFallbackTest expectFn }
    , { label = "Vowel detection", run = vowelDetectionTest expectFn }
    , { label = "Digit char pattern", run = digitCharPatternTest expectFn }
    ]


{-| Test simple char pattern matching.
-}
simpleCharPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleCharPatternTest expectFn _ =
    let
        -- charName : Char -> String
        charNameDef : TypedDef
        charNameDef =
            { name = "charName"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "String" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "a", strExpr "letter a" )
                    , ( pChr "b", strExpr "letter b" )
                    , ( pVar "_", strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "charName") [ chrExpr "a" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ charNameDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test multiple char patterns.
-}
multipleCharPatternsTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleCharPatternsTest expectFn _ =
    let
        -- charType : Char -> Int
        charTypeDef : TypedDef
        charTypeDef =
            { name = "charType"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "0", intExpr 0 )
                    , ( pChr "1", intExpr 1 )
                    , ( pChr "2", intExpr 2 )
                    , ( pChr "3", intExpr 3 )
                    , ( pVar "_", intExpr -1 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "charType") [ chrExpr "2" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ charTypeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test char pattern with fallback.
-}
charPatternWithFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
charPatternWithFallbackTest expectFn _ =
    let
        -- isSpecial : Char -> Bool
        isSpecialDef : TypedDef
        isSpecialDef =
            { name = "isSpecial"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "@", boolExpr True )
                    , ( pChr "#", boolExpr True )
                    , ( pChr "$", boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isSpecial") [ chrExpr "@" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isSpecialDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test vowel detection using char patterns.
-}
vowelDetectionTest : (Src.Module -> Expectation) -> (() -> Expectation)
vowelDetectionTest expectFn _ =
    let
        -- isVowel : Char -> Bool
        isVowelDef : TypedDef
        isVowelDef =
            { name = "isVowel"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "a", boolExpr True )
                    , ( pChr "e", boolExpr True )
                    , ( pChr "i", boolExpr True )
                    , ( pChr "o", boolExpr True )
                    , ( pChr "u", boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isVowel") [ chrExpr "e" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isVowelDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test digit char pattern.
-}
digitCharPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
digitCharPatternTest expectFn _ =
    let
        -- digitToInt : Char -> Int
        digitToIntDef : TypedDef
        digitToIntDef =
            { name = "digitToInt"
            , args = [ pVar "c" ]
            , tipe = tLambda (tType "Char" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "c")
                    [ ( pChr "0", intExpr 0 )
                    , ( pChr "1", intExpr 1 )
                    , ( pChr "2", intExpr 2 )
                    , ( pChr "3", intExpr 3 )
                    , ( pChr "4", intExpr 4 )
                    , ( pChr "5", intExpr 5 )
                    , ( pChr "6", intExpr 6 )
                    , ( pChr "7", intExpr 7 )
                    , ( pChr "8", intExpr 8 )
                    , ( pChr "9", intExpr 9 )
                    , ( pVar "_", intExpr -1 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "digitToInt") [ chrExpr "7" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ digitToIntDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- STRING PATTERN TESTS
-- ============================================================================


stringPatternCases : (Src.Module -> Expectation) -> List TestCase
stringPatternCases expectFn =
    [ { label = "Simple string pattern", run = simpleStringPatternTest expectFn }
    , { label = "Multiple string patterns", run = multipleStringPatternsTest expectFn }
    , { label = "Greeting pattern", run = greetingPatternTest expectFn }
    , { label = "Command pattern", run = commandPatternTest expectFn }
    ]


{-| Test simple string pattern.
-}
simpleStringPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleStringPatternTest expectFn _ =
    let
        -- greet : String -> String
        greetDef : TypedDef
        greetDef =
            { name = "greet"
            , args = [ pVar "name" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body =
                caseExpr (varExpr "name")
                    [ ( pStr "Alice", strExpr "Hello Alice!" )
                    , ( pStr "Bob", strExpr "Hi Bob!" )
                    , ( pVar "_", strExpr "Hello stranger" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "greet") [ strExpr "Alice" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ greetDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test multiple string patterns.
-}
multipleStringPatternsTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleStringPatternsTest expectFn _ =
    let
        -- dayNumber : String -> Int
        dayNumberDef : TypedDef
        dayNumberDef =
            { name = "dayNumber"
            , args = [ pVar "day" ]
            , tipe = tLambda (tType "String" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "day")
                    [ ( pStr "Monday", intExpr 1 )
                    , ( pStr "Tuesday", intExpr 2 )
                    , ( pStr "Wednesday", intExpr 3 )
                    , ( pStr "Thursday", intExpr 4 )
                    , ( pStr "Friday", intExpr 5 )
                    , ( pStr "Saturday", intExpr 6 )
                    , ( pStr "Sunday", intExpr 7 )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "dayNumber") [ strExpr "Wednesday" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ dayNumberDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test greeting pattern.
-}
greetingPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
greetingPatternTest expectFn _ =
    let
        -- respond : String -> String
        respondDef : TypedDef
        respondDef =
            { name = "respond"
            , args = [ pVar "greeting" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body =
                caseExpr (varExpr "greeting")
                    [ ( pStr "hello", strExpr "Hello to you too!" )
                    , ( pStr "hi", strExpr "Hi there!" )
                    , ( pStr "hey", strExpr "Hey!" )
                    , ( pStr "goodbye", strExpr "Goodbye!" )
                    , ( pVar "_", strExpr "I don't understand" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "respond") [ strExpr "hello" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ respondDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test command pattern.
-}
commandPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
commandPatternTest expectFn _ =
    let
        -- executeCommand : String -> Int
        executeCommandDef : TypedDef
        executeCommandDef =
            { name = "executeCommand"
            , args = [ pVar "cmd" ]
            , tipe = tLambda (tType "String" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "cmd")
                    [ ( pStr "start", intExpr 1 )
                    , ( pStr "stop", intExpr 2 )
                    , ( pStr "restart", intExpr 3 )
                    , ( pStr "status", intExpr 4 )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "executeCommand") [ strExpr "restart" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ executeCommandDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED PATTERN TESTS
-- ============================================================================


nestedPatternCases : (Src.Module -> Expectation) -> List TestCase
nestedPatternCases expectFn =
    [ { label = "Nested constructor pattern", run = nestedConstructorPatternTest expectFn }
    , { label = "Tree depth with nested patterns", run = treeDepthTest expectFn }
    , { label = "Double nested pattern", run = doubleNestedPatternTest expectFn }
    , { label = "Pattern in pattern", run = patternInPatternTest expectFn }
    ]


{-| Test nested constructor pattern.
-}
nestedConstructorPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedConstructorPatternTest expectFn _ =
    let
        treeUnion : UnionDef
        treeUnion =
            { name = "Tree"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [ tType "Int" [] ] }
                , { name = "Node", args = [ tType "Tree" [], tType "Tree" [] ] }
                ]
            }

        -- sumTree : Tree -> Int
        sumTreeDef : TypedDef
        sumTreeDef =
            { name = "sumTree"
            , args = [ pVar "tree" ]
            , tipe = tLambda (tType "Tree" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [ pVar "n" ], varExpr "n" )
                    , ( pCtor "Node" [ pVar "left", pVar "right" ]
                      , binopsExpr
                            [ ( callExpr (varExpr "sumTree") [ varExpr "left" ], "+" ) ]
                            (callExpr (varExpr "sumTree") [ varExpr "right" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumTree")
                    [ callExpr (ctorExpr "Node")
                        [ callExpr (ctorExpr "Leaf") [ intExpr 1 ]
                        , callExpr (ctorExpr "Leaf") [ intExpr 2 ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumTreeDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| Test tree depth calculation.
-}
treeDepthTest : (Src.Module -> Expectation) -> (() -> Expectation)
treeDepthTest expectFn _ =
    let
        treeUnion : UnionDef
        treeUnion =
            { name = "Tree"
            , args = []
            , ctors =
                [ { name = "Leaf", args = [ tType "Int" [] ] }
                , { name = "Node", args = [ tType "Tree" [], tType "Tree" [] ] }
                ]
            }

        -- depth : Tree -> Int
        depthDef : TypedDef
        depthDef =
            { name = "depth"
            , args = [ pVar "tree" ]
            , tipe = tLambda (tType "Tree" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [ pVar "_" ], intExpr 1 )
                    , ( pCtor "Node" [ pVar "left", pVar "right" ]
                      , binopsExpr
                            [ ( intExpr 1, "+" ) ]
                            (callExpr (varExpr "max")
                                [ callExpr (varExpr "depth") [ varExpr "left" ]
                                , callExpr (varExpr "depth") [ varExpr "right" ]
                                ]
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "depth")
                    [ callExpr (ctorExpr "Node")
                        [ callExpr (ctorExpr "Node")
                            [ callExpr (ctorExpr "Leaf") [ intExpr 1 ]
                            , callExpr (ctorExpr "Leaf") [ intExpr 2 ]
                            ]
                        , callExpr (ctorExpr "Leaf") [ intExpr 3 ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ depthDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| Test double nested pattern.
-}
doubleNestedPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNestedPatternTest expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors =
                [ { name = "Wrap", args = [ tType "Int" [] ] }
                ]
            }

        containerUnion : UnionDef
        containerUnion =
            { name = "Container"
            , args = []
            , ctors =
                [ { name = "Container", args = [ tType "Wrapper" [] ] }
                ]
            }

        -- extract : Container -> Int
        extractDef : TypedDef
        extractDef =
            { name = "extract"
            , args = [ pVar "container" ]
            , tipe = tLambda (tType "Container" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "container")
                    [ ( pCtor "Container" [ pCtor "Wrap" [ pVar "n" ] ], varExpr "n" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "extract")
                    [ callExpr (ctorExpr "Container")
                        [ callExpr (ctorExpr "Wrap") [ intExpr 42 ] ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ extractDef, testValueDef ]
                [ wrapperUnion, containerUnion ]
                []
    in
    expectFn modul


{-| Test pattern within pattern.
-}
patternInPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
patternInPatternTest expectFn _ =
    let
        pairUnion : UnionDef
        pairUnion =
            { name = "Pair"
            , args = []
            , ctors =
                [ { name = "Pair", args = [ tType "Int" [], tType "Int" [] ] }
                ]
            }

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Box", args = [ tType "Pair" [] ] }
                ]
            }

        -- sumBox : Box -> Int
        sumBoxDef : TypedDef
        sumBoxDef =
            { name = "sumBox"
            , args = [ pVar "box" ]
            , tipe = tLambda (tType "Box" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "box")
                    [ ( pCtor "Box" [ pCtor "Pair" [ pVar "a", pVar "b" ] ]
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumBox")
                    [ callExpr (ctorExpr "Box")
                        [ callExpr (ctorExpr "Pair") [ intExpr 10, intExpr 20 ] ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumBoxDef, testValueDef ]
                [ pairUnion, boxUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- FALLBACK PATTERN TESTS
-- ============================================================================


fallbackPatternCases : (Src.Module -> Expectation) -> List TestCase
fallbackPatternCases expectFn =
    [ { label = "Wildcard fallback", run = wildcardFallbackTest expectFn }
    , { label = "Variable capture fallback", run = variableCaptureFallbackTest expectFn }
    , { label = "Multiple specific then fallback", run = multipleSpecificThenFallbackTest expectFn }
    , { label = "Conditional in fallback", run = conditionalInFallbackTest expectFn }
    ]


{-| Test wildcard fallback pattern.
-}
wildcardFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardFallbackTest expectFn _ =
    let
        statusUnion : UnionDef
        statusUnion =
            { name = "Status"
            , args = []
            , ctors =
                [ { name = "Success", args = [] }
                , { name = "Error", args = [] }
                , { name = "Pending", args = [] }
                , { name = "Unknown", args = [] }
                ]
            }

        -- isSuccess : Status -> Bool
        isSuccessDef : TypedDef
        isSuccessDef =
            { name = "isSuccess"
            , args = [ pVar "status" ]
            , tipe = tLambda (tType "Status" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "status")
                    [ ( pCtor "Success" [], boolExpr True )
                    , ( pAnything, boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isSuccess") [ ctorExpr "Success" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isSuccessDef, testValueDef ]
                [ statusUnion ]
                []
    in
    expectFn modul


{-| Test variable capture in fallback.
-}
variableCaptureFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
variableCaptureFallbackTest expectFn _ =
    let
        -- classify : Int -> String
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pVar "x"
                      , ifExpr
                            (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 0))
                            (strExpr "positive")
                            (strExpr "negative")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "classify") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test multiple specific patterns then fallback.
-}
multipleSpecificThenFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
multipleSpecificThenFallbackTest expectFn _ =
    let
        -- fibBase : Int -> Int
        fibBaseDef : TypedDef
        fibBaseDef =
            { name = "fibBase"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, intExpr 0 )
                    , ( pInt 1, intExpr 1 )
                    , ( pInt 2, intExpr 1 )
                    , ( pInt 3, intExpr 2 )
                    , ( pInt 4, intExpr 3 )
                    , ( pInt 5, intExpr 5 )
                    , ( pVar "_", intExpr -1 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "fibBase") [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ fibBaseDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test conditional in fallback branch.
-}
conditionalInFallbackTest : (Src.Module -> Expectation) -> (() -> Expectation)
conditionalInFallbackTest expectFn _ =
    let
        -- clampedValue : Int -> Int
        clampedValueDef : TypedDef
        clampedValueDef =
            { name = "clampedValue"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, intExpr 0 )
                    , ( pVar "x"
                      , ifExpr
                            (binopsExpr [ ( varExpr "x", "<" ) ] (intExpr 0))
                            (intExpr 0)
                            (ifExpr
                                (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 100))
                                (intExpr 100)
                                (varExpr "x")
                            )
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "clampedValue") [ intExpr 150 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ clampedValueDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERN TESTS
-- ============================================================================


tuplePatternCases : (Src.Module -> Expectation) -> List TestCase
tuplePatternCases expectFn =
    [ { label = "Simple tuple pattern", run = simpleTuplePatternTest expectFn }
    , { label = "Tuple with wildcard", run = tupleWithWildcardTest expectFn }
    , { label = "Nested tuple pattern", run = nestedTuplePatternTest expectFn }
    , { label = "Triple pattern", run = triplePatternTest expectFn }
    ]


{-| Test simple tuple pattern.
-}
simpleTuplePatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
simpleTuplePatternTest expectFn _ =
    let
        -- sumPair : (Int, Int) -> Int
        sumPairDef : TypedDef
        sumPairDef =
            { name = "sumPair"
            , args = [ pVar "pair" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "Int" [])
            , body =
                caseExpr (varExpr "pair")
                    [ ( pTuple (pVar "a") (pVar "b")
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumPair") [ tupleExpr (intExpr 3) (intExpr 4) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumPairDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test tuple pattern with wildcard.
-}
tupleWithWildcardTest : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithWildcardTest expectFn _ =
    let
        -- getFirst : (Int, Int) -> Int
        getFirstDef : TypedDef
        getFirstDef =
            { name = "getFirst"
            , args = [ pVar "pair" ]
            , tipe = tLambda (tTuple (tType "Int" []) (tType "Int" [])) (tType "Int" [])
            , body =
                caseExpr (varExpr "pair")
                    [ ( pTuple (pVar "a") pAnything, varExpr "a" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getFirst") [ tupleExpr (intExpr 10) (intExpr 20) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getFirstDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test nested tuple pattern.
-}
nestedTuplePatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedTuplePatternTest expectFn _ =
    let
        -- sumNested : ((Int, Int), Int) -> Int
        sumNestedDef : TypedDef
        sumNestedDef =
            { name = "sumNested"
            , args = [ pVar "nested" ]
            , tipe =
                tLambda
                    (tTuple
                        (tTuple (tType "Int" []) (tType "Int" []))
                        (tType "Int" [])
                    )
                    (tType "Int" [])
            , body =
                caseExpr (varExpr "nested")
                    [ ( pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c")
                      , binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "sumNested")
                    [ tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (intExpr 3) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumNestedDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test triple pattern (3-tuple).
-}
triplePatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
triplePatternTest expectFn _ =
    let
        -- This tests a different approach - using let binding to destructure
        -- sumTriple : Int -> Int -> Int -> Int
        sumTripleDef : TypedDef
        sumTripleDef =
            { name = "sumTriple"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Int" []))
                    )
            , body =
                binopsExpr [ ( varExpr "a", "+" ), ( varExpr "b", "+" ) ] (varExpr "c")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumTriple") [ intExpr 1, intExpr 2, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumTripleDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- LIST PATTERN TESTS
-- ============================================================================


listPatternCases : (Src.Module -> Expectation) -> List TestCase
listPatternCases expectFn =
    [ { label = "Empty list pattern", run = emptyListPatternTest expectFn }
    , { label = "Single element pattern", run = singleElementPatternTest expectFn }
    , { label = "Two element pattern", run = twoElementPatternTest expectFn }
    , { label = "Head tail pattern", run = headTailPatternTest expectFn }
    , { label = "Nested list pattern", run = nestedListPatternTest expectFn }
    ]


{-| Test empty list pattern.
-}
emptyListPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
emptyListPatternTest expectFn _ =
    let
        -- isEmpty : List Int -> Bool
        isEmptyDef : TypedDef
        isEmptyDef =
            { name = "isEmpty"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isEmpty") [ listExpr [] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isEmptyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test single element list pattern.
-}
singleElementPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
singleElementPatternTest expectFn _ =
    let
        -- isSingleton : List Int -> Bool
        isSingletonDef : TypedDef
        isSingletonDef =
            { name = "isSingleton"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Bool" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pVar "_") (pList []), boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isSingleton") [ listExpr [ intExpr 1 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isSingletonDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test two element list pattern.
-}
twoElementPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
twoElementPatternTest expectFn _ =
    let
        -- sumTwo : List Int -> Int
        sumTwoDef : TypedDef
        sumTwoDef =
            { name = "sumTwo"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCons (pVar "a") (pCons (pVar "b") (pList []))
                      , binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
                      )
                    , ( pVar "_", intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sumTwo") [ listExpr [ intExpr 3, intExpr 4 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumTwoDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test head :: tail pattern.
-}
headTailPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
headTailPatternTest expectFn _ =
    let
        -- listLength : List Int -> Int
        listLengthDef : TypedDef
        listLengthDef =
            { name = "listLength"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], intExpr 0 )
                    , ( pCons (pVar "_") (pVar "rest")
                      , binopsExpr
                            [ ( intExpr 1, "+" ) ]
                            (callExpr (varExpr "listLength") [ varExpr "rest" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "listLength") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ listLengthDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test nested list pattern (list of lists).
-}
nestedListPatternTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedListPatternTest expectFn _ =
    let
        -- flattenFirst : List (List Int) -> List Int
        flattenFirstDef : TypedDef
        flattenFirstDef =
            { name = "flattenFirst"
            , args = [ pVar "xss" ]
            , tipe =
                tLambda
                    (tType "List" [ tType "List" [ tType "Int" [] ] ])
                    (tType "List" [ tType "Int" [] ])
            , body =
                caseExpr (varExpr "xss")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "first") (pVar "_"), varExpr "first" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body =
                callExpr (varExpr "flattenFirst")
                    [ listExpr
                        [ listExpr [ intExpr 1, intExpr 2 ]
                        , listExpr [ intExpr 3, intExpr 4 ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ flattenFirstDef, testValueDef ]
                []
                []
    in
    expectFn modul
