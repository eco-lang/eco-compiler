module SourceIR.SpecializePolyTopCases exposing (expectSuite)

{-| Tests for top-level polymorphic functions specialized at multiple types.

Each test defines a polymorphic top-level function via makeModuleWithTypedDefs,
then calls it from testValue at two or more concrete types, forcing the
monomorphizer to create multiple specializations via the worklist.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pAnything
        , pCons
        , pList
        , pVar
        , strExpr
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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Poly top-level multi-specialization " ++ condStr) <|
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
-- 1. identity : a -> a  called at Int and String
-- ============================================================================


identityMulti : (Src.Module -> Expectation) -> (() -> Expectation)
identityMulti expectFn _ =
    let
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tVar "a")
            , body = varExpr "x"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "identity") [ intExpr 1 ])
                    (callExpr (varExpr "identity") [ strExpr "hello" ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ identityDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 2. const : a -> b -> a  called at (Int,String) and (String,Int)
-- ============================================================================


constMulti : (Src.Module -> Expectation) -> (() -> Expectation)
constMulti expectFn _ =
    let
        constDef : TypedDef
        constDef =
            { name = "const"
            , args = [ pVar "a", pVar "b" ]
            , tipe = tLambda (tVar "a") (tLambda (tVar "b") (tVar "a"))
            , body = varExpr "a"
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "const") [ intExpr 1, strExpr "hi" ])
                    (callExpr (varExpr "const") [ strExpr "hi", intExpr 1 ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ constDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 3. apply : (a -> b) -> a -> b  called at two type combos
-- ============================================================================


applyMulti : (Src.Module -> Expectation) -> (() -> Expectation)
applyMulti expectFn _ =
    let
        applyDef : TypedDef
        applyDef =
            { name = "apply"
            , args = [ pVar "f", pVar "x" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tVar "a") (tVar "b"))
            , body = callExpr (varExpr "f") [ varExpr "x" ]
            }

        -- addOne : Int -> Int
        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "apply") [ varExpr "addOne", intExpr 1 ])
                    (callExpr (varExpr "apply")
                        [ lambdaExpr [ pVar "s" ] (varExpr "s")
                        , strExpr "hi"
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ applyDef, addOneDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 4. compose : (b -> c) -> (a -> b) -> a -> c  at two type combos
-- ============================================================================


composeMulti : (Src.Module -> Expectation) -> (() -> Expectation)
composeMulti expectFn _ =
    let
        composeDef : TypedDef
        composeDef =
            { name = "compose"
            , args = [ pVar "f", pVar "g", pVar "x" ]
            , tipe =
                tLambda (tLambda (tVar "b") (tVar "c"))
                    (tLambda (tLambda (tVar "a") (tVar "b"))
                        (tLambda (tVar "a") (tVar "c"))
                    )
            , body = callExpr (varExpr "f") [ callExpr (varExpr "g") [ varExpr "x" ] ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                tupleExpr
                    -- compose addOne addOne 1  (Int -> Int -> Int)
                    (callExpr (varExpr "compose")
                        [ varExpr "addOne", varExpr "addOne", intExpr 1 ]
                    )
                    -- compose addOne addOne 2  (same types, different args)
                    (callExpr (varExpr "compose")
                        [ varExpr "addOne", varExpr "addOne", intExpr 2 ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ composeDef, addOneDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 5. length : List a -> Int  called on List Int and List String
-- ============================================================================


lengthMulti : (Src.Module -> Expectation) -> (() -> Expectation)
lengthMulti expectFn _ =
    let
        -- length xs = case xs of [] -> 0; _ :: rest -> 1 + length rest
        lengthDef : TypedDef
        lengthDef =
            { name = "length"
            , args = [ pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tVar "a" ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], intExpr 0 )
                    , ( pCons pAnything (pVar "rest")
                      , binopsExpr
                            [ ( intExpr 1, "+" ) ]
                            (callExpr (varExpr "length") [ varExpr "rest" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "length") [ listExpr [ intExpr 1, intExpr 2 ] ])
                    (callExpr (varExpr "length") [ listExpr [ strExpr "a", strExpr "b" ] ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ lengthDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 6. foldl : (a -> b -> b) -> b -> List a -> b  (tail-recursive) at two types
-- ============================================================================


foldlMulti : (Src.Module -> Expectation) -> (() -> Expectation)
foldlMulti expectFn _ =
    let
        -- foldl f acc xs = case xs of [] -> acc; x :: rest -> foldl f (f x acc) rest
        foldlDef : TypedDef
        foldlDef =
            { name = "foldl"
            , args = [ pVar "f", pVar "acc", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                    (tLambda (tVar "b")
                        (tLambda (tType "List" [ tVar "a" ]) (tVar "b"))
                    )
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "x") (pVar "rest")
                      , callExpr (varExpr "foldl")
                            [ varExpr "f"
                            , callExpr (varExpr "f") [ varExpr "x", varExpr "acc" ]
                            , varExpr "rest"
                            ]
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                tupleExpr
                    -- foldl (\x acc -> x + acc) 0 [1, 2, 3]
                    (callExpr (varExpr "foldl")
                        [ lambdaExpr [ pVar "x", pVar "acc" ]
                            (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc"))
                        , intExpr 0
                        , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                        ]
                    )
                    -- foldl (\x acc -> acc + 1) 0 ["a", "b"]  (count strings)
                    (callExpr (varExpr "foldl")
                        [ lambdaExpr [ pVar "x", pVar "acc" ]
                            (binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1))
                        , intExpr 0
                        , listExpr [ strExpr "a", strExpr "b" ]
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test" [ foldlDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 7. map : (a -> b) -> List a -> List b  (recursive) at two types
-- ============================================================================


mapMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapMulti expectFn _ =
    let
        -- map f xs = case xs of [] -> []; x :: rest -> f x :: map f rest
        mapDef : TypedDef
        mapDef =
            { name = "map"
            , args = [ pVar "f", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "x") (pVar "rest")
                      , binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                            (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                      )
                    ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                tupleExpr
                    -- map addOne [1, 2]
                    (callExpr (varExpr "map") [ varExpr "addOne", listExpr [ intExpr 1, intExpr 2 ] ])
                    -- map (\s -> s) ["a", "b"]
                    (callExpr (varExpr "map")
                        [ lambdaExpr [ pVar "s" ] (varExpr "s")
                        , listExpr [ strExpr "a", strExpr "b" ]
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test" [ mapDef, addOneDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 8. Partial application of polymorphic map
-- ============================================================================


mapPartialMulti : (Src.Module -> Expectation) -> (() -> Expectation)
mapPartialMulti expectFn _ =
    let
        mapDef : TypedDef
        mapDef =
            { name = "map"
            , args = [ pVar "f", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "b"))
                    (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "b" ]))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], listExpr [] )
                    , ( pCons (pVar "x") (pVar "rest")
                      , binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "x" ], "::" ) ]
                            (callExpr (varExpr "map") [ varExpr "f", varExpr "rest" ])
                      )
                    ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                letExpr
                    [ -- mapAddOne = map addOne  (partially applied)
                      define "mapAddOne"
                        []
                        (callExpr (varExpr "map") [ varExpr "addOne" ])
                    , -- mapId = map (\s -> s)  (partially applied)
                      define "mapId"
                        []
                        (callExpr (varExpr "map")
                            [ lambdaExpr [ pVar "s" ] (varExpr "s") ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "mapAddOne") [ listExpr [ intExpr 1, intExpr 2 ] ])
                        (callExpr (varExpr "mapId") [ listExpr [ strExpr "a", strExpr "b" ] ])
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test" [ mapDef, addOneDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 9. pair : a -> b -> (a, b)  at two type combos
-- ============================================================================


pairMulti : (Src.Module -> Expectation) -> (() -> Expectation)
pairMulti expectFn _ =
    let
        pairDef : TypedDef
        pairDef =
            { name = "pair"
            , args = [ pVar "a", pVar "b" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "b") (tTuple (tVar "a") (tVar "b")))
            , body = tupleExpr (varExpr "a") (varExpr "b")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tTuple (tType "Int" []) (tType "String" []))
                    (tTuple (tType "String" []) (tType "Int" []))
            , body =
                tupleExpr
                    (callExpr (varExpr "pair") [ intExpr 1, strExpr "hi" ])
                    (callExpr (varExpr "pair") [ strExpr "hi", intExpr 1 ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ pairDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 10. reverse via tail-recursive helper, at two list types
-- ============================================================================


reverseMulti : (Src.Module -> Expectation) -> (() -> Expectation)
reverseMulti expectFn _ =
    let
        -- reverseHelper acc xs = case xs of [] -> acc; x :: rest -> reverseHelper (x :: acc) rest
        reverseHelperDef : TypedDef
        reverseHelperDef =
            { name = "reverseHelper"
            , args = [ pVar "acc", pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tVar "a" ])
                    (tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ]))
            , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "x") (pVar "rest")
                      , callExpr (varExpr "reverseHelper")
                            [ binopsExpr [ ( varExpr "x", "::" ) ] (varExpr "acc")
                            , varExpr "rest"
                            ]
                      )
                    ]
            }

        -- reverse xs = reverseHelper [] xs
        reverseDef : TypedDef
        reverseDef =
            { name = "reverse"
            , args = [ pVar "xs" ]
            , tipe =
                tLambda (tType "List" [ tVar "a" ]) (tType "List" [ tVar "a" ])
            , body =
                callExpr (varExpr "reverseHelper") [ listExpr [], varExpr "xs" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                tupleExpr
                    (callExpr (varExpr "reverse") [ listExpr [ intExpr 1, intExpr 2 ] ])
                    (callExpr (varExpr "reverse") [ listExpr [ strExpr "a", strExpr "b" ] ])
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ reverseHelperDef, reverseDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 11. twice : (a -> a) -> a -> a  at two types
-- ============================================================================


twiceMulti : (Src.Module -> Expectation) -> (() -> Expectation)
twiceMulti expectFn _ =
    let
        twiceDef : TypedDef
        twiceDef =
            { name = "twice"
            , args = [ pVar "f", pVar "x" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "a"))
                    (tLambda (tVar "a") (tVar "a"))
            , body =
                callExpr (varExpr "f")
                    [ callExpr (varExpr "f") [ varExpr "x" ] ]
            }

        addOneDef : TypedDef
        addOneDef =
            { name = "addOne"
            , args = [ pVar "n" ]
            , tipe = tLambda (tType "Int" []) (tType "Int" [])
            , body = binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "String" [])
            , body =
                tupleExpr
                    -- twice addOne 0
                    (callExpr (varExpr "twice") [ varExpr "addOne", intExpr 0 ])
                    -- twice (\s -> s) "hi"
                    (callExpr (varExpr "twice")
                        [ lambdaExpr [ pVar "s" ] (varExpr "s")
                        , strExpr "hi"
                        ]
                    )
            }

        modul =
            makeModuleWithTypedDefs "Test"
                [ twiceDef, addOneDef, testValueDef ]
    in
    expectFn modul



-- ============================================================================
-- 12. singleton : a -> List a  at two types
-- ============================================================================


singletonMulti : (Src.Module -> Expectation) -> (() -> Expectation)
singletonMulti expectFn _ =
    let
        singletonDef : TypedDef
        singletonDef =
            { name = "singleton"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tType "List" [ tVar "a" ])
            , body = listExpr [ varExpr "x" ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe =
                tTuple
                    (tType "List" [ tType "Int" [] ])
                    (tType "List" [ tType "String" [] ])
            , body =
                tupleExpr
                    (callExpr (varExpr "singleton") [ intExpr 42 ])
                    (callExpr (varExpr "singleton") [ strExpr "hi" ])
            }

        modul =
            makeModuleWithTypedDefs "Test" [ singletonDef, testValueDef ]
    in
    expectFn modul
