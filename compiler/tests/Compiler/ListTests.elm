module Compiler.ListTests exposing (expectSuite, testCases)

{-| Tests for list expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefs
        , pCtor
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("List expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    emptyListCases expectFn
        ++ singleElementCases expectFn
        ++ multipleElementCases expectFn
        ++ nestedListCases expectFn
        ++ mixedTypeCases expectFn
        ++ knownListFailsCases expectFn



-- ============================================================================
-- EMPTY LIST
-- ============================================================================


emptyListCases : (Src.Module -> Expectation) -> List TestCase
emptyListCases expectFn =
    [ { label = "Empty list", run = emptyList expectFn }
    ]


emptyList : (Src.Module -> Expectation) -> (() -> Expectation)
emptyList expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [])
    in
    expectFn modul



-- ============================================================================
-- SINGLE ELEMENT
-- ============================================================================


singleElementCases : (Src.Module -> Expectation) -> List TestCase
singleElementCases expectFn =
    [ { label = "Single int list", run = singleIntList expectFn }
    ]


singleIntList : (Src.Module -> Expectation) -> (() -> Expectation)
singleIntList expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 42 ])
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE ELEMENTS
-- ============================================================================


multipleElementCases : (Src.Module -> Expectation) -> List TestCase
multipleElementCases expectFn =
    [ { label = "Three-element int list", run = threeElementIntList expectFn }
    ]


threeElementIntList : (Src.Module -> Expectation) -> (() -> Expectation)
threeElementIntList expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 1, intExpr 2, intExpr 3 ])
    in
    expectFn modul



-- ============================================================================
-- NESTED LISTS
-- ============================================================================


nestedListCases : (Src.Module -> Expectation) -> List TestCase
nestedListCases expectFn =
    [ { label = "List of lists", run = listOfLists expectFn }
    , { label = "Deeply nested list", run = deeplyNestedList expectFn }
    , { label = "List of tuples", run = listOfTuples expectFn }
    , { label = "List of records", run = listOfRecords expectFn }
    ]


listOfLists : (Src.Module -> Expectation) -> (() -> Expectation)
listOfLists expectFn _ =
    let
        inner1 =
            listExpr [ intExpr 1, intExpr 2 ]

        inner2 =
            listExpr [ intExpr 3, intExpr 4 ]

        modul =
            makeModule "testValue" (listExpr [ inner1, inner2 ])
    in
    expectFn modul


deeplyNestedList : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedList expectFn _ =
    let
        inner =
            listExpr [ intExpr 1 ]

        level2 =
            listExpr [ inner ]

        level3 =
            listExpr [ level2 ]

        modul =
            makeModule "testValue" level3
    in
    expectFn modul


listOfTuples : (Src.Module -> Expectation) -> (() -> Expectation)
listOfTuples expectFn _ =
    let
        tuple1 =
            tupleExpr (intExpr 1) (strExpr "a")

        tuple2 =
            tupleExpr (intExpr 2) (strExpr "b")

        modul =
            makeModule "testValue" (listExpr [ tuple1, tuple2 ])
    in
    expectFn modul


listOfRecords : (Src.Module -> Expectation) -> (() -> Expectation)
listOfRecords expectFn _ =
    let
        rec1 =
            recordExpr [ ( "x", intExpr 1 ) ]

        rec2 =
            recordExpr [ ( "x", intExpr 2 ) ]

        modul =
            makeModule "testValue" (listExpr [ rec1, rec2 ])
    in
    expectFn modul



-- ============================================================================
-- MIXED TYPES
-- ============================================================================


mixedTypeCases : (Src.Module -> Expectation) -> List TestCase
mixedTypeCases expectFn =
    [ { label = "List of int tuples", run = listOfIntTuples expectFn }
    , { label = "List of records with multiple fields", run = listOfRecordsMultipleFields expectFn }
    ]


listOfIntTuples : (Src.Module -> Expectation) -> (() -> Expectation)
listOfIntTuples expectFn _ =
    let
        modul =
            makeModule "testValue"
                (listExpr
                    [ tupleExpr (intExpr 1) (intExpr 2)
                    , tupleExpr (intExpr 3) (intExpr 4)
                    ]
                )
    in
    expectFn modul


listOfRecordsMultipleFields : (Src.Module -> Expectation) -> (() -> Expectation)
listOfRecordsMultipleFields expectFn _ =
    let
        modul =
            makeModule "testValue"
                (listExpr
                    [ recordExpr [ ( "x", intExpr 1 ), ( "y", strExpr "a" ) ]
                    , recordExpr [ ( "x", intExpr 2 ), ( "y", strExpr "b" ) ]
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- List Failure Tests
-- ============================================================================
-- These tests exercise the exact type generalization patterns that fail
-- in elm/core List.elm. The function bodies are copied verbatim from List.elm.


{-| Test suite for exact List.elm functions that fail type checking.
-}
knownListFailsCases : (Src.Module -> Expectation) -> List TestCase
knownListFailsCases expectFn =
    [ { label = "concatMap", run = testConcatMap expectFn }
    , { label = "indexedMap", run = testIndexedMap expectFn }
    , { label = "filter", run = testFilter expectFn }
    , { label = "filterMap", run = testFilterMap expectFn }
    ]


{-| concatMap : (a -> List b) -> List a -> List b
concatMap f list =
concat (map f list)
-}
testConcatMap : (Src.Module -> Expectation) -> (() -> Expectation)
testConcatMap expectFn _ =
    let
        -- concatMap : (a -> List b) -> List a -> List b
        concatMapType =
            tLambda (tLambda (tVar "a") (tType "List" [ tVar "b" ]))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))

        -- concat (map f list)
        concatMapBody =
            callExpr (varExpr "concat")
                [ callExpr (varExpr "map") [ varExpr "f", varExpr "list" ] ]

        -- concat : List (List a) -> List a
        concatType =
            tLambda (tType "List" [ tType "List" [ tVar "a" ] ])
                (tType "List" [ tVar "a" ])

        -- map : (a -> b) -> List a -> List b
        mapType =
            tLambda (tLambda (tVar "a") (tVar "b"))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "concat"
                  , args = [ pVar "xs" ]
                  , tipe = concatType
                  , body = listExpr []
                  }
                , { name = "map"
                  , args = [ pVar "f", pVar "xs" ]
                  , tipe = mapType
                  , body = listExpr []
                  }
                , { name = "concatMap"
                  , args = [ pVar "f", pVar "list" ]
                  , tipe = concatMapType
                  , body = concatMapBody
                  }
                ]
    in
    expectFn modul


{-| indexedMap : (Int -> a -> b) -> List a -> List b
indexedMap f xs =
map2 f (range 0 (length xs - 1)) xs
-}
testIndexedMap : (Src.Module -> Expectation) -> (() -> Expectation)
testIndexedMap expectFn _ =
    let
        -- indexedMap : (Int -> a -> b) -> List a -> List b
        indexedMapType =
            tLambda (tLambda (tType "Int" []) (tLambda (tVar "a") (tVar "b")))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))

        -- map2 f (range 0 (length xs - 1)) xs
        -- length xs - 1
        lengthMinus1 =
            binopsExpr
                [ ( callExpr (varExpr "length") [ varExpr "xs" ], "-" ) ]
                (intExpr 1)

        -- range 0 (length xs - 1)
        rangeCall =
            callExpr (varExpr "range") [ intExpr 0, lengthMinus1 ]

        indexedMapBody =
            callExpr (varExpr "map2") [ varExpr "f", rangeCall, varExpr "xs" ]

        -- map2 : (a -> b -> c) -> List a -> List b -> List c
        map2Type =
            tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "c")))
                (tLambda (tType "List" [ tVar "a" ])
                    (tLambda (tType "List" [ tVar "b" ]) (tType "List" [ tVar "c" ]))
                )

        -- range : Int -> Int -> List Int
        rangeType =
            tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "List" [ tType "Int" [] ]))

        -- length : List a -> Int
        lengthType =
            tLambda (tType "List" [ tVar "a" ]) (tType "Int" [])

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "map2"
                  , args = [ pVar "f", pVar "xs", pVar "ys" ]
                  , tipe = map2Type
                  , body = listExpr []
                  }
                , { name = "range"
                  , args = [ pVar "lo", pVar "hi" ]
                  , tipe = rangeType
                  , body = listExpr []
                  }
                , { name = "length"
                  , args = [ pVar "xs" ]
                  , tipe = lengthType
                  , body = intExpr 0
                  }
                , { name = "indexedMap"
                  , args = [ pVar "f", pVar "xs" ]
                  , tipe = indexedMapType
                  , body = indexedMapBody
                  }
                ]
    in
    expectFn modul


{-| filter : (a -> Bool) -> List a -> List a
filter isGood list =
foldr (\x xs -> if isGood x then cons x xs else xs) [] list
-}
testFilter : (Src.Module -> Expectation) -> (() -> Expectation)
testFilter expectFn _ =
    let
        -- filter : (a -> Bool) -> List a -> List a
        filterType =
            tLambda (tLambda (tVar "a") (tType "Bool" []))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ]))

        -- \x xs -> if isGood x then cons x xs else xs
        innerIf =
            ifExpr
                (callExpr (varExpr "isGood") [ varExpr "x" ])
                (callExpr (varExpr "cons") [ varExpr "x", varExpr "xs" ])
                (varExpr "xs")

        theLambda =
            lambdaExpr [ pVar "x", pVar "xs" ] innerIf

        -- foldr (\x xs -> ...) [] list
        filterBody =
            callExpr (varExpr "foldr") [ theLambda, listExpr [], varExpr "list" ]

        -- foldr : (a -> b -> b) -> b -> List a -> b
        foldrType =
            tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                (tLambda (tVar "b")
                    (tLambda (tType "List" [ tVar "a" ]) (tVar "b"))
                )

        -- cons : a -> List a -> List a
        consType =
            tLambda (tVar "a")
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ]))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "foldr"
                  , args = [ pVar "f", pVar "init", pVar "xs" ]
                  , tipe = foldrType
                  , body = varExpr "init"
                  }
                , { name = "cons"
                  , args = [ pVar "x", pVar "xs" ]
                  , tipe = consType
                  , body = varExpr "xs"
                  }
                , { name = "filter"
                  , args = [ pVar "isGood", pVar "list" ]
                  , tipe = filterType
                  , body = filterBody
                  }
                ]
    in
    expectFn modul


{-| filterMap : (a -> Maybe b) -> List a -> List b
filterMap f xs =
foldr (maybeCons f) [] xs

where maybeCons is a helper:
maybeCons : (a -> Maybe b) -> a -> List b -> List b
maybeCons f mx xs =
case f mx of
Nothing -> xs
Just x -> cons x xs

-}
testFilterMap : (Src.Module -> Expectation) -> (() -> Expectation)
testFilterMap expectFn _ =
    let
        -- filterMap : (a -> Maybe b) -> List a -> List b
        filterMapType =
            tLambda (tLambda (tVar "a") (tType "Maybe" [ tVar "b" ]))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))

        -- foldr (maybeCons f) [] xs
        filterMapBody =
            callExpr (varExpr "foldr")
                [ callExpr (varExpr "maybeCons") [ varExpr "f" ]
                , listExpr []
                , varExpr "xs"
                ]

        -- maybeCons : (a -> Maybe b) -> a -> List b -> List b
        maybeConsType =
            tLambda (tLambda (tVar "a") (tType "Maybe" [ tVar "b" ]))
                (tLambda (tVar "a")
                    (tLambda (tType "List" [ tVar "b" ]) (tType "List" [ tVar "b" ]))
                )

        -- case f mx of Nothing -> xs; Just x -> cons x xs
        maybeConsBody =
            caseExpr (callExpr (varExpr "f") [ varExpr "mx" ])
                [ ( pCtor "Nothing" [], varExpr "xs" )
                , ( pCtor "Just" [ pVar "x" ]
                  , callExpr (varExpr "cons") [ varExpr "x", varExpr "xs" ]
                  )
                ]

        -- foldr : (a -> b -> b) -> b -> List a -> b
        foldrType =
            tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                (tLambda (tVar "b")
                    (tLambda (tType "List" [ tVar "a" ]) (tVar "b"))
                )

        -- cons : a -> List a -> List a
        consType =
            tLambda (tVar "a")
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ]))

        modul =
            makeModuleWithTypedDefs "Test"
                [ { name = "foldr"
                  , args = [ pVar "f", pVar "init", pVar "xs" ]
                  , tipe = foldrType
                  , body = varExpr "init"
                  }
                , { name = "cons"
                  , args = [ pVar "x", pVar "xs" ]
                  , tipe = consType
                  , body = varExpr "xs"
                  }
                , { name = "maybeCons"
                  , args = [ pVar "f", pVar "mx", pVar "xs" ]
                  , tipe = maybeConsType
                  , body = maybeConsBody
                  }
                , { name = "filterMap"
                  , args = [ pVar "f", pVar "xs" ]
                  , tipe = filterMapType
                  , body = filterMapBody
                  }
                ]
    in
    expectFn modul
