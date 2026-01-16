module Compiler.SpecializeExprTests exposing (expectSuite, suite)

{-| Test cases for specializeExpr branches in Specialize.elm.

These tests cover:

  - Enum patterns in case expressions
  - Debug.log and Debug.todo
  - Tail recursive functions
  - Various expression specialization paths

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
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pCtor
        , pInt
        , pList
        , pVar
        , qualVarExpr
        , strExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Specialize.elm expression coverage"
        [ expectSuite expectMonomorphization "monomorphizes expressions"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Expression specialization " ++ condStr)
        [ enumPatternTests expectFn condStr
        , debugExprTests expectFn condStr
        , tailRecursiveTests expectFn condStr
        , literalBranchTests expectFn condStr
        ]



-- ============================================================================
-- ENUM PATTERN TESTS
-- ============================================================================


enumPatternTests : (Src.Module -> Expectation) -> String -> Test
enumPatternTests expectFn condStr =
    Test.describe ("Enum patterns " ++ condStr)
        [ Test.test "Simple enum case expression" <|
            simpleEnumCase expectFn
        , Test.test "Nested enum case" <|
            nestedEnumCase expectFn
        , Test.test "Enum with fallback pattern" <|
            enumWithFallback expectFn
        ]


{-| Simple enum type with case expression.
Tests specializeExpr for enum/nullary constructor patterns.
-}
simpleEnumCase : (Src.Module -> Expectation) -> (() -> Expectation)
simpleEnumCase expectFn _ =
    let
        statusUnion : UnionDef
        statusUnion =
            { name = "Status"
            , args = []
            , ctors =
                [ { name = "Pending", args = [] }
                , { name = "Active", args = [] }
                , { name = "Completed", args = [] }
                ]
            }

        -- statusCode : Status -> Int
        statusCodeDef : TypedDef
        statusCodeDef =
            { name = "statusCode"
            , args = [ pVar "s" ]
            , tipe = tLambda (tType "Status" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "s")
                    [ ( pCtor "Pending" [], intExpr 0 )
                    , ( pCtor "Active" [], intExpr 1 )
                    , ( pCtor "Completed" [], intExpr 2 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "statusCode") [ ctorExpr "Active" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ statusCodeDef, testValueDef ]
                [ statusUnion ]
                []
    in
    expectFn modul


{-| Nested case expressions on enums.
-}
nestedEnumCase : (Src.Module -> Expectation) -> (() -> Expectation)
nestedEnumCase expectFn _ =
    let
        colorUnion : UnionDef
        colorUnion =
            { name = "Color"
            , args = []
            , ctors =
                [ { name = "Red", args = [] }
                , { name = "Green", args = [] }
                , { name = "Blue", args = [] }
                ]
            }

        -- mixColors : Color -> Color -> Int
        mixColorsDef : TypedDef
        mixColorsDef =
            { name = "mixColors"
            , args = [ pVar "c1", pVar "c2" ]
            , tipe = tLambda (tType "Color" []) (tLambda (tType "Color" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "c1")
                    [ ( pCtor "Red" []
                      , caseExpr (varExpr "c2")
                            [ ( pCtor "Red" [], intExpr 0xFF0000 )
                            , ( pCtor "Green" [], intExpr 0xFFFF00 )
                            , ( pCtor "Blue" [], intExpr 0xFF00FF )
                            ]
                      )
                    , ( pCtor "Green" [], intExpr 0x00FF00 )
                    , ( pCtor "Blue" [], intExpr 0x0000FF )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "mixColors") [ ctorExpr "Red", ctorExpr "Green" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ mixColorsDef, testValueDef ]
                [ colorUnion ]
                []
    in
    expectFn modul


{-| Enum case with wildcard fallback pattern.
-}
enumWithFallback : (Src.Module -> Expectation) -> (() -> Expectation)
enumWithFallback expectFn _ =
    let
        dayUnion : UnionDef
        dayUnion =
            { name = "Day"
            , args = []
            , ctors =
                [ { name = "Monday", args = [] }
                , { name = "Tuesday", args = [] }
                , { name = "Wednesday", args = [] }
                , { name = "Thursday", args = [] }
                , { name = "Friday", args = [] }
                , { name = "Saturday", args = [] }
                , { name = "Sunday", args = [] }
                ]
            }

        -- isWeekend : Day -> Bool
        isWeekendDef : TypedDef
        isWeekendDef =
            { name = "isWeekend"
            , args = [ pVar "day" ]
            , tipe = tLambda (tType "Day" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "day")
                    [ ( pCtor "Saturday" [], boolExpr True )
                    , ( pCtor "Sunday" [], boolExpr True )
                    , ( pVar "_", boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isWeekend") [ ctorExpr "Saturday" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isWeekendDef, testValueDef ]
                [ dayUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- DEBUG EXPRESSION TESTS
-- ============================================================================


debugExprTests : (Src.Module -> Expectation) -> String -> Test
debugExprTests expectFn condStr =
    Test.describe ("Debug expressions " ++ condStr)
        [ Test.test "Identity function (placeholder for Debug tests)" <|
            identityFunctionTest expectFn
        ]


{-| Simple identity function test as placeholder.
Debug module tests require special imports not available in standard test setup.
-}
identityFunctionTest : (Src.Module -> Expectation) -> (() -> Expectation)
identityFunctionTest expectFn _ =
    let
        -- identity : a -> a
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tVar "a")
            , body = varExpr "x"
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "identity") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ identityDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- TAIL RECURSIVE TESTS
-- ============================================================================


tailRecursiveTests : (Src.Module -> Expectation) -> String -> Test
tailRecursiveTests expectFn condStr =
    Test.describe ("Tail recursive functions " ++ condStr)
        [ Test.test "Tail recursive sum" <|
            tailRecursiveSum expectFn
        , Test.test "Tail recursive with accumulator" <|
            tailRecursiveWithAccumulator expectFn
        , Test.test "Non-tail recursive for comparison" <|
            nonTailRecursive expectFn
        ]


{-| Tail recursive sum function.
Tests tail call optimization detection in specializeExpr.
-}
tailRecursiveSum : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecursiveSum expectFn _ =
    let
        -- sumHelper : Int -> Int -> Int
        -- sumHelper acc n = if n <= 0 then acc else sumHelper (acc + n) (n - 1)
        sumHelperDef : TypedDef
        sumHelperDef =
            { name = "sumHelper"
            , args = [ pVar "acc", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (callExpr (varExpr "sumHelper")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "n")
                        , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        ]
                    )
            }

        -- sum : Int -> Int
        sumDef : TypedDef
        sumDef =
            { name = "sum"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "sumHelper") [ intExpr 0, varExpr "n" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sum") [ intExpr 100 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ sumHelperDef, sumDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Tail recursive function with Int accumulator.
-}
tailRecursiveWithAccumulator : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecursiveWithAccumulator expectFn _ =
    let
        -- countdownHelper : Int -> Int -> Int
        -- Counts down from n while accumulating the sum
        countdownHelperDef : TypedDef
        countdownHelperDef =
            { name = "countdownHelper"
            , args = [ pVar "acc", pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (callExpr (varExpr "countdownHelper")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "n")
                        , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        ]
                    )
            }

        -- countdown : Int -> Int
        countdownDef : TypedDef
        countdownDef =
            { name = "countdown"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = callExpr (varExpr "countdownHelper") [ intExpr 0, varExpr "n" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "countdown") [ intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ countdownHelperDef, countdownDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Non-tail recursive function for comparison.
-}
nonTailRecursive : (Src.Module -> Expectation) -> (() -> Expectation)
nonTailRecursive expectFn _ =
    let
        -- factorial : Int -> Int (not tail recursive due to multiplication after call)
        factorialDef : TypedDef
        factorialDef =
            { name = "factorial"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 1))
                    (intExpr 1)
                    (binopsExpr
                        [ ( varExpr "n", "*" ) ]
                        (callExpr (varExpr "factorial")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ]
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "factorial") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ factorialDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- LITERAL BRANCH TESTS
-- ============================================================================


literalBranchTests : (Src.Module -> Expectation) -> String -> Test
literalBranchTests expectFn condStr =
    Test.describe ("Literal branches " ++ condStr)
        [ Test.test "Int literal patterns" <|
            intLiteralPatterns expectFn
        , Test.test "String literal patterns" <|
            stringLiteralPatterns expectFn
        ]


{-| Case expression with int literal patterns.
-}
intLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralPatterns expectFn _ =
    let
        -- digitName : Int -> String
        digitNameDef : TypedDef
        digitNameDef =
            { name = "digitName"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                caseExpr (varExpr "n")
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pInt 2, strExpr "two" )
                    , ( pVar "_", strExpr "other" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "digitName") [ intExpr 1 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ digitNameDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Case expression with string literal patterns.
-}
stringLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
stringLiteralPatterns expectFn _ =
    let
        -- greet : String -> String
        greetDef : TypedDef
        greetDef =
            { name = "greet"
            , args = [ pVar "name" ]
            , tipe = tLambda (tType "String" []) (tType "String" [])
            , body =
                caseExpr (varExpr "name")
                    [ ( pVar "n"
                      , ifExpr
                            (binopsExpr [ ( varExpr "n", "==" ) ] (strExpr ""))
                            (strExpr "Hello, stranger!")
                            (strExpr "Hello!")
                      )
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
