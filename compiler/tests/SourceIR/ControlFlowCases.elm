module SourceIR.ControlFlowCases exposing (expectSuite, suite)

{-| Test cases for control flow in MLIR codegen.

These tests cover:

  - MLIR.Expr.findBoolBranches (0% coverage)
  - MLIR.Expr.isBoolFanOut (50% coverage)
  - Multi-way if expressions
  - Boolean short-circuit evaluation
  - Complex boolean expressions
  - Nested conditionals

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , strExpr
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
    Test.describe "Control flow coverage"
        [ expectSuite expectMonomorphization "monomorphizes control flow"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Control flow " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ multiWayIfCases expectFn
        , booleanShortCircuitCases expectFn
        , complexBooleanCases expectFn
        , nestedConditionalCases expectFn
        ]



-- ============================================================================
-- MULTI-WAY IF TESTS
-- ============================================================================


multiWayIfCases : (Src.Module -> Expectation) -> List TestCase
multiWayIfCases expectFn =
    [ { label = "Three-way if", run = threeWayIfTest expectFn }
    , { label = "Four-way if", run = fourWayIfTest expectFn }
    , { label = "Five-way if", run = fiveWayIfTest expectFn }
    , { label = "If with function calls in conditions", run = ifWithFunctionCallsTest expectFn }
    , { label = "If returning different types of expressions", run = ifReturningExpressionsTest expectFn }
    ]


{-| Test three-way if expression.
-}
threeWayIfTest : (Src.Module -> Expectation) -> (() -> Expectation)
threeWayIfTest expectFn _ =
    let
        -- sign : Int -> Int
        -- sign n =
        --     if n < 0 then -1
        --     else if n > 0 then 1
        --     else 0
        signDef : TypedDef
        signDef =
            { name = "sign"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                    (intExpr -1)
                    (ifExpr
                        (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
                        (intExpr 1)
                        (intExpr 0)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "sign") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ signDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test four-way if expression.
-}
fourWayIfTest : (Src.Module -> Expectation) -> (() -> Expectation)
fourWayIfTest expectFn _ =
    let
        -- classify : Int -> String
        -- classify n =
        --     if n < 0 then "negative"
        --     else if n == 0 then "zero"
        --     else if n < 10 then "small"
        --     else "large"
        classifyDef : TypedDef
        classifyDef =
            { name = "classify"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                    (strExpr "negative")
                    (ifExpr
                        (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                        (strExpr "zero")
                        (ifExpr
                            (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 10))
                            (strExpr "small")
                            (strExpr "large")
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "classify") [ intExpr 50 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ classifyDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test five-way if expression.
-}
fiveWayIfTest : (Src.Module -> Expectation) -> (() -> Expectation)
fiveWayIfTest expectFn _ =
    let
        -- grade : Int -> String
        -- grade score =
        --     if score >= 90 then "A"
        --     else if score >= 80 then "B"
        --     else if score >= 70 then "C"
        --     else if score >= 60 then "D"
        --     else "F"
        gradeDef : TypedDef
        gradeDef =
            { name = "grade"
            , args = [ pVar "score" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 90))
                    (strExpr "A")
                    (ifExpr
                        (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 80))
                        (strExpr "B")
                        (ifExpr
                            (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 70))
                            (strExpr "C")
                            (ifExpr
                                (binopsExpr [ ( varExpr "score", ">=" ) ] (intExpr 60))
                                (strExpr "D")
                                (strExpr "F")
                            )
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "grade") [ intExpr 75 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ gradeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test if with function calls in conditions.
-}
ifWithFunctionCallsTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifWithFunctionCallsTest expectFn _ =
    let
        -- isPositive : Int -> Bool
        isPositiveDef : TypedDef
        isPositiveDef =
            { name = "isPositive"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0)
            }

        -- isEven : Int -> Bool
        isEvenDef : TypedDef
        isEvenDef =
            { name = "isEven"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "n", "//" ) ] (intExpr 2), "*" )
                    , ( intExpr 2, "==" )
                    ]
                    (varExpr "n")
            }

        -- categorize : Int -> String
        categorizeDef : TypedDef
        categorizeDef =
            { name = "categorize"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "String" [])
            , body =
                ifExpr
                    (callExpr (varExpr "isPositive") [ varExpr "n" ])
                    (ifExpr
                        (callExpr (varExpr "isEven") [ varExpr "n" ])
                        (strExpr "positive even")
                        (strExpr "positive odd")
                    )
                    (strExpr "non-positive")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "categorize") [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isPositiveDef, isEvenDef, categorizeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test if returning different types of expressions.
-}
ifReturningExpressionsTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningExpressionsTest expectFn _ =
    let
        -- selectList : Bool -> List Int
        selectListDef : TypedDef
        selectListDef =
            { name = "selectList"
            , args = [ pVar "flag" ]
            , tipe = tLambda (tType "Bool" []) (tType "List" [ tType "Int" [] ])
            , body =
                ifExpr
                    (varExpr "flag")
                    (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
                    (listExpr [])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body = callExpr (varExpr "selectList") [ boolExpr True ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ selectListDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- BOOLEAN SHORT-CIRCUIT TESTS
-- ============================================================================


booleanShortCircuitCases : (Src.Module -> Expectation) -> List TestCase
booleanShortCircuitCases expectFn =
    [ { label = "And short-circuit", run = andShortCircuitTest expectFn }
    , { label = "Or short-circuit", run = orShortCircuitTest expectFn }
    , { label = "Mixed and/or", run = mixedAndOrTest expectFn }
    , { label = "Short-circuit with function calls", run = shortCircuitWithFunctionCallsTest expectFn }
    ]


{-| Test && short-circuit evaluation.
-}
andShortCircuitTest : (Src.Module -> Expectation) -> (() -> Expectation)
andShortCircuitTest expectFn _ =
    let
        -- safeDivide : Int -> Int -> Bool
        -- safeDivide a b = b /= 0 && (a // b > 0)
        safeDivideDef : TypedDef
        safeDivideDef =
            { name = "safeDivide"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Bool" []))
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "b", "/=" ) ] (intExpr 0), "&&" ) ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "//" ) ] (varExpr "b"), ">" ) ]
                        (intExpr 0)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "safeDivide") [ intExpr 10, intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ safeDivideDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test || short-circuit evaluation.
-}
orShortCircuitTest : (Src.Module -> Expectation) -> (() -> Expectation)
orShortCircuitTest expectFn _ =
    let
        -- isZeroOrPositive : Int -> Bool
        -- isZeroOrPositive n = n == 0 || n > 0
        isZeroOrPositiveDef : TypedDef
        isZeroOrPositiveDef =
            { name = "isZeroOrPositive"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0), "||" ) ]
                    (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isZeroOrPositive") [ intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isZeroOrPositiveDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test mixed && and || operators.
-}
mixedAndOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
mixedAndOrTest expectFn _ =
    let
        -- inRange : Int -> Int -> Int -> Bool
        -- inRange lo hi x = (x >= lo && x <= hi) || x == 0
        inRangeDef : TypedDef
        inRangeDef =
            { name = "inRange"
            , args = [ pVar "lo", pVar "hi", pVar "x" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Bool" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr
                            [ ( binopsExpr [ ( varExpr "x", ">=" ) ] (varExpr "lo"), "&&" ) ]
                            (binopsExpr [ ( varExpr "x", "<=" ) ] (varExpr "hi"))
                      , "||"
                      )
                    ]
                    (binopsExpr [ ( varExpr "x", "==" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "inRange") [ intExpr 1, intExpr 10, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ inRangeDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test short-circuit with function calls.
-}
shortCircuitWithFunctionCallsTest : (Src.Module -> Expectation) -> (() -> Expectation)
shortCircuitWithFunctionCallsTest expectFn _ =
    let
        -- isValid : Int -> Bool
        isValidDef : TypedDef
        isValidDef =
            { name = "isValid"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0)
            }

        -- isSmall : Int -> Bool
        isSmallDef : TypedDef
        isSmallDef =
            { name = "isSmall"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 100)
            }

        -- checkBoth : Int -> Bool
        checkBothDef : TypedDef
        checkBothDef =
            { name = "checkBoth"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body =
                binopsExpr
                    [ ( callExpr (varExpr "isValid") [ varExpr "n" ], "&&" ) ]
                    (callExpr (varExpr "isSmall") [ varExpr "n" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "checkBoth") [ intExpr 50 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isValidDef, isSmallDef, checkBothDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- COMPLEX BOOLEAN TESTS
-- ============================================================================


complexBooleanCases : (Src.Module -> Expectation) -> List TestCase
complexBooleanCases expectFn =
    [ { label = "Triple and", run = tripleAndTest expectFn }
    , { label = "Triple or", run = tripleOrTest expectFn }
    , { label = "Nested boolean expressions", run = nestedBooleanExpressionsTest expectFn }
    , { label = "Boolean with not", run = booleanWithNotTest expectFn }
    ]


{-| Test triple && expression.
-}
tripleAndTest : (Src.Module -> Expectation) -> (() -> Expectation)
tripleAndTest expectFn _ =
    let
        -- allPositive : Int -> Int -> Int -> Bool
        -- allPositive a b c = a > 0 && b > 0 && c > 0
        allPositiveDef : TypedDef
        allPositiveDef =
            { name = "allPositive"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Bool" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0), "&&" )
                    , ( binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0), "&&" )
                    ]
                    (binopsExpr [ ( varExpr "c", ">" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "allPositive") [ intExpr 1, intExpr 2, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ allPositiveDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test triple || expression.
-}
tripleOrTest : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOrTest expectFn _ =
    let
        -- anyZero : Int -> Int -> Int -> Bool
        -- anyZero a b c = a == 0 || b == 0 || c == 0
        anyZeroDef : TypedDef
        anyZeroDef =
            { name = "anyZero"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Int" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" []) (tType "Bool" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "a", "==" ) ] (intExpr 0), "||" )
                    , ( binopsExpr [ ( varExpr "b", "==" ) ] (intExpr 0), "||" )
                    ]
                    (binopsExpr [ ( varExpr "c", "==" ) ] (intExpr 0))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "anyZero") [ intExpr 1, intExpr 0, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ anyZeroDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test nested boolean expressions.
-}
nestedBooleanExpressionsTest : (Src.Module -> Expectation) -> (() -> Expectation)
nestedBooleanExpressionsTest expectFn _ =
    let
        -- complexCheck : Int -> Int -> Bool
        -- complexCheck a b = (a > 0 && b > 0) || (a < 0 && b < 0)
        complexCheckDef : TypedDef
        complexCheckDef =
            { name = "complexCheck"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Bool" []))
            , body =
                binopsExpr
                    [ ( binopsExpr
                            [ ( binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0), "&&" ) ]
                            (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                      , "||"
                      )
                    ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "<" ) ] (intExpr 0), "&&" ) ]
                        (binopsExpr [ ( varExpr "b", "<" ) ] (intExpr 0))
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "complexCheck") [ intExpr -1, intExpr -2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ complexCheckDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test boolean with not operator.
-}
booleanWithNotTest : (Src.Module -> Expectation) -> (() -> Expectation)
booleanWithNotTest expectFn _ =
    let
        -- notPositive : Int -> Bool
        notPositiveDef : TypedDef
        notPositiveDef =
            { name = "notPositive"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Bool" [])
            , body = callExpr (varExpr "not") [ binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "notPositive") [ intExpr -5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ notPositiveDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED CONDITIONAL TESTS
-- ============================================================================


nestedConditionalCases : (Src.Module -> Expectation) -> List TestCase
nestedConditionalCases expectFn =
    [ { label = "If in if branch", run = ifInIfBranchTest expectFn }
    , { label = "If in else branch", run = ifInElseBranchTest expectFn }
    , { label = "If in both branches", run = ifInBothBranchesTest expectFn }
    , { label = "Deep nesting", run = deepNestingTest expectFn }
    ]


{-| Test if in if branch.
-}
ifInIfBranchTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifInIfBranchTest expectFn _ =
    let
        -- nestedIf : Int -> Int -> Int
        nestedIfDef : TypedDef
        nestedIfDef =
            { name = "nestedIf"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0))
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 1)
                        (intExpr 2)
                    )
                    (intExpr 3)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "nestedIf") [ intExpr 5, intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ nestedIfDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test if in else branch.
-}
ifInElseBranchTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifInElseBranchTest expectFn _ =
    let
        -- elseNested : Int -> Int -> Int
        elseNestedDef : TypedDef
        elseNestedDef =
            { name = "elseNested"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0))
                    (intExpr 1)
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 2)
                        (intExpr 3)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "elseNested") [ intExpr -1, intExpr 10 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ elseNestedDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test if in both branches.
-}
ifInBothBranchesTest : (Src.Module -> Expectation) -> (() -> Expectation)
ifInBothBranchesTest expectFn _ =
    let
        -- bothNested : Int -> Int -> Int
        bothNestedDef : TypedDef
        bothNestedDef =
            { name = "bothNested"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "a", ">" ) ] (intExpr 0))
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 1)
                        (intExpr 2)
                    )
                    (ifExpr
                        (binopsExpr [ ( varExpr "b", ">" ) ] (intExpr 0))
                        (intExpr 3)
                        (intExpr 4)
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "bothNested") [ intExpr -1, intExpr -2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ bothNestedDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test deep nesting of conditionals.
-}
deepNestingTest : (Src.Module -> Expectation) -> (() -> Expectation)
deepNestingTest expectFn _ =
    let
        -- deepNest : Int -> Int
        deepNestDef : TypedDef
        deepNestDef =
            { name = "deepNest"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 100))
                    (intExpr 5)
                    (ifExpr
                        (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 50))
                        (intExpr 4)
                        (ifExpr
                            (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 25))
                            (intExpr 3)
                            (ifExpr
                                (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 10))
                                (intExpr 2)
                                (ifExpr
                                    (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
                                    (intExpr 1)
                                    (intExpr 0)
                                )
                            )
                        )
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "deepNest") [ intExpr 30 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ deepNestDef, testValueDef ]
                []
                []
    in
    expectFn modul
