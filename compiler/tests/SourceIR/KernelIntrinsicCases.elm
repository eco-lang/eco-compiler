module SourceIR.KernelIntrinsicCases exposing (expectSuite)

{-| Direct Elm.Kernel.* VarKernel intrinsic tests.

Each test calls a single kernel function directly via qualVarExpr "Elm.Kernel.X" "name"
to exercise specific MLIR intrinsic code generation paths.

Grouped by kernel module: Basics, Utils, Bitwise, JsArray, List, Tuple, String, Bytes.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , callExpr
        , floatExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeKernelModule
        , pVar
        , qualVarExpr
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel intrinsics " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ basicsIntArithCases expectFn
        , basicsFloatArithCases expectFn
        , basicsComparisonCases expectFn
        , basicsBoolCases expectFn
        , basicsTrigCases expectFn
        , basicsConversionCases expectFn
        , basicsConstantCases expectFn
        , basicsMiscCases expectFn
        , utilsIntCases expectFn
        , utilsFloatCases expectFn
        , bitwiseCases expectFn
        , jsArrayCases expectFn
        , listCases expectFn
        , tupleCases expectFn
        , stringCases expectFn
        , bytesCases expectFn
        ]



-- ============================================================================
-- BASICS: INT ARITHMETIC
-- ============================================================================


basicsIntArithCases : (Src.Module -> Expectation) -> List TestCase
basicsIntArithCases expectFn =
    [ { label = "K Basics.add Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ intExpr 3, intExpr 4 ])) }
    , { label = "K Basics.sub Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "sub") [ intExpr 10, intExpr 3 ])) }
    , { label = "K Basics.mul Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ intExpr 6, intExpr 7 ])) }
    , { label = "K Basics.idiv", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "idiv") [ intExpr 10, intExpr 3 ])) }
    , { label = "K Basics.remainderBy", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "remainderBy") [ intExpr 3, intExpr 10 ])) }
    , { label = "K Basics.negate Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "negate") [ intExpr 42 ])) }
    , { label = "K Basics.abs Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "abs") [ intExpr -5 ])) }
    , { label = "K Basics.pow Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "pow") [ intExpr 2, intExpr 10 ])) }
    , { label = "K Basics.min Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "min") [ intExpr 3, intExpr 7 ])) }
    , { label = "K Basics.max Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "max") [ intExpr 3, intExpr 7 ])) }
    ]



-- ============================================================================
-- BASICS: FLOAT ARITHMETIC
-- ============================================================================


basicsFloatArithCases : (Src.Module -> Expectation) -> List TestCase
basicsFloatArithCases expectFn =
    [ { label = "K Basics.fadd", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "fadd") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Basics.fsub", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "fsub") [ floatExpr 10.0, floatExpr 3.0 ])) }
    , { label = "K Basics.fmul", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "fmul") [ floatExpr 3.0, floatExpr 4.0 ])) }
    , { label = "K Basics.fdiv", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "fdiv") [ floatExpr 10.0, floatExpr 3.0 ])) }
    , { label = "K Basics.fpow", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "fpow") [ floatExpr 2.0, floatExpr 8.0 ])) }
    , { label = "K Basics.negate Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "negate") [ floatExpr 3.14 ])) }
    , { label = "K Basics.abs Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "abs") [ floatExpr -3.14 ])) }
    , { label = "K Basics.sqrt", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "sqrt") [ floatExpr 25.0 ])) }
    , { label = "K Basics.log", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "log") [ floatExpr 100.0 ])) }
    , { label = "K Basics.logBase", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "logBase") [ floatExpr 10.0, floatExpr 100.0 ])) }
    , { label = "K Basics.min Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "min") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Basics.max Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "max") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Basics.pow Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "pow") [ floatExpr 2.0, floatExpr 10.0 ])) }
    ]



-- ============================================================================
-- BASICS: COMPARISONS (Int and Float)
-- ============================================================================


basicsComparisonCases : (Src.Module -> Expectation) -> List TestCase
basicsComparisonCases expectFn =
    [ { label = "K Basics.eq Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "eq") [ intExpr 1, intExpr 1 ])) }
    , { label = "K Basics.neq Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "neq") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Basics.lt Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "lt") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Basics.le Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "le") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Basics.gt Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "gt") [ intExpr 2, intExpr 1 ])) }
    , { label = "K Basics.ge Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "ge") [ intExpr 2, intExpr 1 ])) }
    , { label = "K Basics.eq Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "eq") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Basics.neq Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "neq") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Basics.lt Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "lt") [ floatExpr 1.0, floatExpr 2.0 ])) }
    , { label = "K Basics.le Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "le") [ floatExpr 1.0, floatExpr 2.0 ])) }
    , { label = "K Basics.gt Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "gt") [ floatExpr 2.0, floatExpr 1.0 ])) }
    , { label = "K Basics.ge Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "ge") [ floatExpr 2.0, floatExpr 1.0 ])) }
    ]



-- ============================================================================
-- BASICS: BOOLEAN
-- ============================================================================


basicsBoolCases : (Src.Module -> Expectation) -> List TestCase
basicsBoolCases expectFn =
    [ { label = "K Basics.not", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "not") [ boolExpr True ])) }
    , { label = "K Basics.and", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "and") [ boolExpr True, boolExpr False ])) }
    , { label = "K Basics.or", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "or") [ boolExpr True, boolExpr False ])) }
    , { label = "K Basics.xor", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "xor") [ boolExpr True, boolExpr False ])) }
    ]



-- ============================================================================
-- BASICS: TRIG
-- ============================================================================


basicsTrigCases : (Src.Module -> Expectation) -> List TestCase
basicsTrigCases expectFn =
    [ { label = "K Basics.sin", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "sin") [ floatExpr 0.0 ])) }
    , { label = "K Basics.cos", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "cos") [ floatExpr 0.0 ])) }
    , { label = "K Basics.tan", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "tan") [ floatExpr 0.0 ])) }
    , { label = "K Basics.asin", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "asin") [ floatExpr 0.5 ])) }
    , { label = "K Basics.acos", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "acos") [ floatExpr 0.5 ])) }
    , { label = "K Basics.atan", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "atan") [ floatExpr 1.0 ])) }
    , { label = "K Basics.atan2", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "atan2") [ floatExpr 1.0, floatExpr 0.0 ])) }
    ]



-- ============================================================================
-- BASICS: CONVERSIONS
-- ============================================================================


basicsConversionCases : (Src.Module -> Expectation) -> List TestCase
basicsConversionCases expectFn =
    [ { label = "K Basics.toFloat", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "toFloat") [ intExpr 42 ])) }
    , { label = "K Basics.round", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "round") [ floatExpr 3.7 ])) }
    , { label = "K Basics.floor", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "floor") [ floatExpr 3.7 ])) }
    , { label = "K Basics.ceiling", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "ceiling") [ floatExpr 3.2 ])) }
    , { label = "K Basics.truncate", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "truncate") [ floatExpr 3.9 ])) }
    ]



-- ============================================================================
-- BASICS: CONSTANTS
-- ============================================================================


basicsConstantCases : (Src.Module -> Expectation) -> List TestCase
basicsConstantCases expectFn =
    [ { label = "K Basics.pi", run = \_ -> expectFn (makeKernelModule "testValue" (qualVarExpr "Elm.Kernel.Basics" "pi")) }
    , { label = "K Basics.e", run = \_ -> expectFn (makeKernelModule "testValue" (qualVarExpr "Elm.Kernel.Basics" "e")) }
    ]



-- ============================================================================
-- BASICS: MISC (identity, always, isNaN, isInfinite, clamp)
-- ============================================================================


basicsMiscCases : (Src.Module -> Expectation) -> List TestCase
basicsMiscCases expectFn =
    [ { label = "K Basics.identity", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "identity") [ intExpr 99 ])) }
    , { label = "K Basics.always", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "always") [ intExpr 1, strExpr "ignored" ])) }
    , { label = "K Basics.isNaN", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "isNaN") [ floatExpr 0.0 ])) }
    , { label = "K Basics.isInfinite", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "isInfinite") [ floatExpr 1.0 ])) }
    , { label = "K Basics.clamp", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "clamp") [ intExpr 0, intExpr 10, intExpr 15 ])) }
    ]



-- ============================================================================
-- UTILS: INT COMPARISONS
-- ============================================================================


utilsIntCases : (Src.Module -> Expectation) -> List TestCase
utilsIntCases expectFn =
    [ { label = "K Utils.equal Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "equal") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Utils.notEqual Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "notEqual") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Utils.compare Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "compare") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Utils.lt Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "lt") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Utils.le Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "le") [ intExpr 1, intExpr 2 ])) }
    , { label = "K Utils.gt Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "gt") [ intExpr 2, intExpr 1 ])) }
    , { label = "K Utils.ge Int", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "ge") [ intExpr 2, intExpr 1 ])) }
    , { label = "K Utils.append", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "append") [ listExpr [ intExpr 1 ], listExpr [ intExpr 2 ] ])) }
    ]



-- ============================================================================
-- UTILS: FLOAT COMPARISONS
-- ============================================================================


utilsFloatCases : (Src.Module -> Expectation) -> List TestCase
utilsFloatCases expectFn =
    [ { label = "K Utils.equal Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "equal") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Utils.notEqual Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "notEqual") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Utils.compare Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "compare") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Utils.lt Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "lt") [ floatExpr 1.0, floatExpr 2.0 ])) }
    , { label = "K Utils.le Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "le") [ floatExpr 1.0, floatExpr 2.0 ])) }
    , { label = "K Utils.gt Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "gt") [ floatExpr 2.0, floatExpr 1.0 ])) }
    , { label = "K Utils.ge Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Utils" "ge") [ floatExpr 2.0, floatExpr 1.0 ])) }
    ]



-- ============================================================================
-- BITWISE
-- ============================================================================


bitwiseCases : (Src.Module -> Expectation) -> List TestCase
bitwiseCases expectFn =
    [ { label = "K Bitwise.and", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bitwise" "and") [ intExpr 255, intExpr 15 ])) }
    , { label = "K Bitwise.or", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bitwise" "or") [ intExpr 240, intExpr 15 ])) }
    , { label = "K Bitwise.xor", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bitwise" "xor") [ intExpr 255, intExpr 15 ])) }
    , { label = "K Bitwise.complement", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bitwise" "complement") [ intExpr 255 ])) }
    , { label = "K Bitwise.shiftLeftBy", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bitwise" "shiftLeftBy") [ intExpr 4, intExpr 1 ])) }
    , { label = "K Bitwise.shiftRightBy", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bitwise" "shiftRightBy") [ intExpr 2, intExpr 255 ])) }
    , { label = "K Bitwise.shiftRightZfBy", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bitwise" "shiftRightZfBy") [ intExpr 2, intExpr 255 ])) }
    ]



-- ============================================================================
-- JSARRAY
-- ============================================================================


jsArrayCases : (Src.Module -> Expectation) -> List TestCase
jsArrayCases expectFn =
    [ { label = "K JsArray.empty", run = \_ -> expectFn (makeKernelModule "testValue" (qualVarExpr "Elm.Kernel.JsArray" "empty")) }
    , { label = "K JsArray.push", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.JsArray" "push") [ intExpr 42, qualVarExpr "Elm.Kernel.JsArray" "empty" ])) }
    , { label = "K JsArray.length", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.JsArray" "length") [ qualVarExpr "Elm.Kernel.JsArray" "empty" ])) }
    , { label = "K JsArray.unsafeGet", run = jsArrayUnsafeGet expectFn }
    , { label = "K JsArray.unsafeSet", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.JsArray" "unsafeSet") [ intExpr 0, intExpr 99, qualVarExpr "Elm.Kernel.JsArray" "empty" ])) }
    , { label = "K JsArray.slice", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.JsArray" "slice") [ intExpr 0, intExpr 2, qualVarExpr "Elm.Kernel.JsArray" "empty" ])) }
    , { label = "K JsArray.initializeFromList", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.JsArray" "initializeFromList") [ intExpr 3, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ])) }
    , { label = "K JsArray.map", run = jsArrayMap expectFn }
    , { label = "K JsArray.foldl", run = jsArrayFoldl expectFn }
    , { label = "K JsArray.foldr", run = jsArrayFoldr expectFn }
    ]


jsArrayUnsafeGet : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayUnsafeGet expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.JsArray" "unsafeGet")
            [ intExpr 0
            , callExpr (qualVarExpr "Elm.Kernel.JsArray" "initializeFromList") [ intExpr 3, listExpr [ intExpr 10, intExpr 20, intExpr 30 ] ]
            ]))


jsArrayMap : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayMap expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.JsArray" "map")
            [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
            , qualVarExpr "Elm.Kernel.JsArray" "empty"
            ]))


jsArrayFoldl : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayFoldl expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.JsArray" "foldl")
            [ lambdaExpr [ pVar "x", pVar "acc" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", varExpr "acc" ])
            , intExpr 0
            , qualVarExpr "Elm.Kernel.JsArray" "empty"
            ]))


jsArrayFoldr : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayFoldr expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.JsArray" "foldr")
            [ lambdaExpr [ pVar "x", pVar "acc" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", varExpr "acc" ])
            , intExpr 0
            , qualVarExpr "Elm.Kernel.JsArray" "empty"
            ]))



-- ============================================================================
-- LIST
-- ============================================================================


listCases : (Src.Module -> Expectation) -> List TestCase
listCases expectFn =
    [ { label = "K List.cons", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.List" "cons") [ intExpr 1, listExpr [ intExpr 2 ] ])) }
    , { label = "K List.singleton", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.List" "singleton") [ intExpr 42 ])) }
    , { label = "K List.map", run = listMapK expectFn }
    , { label = "K List.map2", run = listMap2K expectFn }
    , { label = "K List.foldl", run = listFoldlK expectFn }
    , { label = "K List.foldr", run = listFoldrK expectFn }
    , { label = "K List.reverse", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.List" "reverse") [ listExpr [ intExpr 3, intExpr 2, intExpr 1 ] ])) }
    , { label = "K List.length", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.List" "length") [ listExpr [ intExpr 1, intExpr 2 ] ])) }
    , { label = "K List.concat", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.List" "concat") [ listExpr [ listExpr [ intExpr 1 ], listExpr [ intExpr 2 ] ] ])) }
    , { label = "K List.range", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.List" "range") [ intExpr 1, intExpr 5 ])) }
    , { label = "K List.drop", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.List" "drop") [ intExpr 2, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ])) }
    ]


listMapK : (Src.Module -> Expectation) -> (() -> Expectation)
listMapK expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "map")
            [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
            , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
            ]))


listMap2K : (Src.Module -> Expectation) -> (() -> Expectation)
listMap2K expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "map2")
            [ lambdaExpr [ pVar "a", pVar "b" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "a", varExpr "b" ])
            , listExpr [ intExpr 1, intExpr 2 ]
            , listExpr [ intExpr 10, intExpr 20 ]
            ]))


listFoldlK : (Src.Module -> Expectation) -> (() -> Expectation)
listFoldlK expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "foldl")
            [ qualVarExpr "Elm.Kernel.Basics" "add", intExpr 0, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]))


listFoldrK : (Src.Module -> Expectation) -> (() -> Expectation)
listFoldrK expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.List" "foldr")
            [ lambdaExpr [ pVar "x", pVar "acc" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", varExpr "acc" ])
            , intExpr 0
            , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
            ]))



-- ============================================================================
-- TUPLE
-- ============================================================================


tupleCases : (Src.Module -> Expectation) -> List TestCase
tupleCases expectFn =
    [ { label = "K Tuple.pair", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Tuple" "pair") [ intExpr 1, strExpr "hello" ])) }
    , { label = "K Tuple.first", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Tuple" "first") [ tupleExpr (intExpr 1) (strExpr "hi") ])) }
    , { label = "K Tuple.second", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Tuple" "second") [ tupleExpr (intExpr 1) (strExpr "hi") ])) }
    , { label = "K Tuple.mapFirst", run = tupleMapFirstK expectFn }
    , { label = "K Tuple.mapSecond", run = tupleMapSecondK expectFn }
    ]


tupleMapFirstK : (Src.Module -> Expectation) -> (() -> Expectation)
tupleMapFirstK expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.Tuple" "mapFirst")
            [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
            , tupleExpr (intExpr 5) (strExpr "hi")
            ]))


tupleMapSecondK : (Src.Module -> Expectation) -> (() -> Expectation)
tupleMapSecondK expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.Tuple" "mapSecond")
            [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
            , tupleExpr (strExpr "hi") (intExpr 5)
            ]))



-- ============================================================================
-- STRING
-- ============================================================================


stringCases : (Src.Module -> Expectation) -> List TestCase
stringCases expectFn =
    [ { label = "K String.fromNumber", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.String" "fromNumber") [ intExpr 42 ])) }
    ]



-- ============================================================================
-- BYTES (fusion detection)
-- ============================================================================


bytesCases : (Src.Module -> Expectation) -> List TestCase
bytesCases expectFn =
    [ { label = "K Bytes.encode", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode") [ intExpr 0 ])) }
    , { label = "K Bytes.decode", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bytes" "decode") [ intExpr 0, intExpr 0 ])) }
    ]
