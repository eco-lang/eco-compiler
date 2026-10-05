module SourceIR.KernelIntrinsicCases exposing (expectSuite)

{-| Programs that refer to `Elm.Kernel.*` names directly, most of them in a
call, so that a compiler stage given them meets each kernel reference with no
elm/core wrapper in between.

A kernel function is one the runtime implements rather than Elm code. A program
names it by a qualified name whose module is a kernel module, such as
`Elm.Kernel.Basics.add`. Canonicalization turns such a name into a kernel
reference only in a module of a kernel package, one authored by `elm`,
`elm-explorations` or `eco`; anywhere else the name is reported as not found.
It does not check that the name exists (`findVarQual`), and for some names
used here `elm-kernel-cpp` exports no function and there is no intrinsic:
`Basics.identity`, `always` and `clamp`;
`List.map`, `foldl`, `foldr`, `singleton`, `length` and `range`; and every
`Tuple` name. Their cases exercise only the compiler's handling of the
reference.

For the kernel modules `Basics`, `Bitwise`, `Utils`, `JsArray`, `List`, `Char`
and `String`, the MLIR back end may emit a call as an inline operation, an
_intrinsic_, instead of a call into the kernel, choosing by the argument and
result types (`Compiler.Generate.MLIR.Intrinsics.kernelIntrinsic`). Because the
choice depends on those types, many functions here are called once with `Int`
and once with `Float` arguments.

Each case is a module built by `makeKernelModule`: a module named `Test` whose
one top-level value, `testValue`, has no annotation and is defined as the kernel
reference or call. The type checker leaves a kernel reference unconstrained
unless it has a row in `Compiler.Type.KernelIntrinsics`, and none of the kernels
called here has one, so the type checker does not check the arguments against
the kernel's real type. Some arguments would be wrong in a running program:
`JsArray.unsafeSet` writes index 0 of the empty array, and the `Bytes.encode`
and `Bytes.decode` cases pass `Int` literals where the kernels take an encoder,
a decoder and bytes.

This module asserts nothing itself. Each case passes its program to the
expectation function the caller supplies, and passes or fails as that does. The
cases, by group:

  - `Basics` on `Int`: `add`, `sub`, `mul`, `idiv`, `remainderBy`, `negate`,
    `abs`, `pow`, `min` and `max`.
  - `Basics` on `Float`: `add`, `sub`, `mul`, `fdiv`, `sqrt`, `log` and
    `logBase`, and `negate`, `abs`, `min`, `max` and `pow`.
  - `Basics` comparisons `eq`, `neq`, `lt`, `le`, `gt` and `ge`, each on two
    `Int`s and on two `Float`s.
  - `Basics` `not`, `and`, `or` and `xor` on `True` and `False`.
  - `Basics` `sin`, `cos`, `tan`, `asin`, `acos`, `atan` and `atan2`.
  - `Basics` `toFloat`, `round`, `floor`, `ceiling` and `truncate`.
  - `Basics` `pi` and `e`, used as values rather than called.
  - `Basics` `identity` and `always`, `isNaN` and `isInfinite` on a `Float`,
    and `clamp` on three `Int`s.
  - `Utils` `equal`, `notEqual`, `compare`, `lt`, `le`, `gt` and `ge`, each on
    two `Int`s and on two `Float`s, and `append` on two lists of `Int`.
  - `Bitwise` `and`, `or`, `xor`, `complement`, `shiftLeftBy`, `shiftRightBy`
    and `shiftRightZfBy`.
  - `JsArray` `empty` used as a value; `push`, `length`, `unsafeSet`, `slice`
    and `initializeFromList`; `unsafeGet` on an array built by
    `initializeFromList`; and `map`, `foldl` and `foldr` with a lambda that
    calls `Basics.add`.
  - `List` `cons`, `singleton`, `reverse`, `length`, `concat`, `range` and
    `drop`; `map`, `map2` and `foldr` with a lambda that calls `Basics.add`;
    and `foldl` with `Basics.add` passed unapplied.
  - `Tuple` `pair`, `first` and `second`, and `mapFirst` and `mapSecond` with
    a lambda.
  - `String.fromNumber` on two `Int` literals and on a `Float`, `Char.fromCode`,
    and `Char.toCode` applied to the result of `Char.fromCode`.
  - `Bytes.encode` and `Bytes.decode` on `Int` literals.
  - `Debug.log` with a `String` tag on a unit value and on a record, so that
    the kernel's result is a unit and a record, and on an `Int`, and
    `Debug.todo` on a `String`.

Among what is not tested: a kernel module outside these, such as `Json`, and
arguments of a custom type other than `Bool`, which no case passes.

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
        , recordExpr
        , strExpr
        , tupleExpr
        , unitExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "Kernel intrinsics " followed by `condStr`, that
passes every program in this module to `expectFn` and fails under the label of
the first case that fails. The cases after it are not run, as
`Compiler.BulkCheck.bulkCheck` describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel intrinsics " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the cases of every group in this module, in the order the groups
appear in the file.
-}
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
        , kernelAbiTypeCases expectFn
        ]



-- ============================================================================
-- BASICS: INT ARITHMETIC
-- ============================================================================


{-| Returns the cases that apply the `Elm.Kernel.Basics` names `add`, `sub`,
`mul`, `idiv`, `remainderBy`, `negate`, `abs`, `pow`, `min` and `max` to `Int`
literals.
-}
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


{-| Returns the cases that apply the `Elm.Kernel.Basics` names `add`, `sub`,
`mul`, `fdiv`, `sqrt`, `log` and `logBase`, and `negate`, `abs`, `min`, `max`
and `pow`, to `Float` literals.
-}
basicsFloatArithCases : (Src.Module -> Expectation) -> List TestCase
basicsFloatArithCases expectFn =
    [ { label = "K Basics.add Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ floatExpr 1.5, floatExpr 2.5 ])) }
    , { label = "K Basics.sub Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "sub") [ floatExpr 10.0, floatExpr 3.0 ])) }
    , { label = "K Basics.mul Float", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "mul") [ floatExpr 3.0, floatExpr 4.0 ])) }
    , { label = "K Basics.fdiv", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "fdiv") [ floatExpr 10.0, floatExpr 3.0 ])) }
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


{-| Returns the cases that apply the `Elm.Kernel.Basics` names `eq`, `neq`,
`lt`, `le`, `gt` and `ge`, each once to two `Int` literals and once to two
`Float` literals.
-}
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


{-| Returns the cases that call the `Basics` kernels `not`, `and`, `or` and
`xor` on `True` and `False`.
-}
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


{-| Returns the cases that call the `Basics` trigonometric kernels on `Float`
literals.
-}
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


{-| Returns the cases that call the `Basics` conversion kernels: `toFloat` on an
`Int`, and `round`, `floor`, `ceiling` and `truncate` on a `Float`.
-}
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


{-| Returns the cases whose program is the kernel value `Basics.pi` or
`Basics.e` on its own, with no call.
-}
basicsConstantCases : (Src.Module -> Expectation) -> List TestCase
basicsConstantCases expectFn =
    [ { label = "K Basics.pi", run = \_ -> expectFn (makeKernelModule "testValue" (qualVarExpr "Elm.Kernel.Basics" "pi")) }
    , { label = "K Basics.e", run = \_ -> expectFn (makeKernelModule "testValue" (qualVarExpr "Elm.Kernel.Basics" "e")) }
    ]



-- ============================================================================
-- BASICS: MISC (identity, always, isNaN, isInfinite, clamp)
-- ============================================================================


{-| Returns the cases that apply the `Elm.Kernel.Basics` names `identity`,
`always` (to two arguments), `isNaN`, `isInfinite`, and `clamp` (to three `Int`
literals).
-}
basicsMiscCases : (Src.Module -> Expectation) -> List TestCase
basicsMiscCases expectFn =
    [ { label = "K Basics.identity", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "identity") [ intExpr 99 ])) }
    , { label = "K Basics.always", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "always") [ intExpr 1, strExpr "ignored" ])) }
    , { label = "K Basics.isNaN", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "isNaN") [ floatExpr 0.0 ])) }
    , { label = "K Basics.isInfinite", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "isInfinite") [ floatExpr 1.0 ])) }
    , { label = "K Basics.clamp", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Basics" "clamp") [ intExpr 0, intExpr 10, intExpr 15 ])) }
    ]



-- ============================================================================
-- UTILS: INT COMPARISONS AND APPEND
-- ============================================================================


{-| Returns the cases that call the `Utils` comparison kernels `equal`,
`notEqual`, `compare`, `lt`, `le`, `gt` and `ge` on two `Int` literals, and
`Utils.append` on two one-element lists of `Int`.
-}
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


{-| Returns the cases that call the `Utils` comparison kernels `equal`,
`notEqual`, `compare`, `lt`, `le`, `gt` and `ge` on two `Float` literals.
-}
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


{-| Returns the cases that call the `Bitwise` kernels `and`, `or`, `xor`,
`complement`, `shiftLeftBy`, `shiftRightBy` and `shiftRightZfBy` on `Int`
literals.
-}
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


{-| Returns the cases that use the `JsArray` kernels: `empty` on its own, and
calls of the rest. Apart from `initializeFromList` and `unsafeGet`, each of the
other calls takes `JsArray.empty` as its array, including `unsafeSet` at index 0
and `slice` from 0 to 2.
-}
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


{-| Applies `expectFn` to a program that calls `JsArray.unsafeGet` at index 0
of the array `JsArray.initializeFromList` builds from `[ 10, 20, 30 ]`.
-}
jsArrayUnsafeGet : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayUnsafeGet expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.JsArray" "unsafeGet")
                [ intExpr 0
                , callExpr (qualVarExpr "Elm.Kernel.JsArray" "initializeFromList") [ intExpr 3, listExpr [ intExpr 10, intExpr 20, intExpr 30 ] ]
                ]
            )
        )


{-| Applies `expectFn` to a program that maps a lambda adding 1 over
`JsArray.empty`.
-}
jsArrayMap : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayMap expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.JsArray" "map")
                [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
                , qualVarExpr "Elm.Kernel.JsArray" "empty"
                ]
            )
        )


{-| Applies `expectFn` to a program that folds a lambda adding its two
arguments over `JsArray.empty` from the left, starting at 0.
-}
jsArrayFoldl : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayFoldl expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.JsArray" "foldl")
                [ lambdaExpr [ pVar "x", pVar "acc" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", varExpr "acc" ])
                , intExpr 0
                , qualVarExpr "Elm.Kernel.JsArray" "empty"
                ]
            )
        )


{-| Applies `expectFn` to a program that folds a lambda adding its two
arguments over `JsArray.empty` from the right, starting at 0.
-}
jsArrayFoldr : (Src.Module -> Expectation) -> (() -> Expectation)
jsArrayFoldr expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.JsArray" "foldr")
                [ lambdaExpr [ pVar "x", pVar "acc" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", varExpr "acc" ])
                , intExpr 0
                , qualVarExpr "Elm.Kernel.JsArray" "empty"
                ]
            )
        )



-- ============================================================================
-- LIST
-- ============================================================================


{-| Returns the cases that apply the `Elm.Kernel.List` names to `Int` literals
and lists, with a function as well for `map`, `map2`, `foldl` and `foldr`.
-}
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


{-| Applies `expectFn` to a program that applies `Elm.Kernel.List.map` to a
lambda adding 1 and `[ 1, 2, 3 ]`.
-}
listMapK : (Src.Module -> Expectation) -> (() -> Expectation)
listMapK expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "map")
                [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
                , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                ]
            )
        )


{-| Applies `expectFn` to a program that applies `Elm.Kernel.List.map2` to a
lambda adding its two arguments, `[ 1, 2 ]` and `[ 10, 20 ]`.
-}
listMap2K : (Src.Module -> Expectation) -> (() -> Expectation)
listMap2K expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "map2")
                [ lambdaExpr [ pVar "a", pVar "b" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "a", varExpr "b" ])
                , listExpr [ intExpr 1, intExpr 2 ]
                , listExpr [ intExpr 10, intExpr 20 ]
                ]
            )
        )


{-| Applies `expectFn` to a program that applies `Elm.Kernel.List.foldl` to the
kernel `Elm.Kernel.Basics.add`, unapplied, 0 and `[ 1, 2, 3 ]`.
-}
listFoldlK : (Src.Module -> Expectation) -> (() -> Expectation)
listFoldlK expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "foldl")
                [ qualVarExpr "Elm.Kernel.Basics" "add", intExpr 0, listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
            )
        )


{-| Applies `expectFn` to a program that applies `Elm.Kernel.List.foldr` to a
lambda adding its two arguments, 0 and `[ 1, 2, 3 ]`.
-}
listFoldrK : (Src.Module -> Expectation) -> (() -> Expectation)
listFoldrK expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.List" "foldr")
                [ lambdaExpr [ pVar "x", pVar "acc" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", varExpr "acc" ])
                , intExpr 0
                , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                ]
            )
        )



-- ============================================================================
-- TUPLE
-- ============================================================================


{-| Returns the cases that apply the `Elm.Kernel.Tuple` names `pair`, `first`,
`second`, `mapFirst` and `mapSecond`, each with an `Int` and a `String`, alone
or as a pair.
-}
tupleCases : (Src.Module -> Expectation) -> List TestCase
tupleCases expectFn =
    [ { label = "K Tuple.pair", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Tuple" "pair") [ intExpr 1, strExpr "hello" ])) }
    , { label = "K Tuple.first", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Tuple" "first") [ tupleExpr (intExpr 1) (strExpr "hi") ])) }
    , { label = "K Tuple.second", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Tuple" "second") [ tupleExpr (intExpr 1) (strExpr "hi") ])) }
    , { label = "K Tuple.mapFirst", run = tupleMapFirstK expectFn }
    , { label = "K Tuple.mapSecond", run = tupleMapSecondK expectFn }
    ]


{-| Applies `expectFn` to a program that applies `Elm.Kernel.Tuple.mapFirst` to
a lambda adding 1 and the pair `( 5, "hi" )`.
-}
tupleMapFirstK : (Src.Module -> Expectation) -> (() -> Expectation)
tupleMapFirstK expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Tuple" "mapFirst")
                [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
                , tupleExpr (intExpr 5) (strExpr "hi")
                ]
            )
        )


{-| Applies `expectFn` to a program that applies `Elm.Kernel.Tuple.mapSecond`
to a lambda adding 1 and the pair `( "hi", 5 )`.
-}
tupleMapSecondK : (Src.Module -> Expectation) -> (() -> Expectation)
tupleMapSecondK expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Tuple" "mapSecond")
                [ lambdaExpr [ pVar "x" ] (callExpr (qualVarExpr "Elm.Kernel.Basics" "add") [ varExpr "x", intExpr 1 ])
                , tupleExpr (strExpr "hi") (intExpr 5)
                ]
            )
        )



-- ============================================================================
-- STRING AND CHAR
-- ============================================================================


{-| Returns the cases that call `String.fromNumber` on the `Int` literals 42
and 12345 and on a `Float` literal, `Char.fromCode` on an `Int`, and
`Char.toCode` on the result of `Char.fromCode`.
-}
stringCases : (Src.Module -> Expectation) -> List TestCase
stringCases expectFn =
    [ { label = "K String.fromNumber", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.String" "fromNumber") [ intExpr 42 ])) }
    , { label = "K String.fromNumber Int (intrinsic)", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.String" "fromNumber") [ intExpr 12345 ])) }
    , { label = "K String.fromNumber Float (intrinsic)", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.String" "fromNumber") [ floatExpr 3.14 ])) }
    , { label = "K Char.toCode (intrinsic)", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Char" "toCode") [ callExpr (qualVarExpr "Elm.Kernel.Char" "fromCode") [ intExpr 65 ] ])) }
    , { label = "K Char.fromCode (intrinsic)", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Char" "fromCode") [ intExpr 97 ])) }
    ]



-- ============================================================================
-- BYTES
-- ============================================================================


{-| Returns the cases that call the `Bytes` kernels `encode` and `decode`. Their
arguments are `Int` literals, not the encoder, decoder and bytes the real
kernels take. The MLIR back end gives a call of either kernel with these
argument counts a path of its own, where it may attempt bytes fusion
(`Compiler.Generate.MLIR.Expr`).
-}
bytesCases : (Src.Module -> Expectation) -> List TestCase
bytesCases expectFn =
    [ { label = "K Bytes.encode", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode") [ intExpr 0 ])) }
    , { label = "K Bytes.decode", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Bytes" "decode") [ intExpr 0, intExpr 0 ])) }
    ]



-- ============================================================================
-- KERNEL ABI TYPE PATTERNS
-- ============================================================================


{-| Returns the cases that call `Elm.Kernel.Debug.log` with a `String` tag on
the unit value, on a record and on an `Int`, so that the kernel's result is of
those types, and `Elm.Kernel.Debug.todo` on a `String`.
-}
kernelAbiTypeCases : (Src.Module -> Expectation) -> List TestCase
kernelAbiTypeCases expectFn =
    [ { label = "K kernel with unit result", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Debug" "log") [ strExpr "unit", unitExpr ])) }
    , { label = "K kernel returning record", run = kernelReturningRecord expectFn }
    , { label = "K Debug.log kernel", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Debug" "log") [ strExpr "tag", intExpr 42 ])) }
    , { label = "K Debug.todo kernel", run = \_ -> expectFn (makeKernelModule "testValue" (callExpr (qualVarExpr "Elm.Kernel.Debug" "todo") [ strExpr "not implemented" ])) }
    ]


{-| Applies `expectFn` to a program that calls `Elm.Kernel.Debug.log` with the
tag "record" on the record `{ n = 1, s = "hi" }`, so that the kernel returns a
record.
-}
kernelReturningRecord : (Src.Module -> Expectation) -> (() -> Expectation)
kernelReturningRecord expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Debug" "log")
                [ strExpr "record"
                , recordExpr [ ( "n", intExpr 1 ), ( "s", strExpr "hi" ) ]
                ]
            )
        )
