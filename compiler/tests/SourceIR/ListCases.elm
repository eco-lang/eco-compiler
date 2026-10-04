module SourceIR.ListCases exposing (expectSuite)

{-| Supplies programs built around list literals and annotated polymorphic
list functions, so that a check on a compiler stage is also run over list
literals of several shapes, and over annotated polymorphic functions that use
one another at different types.

This module asserts nothing itself. `expectSuite` hands each program, as a
`Src.Module`, to the expectation function its caller supplies, and that
function decides what is checked. The cases run inside one test through
`Compiler.BulkCheck.bulkCheck`, so a failure names the first failing case and
the cases after it do not run.

The programs come in two forms. Most are built with `makeModule`: a module
named `Test` that imports `Basics` and `List` and defines one unannotated
value, `testValue`. The last four are built with `makeModuleWithTypedDefs`: a
module named `Test` that imports `Basics`, `Maybe`, `List`, `Elm.JsArray`,
`String` and `Char`, in which every top-level value carries an annotation, and
`testValue` is annotated `List Int`.

The cases, by the program each builds:

  - `emptyList`: `testValue` is `[]`.
  - `singleIntList`: `testValue` is `[ 42 ]`.
  - `threeElementIntList`: `testValue` is `[ 1, 2, 3 ]`.
  - `listOfLists`: `testValue` is `[ [ 1, 2 ], [ 3, 4 ] ]`.
  - `deeplyNestedList`: `testValue` is `[ [ [ 1 ] ] ]`.
  - `listOfTuples`: `testValue` is `[ ( 1, "a" ), ( 2, "b" ) ]`.
  - `listOfRecords`: `testValue` is `[ { x = 1 }, { x = 2 } ]`.
  - `listOfIntTuples`: `testValue` is `[ ( 1, 2 ), ( 3, 4 ) ]`.
  - `listOfRecordsMultipleFields`: `testValue` is
    `[ { x = 1, y = "a" }, { x = 2, y = "b" } ]`.
  - `testConcatMap`, `testIndexedMap`, `testFilter` and `testFilterMap`:
    each defines the function it is named after, with that function's usual
    annotation, in terms of other annotated top-level functions, and applies
    it to `[ 1, 2 ]` in `testValue`. The helpers (`concat`, `map`, `map2`,
    `range`, `length`, `foldr`, `cons`) are stubs that return `[]`, `0` or one
    of their arguments; `maybeCons` is a real `case` on a `Maybe`. The
    annotations reuse the names `a` and `b` for different types: in
    `concatMap`, for example, the `a` of `concat`'s annotation stands for
    `concatMap`'s `b`. So `concatMap`, `indexedMap` and `filterMap`
    type-check only if each helper's annotation is instantiated afresh where
    it is used, rather than its variables being identified by name with those
    of the caller's annotation.

Among what is not tested: list patterns, the `::` and `++` operators, and a
list whose elements are functions.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
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


{-| Builds one test, named `"List expressions "` followed by `condStr`, that
passes when `expectFn` passes for every program in this module.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("List expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, in the order `bulkCheck` runs them, each
applying `expectFn` to its program.
-}
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


{-| Returns the case for the empty list literal.
-}
emptyListCases : (Src.Module -> Expectation) -> List TestCase
emptyListCases expectFn =
    [ { label = "Empty list", run = emptyList expectFn }
    ]


{-| Applies `expectFn` to a module whose `testValue` is `[]`.
-}
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


{-| Returns the case for a list literal of one element.
-}
singleElementCases : (Src.Module -> Expectation) -> List TestCase
singleElementCases expectFn =
    [ { label = "Single int list", run = singleIntList expectFn }
    ]


{-| Applies `expectFn` to a module whose `testValue` is `[ 42 ]`.
-}
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


{-| Returns the case for a list literal of three elements.
-}
multipleElementCases : (Src.Module -> Expectation) -> List TestCase
multipleElementCases expectFn =
    [ { label = "Three-element int list", run = threeElementIntList expectFn }
    ]


{-| Applies `expectFn` to a module whose `testValue` is `[ 1, 2, 3 ]`.
-}
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


{-| Returns the cases for lists of lists, of tuples and of records.
-}
nestedListCases : (Src.Module -> Expectation) -> List TestCase
nestedListCases expectFn =
    [ { label = "List of lists", run = listOfLists expectFn }
    , { label = "Deeply nested list", run = deeplyNestedList expectFn }
    , { label = "List of tuples", run = listOfTuples expectFn }
    , { label = "List of records", run = listOfRecords expectFn }
    ]


{-| Applies `expectFn` to a module whose `testValue` is
`[ [ 1, 2 ], [ 3, 4 ] ]`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`[ [ [ 1 ] ] ]`, a list nested three deep.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`[ ( 1, "a" ), ( 2, "b" ) ]`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`[ { x = 1 }, { x = 2 } ]`.
-}
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


{-| Returns the cases for a list of pairs of integers and a list of two-field
records.
-}
mixedTypeCases : (Src.Module -> Expectation) -> List TestCase
mixedTypeCases expectFn =
    [ { label = "List of int tuples", run = listOfIntTuples expectFn }
    , { label = "List of records with multiple fields", run = listOfRecordsMultipleFields expectFn }
    ]


{-| Applies `expectFn` to a module whose `testValue` is
`[ ( 1, 2 ), ( 3, 4 ) ]`.
-}
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


{-| Applies `expectFn` to a module whose `testValue` is
`[ { x = 1, y = "a" }, { x = 2, y = "b" } ]`.
-}
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
-- ANNOTATED POLYMORPHIC LIST FUNCTIONS
-- ============================================================================


{-| Returns the cases for `concatMap`, `indexedMap`, `filter` and `filterMap`,
each defined with its annotation over annotated helper functions.
-}
knownListFailsCases : (Src.Module -> Expectation) -> List TestCase
knownListFailsCases expectFn =
    [ { label = "concatMap", run = testConcatMap expectFn }
    , { label = "indexedMap", run = testIndexedMap expectFn }
    , { label = "filter", run = testFilter expectFn }
    , { label = "filterMap", run = testFilterMap expectFn }
    ]


{-| Applies `expectFn` to a module that defines `concatMap` over stub `concat`
and `map`:

    concat : List (List a) -> List a
    concat xs =
        []

    map : (a -> b) -> List a -> List b
    map f xs =
        []

    concatMap : (a -> List b) -> List a -> List b
    concatMap f list =
        concat (map f list)

    testValue : List Int
    testValue =
        concatMap (\x -> [ x ]) [ 1, 2 ]

-}
testConcatMap : (Src.Module -> Expectation) -> (() -> Expectation)
testConcatMap expectFn _ =
    let
        concatMapType =
            tLambda (tLambda (tVar "a") (tType "List" [ tVar "b" ]))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))

        concatMapBody =
            callExpr (varExpr "concat")
                [ callExpr (varExpr "map") [ varExpr "f", varExpr "list" ] ]

        concatType =
            tLambda (tType "List" [ tType "List" [ tVar "a" ] ])
                (tType "List" [ tVar "a" ])

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
                , { name = "testValue"
                  , args = []
                  , tipe = tType "List" [ tType "Int" [] ]
                  , body =
                        callExpr (varExpr "concatMap")
                            [ lambdaExpr [ pVar "x" ] (listExpr [ varExpr "x" ])
                            , listExpr [ intExpr 1, intExpr 2 ]
                            ]
                  }
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module that defines `indexedMap` over stub `map2`,
`range` and `length`:

    map2 : (a -> b -> c) -> List a -> List b -> List c
    map2 f xs ys =
        []

    range : Int -> Int -> List Int
    range lo hi =
        []

    length : List a -> Int
    length xs =
        0

    indexedMap : (Int -> a -> b) -> List a -> List b
    indexedMap f xs =
        map2 f (range 0 (length xs - 1)) xs

    testValue : List Int
    testValue =
        indexedMap (\i x -> i) [ 1, 2 ]

-}
testIndexedMap : (Src.Module -> Expectation) -> (() -> Expectation)
testIndexedMap expectFn _ =
    let
        indexedMapType =
            tLambda (tLambda (tType "Int" []) (tLambda (tVar "a") (tVar "b")))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))

        lengthMinus1 =
            binopsExpr
                [ ( callExpr (varExpr "length") [ varExpr "xs" ], "-" ) ]
                (intExpr 1)

        rangeCall =
            callExpr (varExpr "range") [ intExpr 0, lengthMinus1 ]

        indexedMapBody =
            callExpr (varExpr "map2") [ varExpr "f", rangeCall, varExpr "xs" ]

        map2Type =
            tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "c")))
                (tLambda (tType "List" [ tVar "a" ])
                    (tLambda (tType "List" [ tVar "b" ]) (tType "List" [ tVar "c" ]))
                )

        rangeType =
            tLambda (tType "Int" []) (tLambda (tType "Int" []) (tType "List" [ tType "Int" [] ]))

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
                , { name = "testValue"
                  , args = []
                  , tipe = tType "List" [ tType "Int" [] ]
                  , body =
                        callExpr (varExpr "indexedMap")
                            [ lambdaExpr [ pVar "i", pVar "x" ] (varExpr "i")
                            , listExpr [ intExpr 1, intExpr 2 ]
                            ]
                  }
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module that defines `filter` over stub `foldr` and
`cons`:

    foldr : (a -> b -> b) -> b -> List a -> b
    foldr f init xs =
        init

    cons : a -> List a -> List a
    cons x xs =
        xs

    filter : (a -> Bool) -> List a -> List a
    filter isGood list =
        foldr
            (\x xs ->
                if isGood x then
                    cons x xs

                else
                    xs
            )
            []
            list

    testValue : List Int
    testValue =
        filter (\x -> Basics.True) [ 1, 2 ]

-}
testFilter : (Src.Module -> Expectation) -> (() -> Expectation)
testFilter expectFn _ =
    let
        filterType =
            tLambda (tLambda (tVar "a") (tType "Bool" []))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ]))

        innerIf =
            ifExpr
                (callExpr (varExpr "isGood") [ varExpr "x" ])
                (callExpr (varExpr "cons") [ varExpr "x", varExpr "xs" ])
                (varExpr "xs")

        theLambda =
            lambdaExpr [ pVar "x", pVar "xs" ] innerIf

        filterBody =
            callExpr (varExpr "foldr") [ theLambda, listExpr [], varExpr "list" ]

        foldrType =
            tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                (tLambda (tVar "b")
                    (tLambda (tType "List" [ tVar "a" ]) (tVar "b"))
                )

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
                , { name = "testValue"
                  , args = []
                  , tipe = tType "List" [ tType "Int" [] ]
                  , body =
                        callExpr (varExpr "filter")
                            [ lambdaExpr [ pVar "x" ] (boolExpr True)
                            , listExpr [ intExpr 1, intExpr 2 ]
                            ]
                  }
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module that defines `filterMap` over stub `foldr`
and `cons`, and a `maybeCons` that branches on the `Maybe` that `f` returns:

    foldr : (a -> b -> b) -> b -> List a -> b
    foldr f init xs =
        init

    cons : a -> List a -> List a
    cons x xs =
        xs

    maybeCons : (a -> Maybe b) -> a -> List b -> List b
    maybeCons f mx xs =
        case f mx of
            Nothing ->
                xs

            Just x ->
                cons x xs

    filterMap : (a -> Maybe b) -> List a -> List b
    filterMap f xs =
        foldr (maybeCons f) [] xs

    testValue : List Int
    testValue =
        filterMap (\x -> Just x) [ 1, 2 ]

-}
testFilterMap : (Src.Module -> Expectation) -> (() -> Expectation)
testFilterMap expectFn _ =
    let
        filterMapType =
            tLambda (tLambda (tVar "a") (tType "Maybe" [ tVar "b" ]))
                (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))

        filterMapBody =
            callExpr (varExpr "foldr")
                [ callExpr (varExpr "maybeCons") [ varExpr "f" ]
                , listExpr []
                , varExpr "xs"
                ]

        maybeConsType =
            tLambda (tLambda (tVar "a") (tType "Maybe" [ tVar "b" ]))
                (tLambda (tVar "a")
                    (tLambda (tType "List" [ tVar "b" ]) (tType "List" [ tVar "b" ]))
                )

        maybeConsBody =
            caseExpr (callExpr (varExpr "f") [ varExpr "mx" ])
                [ ( pCtor "Nothing" [], varExpr "xs" )
                , ( pCtor "Just" [ pVar "x" ]
                  , callExpr (varExpr "cons") [ varExpr "x", varExpr "xs" ]
                  )
                ]

        foldrType =
            tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                (tLambda (tVar "b")
                    (tLambda (tType "List" [ tVar "a" ]) (tVar "b"))
                )

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
                , { name = "testValue"
                  , args = []
                  , tipe = tType "List" [ tType "Int" [] ]
                  , body =
                        callExpr (varExpr "filterMap")
                            [ lambdaExpr [ pVar "x" ] (callExpr (ctorExpr "Just") [ varExpr "x" ])
                            , listExpr [ intExpr 1, intExpr 2 ]
                            ]
                  }
                ]
    in
    expectFn modul
