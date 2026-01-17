module Compiler.SpecializeConstructorTests exposing (expectSuite, suite)

{-| Test cases for constructor specialization in Specialize.elm.

These tests cover:

  - specializeNodeContent for Ctor nodes
  - Nullary constructors (True, False, Nothing)
  - Unary constructors (Just x)
  - Multi-field constructors (custom union types)
  - Polymorphic constructor instantiation

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Specialize.elm constructor coverage"
        [ expectSuite expectMonomorphization "monomorphizes constructors"
        ]


{-| Test suite that can be used with different expectation functions.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Constructor specialization " ++ condStr)
        [ nullaryCtorTests expectFn condStr
        , unaryCtorTests expectFn condStr
        , multiFieldCtorTests expectFn condStr
        , polymorphicCtorTests expectFn condStr
        ]



-- ============================================================================
-- NULLARY CONSTRUCTOR TESTS
-- ============================================================================


nullaryCtorTests : (Src.Module -> Expectation) -> String -> Test
nullaryCtorTests expectFn condStr =
    Test.describe ("Nullary constructors " ++ condStr)
        [ Test.test "Custom enum type" <|
            customEnumType expectFn
        , Test.test "Multiple enum constructors in case" <|
            multipleEnumCtorsInCase expectFn
        ]


{-| Custom type with only nullary constructors (enum-like).
Tests specializeNodeContent for Ctor with no fields.
-}
customEnumType : (Src.Module -> Expectation) -> (() -> Expectation)
customEnumType expectFn _ =
    let
        colorUnion : UnionDef
        colorUnion =
            { name = "Color"
            , args = []
            , ctors =
                [ { name = "Red", args = [] }
                , { name = "Green", args = [] }
                , { name = "Blue", args = [] }
                ]
            }

        -- toRgb : Color -> Int
        toRgbDef : TypedDef
        toRgbDef =
            { name = "toRgb"
            , args = [ pVar "color" ]
            , tipe = tLambda (tType "Color" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "color")
                    [ ( pCtor "Red" [], intExpr 0x00FF0000 )
                    , ( pCtor "Green" [], intExpr 0xFF00 )
                    , ( pCtor "Blue" [], intExpr 0xFF )
                    ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "toRgb") [ ctorExpr "Red" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ toRgbDef, testValueDef ]
                [ colorUnion ]
                []
    in
    expectFn modul


{-| Pattern matching on multiple enum constructors.
-}
multipleEnumCtorsInCase : (Src.Module -> Expectation) -> (() -> Expectation)
multipleEnumCtorsInCase expectFn _ =
    let
        directionUnion : UnionDef
        directionUnion =
            { name = "Direction"
            , args = []
            , ctors =
                [ { name = "North", args = [] }
                , { name = "South", args = [] }
                , { name = "East", args = [] }
                , { name = "West", args = [] }
                ]
            }

        -- isVertical : Direction -> Bool
        isVerticalDef : TypedDef
        isVerticalDef =
            { name = "isVertical"
            , args = [ pVar "dir" ]
            , tipe = tLambda (tType "Direction" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "dir")
                    [ ( pCtor "North" [], boolExpr True )
                    , ( pCtor "South" [], boolExpr True )
                    , ( pCtor "East" [], boolExpr False )
                    , ( pCtor "West" [], boolExpr False )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body = callExpr (varExpr "isVertical") [ ctorExpr "North" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ isVerticalDef, testValueDef ]
                [ directionUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- UNARY CONSTRUCTOR TESTS
-- ============================================================================


unaryCtorTests : (Src.Module -> Expectation) -> String -> Test
unaryCtorTests expectFn condStr =
    Test.describe ("Unary constructors " ++ condStr)
        [ Test.test "Single-field wrapper type" <|
            singleFieldWrapper expectFn
        , Test.test "Unary constructor with pattern matching" <|
            unaryCtorPatternMatch expectFn
        ]


{-| Wrapper type with single field.
Tests specializeNodeContent for Ctor with one field.
-}
singleFieldWrapper : (Src.Module -> Expectation) -> (() -> Expectation)
singleFieldWrapper expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors =
                [ { name = "Wrap", args = [ tType "Int" [] ] } ]
            }

        -- unwrap : Wrapper -> Int
        unwrapDef : TypedDef
        unwrapDef =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrapper" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pVar "n" ], varExpr "n" ) ]
            }

        -- testValue : Int
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "unwrap") [ callExpr (ctorExpr "Wrap") [ intExpr 42 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapDef, testValueDef ]
                [ wrapperUnion ]
                []
    in
    expectFn modul


{-| Unary constructor used in pattern matching.
-}
unaryCtorPatternMatch : (Src.Module -> Expectation) -> (() -> Expectation)
unaryCtorPatternMatch expectFn _ =
    let
        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Empty", args = [] }
                , { name = "Full", args = [ tType "Int" [] ] }
                ]
            }

        -- getOrDefault : Box -> Int -> Int
        getOrDefaultDef : TypedDef
        getOrDefaultDef =
            { name = "getOrDefault"
            , args = [ pVar "box", pVar "default" ]
            , tipe = tLambda (tType "Box" []) (tLambda (tType "Int" []) (tType "Int" []))
            , body =
                caseExpr (varExpr "box")
                    [ ( pCtor "Empty" [], varExpr "default" )
                    , ( pCtor "Full" [ pVar "x" ], varExpr "x" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "getOrDefault") [ callExpr (ctorExpr "Full") [ intExpr 10 ], intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getOrDefaultDef, testValueDef ]
                [ boxUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- MULTI-FIELD CONSTRUCTOR TESTS
-- ============================================================================


multiFieldCtorTests : (Src.Module -> Expectation) -> String -> Test
multiFieldCtorTests expectFn condStr =
    Test.describe ("Multi-field constructors " ++ condStr)
        [ Test.test "Constructor with two fields" <|
            twoFieldCtor expectFn
        , Test.test "Constructor with three fields" <|
            threeFieldCtor expectFn
        ]


{-| Custom type with two-field constructor.
-}
twoFieldCtor : (Src.Module -> Expectation) -> (() -> Expectation)
twoFieldCtor expectFn _ =
    let
        pointUnion : UnionDef
        pointUnion =
            { name = "Point"
            , args = []
            , ctors =
                [ { name = "Point", args = [ tType "Int" [], tType "Int" [] ] } ]
            }

        -- getX : Point -> Int
        getXDef : TypedDef
        getXDef =
            { name = "getX"
            , args = [ pVar "p" ]
            , tipe = tLambda (tType "Point" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "p")
                    [ ( pCtor "Point" [ pVar "x", pVar "y" ], varExpr "x" ) ]
            }

        -- getY : Point -> Int
        getYDef : TypedDef
        getYDef =
            { name = "getY"
            , args = [ pVar "p" ]
            , tipe = tLambda (tType "Point" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "p")
                    [ ( pCtor "Point" [ pVar "x", pVar "y" ], varExpr "y" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                binopsExpr
                    [ ( callExpr (varExpr "getX") [ callExpr (ctorExpr "Point") [ intExpr 3, intExpr 4 ] ], "+" ) ]
                    (callExpr (varExpr "getY") [ callExpr (ctorExpr "Point") [ intExpr 3, intExpr 4 ] ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ getXDef, getYDef, testValueDef ]
                [ pointUnion ]
                []
    in
    expectFn modul


{-| Custom type with three-field constructor.
-}
threeFieldCtor : (Src.Module -> Expectation) -> (() -> Expectation)
threeFieldCtor expectFn _ =
    let
        vectorUnion : UnionDef
        vectorUnion =
            { name = "Vector3"
            , args = []
            , ctors =
                [ { name = "Vec3", args = [ tType "Int" [], tType "Int" [], tType "Int" [] ] } ]
            }

        -- magnitude : Vector3 -> Int (simplified to sum for testing)
        magnitudeDef : TypedDef
        magnitudeDef =
            { name = "magnitude"
            , args = [ pVar "v" ]
            , tipe = tLambda (tType "Vector3" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "v")
                    [ ( pCtor "Vec3" [ pVar "x", pVar "y", pVar "z" ]
                      , binopsExpr
                            [ ( varExpr "x", "+" )
                            , ( varExpr "y", "+" )
                            ]
                            (varExpr "z")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "magnitude") [ callExpr (ctorExpr "Vec3") [ intExpr 1, intExpr 2, intExpr 3 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ magnitudeDef, testValueDef ]
                [ vectorUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC CONSTRUCTOR TESTS
-- ============================================================================


polymorphicCtorTests : (Src.Module -> Expectation) -> String -> Test
polymorphicCtorTests expectFn condStr =
    Test.describe ("Polymorphic constructors " ++ condStr)
        [ Test.test "Polymorphic wrapper type" <|
            polymorphicWrapper expectFn
        , Test.test "Either-like polymorphic type" <|
            eitherLikeType expectFn
        ]


{-| Polymorphic wrapper type (like Identity).
Tests constructor instantiation with type variables.
-}
polymorphicWrapper : (Src.Module -> Expectation) -> (() -> Expectation)
polymorphicWrapper expectFn _ =
    let
        identityUnion : UnionDef
        identityUnion =
            { name = "Identity"
            , args = [ "a" ]
            , ctors =
                [ { name = "Identity", args = [ tVar "a" ] } ]
            }

        -- runIdentity : Identity a -> a
        runIdentityDef : TypedDef
        runIdentityDef =
            { name = "runIdentity"
            , args = [ pVar "id" ]
            , tipe = tLambda (tType "Identity" [ tVar "a" ]) (tVar "a")
            , body =
                caseExpr (varExpr "id")
                    [ ( pCtor "Identity" [ pVar "x" ], varExpr "x" ) ]
            }

        -- testValue : Int (uses Identity Int)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "runIdentity") [ callExpr (ctorExpr "Identity") [ intExpr 99 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ runIdentityDef, testValueDef ]
                [ identityUnion ]
                []
    in
    expectFn modul


{-| Either-like type with two type parameters.
Tests multi-parameter polymorphic constructors.
-}
eitherLikeType : (Src.Module -> Expectation) -> (() -> Expectation)
eitherLikeType expectFn _ =
    let
        eitherUnion : UnionDef
        eitherUnion =
            { name = "Either"
            , args = [ "a", "b" ]
            , ctors =
                [ { name = "Left", args = [ tVar "a" ] }
                , { name = "Right", args = [ tVar "b" ] }
                ]
            }

        -- fromLeft : Either a b -> a -> a
        fromLeftDef : TypedDef
        fromLeftDef =
            { name = "fromLeft"
            , args = [ pVar "e", pVar "default" ]
            , tipe = tLambda (tType "Either" [ tVar "a", tVar "b" ]) (tLambda (tVar "a") (tVar "a"))
            , body =
                caseExpr (varExpr "e")
                    [ ( pCtor "Left" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Right" [ pVar "_" ], varExpr "default" )
                    ]
            }

        -- testValue : Int (uses Either Int String)
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "fromLeft") [ callExpr (ctorExpr "Left") [ intExpr 42 ], intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ fromLeftDef, testValueDef ]
                [ eitherUnion ]
                []
    in
    expectFn modul
