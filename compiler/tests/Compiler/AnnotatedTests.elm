module Compiler.AnnotatedTests exposing (expectSuite)

{-| Tests for type-annotated definitions with polymorphic type variables.

These tests are designed to verify that type inference works correctly
when type annotations with polymorphic type variables are present.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , callExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Annotated definitions " ++ condStr)
        [ basicAnnotatedTests expectFn condStr
        , polymorphicTests expectFn condStr
        , higherOrderAnnotatedTests expectFn condStr
        , multipleTypeVarTests expectFn condStr
        , recordTypeTests expectFn condStr
        , tupleTypeTests expectFn condStr
        ]



-- ============================================================================
-- BASIC ANNOTATED DEFINITIONS
-- ============================================================================


basicAnnotatedTests : (Src.Module -> Expectation) -> String -> Test
basicAnnotatedTests expectFn condStr =
    Test.describe ("Basic annotated definitions " ++ condStr)
        [ Test.test ("Identity with annotation " ++ condStr) (identityAnnotated expectFn)
        , Test.test ("Const with annotation " ++ condStr) (constAnnotated expectFn)
        , Test.test ("Bool identity " ++ condStr) (boolIdentity expectFn)
        ]


{-| identity : a -> a
identity x = x
-}
identityAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
identityAnnotated expectFn _ =
    let
        -- Type: a -> a
        tipe =
            tLambda (tVar "a") (tVar "a")

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "identity"
                  , args = [ pVar "x" ]
                  , tipe = tipe
                  , body = varExpr "x"
                  }
                ]
    in
    expectFn modul


{-| const : a -> b -> a
const x y = x
-}
constAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
constAnnotated expectFn _ =
    let
        -- Type: a -> b -> a
        tipe =
            tLambda (tVar "a") (tLambda (tVar "b") (tVar "a"))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "const"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body = varExpr "x"
                  }
                ]
    in
    expectFn modul


{-| boolIdentity : Bool -> Bool
boolIdentity x = x
-}
boolIdentity : (Src.Module -> Expectation) -> (() -> Expectation)
boolIdentity expectFn _ =
    let
        -- Type: Bool -> Bool
        tipe =
            tLambda (tType "Bool" []) (tType "Bool" [])

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "boolIdentity"
                  , args = [ pVar "x" ]
                  , tipe = tipe
                  , body = varExpr "x"
                  }
                ]
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC FUNCTION TESTS
-- ============================================================================


polymorphicTests : (Src.Module -> Expectation) -> String -> Test
polymorphicTests expectFn condStr =
    Test.describe ("Polymorphic functions " ++ condStr)
        [ Test.test ("Apply function " ++ condStr) (applyAnnotated expectFn)
        , Test.test ("Apply with usage " ++ condStr) (applyWithUsage expectFn)
        , Test.test ("Flip function " ++ condStr) (flipAnnotated expectFn)
        ]


{-| apply : (a -> b) -> a -> b
apply f x = f x
-}
applyAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
applyAnnotated expectFn _ =
    let
        -- Type: (a -> b) -> a -> b
        tipe =
            tLambda (tLambda (tVar "a") (tVar "b"))
                (tLambda (tVar "a") (tVar "b"))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "apply"
                  , args = [ pVar "f", pVar "x" ]
                  , tipe = tipe
                  , body = callExpr (varExpr "f") [ varExpr "x" ]
                  }
                ]
    in
    expectFn modul


{-| apply : (a -> b) -> a -> b
apply f x = f x

test = apply (\\n -> n) True

-}
applyWithUsage : (Src.Module -> Expectation) -> (() -> Expectation)
applyWithUsage expectFn _ =
    let
        -- apply : (a -> b) -> a -> b
        applyType =
            tLambda (tLambda (tVar "a") (tVar "b"))
                (tLambda (tVar "a") (tVar "b"))

        -- test : Bool
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
                ]
    in
    expectFn modul


{-| flip : (a -> b -> c) -> b -> a -> c
flip f y x = f x y
-}
flipAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
flipAnnotated expectFn _ =
    let
        -- Type: (a -> b -> c) -> b -> a -> c
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
                ]
    in
    expectFn modul



-- ============================================================================
-- HIGHER-ORDER ANNOTATED FUNCTIONS
-- ============================================================================


higherOrderAnnotatedTests : (Src.Module -> Expectation) -> String -> Test
higherOrderAnnotatedTests expectFn condStr =
    Test.describe ("Higher-order annotated functions " ++ condStr)
        [ Test.test ("Compose " ++ condStr) (composeAnnotated expectFn)
        , Test.test ("Compose with usage " ++ condStr) (composeWithUsage expectFn)
        , Test.test ("On function " ++ condStr) (onAnnotated expectFn)
        ]


{-| compose : (b -> c) -> (a -> b) -> a -> c
compose f g x = f (g x)
-}
composeAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
composeAnnotated expectFn _ =
    let
        -- Type: (b -> c) -> (a -> b) -> a -> c
        tipe =
            tLambda (tLambda (tVar "b") (tVar "c"))
                (tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tVar "a") (tVar "c"))
                )

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "compose"
                  , args = [ pVar "f", pVar "g", pVar "x" ]
                  , tipe = tipe
                  , body = callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ]
                  }
                ]
    in
    expectFn modul


{-| compose : (b -> c) -> (a -> b) -> a -> c
compose f g x = f (g x)

test = compose (\\x -> x) (\\y -> y) True

-}
composeWithUsage : (Src.Module -> Expectation) -> (() -> Expectation)
composeWithUsage expectFn _ =
    let
        -- compose : (b -> c) -> (a -> b) -> a -> c
        composeType =
            tLambda (tLambda (tVar "b") (tVar "c"))
                (tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tVar "a") (tVar "c"))
                )

        -- test : Bool
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
                ]
    in
    expectFn modul


{-| on : (b -> b -> c) -> (a -> b) -> a -> a -> c
on f g x y = f (g x) (g y)
-}
onAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
onAnnotated expectFn _ =
    let
        -- Type: (b -> b -> c) -> (a -> b) -> a -> a -> c
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
                ]
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE TYPE VARIABLE TESTS
-- ============================================================================


multipleTypeVarTests : (Src.Module -> Expectation) -> String -> Test
multipleTypeVarTests expectFn condStr =
    Test.describe ("Multiple type variables " ++ condStr)
        [ Test.test ("Pair function " ++ condStr) (pairAnnotated expectFn)
        , Test.test ("Wrap in tuple " ++ condStr) (wrapInTupleAnnotated expectFn)
        , Test.test ("Make pair " ++ condStr) (makePairAnnotated expectFn)
        , Test.test ("Const tuple " ++ condStr) (constTupleAnnotated expectFn)
        ]


{-| pair : a -> b -> ( a, b )
pair x y = ( x, y )
-}
pairAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
pairAnnotated expectFn _ =
    let
        -- Type: a -> b -> ( a, b )
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
                ]
    in
    expectFn modul


{-| wrapInTuple : a -> ( a, a )
wrapInTuple x = ( x, x )
-}
wrapInTupleAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
wrapInTupleAnnotated expectFn _ =
    let
        -- Type: a -> ( a, a )
        tipe =
            tLambda (tVar "a") (tTuple (tVar "a") (tVar "a"))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "wrapInTuple"
                  , args = [ pVar "x" ]
                  , tipe = tipe
                  , body = tupleExpr (varExpr "x") (varExpr "x")
                  }
                ]
    in
    expectFn modul


{-| makePair : a -> b -> ( a, b )
makePair x y = ( x, y )
-}
makePairAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
makePairAnnotated expectFn _ =
    let
        -- Type: a -> b -> ( a, b )
        tipe =
            tLambda (tVar "a") (tLambda (tVar "b") (tTuple (tVar "a") (tVar "b")))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "makePair"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body = tupleExpr (varExpr "x") (varExpr "y")
                  }
                ]
    in
    expectFn modul


{-| constTuple : a -> b -> ( a, a )
constTuple x y = ( x, x )
-}
constTupleAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
constTupleAnnotated expectFn _ =
    let
        -- Type: a -> b -> ( a, a )
        tipe =
            tLambda (tVar "a") (tLambda (tVar "b") (tTuple (tVar "a") (tVar "a")))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "constTuple"
                  , args = [ pVar "x", pVar "y" ]
                  , tipe = tipe
                  , body = tupleExpr (varExpr "x") (varExpr "x")
                  }
                ]
    in
    expectFn modul



-- ============================================================================
-- RECORD TYPE TESTS
-- ============================================================================


recordTypeTests : (Src.Module -> Expectation) -> String -> Test
recordTypeTests expectFn condStr =
    Test.describe ("Record types " ++ condStr)
        [ Test.test ("Make record " ++ condStr) (makeRecordAnnotated expectFn)
        , Test.test ("Make record with same type " ++ condStr) (makeRecordSameTypeAnnotated expectFn)
        ]


{-| makeXY : a -> b -> { x : a, y : b }
makeXY x y = { x = x, y = y }
-}
makeRecordAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
makeRecordAnnotated expectFn _ =
    let
        -- Type: a -> b -> { x : a, y : b }
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
                ]
    in
    expectFn modul


{-| makeSame : a -> { x : a, y : a }
makeSame val = { x = val, y = val }
-}
makeRecordSameTypeAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
makeRecordSameTypeAnnotated expectFn _ =
    let
        -- Type: a -> { x : a, y : a }
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
                ]
    in
    expectFn modul



-- ============================================================================
-- TUPLE TYPE TESTS
-- ============================================================================


tupleTypeTests : (Src.Module -> Expectation) -> String -> Test
tupleTypeTests expectFn condStr =
    Test.describe ("Tuple types " ++ condStr)
        [ Test.test ("Duplicate " ++ condStr) (duplicateAnnotated expectFn)
        , Test.test ("Nest tuple " ++ condStr) (nestTupleAnnotated expectFn)
        ]


{-| duplicate : a -> ( a, a )
duplicate x = ( x, x )
-}
duplicateAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
duplicateAnnotated expectFn _ =
    let
        -- Type: a -> ( a, a )
        tipe =
            tLambda (tVar "a") (tTuple (tVar "a") (tVar "a"))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "duplicate"
                  , args = [ pVar "x" ]
                  , tipe = tipe
                  , body = tupleExpr (varExpr "x") (varExpr "x")
                  }
                ]
    in
    expectFn modul


{-| nest : a -> b -> ( ( a, b ), ( b, a ) )
nest x y = ( ( x, y ), ( y, x ) )
-}
nestTupleAnnotated : (Src.Module -> Expectation) -> (() -> Expectation)
nestTupleAnnotated expectFn _ =
    let
        -- Type: a -> b -> ( ( a, b ), ( b, a ) )
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
                ]
    in
    expectFn modul
