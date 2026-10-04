module SourceIR.ParamArityCases exposing (expectSuite)

{-| Source programs in which a function reaches a call through a variable,
so that the number of arguments it takes cannot be read from the call itself.

A call `f a b` where `f` is a parameter says nothing about whether `f` takes two
arguments, or takes one and returns a function. That number is the function's
_source arity_. A _PAP_ (partial application) is a function given fewer
arguments than its source arity; its own source arity is what is left.

This module only builds the programs and asserts nothing itself. `expectSuite`
runs a caller's expectation over them in turn, stopping at the first that fails,
so what is checked, and at which stage of the compiler, is up to the caller.

Each program is a module `Test` (from `makeModule`) whose one top-level value,
`testValue`, is a `let` that binds a function and calls it with integer
literals. In all but the last program that function is a helper which is also
given a one-parameter or two-parameter lambda; each such lambda returns its
first argument. Every named function the programs define is `let`-bound; none
is top-level.

The programs, in the order they run:

  - Calling a function parameter: `f` is applied to both of its two arguments,
    to two arguments in the reverse order of the helper's parameters, and to its
    one argument.
  - Calling a parameter from a nested expression: `f` is called from inside a
    nested function that captures it, and from inside a tuple.
  - Partial application: a `let` binds a PAP of a parameter `f`, or of a
    `let`-bound two-parameter function, and the PAP is then called with the
    remaining argument.

Among what is not tested: a function argument that is a top-level or kernel
function, or itself a PAP; a parameter called with more arguments than its
source arity; a captured function called with fewer arguments than it takes.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModule
        , pVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Param arity cases " followed by `condStr`, that
applies `expectFn` to every program in this module in turn. It fails with the
label of the first program whose expectation fails, and later programs are not
run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Param arity cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, each applying `expectFn` to its program:
the parameter calls, then the calls from nested expressions, then the partial
applications.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    hoParamCases expectFn
        ++ capturedParamCases expectFn
        ++ localPapCases expectFn



-- ============================================================================
-- CALLING A FUNCTION PARAMETER
-- ============================================================================


{-| Returns the cases in which a function parameter is called directly in the
body of the function that takes it.
-}
hoParamCases : (Src.Module -> Expectation) -> List TestCase
hoParamCases expectFn =
    [ { label = "HO param: apply f a b", run = hoParamApplyTwo expectFn }
    , { label = "HO param: flip f b a", run = hoParamFlip expectFn }
    , { label = "HO param: single-arg apply", run = hoParamApplyOne expectFn }
    ]


{-| Applies `expectFn` to a program that passes a two-parameter lambda to a
helper which calls it with both of its arguments at once:

    testValue =
        let
            applyTwo f a b =
                f a b
        in
        applyTwo (\x y -> x) 1 2

-}
hoParamApplyTwo : (Src.Module -> Expectation) -> (() -> Expectation)
hoParamApplyTwo expectFn _ =
    let
        applyTwoFn =
            define "applyTwo"
                [ pVar "f", pVar "a", pVar "b" ]
                (callExpr (varExpr "f") [ varExpr "a", varExpr "b" ])

        add =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ applyTwoFn ]
                    (callExpr (varExpr "applyTwo") [ add, intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program that passes a two-parameter lambda to a
helper which calls it with its own second and third parameters swapped:

    testValue =
        let
            flip f b a =
                f a b
        in
        flip (\x y -> x) 10 3

-}
hoParamFlip : (Src.Module -> Expectation) -> (() -> Expectation)
hoParamFlip expectFn _ =
    let
        flipFn =
            define "flip"
                [ pVar "f", pVar "b", pVar "a" ]
                (callExpr (varExpr "f") [ varExpr "a", varExpr "b" ])

        sub =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ flipFn ]
                    (callExpr (varExpr "flip") [ sub, intExpr 10, intExpr 3 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program that passes a one-parameter lambda to a
helper which calls it with one argument:

    testValue =
        let
            applyOne f x =
                f x
        in
        applyOne (\y -> y) 42

-}
hoParamApplyOne : (Src.Module -> Expectation) -> (() -> Expectation)
hoParamApplyOne expectFn _ =
    let
        applyOneFn =
            define "applyOne"
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        identity =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        modul =
            makeModule "testValue"
                (letExpr [ applyOneFn ]
                    (callExpr (varExpr "applyOne") [ identity, intExpr 42 ])
                )
    in
    expectFn modul



-- ============================================================================
-- CALLING A PARAMETER FROM A NESTED EXPRESSION
-- ============================================================================


{-| Returns the cases in which a function parameter is called from an
expression nested inside the body of the function that takes it.
-}
capturedParamCases : (Src.Module -> Expectation) -> List TestCase
capturedParamCases expectFn =
    [ { label = "Captured param: inner closure calls captured f", run = capturedParamInner expectFn }
    , { label = "Captured param: two-arg captured function", run = capturedParamTwoArg expectFn }
    ]


{-| Applies `expectFn` to a program in which a helper's one-parameter function
parameter `f` is called from a nested function `g`, which captures it:

    testValue =
        let
            withF f x =
                let
                    g y =
                        f y
                in
                g x
        in
        withF (\z -> z) 7

-}
capturedParamInner : (Src.Module -> Expectation) -> (() -> Expectation)
capturedParamInner expectFn _ =
    let
        withFFn =
            define "withF"
                [ pVar "f", pVar "x" ]
                (letExpr
                    [ define "g" [ pVar "y" ] (callExpr (varExpr "f") [ varExpr "y" ]) ]
                    (callExpr (varExpr "g") [ varExpr "x" ])
                )

        identity =
            lambdaExpr [ pVar "z" ] (varExpr "z")

        modul =
            makeModule "testValue"
                (letExpr [ withFFn ]
                    (callExpr (varExpr "withF") [ identity, intExpr 7 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program in which a helper calls its two-parameter
function parameter `f` with both arguments, as the second element of a tuple:

    testValue =
        let
            mapPair f k v =
                ( k, f k v )
        in
        mapPair (\a b -> a) 1 2

Although the case is grouped with the captured parameters, the call is not
inside a nested function or lambda in the source.

-}
capturedParamTwoArg : (Src.Module -> Expectation) -> (() -> Expectation)
capturedParamTwoArg expectFn _ =
    let
        mapPairFn =
            define "mapPair"
                [ pVar "f", pVar "k", pVar "v" ]
                (tupleExpr (varExpr "k") (callExpr (varExpr "f") [ varExpr "k", varExpr "v" ]))

        add =
            lambdaExpr [ pVar "a", pVar "b" ] (varExpr "a")

        modul =
            makeModule "testValue"
                (letExpr [ mapPairFn ]
                    (callExpr (varExpr "mapPair") [ add, intExpr 1, intExpr 2 ])
                )
    in
    expectFn modul



-- ============================================================================
-- LOCAL PARTIAL APPLICATIONS
-- ============================================================================


{-| Returns the cases in which a `let` binds a partial application and then
calls it with the remaining argument.
-}
localPapCases : (Src.Module -> Expectation) -> List TestCase
localPapCases expectFn =
    [ { label = "Local PAP: let p1 = f x in p1 y", run = localPapFromParam expectFn }
    , { label = "Local PAP: let p1 = add 5 in p1 10", run = localPapFromGlobal expectFn }
    ]


{-| Applies `expectFn` to a program in which a helper binds `p1` to its
function parameter `f` applied to one argument, then calls `p1` with a second.
The function passed is a two-parameter lambda, so `p1` is a PAP with one
argument left:

    testValue =
        let
            makeP1 f x y =
                let
                    p1 =
                        f x
                in
                p1 y
        in
        makeP1 (\a b -> a) 5 10

-}
localPapFromParam : (Src.Module -> Expectation) -> (() -> Expectation)
localPapFromParam expectFn _ =
    let
        makeP1Fn =
            define "makeP1"
                [ pVar "f", pVar "x", pVar "y" ]
                (letExpr
                    [ define "p1" [] (callExpr (varExpr "f") [ varExpr "x" ]) ]
                    (callExpr (varExpr "p1") [ varExpr "y" ])
                )

        add =
            lambdaExpr [ pVar "a", pVar "b" ] (varExpr "a")

        modul =
            makeModule "testValue"
                (letExpr [ makeP1Fn ]
                    (callExpr (varExpr "makeP1") [ add, intExpr 5, intExpr 10 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program in which a `let`-bound two-parameter
function `add` is partially applied, in an inner `let`, to give `add5`, which
is then called with the remaining argument:

    testValue =
        let
            add x y =
                x
        in
        let
            add5 =
                add 5
        in
        add5 10

Although the function's name says "global", `add` is a `let`-bound function,
not a top-level one.

-}
localPapFromGlobal : (Src.Module -> Expectation) -> (() -> Expectation)
localPapFromGlobal expectFn _ =
    let
        addFn =
            define "add" [ pVar "x", pVar "y" ] (varExpr "x")

        modul =
            makeModule "testValue"
                (letExpr [ addFn ]
                    (letExpr
                        [ define "add5" [] (callExpr (varExpr "add") [ intExpr 5 ]) ]
                        (callExpr (varExpr "add5") [ intExpr 10 ])
                    )
                )
    in
    expectFn modul
