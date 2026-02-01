module SourceIR.FloatMathCases exposing (expectSuite, suite, testCases)

{-| Test cases for Float math operations in MLIR codegen.

These tests cover:

  - MLIR.Intrinsics.basicsIntrinsic (38% coverage) - float branches
  - Basics.pi, Basics.e (constants)
  - sqrt, sin, cos, tan, asin, acos, atan, atan2
  - isNaN, isInfinite
  - round, floor, ceiling, truncate
  - Float comparisons (<, <=, >, >=)
  - toFloat

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , floatExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import TestLogic.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Float math operations coverage"
        [ expectSuite expectMonomorphization "monomorphizes float math"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Float math operations " ++ condStr) <|
        \() -> bulkCheck (testCases expectFn)


{-| All test cases for Float math operations.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    constantCases expectFn
        ++ trigCases expectFn
        ++ sqrtLogCases expectFn
        ++ roundingCases expectFn
        ++ comparisonCases expectFn
        ++ specialValueCases expectFn
        ++ combinedFloatCases expectFn



-- ============================================================================
-- CONSTANT TESTS
-- ============================================================================


constantCases : (Src.Module -> Expectation) -> List TestCase
constantCases expectFn =
    [ { label = "Basics.pi"
      , run = piTest expectFn
      }
    , { label = "Basics.e"
      , run = eTest expectFn
      }
    , { label = "pi in expression"
      , run = piInExpressionTest expectFn
      }
    ]


{-| Test Basics.pi constant.
-}
piTest : (Src.Module -> Expectation) -> (() -> Expectation)
piTest expectFn _ =
    let
        -- testValue : Float
        -- testValue = pi
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = qualVarExpr "Basics" "pi"
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test Basics.e constant.
-}
eTest : (Src.Module -> Expectation) -> (() -> Expectation)
eTest expectFn _ =
    let
        -- testValue : Float
        -- testValue = e
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = qualVarExpr "Basics" "e"
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test pi used in arithmetic expression.
-}
piInExpressionTest : (Src.Module -> Expectation) -> (() -> Expectation)
piInExpressionTest expectFn _ =
    let
        -- circleArea : Float -> Float
        -- circleArea r = pi * r * r
        circleAreaDef : TypedDef
        circleAreaDef =
            { name = "circleArea"
            , args = [ pVar "r" ]
            , tipe = tLambda (tType "Float" []) (tType "Float" [])
            , body =
                binopsExpr
                    [ ( qualVarExpr "Basics" "pi", "*" )
                    , ( varExpr "r", "*" )
                    ]
                    (varExpr "r")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "circleArea") [ floatExpr 2.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ circleAreaDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- TRIGONOMETRIC TESTS
-- ============================================================================


trigCases : (Src.Module -> Expectation) -> List TestCase
trigCases expectFn =
    [ { label = "sin"
      , run = sinTest expectFn
      }
    , { label = "cos"
      , run = cosTest expectFn
      }
    , { label = "tan"
      , run = tanTest expectFn
      }
    , { label = "asin"
      , run = asinTest expectFn
      }
    , { label = "acos"
      , run = acosTest expectFn
      }
    , { label = "atan"
      , run = atanTest expectFn
      }
    , { label = "atan2"
      , run = atan2Test expectFn
      }
    ]


{-| Test sin function.
-}
sinTest : (Src.Module -> Expectation) -> (() -> Expectation)
sinTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "sin") [ floatExpr 0.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test cos function.
-}
cosTest : (Src.Module -> Expectation) -> (() -> Expectation)
cosTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "cos") [ floatExpr 0.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test tan function.
-}
tanTest : (Src.Module -> Expectation) -> (() -> Expectation)
tanTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "tan") [ floatExpr 0.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test asin function.
-}
asinTest : (Src.Module -> Expectation) -> (() -> Expectation)
asinTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "asin") [ floatExpr 0.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test acos function.
-}
acosTest : (Src.Module -> Expectation) -> (() -> Expectation)
acosTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "acos") [ floatExpr 1.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test atan function.
-}
atanTest : (Src.Module -> Expectation) -> (() -> Expectation)
atanTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "atan") [ floatExpr 0.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test atan2 function.
-}
atan2Test : (Src.Module -> Expectation) -> (() -> Expectation)
atan2Test expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "atan2") [ floatExpr 1.0, floatExpr 1.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- SQRT AND LOG TESTS
-- ============================================================================


sqrtLogCases : (Src.Module -> Expectation) -> List TestCase
sqrtLogCases expectFn =
    [ { label = "sqrt"
      , run = sqrtTest expectFn
      }
    , { label = "logBase"
      , run = logBaseTest expectFn
      }
    , { label = "sqrt in expression"
      , run = sqrtInExpressionTest expectFn
      }
    ]


{-| Test sqrt function.
-}
sqrtTest : (Src.Module -> Expectation) -> (() -> Expectation)
sqrtTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "sqrt") [ floatExpr 16.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test logBase function.
-}
logBaseTest : (Src.Module -> Expectation) -> (() -> Expectation)
logBaseTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "logBase") [ floatExpr 2.0, floatExpr 8.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test sqrt in a more complex expression.
-}
sqrtInExpressionTest : (Src.Module -> Expectation) -> (() -> Expectation)
sqrtInExpressionTest expectFn _ =
    let
        -- distance : Float -> Float -> Float -> Float -> Float
        -- distance x1 y1 x2 y2 = sqrt ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
        distanceDef : TypedDef
        distanceDef =
            { name = "distance"
            , args = [ pVar "x1", pVar "y1", pVar "x2", pVar "y2" ]
            , tipe =
                tLambda (tType "Float" [])
                    (tLambda (tType "Float" [])
                        (tLambda (tType "Float" [])
                            (tLambda (tType "Float" []) (tType "Float" []))
                        )
                    )
            , body =
                callExpr (qualVarExpr "Basics" "sqrt")
                    [ binopsExpr
                        [ ( binopsExpr
                                [ ( binopsExpr [ ( varExpr "x2", "-" ) ] (varExpr "x1"), "*" ) ]
                                (binopsExpr [ ( varExpr "x2", "-" ) ] (varExpr "x1"))
                          , "+"
                          )
                        ]
                        (binopsExpr
                            [ ( binopsExpr [ ( varExpr "y2", "-" ) ] (varExpr "y1"), "*" ) ]
                            (binopsExpr [ ( varExpr "y2", "-" ) ] (varExpr "y1"))
                        )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "distance") [ floatExpr 0.0, floatExpr 0.0, floatExpr 3.0, floatExpr 4.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ distanceDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- ROUNDING TESTS
-- ============================================================================


roundingCases : (Src.Module -> Expectation) -> List TestCase
roundingCases expectFn =
    [ { label = "round"
      , run = roundTest expectFn
      }
    , { label = "floor"
      , run = floorTest expectFn
      }
    , { label = "ceiling"
      , run = ceilingTest expectFn
      }
    , { label = "truncate"
      , run = truncateTest expectFn
      }
    , { label = "toFloat"
      , run = toFloatTest expectFn
      }
    ]


{-| Test round function.
-}
roundTest : (Src.Module -> Expectation) -> (() -> Expectation)
roundTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (qualVarExpr "Basics" "round") [ floatExpr 2.7 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test floor function.
-}
floorTest : (Src.Module -> Expectation) -> (() -> Expectation)
floorTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (qualVarExpr "Basics" "floor") [ floatExpr 2.7 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test ceiling function.
-}
ceilingTest : (Src.Module -> Expectation) -> (() -> Expectation)
ceilingTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (qualVarExpr "Basics" "ceiling") [ floatExpr 2.3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test truncate function.
-}
truncateTest : (Src.Module -> Expectation) -> (() -> Expectation)
truncateTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (qualVarExpr "Basics" "truncate") [ floatExpr 2.9 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test toFloat function.
-}
toFloatTest : (Src.Module -> Expectation) -> (() -> Expectation)
toFloatTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "toFloat") [ intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- COMPARISON TESTS
-- ============================================================================


comparisonCases : (Src.Module -> Expectation) -> List TestCase
comparisonCases expectFn =
    [ { label = "Float less than"
      , run = floatLessThanTest expectFn
      }
    , { label = "Float less than or equal"
      , run = floatLessEqualTest expectFn
      }
    , { label = "Float greater than"
      , run = floatGreaterThanTest expectFn
      }
    , { label = "Float greater than or equal"
      , run = floatGreaterEqualTest expectFn
      }
    , { label = "Float min"
      , run = floatMinTest expectFn
      }
    , { label = "Float max"
      , run = floatMaxTest expectFn
      }
    ]


{-| Test float less than comparison.
-}
floatLessThanTest : (Src.Module -> Expectation) -> (() -> Expectation)
floatLessThanTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = binopsExpr [ ( floatExpr 1.5, "<" ) ] (floatExpr 2.5)
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test float less than or equal comparison.
-}
floatLessEqualTest : (Src.Module -> Expectation) -> (() -> Expectation)
floatLessEqualTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = binopsExpr [ ( floatExpr 2.0, "<=" ) ] (floatExpr 2.0)
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test float greater than comparison.
-}
floatGreaterThanTest : (Src.Module -> Expectation) -> (() -> Expectation)
floatGreaterThanTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = binopsExpr [ ( floatExpr 3.0, ">" ) ] (floatExpr 2.0)
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test float greater than or equal comparison.
-}
floatGreaterEqualTest : (Src.Module -> Expectation) -> (() -> Expectation)
floatGreaterEqualTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = binopsExpr [ ( floatExpr 2.0, ">=" ) ] (floatExpr 2.0)
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test float min function.
-}
floatMinTest : (Src.Module -> Expectation) -> (() -> Expectation)
floatMinTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "min") [ floatExpr 1.5, floatExpr 2.5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test float max function.
-}
floatMaxTest : (Src.Module -> Expectation) -> (() -> Expectation)
floatMaxTest expectFn _ =
    let
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "max") [ floatExpr 1.5, floatExpr 2.5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- SPECIAL VALUE TESTS
-- ============================================================================


specialValueCases : (Src.Module -> Expectation) -> List TestCase
specialValueCases expectFn =
    [ { label = "isNaN"
      , run = isNaNTest expectFn
      }
    , { label = "isInfinite"
      , run = isInfiniteTest expectFn
      }
    ]


{-| Test isNaN function.
-}
isNaNTest : (Src.Module -> Expectation) -> (() -> Expectation)
isNaNTest expectFn _ =
    let
        -- testValue : Bool
        -- testValue = isNaN (0.0 / 0.0)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body =
                callExpr (qualVarExpr "Basics" "isNaN")
                    [ binopsExpr [ ( floatExpr 0.0, "/" ) ] (floatExpr 0.0) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test isInfinite function.
-}
isInfiniteTest : (Src.Module -> Expectation) -> (() -> Expectation)
isInfiniteTest expectFn _ =
    let
        -- testValue : Bool
        -- testValue = isInfinite (1.0 / 0.0)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body =
                callExpr (qualVarExpr "Basics" "isInfinite")
                    [ binopsExpr [ ( floatExpr 1.0, "/" ) ] (floatExpr 0.0) ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- COMBINED FLOAT TESTS
-- ============================================================================


combinedFloatCases : (Src.Module -> Expectation) -> List TestCase
combinedFloatCases expectFn =
    [ { label = "sin^2 + cos^2 = 1"
      , run = pythagoreanIdentityTest expectFn
      }
    , { label = "Quadratic formula"
      , run = quadraticFormulaTest expectFn
      }
    , { label = "Clamp function"
      , run = clampTest expectFn
      }
    ]


{-| Test sin^2(x) + cos^2(x) = 1 identity.
-}
pythagoreanIdentityTest : (Src.Module -> Expectation) -> (() -> Expectation)
pythagoreanIdentityTest expectFn _ =
    let
        -- pythagorean : Float -> Float
        -- pythagorean x = sin x * sin x + cos x * cos x
        pythagoreanDef : TypedDef
        pythagoreanDef =
            { name = "pythagorean"
            , args = [ pVar "x" ]
            , tipe = tLambda (tType "Float" []) (tType "Float" [])
            , body =
                binopsExpr
                    [ ( binopsExpr
                            [ ( callExpr (qualVarExpr "Basics" "sin") [ varExpr "x" ], "*" ) ]
                            (callExpr (qualVarExpr "Basics" "sin") [ varExpr "x" ])
                      , "+"
                      )
                    ]
                    (binopsExpr
                        [ ( callExpr (qualVarExpr "Basics" "cos") [ varExpr "x" ], "*" ) ]
                        (callExpr (qualVarExpr "Basics" "cos") [ varExpr "x" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "pythagorean") [ floatExpr 1.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ pythagoreanDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test quadratic formula discriminant.
-}
quadraticFormulaTest : (Src.Module -> Expectation) -> (() -> Expectation)
quadraticFormulaTest expectFn _ =
    let
        -- discriminant : Float -> Float -> Float -> Float
        -- discriminant a b c = b * b - 4.0 * a * c
        discriminantDef : TypedDef
        discriminantDef =
            { name = "discriminant"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Float" [])
                    (tLambda (tType "Float" [])
                        (tLambda (tType "Float" []) (tType "Float" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr [ ( varExpr "b", "*" ) ] (varExpr "b"), "-" )
                    , ( floatExpr 4.0, "*" )
                    , ( varExpr "a", "*" )
                    ]
                    (varExpr "c")
            }

        -- quadraticRoot : Float -> Float -> Float -> Float
        -- quadraticRoot a b c = (-b + sqrt (discriminant a b c)) / (2.0 * a)
        quadraticRootDef : TypedDef
        quadraticRootDef =
            { name = "quadraticRoot"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe =
                tLambda (tType "Float" [])
                    (tLambda (tType "Float" [])
                        (tLambda (tType "Float" []) (tType "Float" []))
                    )
            , body =
                binopsExpr
                    [ ( binopsExpr
                            [ ( callExpr (varExpr "negate") [ varExpr "b" ], "+" ) ]
                            (callExpr (qualVarExpr "Basics" "sqrt")
                                [ callExpr (varExpr "discriminant")
                                    [ varExpr "a", varExpr "b", varExpr "c" ]
                                ]
                            )
                      , "/"
                      )
                    , ( floatExpr 2.0, "*" )
                    ]
                    (varExpr "a")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "quadraticRoot") [ floatExpr 1.0, floatExpr -3.0, floatExpr 2.0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ discriminantDef, quadraticRootDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| Test clamp function using min and max.
-}
clampTest : (Src.Module -> Expectation) -> (() -> Expectation)
clampTest expectFn _ =
    let
        -- clamp : Float -> Float -> Float -> Float
        -- clamp lo hi x = min hi (max lo x)
        clampDef : TypedDef
        clampDef =
            { name = "clamp"
            , args = [ pVar "lo", pVar "hi", pVar "x" ]
            , tipe =
                tLambda (tType "Float" [])
                    (tLambda (tType "Float" [])
                        (tLambda (tType "Float" []) (tType "Float" []))
                    )
            , body =
                callExpr (qualVarExpr "Basics" "min")
                    [ varExpr "hi"
                    , callExpr (qualVarExpr "Basics" "max") [ varExpr "lo", varExpr "x" ]
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (qualVarExpr "Basics" "clamp") [ floatExpr 0.0, floatExpr 1.0, floatExpr 1.5 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ clampDef, testValueDef ]
                []
                []
    in
    expectFn modul
