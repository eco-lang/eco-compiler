module SourceIR.PolyEscapeCases exposing (expectSuite)

{-| Tests for polymorphic TVar escape through monomorphization (MONO\_021).

These tests are designed to expose cases where polymorphic type variables
might escape through monomorphization. They cover scenarios where polymorphic
functions are stored in data structures, passed through nested closures with
different types, or used through higher-order combinators with mixed types.

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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Polymorphic TVar escape " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Polymorphic identity in record field", run = polyIdentityInRecordField expectFn }
    , { label = "Polymorphic lambda in local Maybe.map", run = lambdaInMaybeMap expectFn }
    , { label = "Nested polymorphic closures with different types", run = nestedPolymorphicClosures expectFn }
    , { label = "Polymorphic flip with mixed types", run = polyFlipMixedTypes expectFn }
    , { label = "Record update narrowing polymorphic field", run = recordUpdatePolyNarrowing expectFn }
    , { label = "Polymorphic function extracted from tuple", run = polyFunctionInTuple expectFn }
    ]



-- ============================================================================
-- 1. Polymorphic identity in record field
-- ============================================================================


{-| A polymorphic identity lambda stored in a record field must be specialized
to Int -> Int when the field is accessed and applied to an Int.

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



-- ============================================================================
-- 2. Polymorphic lambda in local Maybe.map
-- ============================================================================


{-| A polymorphic identity lambda passed to a locally-defined Maybe.map
must be specialized to Int -> Int when applied to Just 1.

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



-- ============================================================================
-- 3. Nested polymorphic closures with different types
-- ============================================================================


{-| Inner closure g captures x from outer f. When f 1 "a" is called,
x is Int and y is String, so g must be specialized to String -> (Int, String).

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



-- ============================================================================
-- 4. Polymorphic flip with mixed types
-- ============================================================================


{-| flip has type (a -> b -> c) -> b -> a -> c. When called with
(\\x y -> x), 1, and "a", all three type vars must specialize:
a=String, b=Int, c=String.

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



-- ============================================================================
-- 5. Record update narrowing polymorphic field
-- ============================================================================


{-| Record r has polymorphic field f = \\x -> x. A record update replaces f
with the concrete \\y -> y + 1, forcing the polymorphic TVar to specialize
to Int through the record update unification.

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



-- ============================================================================
-- 6. Polymorphic function extracted from tuple
-- ============================================================================


{-| A polymorphic identity function is stored in a tuple alongside an Int,
extracted via a local first function, then applied. The monomorphizer must
specialize id through the tuple storage to Int -> Int.

    testValue =
        let
            id x =
                x

            first t =
                case t of
                    ( a, b ) ->
                        a
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
