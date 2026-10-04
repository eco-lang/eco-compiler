module SourceIR.FunctionCases exposing (expectSuite)

{-| Builds Elm programs whose interest is in their functions, so that the
compiler stages tested with them meet lambdas, calls, partial and
over-application, patterns in function arguments, higher-order functions and
constrained type variables.

This module checks nothing itself. `expectSuite` gives every program to the
expectation function its caller supplies, and that function decides which
stages run and what is asserted. The programs are run as one test through
`Compiler.BulkCheck.bulkCheck`, so a failure reports only the first failing
case, under its label.

Each program is a Source AST module built with `Compiler.AST.SourceBuilder`,
named `Test`, with a top-level value `testValue`. Programs with no type
annotations import `Basics` and `List`; the annotated ones, built with
`makeModuleWithTypedDefs` or `makeModuleWithTypedDefsUnionsAliases`, annotate
every top-level value and import the standard set that module describes. In
most programs the function under test is bound with no arguments to a lambda,
either at the top level as `testFn` or in a `let` inside `testValue`.

The cases, in the order they run:

  - Lambdas: a top-level identity lambda; a two-argument lambda returning its
    first argument; one returning both arguments as a pair; and one with a
    wildcard argument returning `42`. `testValue` calls each with all its
    arguments.
  - Calls: a let-bound identity lambda called with `42`; a let-bound
    two-argument lambda called with two integer literals; and the identity
    called on the result of calling it.
  - Partial application: a let-bound two-argument lambda given one argument,
    so `testValue` is a function. Then seven chained cases: a three-argument
    function returning its first argument is given one argument, that result
    is bound as `p1` and given `2`, so `testValue` is a function still waiting
    for its third argument. The first argument is an integer literal, a Float
    literal, a Char, a Bool, a String or a two-field record, with the function
    a lambda bound as `f`, and `f` and `p1` unannotated and let-bound inside
    `testValue`, or, in the Custom case, `Wrapper 42`, where `Wrapper` is a
    custom type with one constructor holding an Int, the function is defined
    with three arguments, and every value is annotated and top-level.
  - Nested functions: a lambda returning a lambda, called with two arguments
    at once; a lambda whose body let-binds a second lambda and calls it; and
    `testValue` as a pair of two lambdas that are never called.
  - Patterns in function arguments: lambdas taking a pair pattern, the record
    pattern `{ x }`, and a variable, a pair and a wildcard together, each
    called with values that match; and a top-level `swap` whose argument is a
    pair pattern.
  - Higher-order functions: `apply` called with an identity lambda and `42`;
    a three-argument `compose`, once called with two identity lambdas and `42`
    and once returned unapplied; four-argument and two-argument lambdas, each
    returned unapplied; a three-argument lambda given one argument; and a
    three-argument `flip`, returned unapplied.
  - Negation: the negation of `42`, and the negation of that negation.
  - `Basics.abs 5`.
  - Constrained type variables: annotated functions over `number`,
    `comparable`, `appendable` and `compappend`, called at Int, Float or
    String; then unannotated functions using `<`, `++` or both on their
    arguments, which are never called.

Among what is not tested: which stage runs and what holds after it, which
belong to the caller; recursive functions; let definitions with arguments or
annotations; operators used as values; constructor and list patterns in
function arguments; and any program that should fail to compile.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , chrExpr
        , ctorExpr
        , define
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , negateExpr
        , pAnything
        , pRecord
        , pTuple
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Function expressions "` followed by `condStr`,
that passes when `expectFn` passes on every program this module builds.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Function expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of this module, group by group, each giving its program
to `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    lambdaCases expectFn
        ++ callCases expectFn
        ++ partialApplicationCases expectFn
        ++ nestedFunctionCases expectFn
        ++ functionWithPatternsCases expectFn
        ++ higherOrderCases expectFn
        ++ negateCases expectFn
        ++ absCases expectFn
        ++ polymorphicNumberCases expectFn



-- ============================================================================
-- LAMBDA EXPRESSIONS
-- ============================================================================


{-| Returns the cases that call a top-level lambda.
-}
lambdaCases : (Src.Module -> Expectation) -> List TestCase
lambdaCases expectFn =
    [ { label = "Identity lambda", run = identityLambda expectFn }
    , { label = "Two-argument lambda", run = twoArgumentLambda expectFn }
    , { label = "Lambda returning tuple", run = lambdaReturningTuple expectFn }
    , { label = "Lambda with wildcard pattern", run = lambdaWithWildcard expectFn }
    ]


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\x -> x` and `testValue` is `testFn 1`.
-}
identityLambda : (Src.Module -> Expectation) -> (() -> Expectation)
identityLambda expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x" ] (varExpr "x") )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\x y -> x` and `testValue` is `testFn 1 "a"`.
-}
twoArgumentLambda : (Src.Module -> Expectation) -> (() -> Expectation)
twoArgumentLambda expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x") )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\x y -> ( x, y )` and `testValue` is `testFn 1 "a"`.
-}
lambdaReturningTuple : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningTuple expectFn _ =
    let
        body =
            tupleExpr (varExpr "x") (varExpr "y")

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x", pVar "y" ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\_ -> 42` and `testValue` is `testFn 1`.
-}
lambdaWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithWildcard expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pAnything ] (intExpr 42) )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1 ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- FUNCTION CALLS
-- ============================================================================


{-| Returns the cases that call a let-bound lambda.
-}
callCases : (Src.Module -> Expectation) -> List TestCase
callCases expectFn =
    [ { label = "Call with one int arg", run = callWithOneIntArg expectFn }
    , { label = "Call with two args", run = callWithTwoArgs expectFn }
    , { label = "Nested calls", run = nestedCalls expectFn }
    ]


{-| Returns the deferred `expectFn` check of the module
`testValue = let f = \x -> x in f 42`.
-}
callWithOneIntArg : (Src.Module -> Expectation) -> (() -> Expectation)
callWithOneIntArg expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        def =
            define "f" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (callExpr (varExpr "f") [ intExpr 42 ]))
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = let f = \x y -> x in f 1 2`.
-}
callWithTwoArgs : (Src.Module -> Expectation) -> (() -> Expectation)
callWithTwoArgs expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")

        def =
            define "f" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (callExpr (varExpr "f") [ intExpr 1, intExpr 2 ]))
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = let f = \x -> x in f (f 1)`.
-}
nestedCalls : (Src.Module -> Expectation) -> (() -> Expectation)
nestedCalls expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        def =
            define "f" [] fn

        innerCall =
            callExpr (varExpr "f") [ intExpr 1 ]

        outerCall =
            callExpr (varExpr "f") [ innerCall ]

        modul =
            makeModule "testValue" (letExpr [ def ] outerCall)
    in
    expectFn modul



-- ============================================================================
-- PARTIAL APPLICATION
-- ============================================================================


{-| Returns the cases that give a function fewer arguments than it takes.
-}
partialApplicationCases : (Src.Module -> Expectation) -> List TestCase
partialApplicationCases expectFn =
    [ { label = "Partially applied two-arg function", run = partiallyAppliedTwoArg expectFn }
    , { label = "Chained partial application", run = chainedPartialApplication expectFn }
    , { label = "Chained partial application (Float)", run = chainedPartialApplicationFloat expectFn }
    , { label = "Chained partial application (Char)", run = chainedPartialApplicationChar expectFn }
    , { label = "Chained partial application (Bool)", run = chainedPartialApplicationBool expectFn }
    , { label = "Chained partial application (String)", run = chainedPartialApplicationString expectFn }
    , { label = "Chained partial application (Record)", run = chainedPartialApplicationRecord expectFn }
    , { label = "Chained partial application (Custom)", run = chainedPartialApplicationCustom expectFn }
    ]


{-| Returns the deferred `expectFn` check of the module
`testValue = let f = \x y -> ( x, y ) in f 1`, whose value is a function.
-}
partiallyAppliedTwoArg : (Src.Module -> Expectation) -> (() -> Expectation)
partiallyAppliedTwoArg expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "x", pVar "y" ] (tupleExpr (varExpr "x") (varExpr "y"))

        def =
            define "f" [] fn

        partial =
            callExpr (varExpr "f") [ intExpr 1 ]

        modul =
            makeModule "testValue" (letExpr [ def ] partial)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    testValue =
        let
            f =
                \a b c -> a

            p1 =
                f 1
        in
        p1 2

whose value is a function waiting for the third argument of `f`.

-}
chainedPartialApplication : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplication expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ intExpr 1 ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    testValue =
        let
            f =
                \a b c -> a

            p1 =
                f 1.5
        in
        p1 2

whose value is a function waiting for the third argument of `f`.

-}
chainedPartialApplicationFloat : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationFloat expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ floatExpr 1.5 ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    testValue =
        let
            f =
                \a b c -> a

            p1 =
                f 'x'
        in
        p1 2

whose value is a function waiting for the third argument of `f`.

-}
chainedPartialApplicationChar : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationChar expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ chrExpr "x" ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    testValue =
        let
            f =
                \a b c -> a

            p1 =
                f True
        in
        p1 2

whose value is a function waiting for the third argument of `f`.

-}
chainedPartialApplicationBool : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationBool expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ boolExpr True ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    testValue =
        let
            f =
                \a b c -> a

            p1 =
                f "hello"
        in
        p1 2

whose value is a function waiting for the third argument of `f`.

-}
chainedPartialApplicationString : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationString expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ strExpr "hello" ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    testValue =
        let
            f =
                \a b c -> a

            p1 =
                f { x = 1, y = 2 }
        in
        p1 2

whose value is a function waiting for the third argument of `f`.

-}
chainedPartialApplicationRecord : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationRecord expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ] (varExpr "a")

        def =
            define "f" [] fn

        partial1 =
            callExpr (varExpr "f") [ recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ] ]

        defP1 =
            define "p1" [] partial1

        partial2 =
            callExpr (varExpr "p1") [ intExpr 2 ]

        modul =
            makeModule "testValue" (letExpr [ def, defP1 ] partial2)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    type Wrapper
        = Wrapper Int

    f : Wrapper -> Int -> Int -> Wrapper
    f a b c =
        a

    p1 : Int -> Int -> Wrapper
    p1 =
        f (Wrapper 42)

    testValue : Int -> Wrapper
    testValue =
        p1 2

Unlike the other chained cases, every value is top-level and annotated.

-}
chainedPartialApplicationCustom : (Src.Module -> Expectation) -> (() -> Expectation)
chainedPartialApplicationCustom expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors = [ { name = "Wrapper", args = [ tType "Int" [] ] } ]
            }

        fnDef : TypedDef
        fnDef =
            { name = "f"
            , args = [ pVar "a", pVar "b", pVar "c" ]
            , tipe = tLambda (tType "Wrapper" []) (tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Wrapper" [])))
            , body = varExpr "a"
            }

        p1Def : TypedDef
        p1Def =
            { name = "p1"
            , args = []
            , tipe = tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "Wrapper" []))
            , body = callExpr (varExpr "f") [ callExpr (ctorExpr "Wrapper") [ intExpr 42 ] ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tLambda (tType "Int" []) (tType "Wrapper" [])
            , body = callExpr (varExpr "p1") [ intExpr 2 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ fnDef, p1Def, testValueDef ] [ wrapperUnion ] []
    in
    expectFn modul



-- ============================================================================
-- NESTED FUNCTIONS
-- ============================================================================


{-| Returns the cases with a lambda inside another lambda or inside a pair.
-}
nestedFunctionCases : (Src.Module -> Expectation) -> List TestCase
nestedFunctionCases expectFn =
    [ { label = "Lambda returning lambda", run = lambdaReturningLambda expectFn }
    , { label = "Lambda inside let inside lambda", run = lambdaInsideLetInsideLambda expectFn }
    , { label = "Multiple lambdas in tuple", run = multipleLambdasInTuple expectFn }
    ]


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\x -> \y -> y` and `testValue` is `testFn 1 "a"`, a call with more arguments
than the outer lambda takes.
-}
lambdaReturningLambda : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaReturningLambda expectFn _ =
    let
        inner =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x" ] inner )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1, strExpr "a" ] )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\x -> let inner = \y -> y in inner x` and `testValue` is `testFn 1`.
-}
lambdaInsideLetInsideLambda : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaInsideLetInsideLambda expectFn _ =
    let
        innerLambda =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        def =
            define "inner" [] innerLambda

        body =
            letExpr [ def ] (callExpr (varExpr "inner") [ varExpr "x" ])

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pVar "x" ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = ( \x -> x, \y -> 0 )`, in which neither lambda is called.
-}
multipleLambdasInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLambdasInTuple expectFn _ =
    let
        lambda1 =
            lambdaExpr [ pVar "x" ] (varExpr "x")

        lambda2 =
            lambdaExpr [ pVar "y" ] (intExpr 0)

        modul =
            makeModule "testValue" (tupleExpr lambda1 lambda2)
    in
    expectFn modul



-- ============================================================================
-- FUNCTIONS WITH PATTERNS
-- ============================================================================


{-| Returns the cases whose functions destructure their arguments with pair or
record patterns.
-}
functionWithPatternsCases : (Src.Module -> Expectation) -> List TestCase
functionWithPatternsCases expectFn =
    [ { label = "Lambda with tuple pattern", run = lambdaWithTuplePattern expectFn }
    , { label = "Lambda with record pattern", run = lambdaWithRecordPattern expectFn }
    , { label = "Lambda with mixed patterns", run = lambdaWithMixedPatterns expectFn }
    , { label = "Top-level function with patterns", run = topLevelFunctionWithPatterns expectFn }
    ]


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\( x, y ) -> ( y, x )` and `testValue` is `testFn ( 1, "a" )`.
-}
lambdaWithTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithTuplePattern expectFn _ =
    let
        pattern =
            pTuple (pVar "x") (pVar "y")

        body =
            tupleExpr (varExpr "y") (varExpr "x")

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pattern ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ tupleExpr (intExpr 1) (strExpr "a") ] )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\{ x } -> x` and `testValue` is `testFn { x = 1 }`.
-}
lambdaWithRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithRecordPattern expectFn _ =
    let
        pattern =
            pRecord [ "x" ]

        body =
            varExpr "x"

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn", [], lambdaExpr [ pattern ] body )
                , ( "testValue", [], callExpr (varExpr "testFn") [ recordExpr [ ( "x", intExpr 1 ) ] ] )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of a module where `testFn` is
`\a ( b, c ) _ -> b` and `testValue` is `testFn 1 ( "a", 2 ) 3`.
-}
lambdaWithMixedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaWithMixedPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn"
                  , []
                  , lambdaExpr
                        [ pVar "a"
                        , pTuple (pVar "b") (pVar "c")
                        , pAnything
                        ]
                        (varExpr "b")
                  )
                , ( "testValue"
                  , []
                  , callExpr (varExpr "testFn") [ intExpr 1, tupleExpr (strExpr "a") (intExpr 2), intExpr 3 ]
                  )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`swap ( a, b ) = ( b, a )`, `testValue = swap ( 1, "a" )`, where `swap`'s
argument is a pattern on the top-level definition rather than on a lambda.
-}
topLevelFunctionWithPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
topLevelFunctionWithPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "swap", [ pTuple (pVar "a") (pVar "b") ], tupleExpr (varExpr "b") (varExpr "a") )
                , ( "testValue", [], callExpr (varExpr "swap") [ tupleExpr (intExpr 1) (strExpr "a") ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER FUNCTIONS
-- ============================================================================


{-| Returns the cases that pass functions as arguments, return multi-argument
lambdas unapplied, or give a three-argument lambda one argument.
-}
higherOrderCases : (Src.Module -> Expectation) -> List TestCase
higherOrderCases expectFn =
    [ { label = "Apply function", run = applyFunction expectFn }
    , { label = "Compose functions applied", run = composeFunctionsApplied expectFn }
    , { label = "Compose functions", run = composeFunctions expectFn }
    , { label = "Four-arg lambda as value", run = fourArgLambdaAsValue expectFn }
    , { label = "Two-arg lambda as value", run = twoArgLambdaAsValue expectFn }
    , { label = "Multi-arg lambda partially applied", run = multiArgLambdaPartiallyApplied expectFn }
    , { label = "Flip as lambda value", run = flipAsLambdaValue expectFn }
    ]


{-| Returns the deferred `expectFn` check of the module
`testValue = let apply = \f x -> f x in apply (\y -> y) 42`.
-}
applyFunction : (Src.Module -> Expectation) -> (() -> Expectation)
applyFunction expectFn _ =
    let
        applyFn =
            lambdaExpr
                [ pVar "f", pVar "x" ]
                (callExpr (varExpr "f") [ varExpr "x" ])

        def =
            define "apply" [] applyFn

        identity =
            lambdaExpr [ pVar "y" ] (varExpr "y")

        application =
            callExpr (varExpr "apply") [ identity, intExpr 42 ]

        modul =
            makeModule "testValue" (letExpr [ def ] application)
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = let compose = \f g x -> f (g x) in compose`, whose value is the
three-argument lambda itself, unapplied.
-}
composeFunctions : (Src.Module -> Expectation) -> (() -> Expectation)
composeFunctions expectFn _ =
    let
        composeFn =
            lambdaExpr
                [ pVar "f", pVar "g", pVar "x" ]
                (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])

        def =
            define "compose" [] composeFn

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "compose"))
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    testValue =
        let
            compose =
                \f g x -> f (g x)
        in
        compose (\n -> n) (\n -> n) 42

It is `composeFunctions` with the lambda called with all three arguments
instead of returned.

-}
composeFunctionsApplied : (Src.Module -> Expectation) -> (() -> Expectation)
composeFunctionsApplied expectFn _ =
    let
        composeFn =
            lambdaExpr
                [ pVar "f", pVar "g", pVar "x" ]
                (callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ])

        def =
            define "compose" [] composeFn

        fn1 =
            lambdaExpr [ pVar "n" ] (varExpr "n")

        modul =
            makeModule "testValue"
                (letExpr [ def ]
                    (callExpr (varExpr "compose") [ fn1, fn1, intExpr 42 ])
                )
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = let fourArgs = \a b c d -> [ a, b, c, d ] in fourArgs`, whose
value is the four-argument lambda itself, unapplied.
-}
fourArgLambdaAsValue : (Src.Module -> Expectation) -> (() -> Expectation)
fourArgLambdaAsValue expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c", pVar "d" ]
                (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d" ])

        def =
            define "fourArgs" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "fourArgs"))
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = let twoArgs = \a b -> ( a, b ) in twoArgs`, whose value is the
two-argument lambda itself, unapplied.
-}
twoArgLambdaAsValue : (Src.Module -> Expectation) -> (() -> Expectation)
twoArgLambdaAsValue expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b" ]
                (tupleExpr (varExpr "a") (varExpr "b"))

        def =
            define "twoArgs" [] fn

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "twoArgs"))
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = let threeArgs = \a b c -> [ a, b, c ] in threeArgs 1`, whose
value is a function waiting for the remaining two arguments.
-}
multiArgLambdaPartiallyApplied : (Src.Module -> Expectation) -> (() -> Expectation)
multiArgLambdaPartiallyApplied expectFn _ =
    let
        fn =
            lambdaExpr [ pVar "a", pVar "b", pVar "c" ]
                (listExpr [ varExpr "a", varExpr "b", varExpr "c" ])

        def =
            define "threeArgs" [] fn

        modul =
            makeModule "testValue"
                (letExpr [ def ]
                    (callExpr (varExpr "threeArgs") [ intExpr 1 ])
                )
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module
`testValue = let flip = \f b a -> f a b in flip`, whose value is the
three-argument lambda itself, unapplied.
-}
flipAsLambdaValue : (Src.Module -> Expectation) -> (() -> Expectation)
flipAsLambdaValue expectFn _ =
    let
        flipFn =
            lambdaExpr [ pVar "f", pVar "b", pVar "a" ]
                (callExpr (varExpr "f") [ varExpr "a", varExpr "b" ])

        def =
            define "flip" [] flipFn

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "flip"))
    in
    expectFn modul



-- ============================================================================
-- NEGATE
-- ============================================================================


{-| Returns the negation cases.
-}
negateCases : (Src.Module -> Expectation) -> List TestCase
negateCases expectFn =
    [ { label = "Negate int", run = negateInt expectFn }
    , { label = "Double negate", run = doubleNegate expectFn }
    ]


{-| Returns the deferred `expectFn` check of the module whose `testValue` is
the negation (`Src.Negate`) of the literal `42`.
-}
negateInt : (Src.Module -> Expectation) -> (() -> Expectation)
negateInt expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (intExpr 42))
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module whose `testValue` is
the negation of the negation of the literal `42`, with no parentheses between.
The parser does not produce that nesting (see
`Compiler.AST.SourceBuilder.negateExpr`).
-}
doubleNegate : (Src.Module -> Expectation) -> (() -> Expectation)
doubleNegate expectFn _ =
    let
        modul =
            makeModule "testValue" (negateExpr (negateExpr (intExpr 42)))
    in
    expectFn modul



-- ============================================================================
-- ABS
-- ============================================================================


{-| Returns the case that calls `Basics.abs`.
-}
absCases : (Src.Module -> Expectation) -> List TestCase
absCases expectFn =
    [ { label = "Abs positive int", run = absPositiveInt expectFn }
    ]


{-| Returns the deferred `expectFn` check of the module
`testValue = Basics.abs 5`, with the call written qualified.
-}
absPositiveInt : (Src.Module -> Expectation) -> (() -> Expectation)
absPositiveInt expectFn _ =
    let
        modul =
            makeModule "testValue" (callExpr (qualVarExpr "Basics" "abs") [ intExpr 5 ])
    in
    expectFn modul



-- ============================================================================
-- CONSTRAINED TYPE VARIABLES
-- ============================================================================


{-| Returns the cases with type variables constrained to `number`, `comparable`,
`appendable` or `compappend`.
-}
polymorphicNumberCases : (Src.Module -> Expectation) -> List TestCase
polymorphicNumberCases expectFn =
    [ { label = "zabs with Int (baseline)", run = zabsWithInt expectFn }
    , { label = "zabs with Float (Int literal promoted)", run = zabsWithFloat expectFn }
    , { label = "comparable min with Int", run = comparableMinWithInt expectFn }
    , { label = "appendable concat with String", run = appendableConcatWithString expectFn }
    , { label = "compappend with String", run = compappendWithString expectFn }
    , { label = "unannotated comparable", run = unannotatedComparable expectFn }
    , { label = "unannotated appendable", run = unannotatedAppendable expectFn }
    , { label = "unannotated compappend", run = unannotatedCompappend expectFn }
    ]


{-| Returns the deferred `expectFn` check of the module

    zabs : number -> number
    zabs n =
        if n < 0 then
            -n

        else
            n

    testValue : Int
    testValue =
        zabs 5

-}
zabsWithInt : (Src.Module -> Expectation) -> (() -> Expectation)
zabsWithInt expectFn _ =
    let
        zabsType =
            tLambda (tVar "number") (tVar "number")

        zabsBody =
            ifExpr
                (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                (negateExpr (varExpr "n"))
                (varExpr "n")

        zabsDef : TypedDef
        zabsDef =
            { name = "zabs"
            , args = [ pVar "n" ]
            , tipe = zabsType
            , body = zabsBody
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "zabs") [ intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zabsDef, testValueDef ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    zabs : number -> number
    zabs n =
        if n < 0 then
            -n

        else
            n

    testValue : Float
    testValue =
        zabs 3.14

The literal `0` is an integer literal (`Src.Int`), but `<` compares two values
of one type, so it has `n`'s type, `number`, which the only call, `zabs 3.14`,
instantiates at Float.

-}
zabsWithFloat : (Src.Module -> Expectation) -> (() -> Expectation)
zabsWithFloat expectFn _ =
    let
        zabsType =
            tLambda (tVar "number") (tVar "number")

        zabsBody =
            ifExpr
                (binopsExpr [ ( varExpr "n", "<" ) ] (intExpr 0))
                (negateExpr (varExpr "n"))
                (varExpr "n")

        zabsDef : TypedDef
        zabsDef =
            { name = "zabs"
            , args = [ pVar "n" ]
            , tipe = zabsType
            , body = zabsBody
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Float" []
            , body = callExpr (varExpr "zabs") [ floatExpr 3.14 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zabsDef, testValueDef ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    zmin : comparable -> comparable -> comparable
    zmin a b =
        if a < b then
            a

        else
            b

    testValue : Int
    testValue =
        zmin 3 5

-}
comparableMinWithInt : (Src.Module -> Expectation) -> (() -> Expectation)
comparableMinWithInt expectFn _ =
    let
        zminType =
            tLambda (tVar "comparable") (tLambda (tVar "comparable") (tVar "comparable"))

        zminBody =
            ifExpr
                (binopsExpr [ ( varExpr "a", "<" ) ] (varExpr "b"))
                (varExpr "a")
                (varExpr "b")

        zminDef : TypedDef
        zminDef =
            { name = "zmin"
            , args = [ pVar "a", pVar "b" ]
            , tipe = zminType
            , body = zminBody
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "zmin") [ intExpr 3, intExpr 5 ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zminDef, testValueDef ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    zsortConcat : compappend -> compappend -> compappend
    zsortConcat a b =
        if a < b then
            a ++ b

        else
            b ++ a

    testValue : String
    testValue =
        zsortConcat "hello" "world"

The annotation's `compappend` asks for a type that is both comparable and
appendable, which the body uses with `<` and `++`.

-}
compappendWithString : (Src.Module -> Expectation) -> (() -> Expectation)
compappendWithString expectFn _ =
    let
        zsortConcatType =
            tLambda (tVar "compappend") (tLambda (tVar "compappend") (tVar "compappend"))

        zsortConcatBody =
            ifExpr
                (binopsExpr [ ( varExpr "a", "<" ) ] (varExpr "b"))
                (binopsExpr [ ( varExpr "a", "++" ) ] (varExpr "b"))
                (binopsExpr [ ( varExpr "b", "++" ) ] (varExpr "a"))

        zsortConcatDef : TypedDef
        zsortConcatDef =
            { name = "zsortConcat"
            , args = [ pVar "a", pVar "b" ]
            , tipe = zsortConcatType
            , body = zsortConcatBody
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "zsortConcat") [ strExpr "hello", strExpr "world" ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zsortConcatDef, testValueDef ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    zconcat : appendable -> appendable -> appendable
    zconcat a b =
        a ++ b

    testValue : String
    testValue =
        zconcat "hello" " world"

-}
appendableConcatWithString : (Src.Module -> Expectation) -> (() -> Expectation)
appendableConcatWithString expectFn _ =
    let
        zconcatType =
            tLambda (tVar "appendable") (tLambda (tVar "appendable") (tVar "appendable"))

        zconcatBody =
            binopsExpr [ ( varExpr "a", "++" ) ] (varExpr "b")

        zconcatDef : TypedDef
        zconcatDef =
            { name = "zconcat"
            , args = [ pVar "a", pVar "b" ]
            , tipe = zconcatType
            , body = zconcatBody
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "zconcat") [ strExpr "hello", strExpr " world" ]
            }

        modul =
            makeModuleWithTypedDefs "Test" [ zconcatDef, testValueDef ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    zmin x y =
        if x < y then
            x

        else
            y

    testValue =
        0

`zmin` has no annotation, so its arguments' comparable constraint comes only
from the use of `<`, and the type variable carrying it has no name written in
the source. Nothing calls `zmin`, so no use fixes that variable to a concrete
type.

-}
unannotatedComparable : (Src.Module -> Expectation) -> (() -> Expectation)
unannotatedComparable expectFn _ =
    let
        zminBody =
            ifExpr
                (binopsExpr [ ( varExpr "x", "<" ) ] (varExpr "y"))
                (varExpr "x")
                (varExpr "y")

        modul =
            makeModuleWithDefs "Test"
                [ ( "zmin", [ pVar "x", pVar "y" ], zminBody )
                , ( "testValue", [], intExpr 0 )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    zappend x y =
        x ++ y

    testValue =
        0

`zappend` has no annotation, so its arguments' appendable constraint comes only
from the use of `++`, and the type variable carrying it has no name written in
the source. Nothing calls `zappend`.

-}
unannotatedAppendable : (Src.Module -> Expectation) -> (() -> Expectation)
unannotatedAppendable expectFn _ =
    let
        zappendBody =
            binopsExpr [ ( varExpr "x", "++" ) ] (varExpr "y")

        modul =
            makeModuleWithDefs "Test"
                [ ( "zappend", [ pVar "x", pVar "y" ], zappendBody )
                , ( "testValue", [], intExpr 0 )
                ]
    in
    expectFn modul


{-| Returns the deferred `expectFn` check of the module

    zsortcat x y =
        if x < y then
            x ++ y

        else
            y ++ x

    testValue =
        0

`zsortcat` has no annotation and uses its arguments with both `<` and `++`, so
their type must be both comparable and appendable, a constraint that no name in
the source states. Nothing calls `zsortcat`.

-}
unannotatedCompappend : (Src.Module -> Expectation) -> (() -> Expectation)
unannotatedCompappend expectFn _ =
    let
        zsortcatBody =
            ifExpr
                (binopsExpr [ ( varExpr "x", "<" ) ] (varExpr "y"))
                (binopsExpr [ ( varExpr "x", "++" ) ] (varExpr "y"))
                (binopsExpr [ ( varExpr "y", "++" ) ] (varExpr "x"))

        modul =
            makeModuleWithDefs "Test"
                [ ( "zsortcat", [ pVar "x", pVar "y" ], zsortcatBody )
                , ( "testValue", [], intExpr 0 )
                ]
    in
    expectFn modul


{-| `Compiler.AST.SourceBuilder.tLambda`, which builds a function type from an
argument type and a result type, under a short local name.
-}
tLambda : Src.Type -> Src.Type -> Src.Type
tLambda =
    Compiler.AST.SourceBuilder.tLambda


{-| `Compiler.AST.SourceBuilder.tVar`, which builds a type variable, under a
short local name.
-}
tVar : String -> Src.Type
tVar =
    Compiler.AST.SourceBuilder.tVar


{-| `Compiler.AST.SourceBuilder.tType`, which builds a named type applied to
arguments, under a short local name.
-}
tType : String -> List Src.Type -> Src.Type
tType =
    Compiler.AST.SourceBuilder.tType
