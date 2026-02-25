module SourceIR.SpecializePolyLetCases exposing (expectSuite)

{-| Tests for let-bound polymorphic functions specialized at multiple types.

Each test defines a polymorphic function inside a local let expression,
then calls it at two or more concrete types in the body, forcing the
monomorphizer's demand-driven local multi-specialization (localMulti stack).

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pAnything
        , pCons
        , pList
        , pVar
        , strExpr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Poly let-bound multi-specialization " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "identity at Int and String", run = identityMulti expectFn }
    , { label = "const at two type combos", run = constMulti expectFn }
    , { label = "apply higher-order at two types", run = applyMulti expectFn }
    , { label = "compose at two type combos", run = composeMulti expectFn }
    , { label = "recursive length at two list types", run = lengthMulti expectFn }
    , { label = "tail-recursive foldl at two types", run = foldlMulti expectFn }
    , { label = "recursive map at two types", run = mapMulti expectFn }
    , { label = "partial application of map", run = mapPartialMulti expectFn }
    , { label = "pair constructor at two type combos", run = pairMulti expectFn }
    , { label = "tail-recursive reverse at two types", run = reverseMulti expectFn }
    , { label = "twice higher-order at two types", run = twiceMulti expectFn }
    , { label = "singleton at two types", run = singletonMulti expectFn }
    ]



-- ============================================================================
-- 1. identity at Int and String
-- ============================================================================


identityMulti : (Src.Module -> Expectation) -> (() -> Expectation)
identityMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "identity" [ pVar "x" ] (varExpr "x") ]
                    (tupleExpr
                        (callExpr (varExpr "identity") [ intExpr 1 ])
                        (callExpr (varExpr "identity") [ strExpr "hello" ])
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 2. const at two type combos
-- ============================================================================


constMulti : (Src.Module -> Expectation) -> (() -> Expectation)
constMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "const" [ pVar "a", pVar "b" ] (varExpr "a") ]
                    (tupleExpr
                        (callExpr (varExpr "const") [ intExpr 1, strExpr "hi" ])
                        (callExpr (varExpr "const") [ strExpr "hi", intExpr 1 ])
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 3. apply higher-order at two types
-- ============================================================================


applyMulti : (Src.Module -> Expectation) -> (() -> Expectation)
applyMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "apply"
                        [ pVar "f", pVar "x" ]
                        (callExpr (varExpr "f") [ varExpr "x" ])
                    ]
                    (tupleExpr
                        (callExpr (varExpr "apply")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            , intExpr 1
                            ]
                        )
                        (callExpr (varExpr "apply")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s")
                            , strExpr "hi"
                            ]
                        )
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 4. compose at two type combos
-- ============================================================================


composeMulti : (Src.Module -> Expectation) -> (() -> Expectation)
composeMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "compose"
                        [ pVar "f", pVar "g", pVar "x" ]
                        (callExpr (varExpr "f")
                            [ callExpr (varExpr "g") [ varExpr "x" ] ]
                        )
                    , define "addOne"
                        [ pVar "n" ]
                        (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                    ]
                    (tupleExpr
                        (callExpr (varExpr "compose")
                            [ varExpr "addOne", varExpr "addOne", intExpr 1 ]
                        )
                        (callExpr (varExpr "compose")
                            [ varExpr "addOne", varExpr "addOne", intExpr 2 ]
                        )
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 5. recursive length at two list types
-- ============================================================================


lengthMulti : (Src.Module -> Expectation) -> (() -> Expectation)
lengthMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "length"
                        [ pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], intExpr 0 )
                            , ( pCons pAnything (pVar "rest")
                              , binopsExpr
                                    [ ( intExpr 1, "+" ) ]
                                    (callExpr (varExpr "length") [ varExpr "rest" ])
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "length") [ listExpr [ intExpr 1, intExpr 2 ] ])
                        (callExpr (varExpr "length") [ listExpr [ strExpr "a", strExpr "b" ] ])
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 6. tail-recursive foldl at two types
-- ============================================================================


foldlMulti : (Src.Module -> Expectation) -> (() -> Expectation)
foldlMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "foldl"
                        [ pVar "f", pVar "acc", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], varExpr "acc" )
                            , ( pCons (pVar "x") (pVar "rest")
                              , callExpr (varExpr "foldl")
                                    [ varExpr "f"
                                    , callExpr (varExpr "f") [ varExpr "x", varExpr "acc" ]
                                    , varExpr "rest"
                                    ]
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        -- foldl (\x acc -> x + acc) 0 [1, 2, 3]
                        (callExpr (varExpr "foldl")
                            [ lambdaExpr [ pVar "x", pVar "acc" ]
                                (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc"))
                            , intExpr 0
                            , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                            ]
                        )
                        -- foldl (\x acc -> acc + 1) 0 ["a", "b"]
                        (callExpr (varExpr "foldl")
                            [ lambdaExpr [ pVar "x", pVar "acc" ]
                                (binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1))
                            , intExpr 0
                            , listExpr [ strExpr "a", strExpr "b" ]
                            ]
                        )
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 7. recursive map at two types
-- ============================================================================


mapMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "map"
                        [ pVar "f", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], listExpr [] )
                            , ( pCons (pVar "x") (pVar "rest")
                              , binopsExpr
                                    [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                                    (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            , listExpr [ intExpr 1, intExpr 2 ]
                            ]
                        )
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s")
                            , listExpr [ strExpr "a", strExpr "b" ]
                            ]
                        )
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 8. partial application of map
-- ============================================================================


mapPartialMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapPartialMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "map"
                        [ pVar "f", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], listExpr [] )
                            , ( pCons (pVar "x") (pVar "rest")
                              , binopsExpr
                                    [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                                    (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                              )
                            ]
                        )
                    , define "mapAddOne"
                        []
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            ]
                        )
                    , define "mapId"
                        []
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s") ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "mapAddOne") [ listExpr [ intExpr 1, intExpr 2 ] ])
                        (callExpr (varExpr "mapId") [ listExpr [ strExpr "a", strExpr "b" ] ])
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 9. pair constructor at two type combos
-- ============================================================================


pairMulti : (Src.Module -> Expectation) -> (() -> Expectation)
pairMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "pair"
                        [ pVar "a", pVar "b" ]
                        (tupleExpr (varExpr "a") (varExpr "b"))
                    ]
                    (tupleExpr
                        (callExpr (varExpr "pair") [ intExpr 1, strExpr "hi" ])
                        (callExpr (varExpr "pair") [ strExpr "hi", intExpr 1 ])
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 10. tail-recursive reverse at two types
-- ============================================================================


reverseMulti : (Src.Module -> Expectation) -> (() -> Expectation)
reverseMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "reverseHelper"
                        [ pVar "acc", pVar "xs" ]
                        (caseExpr (varExpr "xs")
                            [ ( pList [], varExpr "acc" )
                            , ( pCons (pVar "x") (pVar "rest")
                              , callExpr (varExpr "reverseHelper")
                                    [ binopsExpr [ ( varExpr "x", "::" ) ] (varExpr "acc")
                                    , varExpr "rest"
                                    ]
                              )
                            ]
                        )
                    , define "reverse"
                        [ pVar "xs" ]
                        (callExpr (varExpr "reverseHelper") [ listExpr [], varExpr "xs" ])
                    ]
                    (tupleExpr
                        (callExpr (varExpr "reverse") [ listExpr [ intExpr 1, intExpr 2 ] ])
                        (callExpr (varExpr "reverse") [ listExpr [ strExpr "a", strExpr "b" ] ])
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 11. twice higher-order at two types
-- ============================================================================


twiceMulti : (Src.Module -> Expectation) -> (() -> Expectation)
twiceMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "twice"
                        [ pVar "f", pVar "x" ]
                        (callExpr (varExpr "f")
                            [ callExpr (varExpr "f") [ varExpr "x" ] ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "twice")
                            [ lambdaExpr [ pVar "n" ]
                                (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1))
                            , intExpr 0
                            ]
                        )
                        (callExpr (varExpr "twice")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s")
                            , strExpr "hi"
                            ]
                        )
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- 12. singleton at two types
-- ============================================================================


singletonMulti : (Src.Module -> Expectation) -> (() -> Expectation)
singletonMulti expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "singleton"
                        [ pVar "x" ]
                        (listExpr [ varExpr "x" ])
                    ]
                    (tupleExpr
                        (callExpr (varExpr "singleton") [ intExpr 42 ])
                        (callExpr (varExpr "singleton") [ strExpr "hi" ])
                    )
                )
    in
    expectFn modul
