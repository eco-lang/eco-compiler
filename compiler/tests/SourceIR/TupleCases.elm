module SourceIR.TupleCases exposing (expectSuite)

{-| Source programs built around tuple expressions, so that a caller's check
can be run over pairs and triples, nested tuples, and tuples holding lists and
records.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies, so what is checked, and at
which stage, is decided by that function.

Every program is a module named `Test`, built with `makeModule`, that imports
`Basics` and `List` and has one top-level value, `testValue`, defined with no
arguments and no annotation. `testValue` is the expression shown for each case
below, written as Elm source.

The cases, by label:

  - "Pair of ints": `(1, 2)`.
  - "Triple of ints": `(1, 2, 3)`.
  - "Triple of mixed types": `(42, "hello", 100)`, two integer literals around
    a string literal.
  - "Tuple containing tuple": `((1, 2), 3)`.
  - "Deeply nested tuple": `(0, ((1, 2), 3))`, three tuples deep.
  - "2-tuple containing 3-tuples": `((1, 2, 3), (4, 5, 6))`.
  - "Tuple with list": `([1, 2], "hello")`.
  - "Tuple with record": `({ x = 10 }, 20)`.
  - "Triple with list and record": `([1], { y = "test" }, 5)`.

All nine run inside one test through `Compiler.BulkCheck.bulkCheck`, which
stops at the first case that fails and reports its label.

Among what is not tested: tuple patterns, tuple type annotations, the `Tuple`
module's functions, tuples passed to or returned from a function, and tuples
holding a `Float`, a `Char`, a function or a custom type value.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( intExpr
        , listExpr
        , makeModule
        , recordExpr
        , strExpr
        , tuple3Expr
        , tupleExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Tuple expressions " followed by `condStr`, that
passes when `expectFn` passes on every case's program and otherwise fails with
the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tuple expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns all nine cases, each running `expectFn` on its program: the pair,
then the triples, the nested tuples and the tuples holding lists and records.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    tuple2Cases expectFn
        ++ tuple3Cases expectFn
        ++ nestedTupleCases expectFn
        ++ mixedTypeTupleCases expectFn



-- ============================================================================
-- 2-TUPLES
-- ============================================================================


{-| Returns the one 2-tuple case, a pair of integer literals.
-}
tuple2Cases : (Src.Module -> Expectation) -> List TestCase
tuple2Cases expectFn =
    [ { label = "Pair of ints", run = pairOfInts expectFn }
    ]


{-| Runs `expectFn` on a program whose `testValue` is `(1, 2)`.
-}
pairOfInts : (Src.Module -> Expectation) -> (() -> Expectation)
pairOfInts expectFn _ =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2))
    in
    expectFn modul



-- ============================================================================
-- 3-TUPLES
-- ============================================================================


{-| Returns the 3-tuple cases, one of three integer literals and one with a
string literal between two integer literals.
-}
tuple3Cases : (Src.Module -> Expectation) -> List TestCase
tuple3Cases expectFn =
    [ { label = "Triple of ints", run = tripleOfInts expectFn }
    , { label = "Triple of mixed types", run = tripleOfMixedTypes expectFn }
    ]


{-| Runs `expectFn` on a program whose `testValue` is `(1, 2, 3)`.
-}
tripleOfInts : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOfInts expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3))
    in
    expectFn modul


{-| Runs `expectFn` on a program whose `testValue` is `(42, "hello", 100)`.
-}
tripleOfMixedTypes : (Src.Module -> Expectation) -> (() -> Expectation)
tripleOfMixedTypes expectFn _ =
    let
        modul =
            makeModule "testValue" (tuple3Expr (intExpr 42) (strExpr "hello") (intExpr 100))
    in
    expectFn modul



-- ============================================================================
-- NESTED TUPLES
-- ============================================================================


{-| Returns the cases whose tuples have tuples as elements.
-}
nestedTupleCases : (Src.Module -> Expectation) -> List TestCase
nestedTupleCases expectFn =
    [ { label = "Tuple containing tuple", run = tupleContainingTuple expectFn }
    , { label = "Deeply nested tuple", run = deeplyNestedTuple expectFn }
    , { label = "2-tuple containing 3-tuples", run = tuple2Containing3Tuples expectFn }
    ]


{-| Runs `expectFn` on a program whose `testValue` is `((1, 2), 3)`.
-}
tupleContainingTuple : (Src.Module -> Expectation) -> (() -> Expectation)
tupleContainingTuple expectFn _ =
    let
        inner =
            tupleExpr (intExpr 1) (intExpr 2)

        modul =
            makeModule "testValue" (tupleExpr inner (intExpr 3))
    in
    expectFn modul


{-| Runs `expectFn` on a program whose `testValue` is `(0, ((1, 2), 3))`, a
pair whose second element is a pair whose first element is a pair.
-}
deeplyNestedTuple : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedTuple expectFn _ =
    let
        level3 =
            tupleExpr (intExpr 1) (intExpr 2)

        level2 =
            tupleExpr level3 (intExpr 3)

        modul =
            makeModule "testValue" (tupleExpr (intExpr 0) level2)
    in
    expectFn modul


{-| Runs `expectFn` on a program whose `testValue` is `((1, 2, 3), (4, 5, 6))`.
-}
tuple2Containing3Tuples : (Src.Module -> Expectation) -> (() -> Expectation)
tuple2Containing3Tuples expectFn _ =
    let
        triple1 =
            tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)

        triple2 =
            tuple3Expr (intExpr 4) (intExpr 5) (intExpr 6)

        modul =
            makeModule "testValue" (tupleExpr triple1 triple2)
    in
    expectFn modul



-- ============================================================================
-- MIXED TYPE TUPLES
-- ============================================================================


{-| Returns the cases whose tuples hold a list literal, a record literal, or
both.
-}
mixedTypeTupleCases : (Src.Module -> Expectation) -> List TestCase
mixedTypeTupleCases expectFn =
    [ { label = "Tuple with list", run = tupleWithList expectFn }
    , { label = "Tuple with record", run = tupleWithRecord expectFn }
    , { label = "Triple with list and record", run = tripleWithListAndRecord expectFn }
    ]


{-| Runs `expectFn` on a program whose `testValue` is `([1, 2], "hello")`.
-}
tupleWithList : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithList expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2 ]

        modul =
            makeModule "testValue" (tupleExpr list (strExpr "hello"))
    in
    expectFn modul


{-| Runs `expectFn` on a program whose `testValue` is `({ x = 10 }, 20)`.
-}
tupleWithRecord : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWithRecord expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 10 ) ]

        modul =
            makeModule "testValue" (tupleExpr record (intExpr 20))
    in
    expectFn modul


{-| Runs `expectFn` on a program whose `testValue` is
`([1], { y = "test" }, 5)`.
-}
tripleWithListAndRecord : (Src.Module -> Expectation) -> (() -> Expectation)
tripleWithListAndRecord expectFn _ =
    let
        list =
            listExpr [ intExpr 1 ]

        record =
            recordExpr [ ( "y", strExpr "test" ) ]

        modul =
            makeModule "testValue" (tuple3Expr list record (intExpr 5))
    in
    expectFn modul
