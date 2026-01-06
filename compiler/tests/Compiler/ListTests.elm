module Compiler.ListTests exposing (expectSuite)

{-| Tests for list expressions.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , charFuzzer
        , chrExpr
        , floatExpr
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
import Expect exposing (Expectation)
import Fuzz
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("List expressions " ++ condStr)
        [ emptyListTests expectFn condStr
        , singleElementTests expectFn condStr
        , multipleElementTests expectFn condStr
        , nestedListTests expectFn condStr
        , mixedTypeTests expectFn condStr
        , listFuzzTests expectFn condStr
        , knownListFails expectFn condStr
        ]



-- ============================================================================
-- EMPTY LIST (4 tests)
-- ============================================================================


emptyListTests : (Src.Module -> Expectation) -> String -> Test
emptyListTests expectFn condStr =
    Test.describe ("Empty lists " ++ condStr)
        [ Test.test ("Empty list " ++ condStr) (emptyList expectFn)
        , Test.test ("Two empty lists in separate modules " ++ condStr) (twoEmptyLists expectFn)
        , Test.test ("Empty int list " ++ condStr) (emptyIntList expectFn)
        , Test.test ("Empty string list " ++ condStr) (emptyStringList expectFn)
        ]


emptyList : (Src.Module -> Expectation) -> (() -> Expectation)
emptyList expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [])
    in
    expectFn modul


twoEmptyLists : (Src.Module -> Expectation) -> (() -> Expectation)
twoEmptyLists expectFn _ =
    let
        modul1 =
            makeModule "list1" (listExpr [])

        modul2 =
            makeModule "list2" (listExpr [])
    in
    Expect.all
        [ \_ -> expectFn modul1
        , \_ -> expectFn modul2
        ]
        ()


emptyIntList : (Src.Module -> Expectation) -> (() -> Expectation)
emptyIntList expectFn _ =
    let
        modul =
            makeModule "intList" (listExpr [])
    in
    expectFn modul


emptyStringList : (Src.Module -> Expectation) -> (() -> Expectation)
emptyStringList expectFn _ =
    let
        modul =
            makeModule "strList" (listExpr [])
    in
    expectFn modul



-- ============================================================================
-- SINGLE ELEMENT (4 tests)
-- ============================================================================


singleElementTests : (Src.Module -> Expectation) -> String -> Test
singleElementTests expectFn condStr =
    Test.describe ("Single element lists " ++ condStr)
        [ Test.fuzz Fuzz.int ("Single int list " ++ condStr) (singleIntList expectFn)
        , Test.fuzz Fuzz.string ("Single string list " ++ condStr) (singleStringList expectFn)
        , Test.fuzz Fuzz.float ("Single float list " ++ condStr) (singleFloatList expectFn)
        , Test.fuzz charFuzzer ("Single char list " ++ condStr) (singleCharList expectFn)
        ]


singleIntList : (Src.Module -> Expectation) -> (Int -> Expectation)
singleIntList expectFn n =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr n ])
    in
    expectFn modul


singleStringList : (Src.Module -> Expectation) -> (String -> Expectation)
singleStringList expectFn s =
    let
        modul =
            makeModule "testValue" (listExpr [ strExpr s ])
    in
    expectFn modul


singleFloatList : (Src.Module -> Expectation) -> (Float -> Expectation)
singleFloatList expectFn f =
    let
        modul =
            makeModule "testValue" (listExpr [ floatExpr f ])
    in
    expectFn modul


singleCharList : (Src.Module -> Expectation) -> (String -> Expectation)
singleCharList expectFn c =
    let
        modul =
            makeModule "testValue" (listExpr [ chrExpr c ])
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE ELEMENTS (7 tests)
-- ============================================================================


multipleElementTests : (Src.Module -> Expectation) -> String -> Test
multipleElementTests expectFn condStr =
    Test.describe ("Multiple element lists " ++ condStr)
        [ Test.fuzz2 Fuzz.int Fuzz.int ("Two-element int list " ++ condStr) (twoElementIntList expectFn)
        , Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int ("Three-element int list " ++ condStr) (threeElementIntList expectFn)
        , Test.test ("Five-element int list " ++ condStr) (fiveElementIntList expectFn)
        , Test.fuzz2 Fuzz.string Fuzz.string ("Two-element string list " ++ condStr) (twoElementStringList expectFn)
        , Test.fuzz3 Fuzz.float Fuzz.float Fuzz.float ("Three-element float list " ++ condStr) (threeElementFloatList expectFn)
        , Test.test ("Ten-element int list " ++ condStr) (tenElementIntList expectFn)
        , Test.test ("Large int list " ++ condStr) (largeIntList expectFn)
        ]


twoElementIntList : (Src.Module -> Expectation) -> (Int -> Int -> Expectation)
twoElementIntList expectFn a b =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr a, intExpr b ])
    in
    expectFn modul


threeElementIntList : (Src.Module -> Expectation) -> (Int -> Int -> Int -> Expectation)
threeElementIntList expectFn a b c =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr a, intExpr b, intExpr c ])
    in
    expectFn modul


fiveElementIntList : (Src.Module -> Expectation) -> (() -> Expectation)
fiveElementIntList expectFn _ =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 1, intExpr 2, intExpr 3, intExpr 4, intExpr 5 ])
    in
    expectFn modul


twoElementStringList : (Src.Module -> Expectation) -> (String -> String -> Expectation)
twoElementStringList expectFn a b =
    let
        modul =
            makeModule "testValue" (listExpr [ strExpr a, strExpr b ])
    in
    expectFn modul


threeElementFloatList : (Src.Module -> Expectation) -> (Float -> Float -> Float -> Expectation)
threeElementFloatList expectFn a b c =
    let
        modul =
            makeModule "testValue" (listExpr [ floatExpr a, floatExpr b, floatExpr c ])
    in
    expectFn modul


tenElementIntList : (Src.Module -> Expectation) -> (() -> Expectation)
tenElementIntList expectFn _ =
    let
        elements =
            List.map intExpr (List.range 1 10)

        modul =
            makeModule "testValue" (listExpr elements)
    in
    expectFn modul


largeIntList : (Src.Module -> Expectation) -> (() -> Expectation)
largeIntList expectFn _ =
    let
        elements =
            List.map intExpr (List.range 1 100)

        modul =
            makeModule "testValue" (listExpr elements)
    in
    expectFn modul



-- ============================================================================
-- NESTED LISTS (4 tests)
-- ============================================================================


nestedListTests : (Src.Module -> Expectation) -> String -> Test
nestedListTests expectFn condStr =
    Test.describe ("Nested lists " ++ condStr)
        [ Test.test ("List of lists " ++ condStr) (listOfLists expectFn)
        , Test.test ("Deeply nested list " ++ condStr) (deeplyNestedList expectFn)
        , Test.test ("List of tuples " ++ condStr) (listOfTuples expectFn)
        , Test.test ("List of records " ++ condStr) (listOfRecords expectFn)
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
-- MIXED TYPES (4 tests)
-- ============================================================================


mixedTypeTests : (Src.Module -> Expectation) -> String -> Test
mixedTypeTests expectFn condStr =
    Test.describe ("Mixed element types (in tuples/records) " ++ condStr)
        [ Test.test ("List of int tuples " ++ condStr) (listOfIntTuples expectFn)
        , Test.test ("List of string tuples " ++ condStr) (listOfStringTuples expectFn)
        , Test.test ("List with nested lists of different types " ++ condStr) (listWithNestedListsDifferentTypes expectFn)
        , Test.test ("List of records with multiple fields " ++ condStr) (listOfRecordsMultipleFields expectFn)
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


listOfStringTuples : (Src.Module -> Expectation) -> (() -> Expectation)
listOfStringTuples expectFn _ =
    let
        modul =
            makeModule "testValue"
                (listExpr
                    [ tupleExpr (strExpr "a") (strExpr "b")
                    , tupleExpr (strExpr "c") (strExpr "d")
                    ]
                )
    in
    expectFn modul


listWithNestedListsDifferentTypes : (Src.Module -> Expectation) -> (() -> Expectation)
listWithNestedListsDifferentTypes expectFn _ =
    let
        modul =
            makeModule "testValue"
                (listExpr
                    [ listExpr [ intExpr 1, intExpr 2 ]
                    , listExpr [ intExpr 3 ]
                    , listExpr []
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
-- FUZZ TESTS (4 tests)
-- ============================================================================


listFuzzTests : (Src.Module -> Expectation) -> String -> Test
listFuzzTests expectFn condStr =
    Test.describe ("Fuzzed list tests " ++ condStr)
        [ Test.fuzz (Fuzz.listOfLengthBetween 0 5 Fuzz.int) ("Random length int list " ++ condStr) (randomLengthIntList expectFn)
        , Test.fuzz (Fuzz.listOfLengthBetween 0 5 Fuzz.string) ("Random length string list " ++ condStr) (randomLengthStringList expectFn)
        , Test.fuzz (Fuzz.listOfLengthBetween 0 3 Fuzz.int) ("Random nested int lists " ++ condStr) (randomNestedIntLists expectFn)
        , Test.fuzz2 (Fuzz.listOfLengthBetween 0 3 Fuzz.int) (Fuzz.listOfLengthBetween 0 3 Fuzz.int) ("Two random lists " ++ condStr) (twoRandomLists expectFn)
        ]


randomLengthIntList : (Src.Module -> Expectation) -> (List Int -> Expectation)
randomLengthIntList expectFn ints =
    let
        modul =
            makeModule "testValue" (listExpr (List.map intExpr ints))
    in
    expectFn modul


randomLengthStringList : (Src.Module -> Expectation) -> (List String -> Expectation)
randomLengthStringList expectFn strs =
    let
        modul =
            makeModule "testValue" (listExpr (List.map strExpr strs))
    in
    expectFn modul


randomNestedIntLists : (Src.Module -> Expectation) -> (List Int -> Expectation)
randomNestedIntLists expectFn ints =
    let
        innerList =
            listExpr (List.map intExpr ints)

        modul =
            makeModule "testValue" (listExpr [ innerList ])
    in
    expectFn modul


twoRandomLists : (Src.Module -> Expectation) -> (List Int -> List Int -> Expectation)
twoRandomLists expectFn ints1 ints2 =
    let
        list1 =
            listExpr (List.map intExpr ints1)

        list2 =
            listExpr (List.map intExpr ints2)

        modul =
            makeModule "testValue" (listExpr [ list1, list2 ])
    in
    expectFn modul



-- ============================================================================
-- List Failure Tests
-- ============================================================================
-- These tests exercise the exact type generalization patterns that fail
-- in elm/core List.elm. The function bodies are copied verbatim from List.elm.


{-| Test suite for exact List.elm functions that fail type checking.
-}
knownListFails : (Src.Module -> Expectation) -> String -> Test
knownListFails expectFn condStr =
    Test.describe ("Exact List.elm functions " ++ condStr)
        [ Test.test ("concatMap " ++ condStr) (testConcatMap expectFn)
        , Test.test ("indexedMap " ++ condStr) (testIndexedMap expectFn)
        , Test.test ("filter " ++ condStr) (testFilter expectFn)
        , Test.test ("filterMap " ++ condStr) (testFilterMap expectFn)
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
foldr (\\x xs -> if isGood x then cons x xs else xs) [] list
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
