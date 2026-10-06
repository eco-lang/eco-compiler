module SourceIR.SpecializeConstructorCases exposing (expectSuite, suite)

{-| Source programs that declare their own custom types and both build and
pattern match on their constructors, so that a pipeline stage is run over
constructors of these shapes: with no fields, with one field, with several,
with type parameters, and with a field whose type is a parameterised type
alias. A stage that mishandles one of those shapes, for example when
monomorphization gives a constructor its concrete field types, then fails on a
small program built around that shape.

The module asserts nothing itself. Each case builds one module, named `Test`,
with `Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`: a few
annotated top-level functions, the custom types and aliases they use, and an
annotated top-level `testValue` that calls those functions on values built
with the constructors. It then hands the module to the expectation function
the caller supplies, which decides what is checked. `expectSuite` runs all
twelve cases inside one test with `Compiler.BulkCheck.bulkCheck`, and `suite`
supplies `TestLogic.TestPipeline.expectMonomorphization`. Under `suite`, the
test pipeline appends a `main` that binds `testValue`, and monomorphization
starts from that `main`, so each function is specialized only as `testValue`
uses it.

The cases, by group:

  - Constructors with no fields: a three-constructor enum `Color` and a
    four-constructor enum `Direction`, each matched in full by a function that
    `testValue` applies to one constructor.
  - Constructors with one field: an `Int` wrapper, a `Bool` wrapper whose
    unwrapped value is matched against `True` and `False`, and a type `Box`
    with one constructor without fields and one with an `Int` field.
  - Constructors with several fields: a two-field `Point` and a three-field
    `Vec3`.
  - Constructors with type parameters: `Identity a`, `Either a b`, and three
    types whose single constructor's field is an alias applied to the type's
    own parameter (`Pair b`, `Id x` and `Opt b`). The alias's formal parameter
    has a different name from the type's parameter, so it can only be resolved
    through the alias, not among the type's own variables; the monomorphizer
    does this with `Compiler.Monomorphize.Analysis.convertCanTypeNameToMVarId`.

Among what is not tested: the value any `testValue` would compute, since no
case evaluates it; a phantom alias, one whose body does not mention its
parameter, which canonicalization rejects (`TypeVarsMessedUpInAlias`), as Elm
does; an alias with more than one parameter in a constructor field; record and recursive constructor fields; and
under `suite`, the bootstrap Stage 5 (substitution engine) pipeline, since
`expectMonomorphization` runs the production default.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pTuple
        , pVar
        , tLambda
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| The twelve cases run as one test against
`TestLogic.TestPipeline.expectMonomorphization`, which passes when a module
compiles through monomorphization, under the production pipeline, to a graph with
a `main` and at least one node.
-}
suite : Test
suite =
    Test.describe "Specialize.elm constructor coverage"
        [ expectSuite expectMonomorphization "monomorphizes constructors"
        ]


{-| Creates one test, named "Constructor specialization " followed by
`condStr`, that applies `expectFn` to each case's module in turn. It stops at
the first case that fails and reports that case's label, as
`Compiler.BulkCheck.bulkCheck` describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Constructor specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each checked with `expectFn`: those without fields,
then one field, then several fields, then type parameters.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ nullaryCtorCases expectFn
        , unaryCtorCases expectFn
        , multiFieldCtorCases expectFn
        , polymorphicCtorCases expectFn
        ]



-- ============================================================================
-- NULLARY CONSTRUCTOR TESTS
-- ============================================================================


{-| Returns the cases whose custom types have only constructors without
fields, checked with `expectFn`.
-}
nullaryCtorCases : (Src.Module -> Expectation) -> List TestCase
nullaryCtorCases expectFn =
    [ { label = "Custom enum type", run = customEnumType expectFn }
    , { label = "Multiple enum constructors in case", run = multipleEnumCtorsInCase expectFn }
    ]


{-| Applies `expectFn` to a module that maps a three-constructor enum to an
`Int`:

    type Color
        = Red
        | Green
        | Blue

    toRgb : Color -> Int
    toRgb color =
        case color of
            Red ->
                16711680

            Green ->
                65280

            Blue ->
                255

    testValue : Int
    testValue =
        toRgb Red

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


{-| Applies `expectFn` to a module that matches every constructor of a
four-constructor enum, each in its own branch:

    type Direction
        = North
        | South
        | East
        | West

    isVertical : Direction -> Bool
    isVertical dir =
        case dir of
            North ->
                True

            South ->
                True

            East ->
                False

            West ->
                False

    testValue : Bool
    testValue =
        isVertical North

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


{-| Returns the cases whose custom types have a constructor with one field,
checked with `expectFn`.
-}
unaryCtorCases : (Src.Module -> Expectation) -> List TestCase
unaryCtorCases expectFn =
    [ { label = "Single-field wrapper type", run = singleFieldWrapper expectFn }
    , { label = "Bool wrapper type", run = boolWrapperType expectFn }
    , { label = "Unary constructor with pattern matching", run = unaryCtorPatternMatch expectFn }
    ]


{-| Applies `expectFn` to a module that wraps an `Int` in a one-constructor
type and unwraps it again:

    type Wrapper
        = Wrap Int

    unwrap : Wrapper -> Int
    unwrap w =
        case w of
            Wrap n ->
                n

    testValue : Int
    testValue =
        unwrap (Wrap 42)

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

        unwrapDef : TypedDef
        unwrapDef =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrapper" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pVar "n" ], varExpr "n" ) ]
            }

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


{-| Applies `expectFn` to a module that stores a `Bool` in a constructor
field, takes it out again, and matches it against `True` and `False`:

    type BoolWrapper
        = WrapBool Bool

    boolToInt : Bool -> Int
    boolToInt b =
        case b of
            True ->
                1

            False ->
                0

    unwrapBool : BoolWrapper -> Bool
    unwrapBool w =
        case w of
            WrapBool b ->
                b

    testValue : Int
    testValue =
        boolToInt (unwrapBool (WrapBool True))

The program passes the `Bool` through a constructor field and a function
argument and result, places where the MLIR back end represents a `Bool` boxed
rather than as an `i1`, as `Compiler.Generate.MLIR.Types` describes. Whether
that representation is checked depends on `expectFn`.

-}
boolWrapperType : (Src.Module -> Expectation) -> (() -> Expectation)
boolWrapperType expectFn _ =
    let
        boolWrapperUnion : UnionDef
        boolWrapperUnion =
            { name = "BoolWrapper"
            , args = []
            , ctors =
                [ { name = "WrapBool", args = [ tType "Bool" [] ] } ]
            }

        unwrapBoolDef : TypedDef
        unwrapBoolDef =
            { name = "unwrapBool"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "BoolWrapper" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapBool" [ pVar "b" ], varExpr "b" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "boolToInt")
                    [ callExpr (varExpr "unwrapBool")
                        [ callExpr (ctorExpr "WrapBool") [ boolExpr True ] ]
                    ]
            }

        boolToIntDef : TypedDef
        boolToIntDef =
            { name = "boolToInt"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Bool" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "True" [], intExpr 1 )
                    , ( pCtor "False" [], intExpr 0 )
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ boolToIntDef, unwrapBoolDef, testValueDef ]
                [ boolWrapperUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module whose type has one constructor without
fields and one with an `Int` field, both matched:

    type Box
        = Empty
        | Full Int

    getOrDefault : Box -> Int -> Int
    getOrDefault box default =
        case box of
            Empty ->
                default

            Full x ->
                x

    testValue : Int
    testValue =
        getOrDefault (Full 10) 0

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


{-| Returns the cases whose custom types have a constructor with several
fields, checked with `expectFn`.
-}
multiFieldCtorCases : (Src.Module -> Expectation) -> List TestCase
multiFieldCtorCases expectFn =
    [ { label = "Constructor with two fields", run = twoFieldCtor expectFn }
    , { label = "Constructor with three fields", run = threeFieldCtor expectFn }
    ]


{-| Applies `expectFn` to a module that builds a two-field constructor twice
and reads each field with its own match:

    type Point
        = Point Int Int

    getX : Point -> Int
    getX p =
        case p of
            Point x y ->
                x

    getY : Point -> Int
    getY p =
        case p of
            Point x y ->
                y

    testValue : Int
    testValue =
        getX (Point 3 4) + getY (Point 3 4)

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

        getXDef : TypedDef
        getXDef =
            { name = "getX"
            , args = [ pVar "p" ]
            , tipe = tLambda (tType "Point" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "p")
                    [ ( pCtor "Point" [ pVar "x", pVar "y" ], varExpr "x" ) ]
            }

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


{-| Applies `expectFn` to a module that builds a three-field constructor and
adds its fields together in one match:

    type Vector3
        = Vec3 Int Int Int

    magnitude : Vector3 -> Int
    magnitude v =
        case v of
            Vec3 x y z ->
                x + y + z

    testValue : Int
    testValue =
        magnitude (Vec3 1 2 3)

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


{-| Returns the cases whose custom types have type parameters, checked with
`expectFn`.
-}
polymorphicCtorCases : (Src.Module -> Expectation) -> List TestCase
polymorphicCtorCases expectFn =
    [ { label = "Polymorphic wrapper type", run = polymorphicWrapper expectFn }
    , { label = "Either-like polymorphic type", run = eitherLikeType expectFn }
    , { label = "Ctor field referencing parameterized alias (Pair)", run = ctorFieldReferencingPairAlias expectFn }
    , { label = "Ctor field referencing identity alias", run = ctorFieldReferencingIdAlias expectFn }
    , { label = "Ctor field referencing alias of Maybe", run = ctorFieldReferencingMaybeAlias expectFn }
    ]


{-| Applies `expectFn` to a module whose constructor field is a one-parameter
alias applied to the type's own parameter, where the alias's parameter has a
different name:

    type alias Opt a =
        Maybe a

    type Marker b
        = Marker (Opt b)

    unmark : Marker Int -> Int
    unmark m =
        case m of
            Marker (Just n) ->
                n

            Marker Nothing ->
                0

    testValue : Int
    testValue =
        unmark (Marker (Just 5))

What it adds to the `Pair` and `Id` alias cases is the parameter sitting inside
`Maybe`, and a match on nested constructors.

-}
ctorFieldReferencingMaybeAlias : (Src.Module -> Expectation) -> (() -> Expectation)
ctorFieldReferencingMaybeAlias expectFn _ =
    let
        optAlias : AliasDef
        optAlias =
            { name = "Opt"
            , args = [ "a" ]
            , tipe = tType "Maybe" [ tVar "a" ]
            }

        markerUnion : UnionDef
        markerUnion =
            { name = "Marker"
            , args = [ "b" ]
            , ctors =
                [ { name = "Marker", args = [ tType "Opt" [ tVar "b" ] ] } ]
            }

        unmarkDef : TypedDef
        unmarkDef =
            { name = "unmark"
            , args = [ pVar "m" ]
            , tipe = tLambda (tType "Marker" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Marker" [ pCtor "Just" [ pVar "n" ] ], varExpr "n" )
                    , ( pCtor "Marker" [ pCtor "Nothing" [] ], intExpr 0 )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "unmark")
                    [ callExpr (ctorExpr "Marker") [ callExpr (ctorExpr "Just") [ intExpr 5 ] ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unmarkDef, testValueDef ]
                [ markerUnion ]
                [ optAlias ]
    in
    expectFn modul


{-| Applies `expectFn` to a module whose constructor field is a pair alias
applied to the type's own parameter, where the alias's parameter has a
different name:

    type alias Pair a =
        ( a, a )

    type Box b
        = Box (Pair b)

    firstOfBox : Box Int -> Int
    firstOfBox box =
        case box of
            Box ( x, y ) ->
                x

    testValue : Int
    testValue =
        firstOfBox (Box ( 1, 2 ))

The alias's body uses its parameter `a`, which is not among `Box`'s type
variables, so converting the field type must resolve `a` through the alias.

-}
ctorFieldReferencingPairAlias : (Src.Module -> Expectation) -> (() -> Expectation)
ctorFieldReferencingPairAlias expectFn _ =
    let
        pairAlias : AliasDef
        pairAlias =
            { name = "Pair"
            , args = [ "a" ]
            , tipe = tTuple (tVar "a") (tVar "a")
            }

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = [ "b" ]
            , ctors =
                [ { name = "Box", args = [ tType "Pair" [ tVar "b" ] ] } ]
            }

        firstOfBoxDef : TypedDef
        firstOfBoxDef =
            { name = "firstOfBox"
            , args = [ pVar "box" ]
            , tipe = tLambda (tType "Box" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "box")
                    [ ( pCtor "Box" [ pTuple (pVar "x") (pVar "y") ]
                      , varExpr "x"
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "firstOfBox")
                    [ callExpr (ctorExpr "Box") [ tupleExpr (intExpr 1) (intExpr 2) ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ firstOfBoxDef, testValueDef ]
                [ boxUnion ]
                [ pairAlias ]
    in
    expectFn modul


{-| Applies `expectFn` to a module whose constructor field is an identity
alias applied to the type's own parameter, where the alias's parameter has a
different name:

    type alias Id a =
        a

    type Wrap x
        = Wrap (Id x)

    unwrap : Wrap Int -> Int
    unwrap w =
        case w of
            Wrap n ->
                n

    testValue : Int
    testValue =
        unwrap (Wrap 7)

-}
ctorFieldReferencingIdAlias : (Src.Module -> Expectation) -> (() -> Expectation)
ctorFieldReferencingIdAlias expectFn _ =
    let
        idAlias : AliasDef
        idAlias =
            { name = "Id"
            , args = [ "a" ]
            , tipe = tVar "a"
            }

        wrapUnion : UnionDef
        wrapUnion =
            { name = "Wrap"
            , args = [ "x" ]
            , ctors =
                [ { name = "Wrap", args = [ tType "Id" [ tVar "x" ] ] } ]
            }

        unwrapDef : TypedDef
        unwrapDef =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrap" [ tType "Int" [] ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pVar "n" ], varExpr "n" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (varExpr "unwrap")
                    [ callExpr (ctorExpr "Wrap") [ intExpr 7 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapDef, testValueDef ]
                [ wrapUnion ]
                [ idAlias ]
    in
    expectFn modul


{-| Applies `expectFn` to a module with a one-parameter wrapper type, unwrapped
by a polymorphic function that is called at `Int`:

    type Identity a
        = Identity a

    runIdentity : Identity a -> a
    runIdentity id =
        case id of
            Identity x ->
                x

    testValue : Int
    testValue =
        runIdentity (Identity 99)

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

        runIdentityDef : TypedDef
        runIdentityDef =
            { name = "runIdentity"
            , args = [ pVar "id" ]
            , tipe = tLambda (tType "Identity" [ tVar "a" ]) (tVar "a")
            , body =
                caseExpr (varExpr "id")
                    [ ( pCtor "Identity" [ pVar "x" ], varExpr "x" ) ]
            }

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


{-| Applies `expectFn` to a module with a two-parameter type whose
constructors each carry one of the parameters:

    type Either a b
        = Left a
        | Right b

    fromLeft : Either a b -> a -> a
    fromLeft e default =
        case e of
            Left x ->
                x

            Right _ ->
                default

    testValue : Int
    testValue =
        fromLeft (Left 42) 0

The call fixes `a` to `Int` and leaves `b` unconstrained. The `_` in the
`Right` pattern is built as a variable named `_`, not as a wildcard pattern.

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
