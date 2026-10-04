module SourceIR.LetCases exposing (expectSuite)

{-| Supplies programs built around `let` expressions to a check that the caller
provides. A `let` can hold several definitions, a definition that refers to an
earlier one, a local function, or another `let`.

This module asserts nothing itself. `expectSuite` takes the caller's
expectation function and applies it to the programs in turn, so what is
checked is decided by the caller. All the programs run inside one
elm-test test through `Compiler.BulkCheck.bulkCheck`, which stops at the first
program whose expectation fails and reports that program's label.

Every program is a module built by `Compiler.AST.SourceBuilder.makeModule`:
a module named `Test` that imports `Basics` and `List` and has one top-level
value, `testValue`, with no arguments and no type annotation. Each case
function builds that module around one expression, gives it to the
expectation function, and is deferred behind `()` until `bulkCheck` runs it.

The programs, by group:

  - Simple `let`: one definition, `x = 42`, with a body that uses it and
    with a unit body that does not.
  - Several definitions: two independent ones, one that uses the one before
    it, and a chain of three in which each refers to the previous one.
  - Nested `let`: a `let` as the body of another, a `let` as the value of a
    definition, two `let`s side by side in a tuple with no enclosing `let`,
    and a `let` as an element of a list that is the body of another `let`.
  - Local functions: a function defined with an argument, one defined as a
    lambda, two functions of one and two arguments, and a function that calls
    another defined in the same `let`.
  - Compound values: a definition bound to a record, a tuple and a list.

Among what is not tested: destructuring definitions, type annotations on
`let` definitions, and recursive or mutually recursive definitions.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pVar
        , recordExpr
        , strExpr
        , tupleExpr
        , unitExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Let expressions "` followed by `condStr`, that
applies `expectFn` to the programs in this module in turn. It fails with the
label of the first program whose expectation fails, and the programs after it
are not run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, group by group in the order the groups
appear here.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    simpleLetCases expectFn
        ++ multipleBindingsCases expectFn
        ++ nestedLetCases expectFn
        ++ letWithFunctionsCases expectFn
        ++ letWithComplexExpressionsCases expectFn



-- ============================================================================
-- SIMPLE LET
-- ============================================================================


{-| Returns the cases whose `let` holds a single definition, `x = 42`.
-}
simpleLetCases : (Src.Module -> Expectation) -> List TestCase
simpleLetCases expectFn =
    [ { label = "Let with single int binding", run = letWithSingleIntBinding expectFn }
    , { label = "Let with unit body", run = letWithUnitBody expectFn }
    ]


{-| Builds `let x = 42 in x` and gives it to `expectFn`.
-}
letWithSingleIntBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithSingleIntBinding expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


{-| Builds a `let` that defines `x = 42` and has the unit value `()` as its
body, so `x` is never used, and gives it to `expectFn`.
-}
letWithUnitBody : (Src.Module -> Expectation) -> (() -> Expectation)
letWithUnitBody expectFn _ =
    let
        def =
            define "x" [] (intExpr 42)

        modul =
            makeModule "testValue" (letExpr [ def ] unitExpr)
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE BINDINGS
-- ============================================================================


{-| Returns the cases whose `let` holds two or three definitions.
-}
multipleBindingsCases : (Src.Module -> Expectation) -> List TestCase
multipleBindingsCases expectFn =
    [ { label = "Let with two bindings", run = letWithTwoBindings expectFn }
    , { label = "Let with binding using previous binding", run = letWithBindingUsingPrevious expectFn }
    , { label = "Let with chained references", run = letWithChainedReferences expectFn }
    ]


{-| Builds a `let` that defines `x = 1` and `y = 2`, with body `( x, y )`,
and gives it to `expectFn`.
-}
letWithTwoBindings : (Src.Module -> Expectation) -> (() -> Expectation)
letWithTwoBindings expectFn _ =
    let
        def1 =
            define "x" [] (intExpr 1)

        def2 =
            define "y" [] (intExpr 2)

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


{-| Builds a `let` that defines `x = 1` and then `y = ( x, 2 )`, with body
`y`, and gives it to `expectFn`.
-}
letWithBindingUsingPrevious : (Src.Module -> Expectation) -> (() -> Expectation)
letWithBindingUsingPrevious expectFn _ =
    let
        def1 =
            define "x" [] (intExpr 1)

        def2 =
            define "y" [] (tupleExpr (varExpr "x") (intExpr 2))

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (varExpr "y"))
    in
    expectFn modul


{-| Builds a `let` that defines `a = 1`, `b = a` and `c = b`, in that order,
with body `c`, and gives it to `expectFn`.
-}
letWithChainedReferences : (Src.Module -> Expectation) -> (() -> Expectation)
letWithChainedReferences expectFn _ =
    let
        def1 =
            define "a" [] (intExpr 1)

        def2 =
            define "b" [] (varExpr "a")

        def3 =
            define "c" [] (varExpr "b")

        modul =
            makeModule "testValue" (letExpr [ def1, def2, def3 ] (varExpr "c"))
    in
    expectFn modul



-- ============================================================================
-- NESTED LET
-- ============================================================================


{-| Returns the cases with a `let` inside another expression.
-}
nestedLetCases : (Src.Module -> Expectation) -> List TestCase
nestedLetCases expectFn =
    [ { label = "Let inside let", run = letInsideLet expectFn }
    , { label = "Let in binding value", run = letInBindingValue expectFn }
    , { label = "Multiple nested lets", run = multipleNestedLets expectFn }
    , { label = "Let inside list inside let", run = letInsideListInsideLet expectFn }
    ]


{-| Builds a `let` that defines `x = 1` and whose body is `let y = 2 in y`,
so `x` is never used, and gives it to `expectFn`.
-}
letInsideLet : (Src.Module -> Expectation) -> (() -> Expectation)
letInsideLet expectFn _ =
    let
        innerLet =
            letExpr [ define "y" [] (intExpr 2) ] (varExpr "y")

        def =
            define "x" [] (intExpr 1)

        modul =
            makeModule "testValue" (letExpr [ def ] innerLet)
    in
    expectFn modul


{-| Builds a `let` that defines `x` as `let inner = 42 in inner`, with body
`x`, and gives it to `expectFn`.
-}
letInBindingValue : (Src.Module -> Expectation) -> (() -> Expectation)
letInBindingValue expectFn _ =
    let
        innerLet =
            letExpr [ define "inner" [] (intExpr 42) ] (varExpr "inner")

        def =
            define "x" [] innerLet

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


{-| Builds the tuple `( let a = 1 in a, let b = 2 in b )` as the whole of
`testValue` and gives it to `expectFn`. Neither `let` is inside the other, and
there is no enclosing `let`.
-}
multipleNestedLets : (Src.Module -> Expectation) -> (() -> Expectation)
multipleNestedLets expectFn _ =
    let
        let1 =
            letExpr [ define "a" [] (intExpr 1) ] (varExpr "a")

        let2 =
            letExpr [ define "b" [] (intExpr 2) ] (varExpr "b")

        modul =
            makeModule "testValue" (tupleExpr let1 let2)
    in
    expectFn modul


{-| Builds a `let` that defines `x = 0` and whose body is the list
`[ 1, let y = 2 in y, 3 ]`, so `x` is never used, and gives it to `expectFn`.
-}
letInsideListInsideLet : (Src.Module -> Expectation) -> (() -> Expectation)
letInsideListInsideLet expectFn _ =
    let
        innerLet =
            letExpr [ define "y" [] (intExpr 2) ] (varExpr "y")

        list =
            listExpr [ intExpr 1, innerLet, intExpr 3 ]

        modul =
            makeModule "testValue" (letExpr [ define "x" [] (intExpr 0) ] list)
    in
    expectFn modul



-- ============================================================================
-- LET WITH FUNCTIONS
-- ============================================================================


{-| Returns the cases that define functions in a `let`.
-}
letWithFunctionsCases : (Src.Module -> Expectation) -> List TestCase
letWithFunctionsCases expectFn =
    [ { label = "Let with function", run = letWithFunction expectFn }
    , { label = "Let with lambda binding", run = letWithLambdaBinding expectFn }
    , { label = "Let with multiple functions", run = letWithMultipleFunctions expectFn }
    , { label = "Let with function calling another function", run = letWithFunctionCallingAnother expectFn }
    ]


{-| Builds a `let` that defines `f x = x`, with body `f 42`, and gives it to
`expectFn`.
-}
letWithFunction : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFunction expectFn _ =
    let
        fn =
            define "f" [ pVar "x" ] (varExpr "x")

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 42 ]))
    in
    expectFn modul


{-| Builds a `let` that defines `f` as the lambda `\x -> x`, with no
arguments of its own, and body `f 42`, and gives it to `expectFn`.
-}
letWithLambdaBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithLambdaBinding expectFn _ =
    let
        fn =
            define "f" [] (lambdaExpr [ pVar "x" ] (varExpr "x"))

        modul =
            makeModule "testValue" (letExpr [ fn ] (callExpr (varExpr "f") [ intExpr 42 ]))
    in
    expectFn modul


{-| Builds a `let` that defines `identity x = x` and `const x y = x`, with
body `( identity 1, const 2 3 )`, and gives it to `expectFn`.

The local `identity` hides the `identity` that the module's
`import Basics exposing (..)` brings in.

-}
letWithMultipleFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
letWithMultipleFunctions expectFn _ =
    let
        fn1 =
            define "identity" [ pVar "x" ] (varExpr "x")

        fn2 =
            define "const" [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ fn1, fn2 ]
                    (tupleExpr
                        (callExpr (varExpr "identity") [ intExpr 1 ])
                        (callExpr (varExpr "const") [ intExpr 2, intExpr 3 ])
                    )
                )
    in
    expectFn modul


{-| Builds a `let` that defines `double x = ( x, x )` and then
`doubleTwice y = double (double y)`, with body `doubleTwice 1`, and gives it to
`expectFn`. `double` pairs its argument with itself; it does no arithmetic.
-}
letWithFunctionCallingAnother : (Src.Module -> Expectation) -> (() -> Expectation)
letWithFunctionCallingAnother expectFn _ =
    let
        fn1 =
            define "double" [ pVar "x" ] (tupleExpr (varExpr "x") (varExpr "x"))

        fn2 =
            define "doubleTwice" [ pVar "y" ] (callExpr (varExpr "double") [ callExpr (varExpr "double") [ varExpr "y" ] ])

        modul =
            makeModule "testValue"
                (letExpr [ fn1, fn2 ]
                    (callExpr (varExpr "doubleTwice") [ intExpr 1 ])
                )
    in
    expectFn modul



-- ============================================================================
-- LET WITH COMPLEX EXPRESSIONS
-- ============================================================================


{-| Returns the cases that bind a record, a tuple or a list in a `let`.
-}
letWithComplexExpressionsCases : (Src.Module -> Expectation) -> List TestCase
letWithComplexExpressionsCases expectFn =
    [ { label = "Let with record binding", run = letWithRecordBinding expectFn }
    , { label = "Let with tuple binding", run = letWithTupleBinding expectFn }
    , { label = "Let with list binding", run = letWithListBinding expectFn }
    ]


{-| Builds a `let` that defines `r = { x = 1, y = 2 }`, with body `r.x`, and
gives it to `expectFn`.
-}
letWithRecordBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithRecordBinding expectFn _ =
    let
        def =
            define "r" [] (recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ])

        modul =
            makeModule "testValue" (letExpr [ def ] (accessExpr (varExpr "r") "x"))
    in
    expectFn modul


{-| Builds a `let` that defines `pair = ( 1, "one" )`, with body `pair`, and
gives it to `expectFn`.
-}
letWithTupleBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithTupleBinding expectFn _ =
    let
        def =
            define "pair" [] (tupleExpr (intExpr 1) (strExpr "one"))

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "pair"))
    in
    expectFn modul


{-| Builds a `let` that defines `items = [ 1, 2, 3 ]`, with body `items`, and
gives it to `expectFn`.
-}
letWithListBinding : (Src.Module -> Expectation) -> (() -> Expectation)
letWithListBinding expectFn _ =
    let
        def =
            define "items" [] (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "items"))
    in
    expectFn modul
