module SourceIR.FloatMathCases exposing (expectSuite, suite)

{-| Programs that call `Basics` operations on `Float`, one or a few per case,
so that a compiler stage meets each of them with `Float` arguments or results.

The MLIR back end can turn a call to a `Basics` operation into an intrinsic,
chosen by the operation's name and its monomorphized argument types in the
private `basicsIntrinsic` of `Compiler.GlobalOpt.KernelIntrinsics`. That function
gives an intrinsic for every operation these programs call, at the types they
call it at, except two: its `logBase` row gives none, and it has no row for
`clamp`. These cases give each operation a small program that calls it at
those types. Whether a run gets as far as code generation depends on the
expectation it is given.

Every case builds a module named `Test` with
`makeModuleWithTypedDefsUnionsAliases`, which imports `Basics` with
`exposing (..)`. The module holds an annotated `testValue` and, in some cases,
one or two annotated helper functions. Every literal is a `Float`, apart
from the `Int` 42 given to `toFloat`. Most operations are named qualified, as
`Basics.sin`; `logBase` and `negate` are named unqualified. Operator chains are
built with `binopsExpr`, which leaves precedence to canonicalization. Where one
chain is an operand of another it is placed there directly rather than in
`parensExpr`, a shape the parser never produces; canonicalization reads the
inner chain as a single operand.

This module asserts nothing itself. `expectSuite` hands the programs, in
order, to the caller's expectation until one fails, and `suite` runs them with
`TestLogic.TestPipeline.expectMonomorphization`. The cases, in the order they
run:

  - Constants: `testValue` is `Basics.pi`; it is `Basics.e`; and it is
    `circleArea 2.0`, where `circleArea r = pi * r * r`.
  - Trigonometry: `sin`, `cos`, `tan`, `asin` and `atan` of 0.0, `acos` of 1.0,
    and `atan2 1.0 1.0`.
  - Square root and logarithm: `sqrt 16.0`; `logBase 2.0 8.0`; and
    `distance 0.0 0.0 3.0 4.0`, where `distance` takes the `sqrt` of the sum of
    the squared differences of its coordinates.
  - Rounding and conversion: `round 2.7`, `floor 2.7`, `ceiling 2.3` and
    `truncate 2.9`, each with an `Int` `testValue`, and `toFloat 42`.
  - Comparison: `1.5 < 2.5`, `2.0 <= 2.0`, `3.0 > 2.0` and `2.0 >= 2.0`, each
    with a `Bool` `testValue`, and `Basics.min` and `Basics.max` of 1.5 and
    2.5.
  - Special values: `isNaN (0.0 / 0.0)` and `isInfinite (1.0 / 0.0)`.
  - Combined: `sin x * sin x + cos x * cos x` at 1.0; a quadratic root built
    from `negate`, `sqrt`, `/` and a helper `discriminant`; and a user-defined
    `clampF` built from `Basics.min` and `Basics.max`, compared with
    `Basics.clamp`.

Among what is not tested:

  - the value any program computes: the cases only build programs, and
    `expectMonomorphization` does not evaluate them;
  - `==`, `/=`, `abs` and `^` on `Float`.

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
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| The cases of this module run with `expectMonomorphization`, as a test of
their own.
-}
suite : Test
suite =
    Test.describe "Float math operations coverage"
        [ expectSuite expectMonomorphization "monomorphizes float math"
        ]


{-| Creates one test, named "Float math operations " followed by `condStr`,
that passes when `expectFn` passes on every program in this module.

The cases run through `Compiler.BulkCheck.bulkCheck`, so a failure names only
the first case that fails, and the cases after it do not run.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Float math operations " ++ condStr) <|
        \() -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, group by group, each handing its
program to `expectFn`.
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


{-| Returns the cases for the constants `pi` and `e`, each handing its program
to `expectFn`.
-}
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.pi`.
-}
piTest : (Src.Module -> Expectation) -> (() -> Expectation)
piTest expectFn _ =
    let
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.e`.
-}
eTest : (Src.Module -> Expectation) -> (() -> Expectation)
eTest expectFn _ =
    let
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `circleArea 2.0`, where `circleArea r` is
`Basics.pi * r * r`.
-}
piInExpressionTest : (Src.Module -> Expectation) -> (() -> Expectation)
piInExpressionTest expectFn _ =
    let
        -- circleArea : Float -> Float
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


{-| Returns the cases for `sin`, `cos`, `tan`, `asin`, `acos`, `atan` and
`atan2`, each handing its program to `expectFn`.
-}
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.sin 0.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.cos 0.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.tan 0.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.asin 0.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.acos 1.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.atan 0.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.atan2 1.0 1.0`.
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


{-| Returns the cases for `sqrt` and `logBase`, each handing its program to
`expectFn`.
-}
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.sqrt 16.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `logBase 2.0 8.0`, with `logBase` named unqualified.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `distance 0.0 0.0 3.0 4.0`, where `distance x1 y1 x2 y2`
is `Basics.sqrt` of the sum of the squares of `x2 - x1` and `y2 - y1`.
-}
sqrtInExpressionTest : (Src.Module -> Expectation) -> (() -> Expectation)
sqrtInExpressionTest expectFn _ =
    let
        -- distance : Float -> Float -> Float -> Float -> Float
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


{-| Returns the cases for `round`, `floor`, `ceiling`, `truncate` and
`toFloat`, each handing its program to `expectFn`.
-}
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


{-| Returns a thunk that applies `expectFn` to a program whose `testValue : Int`
is `Basics.round 2.7`.
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


{-| Returns a thunk that applies `expectFn` to a program whose `testValue : Int`
is `Basics.floor 2.7`.
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


{-| Returns a thunk that applies `expectFn` to a program whose `testValue : Int`
is `Basics.ceiling 2.3`.
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


{-| Returns a thunk that applies `expectFn` to a program whose `testValue : Int`
is `Basics.truncate 2.9`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.toFloat 42`.
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


{-| Returns the cases for `<`, `<=`, `>`, `>=`, `min` and `max` on `Float`,
each handing its program to `expectFn`.
-}
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Bool` is `1.5 < 2.5`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Bool` is `2.0 <= 2.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Bool` is `3.0 > 2.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Bool` is `2.0 >= 2.0`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.min 1.5 2.5`.
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `Basics.max 1.5 2.5`.
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


{-| Returns the cases for `isNaN` and `isInfinite`, each handing its program to
`expectFn`.
-}
specialValueCases : (Src.Module -> Expectation) -> List TestCase
specialValueCases expectFn =
    [ { label = "isNaN"
      , run = isNaNTest expectFn
      }
    , { label = "isInfinite"
      , run = isInfiniteTest expectFn
      }
    ]


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Bool` is `Basics.isNaN (0.0 / 0.0)`.
-}
isNaNTest : (Src.Module -> Expectation) -> (() -> Expectation)
isNaNTest expectFn _ =
    let
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Bool` is `Basics.isInfinite (1.0 / 0.0)`.
-}
isInfiniteTest : (Src.Module -> Expectation) -> (() -> Expectation)
isInfiniteTest expectFn _ =
    let
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


{-| Returns the cases that use several `Float` operations in one program, each
handing its program to `expectFn`.
-}
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `pythagorean 1.0`, where `pythagorean x` is
`Basics.sin x * Basics.sin x + Basics.cos x * Basics.cos x`.

Its case label states the identity that makes this 1, but nothing evaluates
the result.

-}
pythagoreanIdentityTest : (Src.Module -> Expectation) -> (() -> Expectation)
pythagoreanIdentityTest expectFn _ =
    let
        -- pythagorean : Float -> Float
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : Float` is `quadraticRoot 1.0 -3.0 2.0`, with two helpers:
`discriminant a b c` is `b * b - 4.0 * a * c`, and `quadraticRoot a b c` is
`(negate b + sqrt (discriminant a b c)) / (2.0 * a)`.

The divisor `2.0 * a` is its own nested `Binops` operand, as a parenthesised
product parses; a flat chain would group `/` and `*` to the left. The
`-3.0` is built directly as a negative `Float` literal, which the parser never
produces; it would parse `-3.0` as a negation.

-}
quadraticFormulaTest : (Src.Module -> Expectation) -> (() -> Expectation)
quadraticFormulaTest expectFn _ =
    let
        -- discriminant : Float -> Float -> Float -> Float
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
                    ]
                    (binopsExpr [ ( floatExpr 2.0, "*" ) ] (varExpr "a"))
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


{-| Returns a thunk that applies `expectFn` to a program whose
`testValue : ( Float, Float )` is
`( clampF 0.0 1.0 1.5, Basics.clamp 0.0 1.0 1.5 )`, where the program's own
`clampF lo hi x` is `min hi (max lo x)`.
-}
clampTest : (Src.Module -> Expectation) -> (() -> Expectation)
clampTest expectFn _ =
    let
        -- clampF : Float -> Float -> Float -> Float
        clampDef : TypedDef
        clampDef =
            { name = "clampF"
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
            , tipe = tTuple (tType "Float" []) (tType "Float" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "clampF") [ floatExpr 0.0, floatExpr 1.0, floatExpr 1.5 ])
                    (callExpr (qualVarExpr "Basics" "clamp") [ floatExpr 0.0, floatExpr 1.0, floatExpr 1.5 ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ clampDef, testValueDef ]
                []
                []
    in
    expectFn modul
