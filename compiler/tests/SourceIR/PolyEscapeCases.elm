module SourceIR.PolyEscapeCases exposing (expectSuite)

{-| Programs in which a polymorphic function reaches the place where it is
applied by an indirect route, for checking that the concrete type it is used
at is carried along that route.

Monomorphization makes a separate copy, a _specialization_, of a polymorphic
function for each concrete type it is used at. When the function is not called
directly but stored in a record or tuple, returned from another function as a
closure, or passed to another function first, the type it is finally used at
has to be traced back through that route. Where it is not, a type variable can
be left in a specialization that should have been concrete. Each program here
builds one such route.

The module asserts nothing itself. `expectSuite` passes each program to the
expectation function its caller supplies, and that function decides what is
checked.

Every program defines a top-level `testValue` and is built with
`Compiler.AST.SourceBuilder`. Five of them are built with `makeModule`, so they
carry no type annotation, and their integer literals have the type `number`
until something later fixes it. The other is a module with annotations, in
which `testValue` is an `Int`.

The cases, in the order they run:

  - "Polymorphic identity in record field" stores an identity lambda in a
    record field, reads it back and applies it to an integer literal.
  - "Polymorphic lambda in local Maybe.map" declares its own `Maybe` type and
    an annotated `maybeMap`, and passes an identity lambda to `maybeMap` with
    `Just 1`.
  - "Nested polymorphic closures with different types" has an inner function
    that captures its outer function's argument and pairs it with its own, so
    that the two components of the pair get different types.
  - "Polymorphic flip with mixed types" defines a local `flip` and calls it
    with a two-argument lambda, an integer literal and a string, so that all
    three of `flip`'s type variables are instantiated.
  - "Record update narrowing polymorphic field" replaces a record's identity
    field by an update, so that the identity is used at the type of the new
    function.
  - "Polymorphic function extracted from tuple" stores a local identity
    function in a pair, takes it out with a local `first` and applies it.

Among what is not tested: a polymorphic function stored in a list or in a
custom type's constructor, and one polymorphic function used at two different
types in the same program.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tVar
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Polymorphic TVar escape " followed by `condStr`,
that passes each program in this module to `expectFn` in turn.

The cases are run by `Compiler.BulkCheck.bulkCheck`, so the test fails with the
label of the first case that fails, and the cases after it do not run.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Polymorphic TVar escape " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the six cases, each pairing a label with its program passed to
`expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Polymorphic identity in record field", run = polyIdentityInRecordField expectFn }
    , { label = "Polymorphic lambda in local Maybe.map", run = lambdaInMaybeMap expectFn }
    , { label = "Nested polymorphic closures with different types", run = nestedPolymorphicClosures expectFn }
    , { label = "Polymorphic flip with mixed types", run = polyFlipMixedTypes expectFn }
    , { label = "Record update narrowing polymorphic field", run = recordUpdatePolyNarrowing expectFn }
    , { label = "Polymorphic function extracted from tuple", run = polyFunctionInTuple expectFn }
    ]


{-| Applies `expectFn` to a program that stores an identity lambda in a record
field, then reads the field and applies it to an integer literal, so the
identity is used at `number -> number`. The program is:

    testValue =
        let
            r =
                { fn = \x -> x }
        in
        r.fn 42

-}
polyIdentityInRecordField : (Src.Module -> Expectation) -> (() -> Expectation)
polyIdentityInRecordField expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r"
                        []
                        (recordExpr
                            [ ( "fn", lambdaExpr [ pVar "x" ] (varExpr "x") ) ]
                        )
                    ]
                    (callExpr (accessExpr (varExpr "r") "fn") [ intExpr 42 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a module named `Test` that declares its own `Maybe`
type and a `maybeMap` over it, and passes an identity lambda to `maybeMap`
together with `Just 1`. The annotation `testValue : Int` makes the lambda's type
`Int -> Int`. The module also imports the `Maybe` module, which
`makeModuleWithTypedDefsUnionsAliases` adds with everything exposed. It
declares:

    type Maybe a
        = Just a
        | Nothing

    maybeMap : (a -> b) -> Maybe a -> Maybe b
    maybeMap f m =
        case m of
            Just x ->
                Just (f x)

            Nothing ->
                Nothing

    testValue : Int
    testValue =
        case maybeMap (\x -> x) (Just 1) of
            Just n ->
                n

            Nothing ->
                0

-}
lambdaInMaybeMap : (Src.Module -> Expectation) -> (() -> Expectation)
lambdaInMaybeMap expectFn _ =
    let
        maybeUnion : UnionDef
        maybeUnion =
            { name = "Maybe"
            , args = [ "a" ]
            , ctors =
                [ { name = "Just", args = [ tVar "a" ] }
                , { name = "Nothing", args = [] }
                ]
            }

        maybeMapDef : TypedDef
        maybeMapDef =
            { name = "maybeMap"
            , args = [ pVar "f", pVar "m" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tType "Maybe" [ tVar "a" ])
                        (tType "Maybe" [ tVar "b" ])
                    )
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Just" [ pVar "x" ]
                      , callExpr (ctorExpr "Just")
                            [ callExpr (varExpr "f") [ varExpr "x" ] ]
                      )
                    , ( pCtor "Nothing" []
                      , ctorExpr "Nothing"
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                caseExpr
                    (callExpr (varExpr "maybeMap")
                        [ lambdaExpr [ pVar "x" ] (varExpr "x")
                        , callExpr (ctorExpr "Just") [ intExpr 1 ]
                        ]
                    )
                    [ ( pCtor "Just" [ pVar "n" ], varExpr "n" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ maybeMapDef, testValueDef ]
                [ maybeUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a program in which a local `f` returns an inner
function `g` that captures `f`'s argument `x` and pairs it with its own argument
`y`. The call `f 1 "a"` makes `x` an integer literal and `y` a `String`, so `g`
is used at `String -> ( number, String )`. The program is:

    testValue =
        let
            f x =
                let
                    g y =
                        ( x, y )
                in
                g
        in
        f 1 "a"

-}
nestedPolymorphicClosures : (Src.Module -> Expectation) -> (() -> Expectation)
nestedPolymorphicClosures expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "f"
                        [ pVar "x" ]
                        (letExpr
                            [ define "g"
                                [ pVar "y" ]
                                (tupleExpr (varExpr "x") (varExpr "y"))
                            ]
                            (varExpr "g")
                        )
                    ]
                    (callExpr
                        (callExpr (varExpr "f") [ intExpr 1 ])
                        [ strExpr "a" ]
                    )
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program that defines a local `flip` and calls it
with a lambda returning its first argument, an integer literal and a string.
`flip` passes its last two arguments to the lambda in reverse order, so the
lambda is used at `String -> number -> String` and the result is the string.
The program is:

    testValue =
        let
            flip f a b =
                f b a
        in
        flip (\x y -> x) 1 "a"

-}
polyFlipMixedTypes : (Src.Module -> Expectation) -> (() -> Expectation)
polyFlipMixedTypes expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "flip"
                        [ pVar "f", pVar "a", pVar "b" ]
                        (callExpr (varExpr "f") [ varExpr "b", varExpr "a" ])
                    ]
                    (callExpr (varExpr "flip")
                        [ lambdaExpr [ pVar "x", pVar "y" ] (varExpr "x")
                        , intExpr 1
                        , strExpr "a"
                        ]
                    )
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program in which a record `r` holds an identity
function in field `f`, and `r2` is `r` with `f` replaced by a function that
adds 1. A record update gives its result the same type as the record it
updates, so `r`'s field `f` takes the replacement's type, `number -> number`,
although the identity itself is never called. The program is:

    testValue =
        let
            r =
                { f = \x -> x, g = 0 }

            r2 =
                { r | f = \y -> y + 1 }
        in
        r2.f 5

-}
recordUpdatePolyNarrowing : (Src.Module -> Expectation) -> (() -> Expectation)
recordUpdatePolyNarrowing expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "r"
                        []
                        (recordExpr
                            [ ( "f", lambdaExpr [ pVar "x" ] (varExpr "x") )
                            , ( "g", intExpr 0 )
                            ]
                        )
                    , define "r2"
                        []
                        (updateExpr (varExpr "r")
                            [ ( "f"
                              , lambdaExpr [ pVar "y" ]
                                    (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 1))
                              )
                            ]
                        )
                    ]
                    (callExpr (accessExpr (varExpr "r2") "f") [ intExpr 5 ])
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program that pairs a local identity function `id`
with an integer literal, takes it out of the pair with a local `first` and
applies it to another integer literal, so `id` is used at `number -> number`.
The program is:

    testValue =
        let
            id x =
                x

            first t =
                case t of
                    ( fst, _ ) ->
                        fst
        in
        first ( id, 0 ) 42

-}
polyFunctionInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
polyFunctionInTuple expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "id" [ pVar "x" ] (varExpr "x")
                    , define "first"
                        [ pVar "t" ]
                        (caseExpr (varExpr "t")
                            [ ( pTuple (pVar "fst") pAnything, varExpr "fst" ) ]
                        )
                    ]
                    (callExpr
                        (callExpr (varExpr "first")
                            [ tupleExpr (varExpr "id") (intExpr 0) ]
                        )
                        [ intExpr 42 ]
                    )
                )
    in
    expectFn modul
