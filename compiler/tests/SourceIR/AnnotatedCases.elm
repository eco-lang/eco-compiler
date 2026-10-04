module SourceIR.AnnotatedCases exposing (expectSuite)

{-| Source programs in which every top-level definition carries a type
annotation, for a compiler stage to be tested on. In most cases the program's
function has type variables in its annotation, and is used by a value whose
annotation is concrete.

A type variable in an annotation, such as the `a` in `identity : a -> a`, is
named by the programmer rather than invented by inference, and each use of the
definition fills it in afresh. Here each use sits in a definition with a
concrete annotation of its own, but that does not fix every type variable: in
the `testValue` of the `flip`, `compose` and `on` cases, a type variable is
filled only by an integer literal, which no annotation pins to `Int`.

This module asserts nothing itself. `expectSuite` hands each program it builds
to the caller's expectation function, which decides what the program is run
through and what counts as passing.

Each case is one module named `Test`, made with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefs`, so it has that builder's
imports and every one of its top-level definitions is annotated. Each ends with
a value named `testValue`, with a concrete annotation, which applies the case's
function; some cases also define a value named `test` that uses it at a second
set of types. Each case's docstring gives the program it builds as Elm source.

The cases, by group:

  - Basic: `identity : a -> a` and `const : a -> b -> a`, each applied once,
    and `boolIdentity : Bool -> Bool`, whose annotation has no type variable.
  - Polymorphic functions: `apply`, used once at `Bool` and once at `String`,
    and `flip`.
  - Higher-order functions: `compose`, used twice at different types, and
    `on`.
  - Multiple type variables: functions returning pairs, `( a, b )`,
    `( a, a )`, and `( a, a )` from two arguments where the second is unused.
  - Records: functions returning the closed record types `{ x : a, y : b }`
    and `{ x : a, y : a }`.
  - Tuples: a function returning the nested pair `( ( a, b ), ( b, a ) )`.

Among what is not tested: annotations naming a custom type or type alias
declared in the program, extensible record types, annotations using
constrained type variables such as `number` or `comparable`, annotations on
definitions inside a `let`, and programs that should fail to type check.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , callExpr
        , floatExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named `"Annotated definitions "` followed by `condStr`,
that passes each case's program to `expectFn` in turn.

The cases run in the order the module docstring lists them, through
`Compiler.BulkCheck.bulkCheck`, so the first case that fails ends the test and
is the only one reported.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Annotated definitions " ++ condStr) (\() -> bulkCheck (testCases expectFn))


{-| Returns every case in this module, each checked by `expectFn`, group by
group.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    basicAnnotatedCases expectFn
        ++ polymorphicCases expectFn
        ++ higherOrderAnnotatedCases expectFn
        ++ multipleTypeVarCases expectFn
        ++ recordTypeCases expectFn
        ++ tupleTypeCases expectFn



-- ============================================================================
-- BASIC ANNOTATED DEFINITIONS
-- ============================================================================


{-| Returns the cases for the identity and const functions and the
`Bool -> Bool` identity, each checked by `expectFn`.
-}
basicAnnotatedCases : (Src.Module -> Expectation) -> List TestCase
basicAnnotatedCases expectFn =
    [ { label = "Identity with annotation", run = identityAnnotated expectFn }
    , { label = "Const with annotation", run = constAnnotated expectFn }
    , { label = "Bool identity", run = boolIdentity expectFn }
    ]


{-| Returns `expectFn`'s expectation for this program:

    identity : a -> a
    identity x =
        x

    testValue : Int
    testValue =
        identity 1

-}
identityAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
identityAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a") (tVar "a")

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "identity"
                  , args = [ pVar "x" ]
                  , tipe = tipe
                  , body = varExpr "x"
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body = callExpr (varExpr "identity") [ intExpr 1 ]
                  }
                ]
    in
    expectFn modul


{-| Returns `expectFn`'s expectation for this program:

    const : a -> b -> a
    const x y =
        x

    testValue : Int
    testValue =
        const 42 "hello"

-}
constAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
constAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a") (tLambda (tVar "b") (tVar "a"))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "const"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body = varExpr "x"
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Int" []
                  , body = callExpr (varExpr "const") [ intExpr 42, strExpr "hello" ]
                  }
                ]
    in
    expectFn modul


{-| Returns `expectFn`'s expectation for this program, whose annotations have
no type variables:

    boolIdentity : Bool -> Bool
    boolIdentity x =
        x

    testValue : Bool
    testValue =
        boolIdentity True

-}
boolIdentity : (Src.Module -> Expectation) -> (() -> Expectation)
boolIdentity expectFn _ =
    let
        tipe =
            tLambda (tType "Bool" []) (tType "Bool" [])

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "boolIdentity"
                  , args = [ pVar "x" ]
                  , tipe = tipe
                  , body = varExpr "x"
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Bool" []
                  , body = callExpr (varExpr "boolIdentity") [ boolExpr True ]
                  }
                ]
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC FUNCTION TESTS
-- ============================================================================


{-| Returns the cases for the apply and flip functions, each checked by
`expectFn`.
-}
polymorphicCases : (Src.Module -> Expectation) -> List TestCase
polymorphicCases expectFn =
    [ { label = "Apply with usage", run = applyWithUsage expectFn }
    , { label = "Flip function", run = flipAnnotated expectFn }
    ]


{-| Returns `expectFn`'s expectation for this program, which uses `apply` at
two different types:

    apply : (a -> b) -> a -> b
    apply f x =
        f x

    test : Bool
    test =
        apply (\n -> n) True

    testValue : String
    testValue =
        apply (\n -> n) "hello"

-}
applyWithUsage : (Src.Module -> Expectation) -> (() -> Expectation)
applyWithUsage expectFn _ =
    let
        applyType =
            tLambda (tLambda (tVar "a") (tVar "b"))
                (tLambda (tVar "a") (tVar "b"))

        testType =
            tType "Bool" []

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "apply"
                  , args = [ pVar "f", pVar "x" ]
                  , tipe = applyType
                  , body = callExpr (varExpr "f") [ varExpr "x" ]
                  }
                , { name = "test"
                  , args = []
                  , tipe = testType
                  , body =
                        callExpr (varExpr "apply")
                            [ lambdaExpr [ pVar "n" ] (varExpr "n")
                            , boolExpr True
                            ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "String" []
                  , body =
                        callExpr (varExpr "apply")
                            [ lambdaExpr [ pVar "n" ] (varExpr "n")
                            , strExpr "hello"
                            ]
                  }
                ]
    in
    expectFn modul


{-| Returns `expectFn`'s expectation for this program:

    flip : (a -> b -> c) -> b -> a -> c
    flip f y x =
        f x y

    testValue : Float
    testValue =
        flip (\a b -> 3.14) "world" 7

-}
flipAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
flipAnnotated expectFn _ =
    let
        tipe =
            tLambda
                (tLambda (tVar "a") (tLambda (tVar "b") (tVar "c")))
                (tLambda (tVar "b") (tLambda (tVar "a") (tVar "c")))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "flip"
                  , args = [ pVar "f", pVar "y", pVar "x" ]
                  , tipe = tipe
                  , body = callExpr (varExpr "f") [ varExpr "x", varExpr "y" ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Float" []
                  , body =
                        callExpr (varExpr "flip")
                            [ lambdaExpr [ pVar "a", pVar "b" ] (floatExpr 3.14)
                            , strExpr "world"
                            , intExpr 7
                            ]
                  }
                ]
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER ANNOTATED FUNCTIONS
-- ============================================================================


{-| Returns the cases for the compose and on functions, each checked by
`expectFn`.
-}
higherOrderAnnotatedCases : (Src.Module -> Expectation) -> List TestCase
higherOrderAnnotatedCases expectFn =
    [ { label = "Compose with usage", run = composeWithUsage expectFn }
    , { label = "On function", run = onAnnotated expectFn }
    ]


{-| Returns `expectFn`'s expectation for this program, which uses `compose`
at two different sets of types:

    compose : (b -> c) -> (a -> b) -> a -> c
    compose f g x =
        f (g x)

    test : Bool
    test =
        compose (\x -> x) (\y -> y) True

    testValue : String
    testValue =
        compose (\x -> "result") (\y -> 1) 42

-}
composeWithUsage : (Src.Module -> Expectation) -> (() -> Expectation)
composeWithUsage expectFn _ =
    let
        composeType =
            tLambda (tLambda (tVar "b") (tVar "c"))
                (tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tVar "a") (tVar "c"))
                )

        testType =
            tType "Bool" []

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "compose"
                  , args = [ pVar "f", pVar "g", pVar "x" ]
                  , tipe = composeType
                  , body = callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ]
                  }
                , { name = "test"
                  , args = []
                  , tipe = testType
                  , body =
                        callExpr (varExpr "compose")
                            [ lambdaExpr [ pVar "x" ] (varExpr "x")
                            , lambdaExpr [ pVar "y" ] (varExpr "y")
                            , boolExpr True
                            ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "String" []
                  , body =
                        callExpr (varExpr "compose")
                            [ lambdaExpr [ pVar "x" ] (strExpr "result")
                            , lambdaExpr [ pVar "y" ] (intExpr 1)
                            , intExpr 42
                            ]
                  }
                ]
    in
    expectFn modul


{-| Returns `expectFn`'s expectation for this program:

    on : (b -> b -> c) -> (a -> b) -> a -> a -> c
    on f g x y =
        f (g x) (g y)

    testValue : Float
    testValue =
        on (\a b -> 1.0) (\a -> "x") 1 2

The `1.0` is built as a `Float` literal, though the spelling stored with it is
`1`.

-}
onAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
onAnnotated expectFn _ =
    let
        tipe =
            tLambda (tLambda (tVar "b") (tLambda (tVar "b") (tVar "c")))
                (tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tVar "a") (tLambda (tVar "a") (tVar "c")))
                )

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "on"
                  , args = [ pVar "f", pVar "g", pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body =
                        callExpr (varExpr "f")
                            [ callExpr (varExpr "g") [ varExpr "x" ]
                            , callExpr (varExpr "g") [ varExpr "y" ]
                            ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "Float" []
                  , body =
                        callExpr (varExpr "on")
                            [ lambdaExpr [ pVar "a", pVar "b" ] (floatExpr 1.0)
                            , lambdaExpr [ pVar "a" ] (strExpr "x")
                            , intExpr 1
                            , intExpr 2
                            ]
                  }
                ]
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE TYPE VARIABLE TESTS
-- ============================================================================


{-| Returns the cases for functions that return pairs, each checked by
`expectFn`.
-}
multipleTypeVarCases : (Src.Module -> Expectation) -> List TestCase
multipleTypeVarCases expectFn =
    [ { label = "Pair function", run = pairAnnotated expectFn }
    , { label = "Wrap in tuple", run = wrapInTupleAnnotated expectFn }
    , { label = "Const tuple", run = constTupleAnnotated expectFn }
    ]


{-| Returns `expectFn`'s expectation for this program:

    pair : a -> b -> ( a, b )
    pair x y =
        ( x, y )

    testValue : ( Int, String )
    testValue =
        pair 1 "hello"

-}
pairAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
pairAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a")
                (tLambda (tVar "b") (tTuple (tVar "a") (tVar "b")))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "pair"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body = tupleExpr (varExpr "x") (varExpr "y")
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tTuple (tType "Int" []) (tType "String" [])
                  , body = callExpr (varExpr "pair") [ intExpr 1, strExpr "hello" ]
                  }
                ]
    in
    expectFn modul


{-| Returns `expectFn`'s expectation for this program:

    wrapInTuple : a -> ( a, a )
    wrapInTuple x =
        ( x, x )

    testValue : ( Float, Float )
    testValue =
        wrapInTuple 2.5

-}
wrapInTupleAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
wrapInTupleAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a") (tTuple (tVar "a") (tVar "a"))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "wrapInTuple"
                  , args = [ pVar "x" ]
                  , tipe = tipe
                  , body = tupleExpr (varExpr "x") (varExpr "x")
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tTuple (tType "Float" []) (tType "Float" [])
                  , body = callExpr (varExpr "wrapInTuple") [ floatExpr 2.5 ]
                  }
                ]
    in
    expectFn modul


{-| Returns `expectFn`'s expectation for this program, in which the type
variable `b` appears only in an argument the body ignores:

    constTuple : a -> b -> ( a, a )
    constTuple x y =
        ( x, x )

    testValue : ( Int, Int )
    testValue =
        constTuple 5 "ignored"

-}
constTupleAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
constTupleAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a") (tLambda (tVar "b") (tTuple (tVar "a") (tVar "a")))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "constTuple"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body = tupleExpr (varExpr "x") (varExpr "x")
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tTuple (tType "Int" []) (tType "Int" [])
                  , body = callExpr (varExpr "constTuple") [ intExpr 5, strExpr "ignored" ]
                  }
                ]
    in
    expectFn modul



-- ============================================================================
-- RECORD TYPE TESTS
-- ============================================================================


{-| Returns the cases for functions that return records, each checked by
`expectFn`.
-}
recordTypeCases : (Src.Module -> Expectation) -> List TestCase
recordTypeCases expectFn =
    [ { label = "Make record", run = makeRecordAnnotated expectFn }
    , { label = "Make record with same type", run = makeRecordSameTypeAnnotated expectFn }
    ]


{-| Returns `expectFn`'s expectation for this program:

    makeXY : a -> b -> { x : a, y : b }
    makeXY x y =
        { x = x, y = y }

    testValue : { x : Int, y : String }
    testValue =
        makeXY 10 "world"

-}
makeRecordAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
makeRecordAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a")
                (tLambda (tVar "b")
                    (tRecord [ ( "x", tVar "a" ), ( "y", tVar "b" ) ])
                )

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "makeXY"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body = recordExpr [ ( "x", varExpr "x" ), ( "y", varExpr "y" ) ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tRecord [ ( "x", tType "Int" [] ), ( "y", tType "String" [] ) ]
                  , body = callExpr (varExpr "makeXY") [ intExpr 10, strExpr "world" ]
                  }
                ]
    in
    expectFn modul


{-| Returns `expectFn`'s expectation for this program:

    makeSame : a -> { x : a, y : a }
    makeSame val =
        { x = val, y = val }

    testValue : { x : Float, y : Float }
    testValue =
        makeSame 9.9

-}
makeRecordSameTypeAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
makeRecordSameTypeAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a")
                (tRecord [ ( "x", tVar "a" ), ( "y", tVar "a" ) ])

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "makeSame"
                  , args = [ pVar "val" ]
                  , tipe = tipe
                  , body = recordExpr [ ( "x", varExpr "val" ), ( "y", varExpr "val" ) ]
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tRecord [ ( "x", tType "Float" [] ), ( "y", tType "Float" [] ) ]
                  , body = callExpr (varExpr "makeSame") [ floatExpr 9.9 ]
                  }
                ]
    in
    expectFn modul



-- ============================================================================
-- TUPLE TYPE TESTS
-- ============================================================================


{-| Returns the case for a function that returns a nested pair, checked by
`expectFn`.
-}
tupleTypeCases : (Src.Module -> Expectation) -> List TestCase
tupleTypeCases expectFn =
    [ { label = "Nest tuple", run = nestTupleAnnotated expectFn }
    ]


{-| Returns `expectFn`'s expectation for this program:

    nest : a -> b -> ( ( a, b ), ( b, a ) )
    nest x y =
        ( ( x, y ), ( y, x ) )

    testValue : ( ( Int, String ), ( String, Int ) )
    testValue =
        nest 3 "abc"

-}
nestTupleAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
nestTupleAnnotated expectFn _ =
    let
        tipe =
            tLambda (tVar "a")
                (tLambda (tVar "b")
                    (tTuple
                        (tTuple (tVar "a") (tVar "b"))
                        (tTuple (tVar "b") (tVar "a"))
                    )
                )

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "nest"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body =
                        tupleExpr
                            (tupleExpr (varExpr "x") (varExpr "y"))
                            (tupleExpr (varExpr "y") (varExpr "x"))
                  }
                , { name = "testValue"
                  , args = []
                  , tipe =
                        tTuple
                            (tTuple (tType "Int" []) (tType "String" []))
                            (tTuple (tType "String" []) (tType "Int" []))
                  , body = callExpr (varExpr "nest") [ intExpr 3, strExpr "abc" ]
                  }
                ]
    in
    expectFn modul
