module SourceIR.PolyChainCases exposing (expectSuite, suite)

{-| Test cases for chained polymorphic function calls that trigger the
__callee rename collision bug in monomorphization type substitution.

The bug mechanism requires three layers:
1. A concrete entry point that specializes a polymorphic middle function
2. A polymorphic middle function (caller) whose type vars enter the substitution
3. A polymorphic helper (callee) with overlapping var names, called multiple times

When the callee's type vars overlap with the caller's, buildRenameMap renames
them with __callee suffixes. But the counter resets to 0 on each unifyFuncCall,
so the second call reuses the same __callee names. Combined with:
- normalizeMonoType not resolving inner MVars in complex types
- isSelfRef only catching bare MVar self-references

This allows circular bindings like a__callee0 = Tree (MVar "a__callee0") to form.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
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


suite : Test
suite =
    Test.describe "Chained polymorphic calls over complex types"
        [ expectSuite expectMonomorphization "monomorphizes poly chains"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Poly chain cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ occursCheckCases expectFn
        , chainedInsertCases expectFn
        , nestedContainerCases expectFn
        , multiCallSamePolyCases expectFn
        ]



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


tInt : Src.Type
tInt =
    tType "Int" []


tString : Src.Type
tString =
    tType "String" []


tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]


tBool : Src.Type
tBool =
    tType "Bool" []



-- ============================================================================
-- OCCURS CHECK CASES
-- These directly target the bug: polymorphic caller calls polymorphic callee
-- multiple times, with result feeding forward and type vars wrapped in
-- complex types. The __callee rename collision creates circular bindings.
-- ============================================================================


occursCheckCases : (Src.Module -> Expectation) -> List TestCase
occursCheckCases expectFn =
    [ { label = "Custom type wrapping: insertTree called twice from polymorphic caller"
      , run = treeInsertFromPolyCaller expectFn
      }
    , { label = "Tuple wrapping: poly helper returns (a, Int), called from poly caller"
      , run = tupleWrapFromPolyCaller expectFn
      }
    , { label = "Two type vars: both collide, called from poly caller with same names"
      , run = twoVarCollision expectFn
      }
    , { label = "Dict-like insert from polymorphic caller (3 type var collision)"
      , run = dictInsertFromPolyCaller expectFn
      }
    , { label = "Chained calls: result feeds through 4 calls in poly context"
      , run = chainedFeedForward4 expectFn
      }
    , { label = "Nested wrapper: a inside (List a, Int) from poly caller"
      , run = nestedWrapperFromPolyCaller expectFn
      }
    ]


{-| Core reproducer for the occurs check bug.

    type Tree a = Leaf | Node (Tree a) a (Tree a)

    insertTree : a -> Tree a -> Tree a    -- callee (polymorphic)
    insertTree val tree = Node tree val Leaf

    buildTree : a -> a -> Tree a           -- caller (polymorphic, shares var `a`)
    buildTree x y =
        let
            t1 = insertTree x Leaf         -- 1st call: a → a__callee0
            t2 = insertTree y t1           -- 2nd call: a → a__callee0 REUSED
        in                                 -- t1's type = Tree (MVar "a__callee0")
        t2                                 -- isSelfRef misses it → cycle!

    testValue = buildTree 1 2              -- concrete entry point

-}
treeInsertFromPolyCaller : (Src.Module -> Expectation) -> (() -> Expectation)
treeInsertFromPolyCaller expectFn _ =
    let
        tTree a =
            tType "Tree" [ a ]

        treeUnion : UnionDef
        treeUnion =
            { name = "Tree"
            , args = [ "a" ]
            , ctors =
                [ { name = "Leaf", args = [] }
                , { name = "Node"
                  , args = [ tTree (tVar "a"), tVar "a", tTree (tVar "a") ]
                  }
                ]
            }

        -- insertTree : a -> Tree a -> Tree a
        insertTreeDef : TypedDef
        insertTreeDef =
            { name = "insertTree"
            , args = [ pVar "val", pVar "tree" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tTree (tVar "a"))
                        (tTree (tVar "a"))
                    )
            , body =
                callExpr (ctorExpr "Node")
                    [ varExpr "tree", varExpr "val", callExpr (ctorExpr "Leaf") [] ]
            }

        -- buildTree : a -> a -> Tree a
        -- POLYMORPHIC CALLER — shares var name `a` with insertTree
        buildTreeDef : TypedDef
        buildTreeDef =
            { name = "buildTree"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "a")
                        (tTree (tVar "a"))
                    )
            , body =
                letExpr
                    [ define "t1" []
                        (callExpr (varExpr "insertTree")
                            [ varExpr "x", callExpr (ctorExpr "Leaf") [] ]
                        )
                    , define "t2" []
                        (callExpr (varExpr "insertTree")
                            [ varExpr "y", varExpr "t1" ]
                        )
                    ]
                    (varExpr "t2")
            }

        -- sizeTree : Tree a -> Int
        sizeTreeDef : TypedDef
        sizeTreeDef =
            { name = "sizeTree"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTree (tVar "a")) tInt
            , body =
                caseExpr (varExpr "t")
                    [ ( pVar "leaf", intExpr 0 )
                    , ( pVar "node", intExpr 1 )
                    ]
            }

        -- testValue : Int
        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "sizeTree")
                    [ callExpr (varExpr "buildTree") [ intExpr 1, intExpr 2 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ insertTreeDef, buildTreeDef, sizeTreeDef, mainDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| Tuple wrapping variant: the helper returns a type where `a` is inside a tuple.

    tag : a -> (a, Int)
    tag x = (x, 0)

    tagBoth : a -> a -> (a, Int)    -- poly caller, shares `a`
    tagBoth x y =
        let
            r1 = tag x              -- a__callee0 → MVar "a"
            r2 = tag y              -- a__callee0 reused
        in                          -- r1 type = (MVar "a__callee0", Int)
        r2                          -- binding sees nested self-ref

-}
tupleWrapFromPolyCaller : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWrapFromPolyCaller expectFn _ =
    let
        -- tag : a -> (a, Int)
        tagDef : TypedDef
        tagDef =
            { name = "tag"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tVar "a")
                    (tTuple (tVar "a") tInt)
            , body = tupleExpr (varExpr "x") (intExpr 0)
            }

        -- tagBoth : a -> a -> (a, Int)
        tagBothDef : TypedDef
        tagBothDef =
            { name = "tagBoth"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "a")
                        (tTuple (tVar "a") tInt)
                    )
            , body =
                letExpr
                    [ define "r1" [] (callExpr (varExpr "tag") [ varExpr "x" ])
                    , define "r2" [] (callExpr (varExpr "tag") [ varExpr "y" ])
                    ]
                    (varExpr "r2")
            }

        -- testValue : (String, Int)
        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple tString tInt
            , body =
                callExpr (varExpr "tagBoth")
                    [ strExpr "hello", strExpr "world" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ tagDef, tagBothDef, mainDef ]
                []
                []
    in
    expectFn modul


{-| Two type vars both collide between caller and callee.

    type Pair a b = Pair a b

    combine : a -> b -> Pair a b     -- callee with vars a, b
    combine x y = MkPair x y

    process : a -> b -> Pair a b     -- caller with SAME var names a, b
    process x y =
        let
            r1 = combine x y          -- a→a__callee0, b→b__callee1
            r2 = combine x y          -- reuses a__callee0, b__callee1
        in
        r2

    testValue = process 42 "hello"

-}
twoVarCollision : (Src.Module -> Expectation) -> (() -> Expectation)
twoVarCollision expectFn _ =
    let
        tPair a b =
            tType "Pair" [ a, b ]

        pairUnion : UnionDef
        pairUnion =
            { name = "Pair"
            , args = [ "a", "b" ]
            , ctors =
                [ { name = "MkPair", args = [ tVar "a", tVar "b" ] }
                ]
            }

        -- combine : a -> b -> Pair a b
        combineDef : TypedDef
        combineDef =
            { name = "combine"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "b")
                        (tPair (tVar "a") (tVar "b"))
                    )
            , body = callExpr (ctorExpr "MkPair") [ varExpr "x", varExpr "y" ]
            }

        -- process : a -> b -> Pair a b
        -- POLYMORPHIC CALLER with same var names a, b as combine
        processDef : TypedDef
        processDef =
            { name = "process"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "b")
                        (tPair (tVar "a") (tVar "b"))
                    )
            , body =
                letExpr
                    [ define "r1" []
                        (callExpr (varExpr "combine") [ varExpr "x", varExpr "y" ])
                    , define "r2" []
                        (callExpr (varExpr "combine") [ varExpr "x", varExpr "y" ])
                    ]
                    (varExpr "r2")
            }

        -- testValue : Pair Int String
        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tPair tInt tString
            , body =
                callExpr (varExpr "process") [ intExpr 42, strExpr "hello" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ combineDef, processDef, mainDef ]
                [ pairUnion ]
                []
    in
    expectFn modul


{-| Dict-like insert from a polymorphic caller with 3 colliding type vars.

    type MyDict k v = Empty | Entry k v (MyDict k v)

    insert : k -> v -> MyDict k v -> MyDict k v

    buildDict : k -> v -> v -> MyDict k v    -- poly caller, shares k, v
    buildDict key v1 v2 =
        let
            d0 = Empty
            d1 = insert key v1 d0             -- k→k__callee0, v→v__callee1
            d2 = insert key v2 d1             -- reuses k__callee0, v__callee1
        in                                    -- d1 type has unresolved MVars
        d2

    testValue = buildDict "key" 1 2

-}
dictInsertFromPolyCaller : (Src.Module -> Expectation) -> (() -> Expectation)
dictInsertFromPolyCaller expectFn _ =
    let
        tMyDict k v =
            tType "MyDict" [ k, v ]

        myDictUnion : UnionDef
        myDictUnion =
            { name = "MyDict"
            , args = [ "k", "v" ]
            , ctors =
                [ { name = "Empty", args = [] }
                , { name = "Entry"
                  , args =
                        [ tVar "k"
                        , tVar "v"
                        , tMyDict (tVar "k") (tVar "v")
                        ]
                  }
                ]
            }

        -- insert : k -> v -> MyDict k v -> MyDict k v
        insertDef : TypedDef
        insertDef =
            { name = "insert"
            , args = [ pVar "key", pVar "val", pVar "dict" ]
            , tipe =
                tLambda (tVar "k")
                    (tLambda (tVar "v")
                        (tLambda (tMyDict (tVar "k") (tVar "v"))
                            (tMyDict (tVar "k") (tVar "v"))
                        )
                    )
            , body =
                callExpr (ctorExpr "Entry")
                    [ varExpr "key", varExpr "val", varExpr "dict" ]
            }

        -- buildDict : k -> v -> v -> MyDict k v
        -- POLYMORPHIC CALLER with same var names k, v
        buildDictDef : TypedDef
        buildDictDef =
            { name = "buildDict"
            , args = [ pVar "key", pVar "v1", pVar "v2" ]
            , tipe =
                tLambda (tVar "k")
                    (tLambda (tVar "v")
                        (tLambda (tVar "v")
                            (tMyDict (tVar "k") (tVar "v"))
                        )
                    )
            , body =
                letExpr
                    [ define "d0" [] (callExpr (ctorExpr "Empty") [])
                    , define "d1" []
                        (callExpr (varExpr "insert")
                            [ varExpr "key", varExpr "v1", varExpr "d0" ]
                        )
                    , define "d2" []
                        (callExpr (varExpr "insert")
                            [ varExpr "key", varExpr "v2", varExpr "d1" ]
                        )
                    ]
                    (varExpr "d2")
            }

        -- size : MyDict k v -> Int
        sizeDef : TypedDef
        sizeDef =
            { name = "size"
            , args = [ pVar "d" ]
            , tipe = tLambda (tMyDict (tVar "k") (tVar "v")) tInt
            , body =
                caseExpr (varExpr "d")
                    [ ( pVar "empty", intExpr 0 )
                    , ( pVar "entry", intExpr 1 )
                    ]
            }

        -- testValue : Int
        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "size")
                    [ callExpr (varExpr "buildDict")
                        [ strExpr "key", intExpr 1, intExpr 2 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ insertDef, buildDictDef, sizeDef, mainDef ]
                [ myDictUnion ]
                []
    in
    expectFn modul


{-| Longer chain: 4 calls to the same polymorphic helper in a polymorphic
caller, each feeding its result to the next.

    type Box a = Box a

    wrap : a -> Box a -> Box a
    wrap x b = Box x

    chain4 : a -> Box a -> Box a
    chain4 x b =
        let r1 = wrap x b
            r2 = wrap x r1
            r3 = wrap x r2
            r4 = wrap x r3
        in r4

    testValue = chain4 42 (Box 0)

-}
chainedFeedForward4 : (Src.Module -> Expectation) -> (() -> Expectation)
chainedFeedForward4 expectFn _ =
    let
        tBox a =
            tType "Box" [ a ]

        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = [ "a" ]
            , ctors =
                [ { name = "Box", args = [ tVar "a" ] }
                ]
            }

        -- wrap : a -> Box a -> Box a
        wrapDef : TypedDef
        wrapDef =
            { name = "wrap"
            , args = [ pVar "x", pVar "b" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tBox (tVar "a"))
                        (tBox (tVar "a"))
                    )
            , body = callExpr (ctorExpr "Box") [ varExpr "x" ]
            }

        -- chain4 : a -> Box a -> Box a   (poly caller, shares `a`)
        chain4Def : TypedDef
        chain4Def =
            { name = "chain4"
            , args = [ pVar "x", pVar "b" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tBox (tVar "a"))
                        (tBox (tVar "a"))
                    )
            , body =
                letExpr
                    [ define "r1" []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "b" ])
                    , define "r2" []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "r1" ])
                    , define "r3" []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "r2" ])
                    , define "r4" []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "r3" ])
                    ]
                    (varExpr "r4")
            }

        -- testValue : Box Int
        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tBox tInt
            , body =
                callExpr (varExpr "chain4")
                    [ intExpr 42
                    , callExpr (ctorExpr "Box") [ intExpr 0 ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ wrapDef, chain4Def, mainDef ]
                [ boxUnion ]
                []
    in
    expectFn modul


{-| Nested wrapper: the type var appears inside a more complex structure.

    type Entry a = Entry (List a, Int) a

    addEntry : a -> Entry a -> Entry a
    addEntry x e = Entry ([], 0) x

    collect : a -> a -> Entry a     -- poly caller
    collect x y =
        let
            e1 = addEntry x (Entry ([], 0) x)
            e2 = addEntry y e1
        in e2

    testValue = collect "a" "b"

-}
nestedWrapperFromPolyCaller : (Src.Module -> Expectation) -> (() -> Expectation)
nestedWrapperFromPolyCaller expectFn _ =
    let
        tEntry a =
            tType "Entry" [ a ]

        entryUnion : UnionDef
        entryUnion =
            { name = "Entry"
            , args = [ "a" ]
            , ctors =
                [ { name = "MkEntry"
                  , args =
                        [ tTuple (tList (tVar "a")) tInt
                        , tVar "a"
                        ]
                  }
                ]
            }

        -- addEntry : a -> Entry a -> Entry a
        addEntryDef : TypedDef
        addEntryDef =
            { name = "addEntry"
            , args = [ pVar "x", pVar "e" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tEntry (tVar "a"))
                        (tEntry (tVar "a"))
                    )
            , body =
                callExpr (ctorExpr "MkEntry")
                    [ tupleExpr (listExpr []) (intExpr 0)
                    , varExpr "x"
                    ]
            }

        -- collect : a -> a -> Entry a   (poly caller)
        collectDef : TypedDef
        collectDef =
            { name = "collect"
            , args = [ pVar "x", pVar "y" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tVar "a")
                        (tEntry (tVar "a"))
                    )
            , body =
                letExpr
                    [ define "e1" []
                        (callExpr (varExpr "addEntry")
                            [ varExpr "x"
                            , callExpr (ctorExpr "MkEntry")
                                [ tupleExpr (listExpr []) (intExpr 0)
                                , varExpr "x"
                                ]
                            ]
                        )
                    , define "e2" []
                        (callExpr (varExpr "addEntry")
                            [ varExpr "y", varExpr "e1" ]
                        )
                    ]
                    (varExpr "e2")
            }

        -- testValue : Entry String
        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tEntry tString
            , body =
                callExpr (varExpr "collect") [ strExpr "a", strExpr "b" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ addEntryDef, collectDef, mainDef ]
                [ entryUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- CHAINED INSERT CASES (original tests, kept for regression coverage)
-- These call polymorphic helpers from CONCRETE contexts, so they don't
-- trigger the __callee collision. Kept as baseline regression tests.
-- ============================================================================


chainedInsertCases : (Src.Module -> Expectation) -> List TestCase
chainedInsertCases expectFn =
    [ { label = "Dict-like insert chained 5 times with tuple keys (concrete caller)"
      , run = dictInsertChain5 expectFn
      }
    , { label = "Dict-like insert chained 10 times with tuple keys (concrete caller)"
      , run = dictInsertChain10 expectFn
      }
    , { label = "Dict-like insert chained 5 times with (List String) keys (concrete caller)"
      , run = dictInsertChainListKey5 expectFn
      }
    ]


dictInsertChain5 : (Src.Module -> Expectation) -> (() -> Expectation)
dictInsertChain5 expectFn _ =
    dictInsertChainN 5 (tTuple tString tInt) expectFn


dictInsertChain10 : (Src.Module -> Expectation) -> (() -> Expectation)
dictInsertChain10 expectFn _ =
    dictInsertChainN 10 (tTuple tString tInt) expectFn


dictInsertChainListKey5 : (Src.Module -> Expectation) -> (() -> Expectation)
dictInsertChainListKey5 expectFn _ =
    dictInsertChainN 5 (tList tString) expectFn


dictInsertChainN : Int -> Src.Type -> (Src.Module -> Expectation) -> Expectation
dictInsertChainN n keyType expectFn =
    let
        tMyDict k v =
            tType "MyDict" [ k, v ]

        myDictUnion : UnionDef
        myDictUnion =
            { name = "MyDict"
            , args = [ "k", "v" ]
            , ctors =
                [ { name = "Empty", args = [] }
                , { name = "Entry"
                  , args =
                        [ tVar "k"
                        , tVar "v"
                        , tMyDict (tVar "k") (tVar "v")
                        ]
                  }
                ]
            }

        -- insert : k -> v -> MyDict k v -> MyDict k v
        insertDef : TypedDef
        insertDef =
            { name = "insert"
            , args = [ pVar "key", pVar "val", pVar "dict" ]
            , tipe =
                tLambda (tVar "k")
                    (tLambda (tVar "v")
                        (tLambda (tMyDict (tVar "k") (tVar "v"))
                            (tMyDict (tVar "k") (tVar "v"))
                        )
                    )
            , body =
                callExpr (ctorExpr "Entry")
                    [ varExpr "key", varExpr "val", varExpr "dict" ]
            }

        chainDefs : List Src.Def
        chainDefs =
            define "d0" [] (callExpr (ctorExpr "Empty") [])
                :: List.indexedMap
                    (\i _ ->
                        let
                            prevName =
                                "d" ++ String.fromInt i

                            currName =
                                "d" ++ String.fromInt (i + 1)
                        in
                        define currName
                            []
                            (callExpr (varExpr "insert")
                                [ tupleExpr (strExpr ("k" ++ String.fromInt i)) (intExpr i)
                                , intExpr (i * 10)
                                , varExpr prevName
                                ]
                            )
                    )
                    (List.repeat n ())

        lastDictName =
            "d" ++ String.fromInt n

        -- size : MyDict k v -> Int
        sizeDef : TypedDef
        sizeDef =
            { name = "size"
            , args = [ pVar "d" ]
            , tipe = tLambda (tMyDict (tVar "k") (tVar "v")) tInt
            , body =
                caseExpr (varExpr "d")
                    [ ( pVar "empty", intExpr 0 )
                    , ( pVar "entry", intExpr 1 )
                    ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                letExpr chainDefs
                    (callExpr (varExpr "size") [ varExpr lastDictName ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ insertDef, sizeDef, mainDef ]
                [ myDictUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- NESTED CONTAINER CASES (original tests, kept)
-- ============================================================================


nestedContainerCases : (Src.Module -> Expectation) -> List TestCase
nestedContainerCases expectFn =
    [ { label = "Nested container: Set of (module, name) pairs with multiple ops"
      , run = setOfPairsMultiOps expectFn
      }
    , { label = "Nested container: Graph node with complex key, multiple lookups"
      , run = graphNodeComplexKey expectFn
      }
    ]


setOfPairsMultiOps : (Src.Module -> Expectation) -> (() -> Expectation)
setOfPairsMultiOps expectFn _ =
    let
        tMySet a =
            tType "MySet" [ a ]

        tGlobal =
            tType "Global" []

        mySetUnion : UnionDef
        mySetUnion =
            { name = "MySet"
            , args = [ "a" ]
            , ctors =
                [ { name = "MySet", args = [ tList (tVar "a") ] }
                ]
            }

        globalUnion : UnionDef
        globalUnion =
            { name = "Global"
            , args = []
            , ctors =
                [ { name = "Global", args = [] }
                ]
            }

        -- singleton : a -> MySet a
        singletonDef : TypedDef
        singletonDef =
            { name = "singleton"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tMySet (tVar "a"))
            , body = callExpr (ctorExpr "MySet") [ listExpr [ varExpr "x" ] ]
            }

        -- union : MySet a -> MySet a -> MySet a
        unionDef : TypedDef
        unionDef =
            { name = "union"
            , args = [ pVar "s1", pVar "s2" ]
            , tipe =
                tLambda (tMySet (tVar "a"))
                    (tLambda (tMySet (tVar "a"))
                        (tMySet (tVar "a"))
                    )
            , body = varExpr "s1"
            }

        chainDefs : List Src.Def
        chainDefs =
            List.indexedMap
                (\i _ ->
                    define ("s" ++ String.fromInt (i + 1))
                        []
                        (callExpr (varExpr "singleton")
                            [ tupleExpr
                                (listExpr [ strExpr (String.fromInt i) ])
                                (callExpr (ctorExpr "Global") [])
                            ]
                        )
                )
                (List.repeat 8 ())

        -- Build nested union calls: union s1 (union s2 (... (union s7 s8)))
        nestedUnion : Src.Expr
        nestedUnion =
            List.foldr
                (\i acc ->
                    callExpr (varExpr "union")
                        [ varExpr ("s" ++ String.fromInt i), acc ]
                )
                (varExpr "s8")
                (List.range 1 7)

        -- count : MySet a -> Int
        countDef : TypedDef
        countDef =
            { name = "count"
            , args = [ pVar "s" ]
            , tipe = tLambda (tMySet (tVar "a")) tInt
            , body = intExpr 0
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                letExpr chainDefs
                    (callExpr (varExpr "count") [ nestedUnion ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ singletonDef, unionDef, countDef, mainDef ]
                [ mySetUnion, globalUnion ]
                []
    in
    expectFn modul


graphNodeComplexKey : (Src.Module -> Expectation) -> (() -> Expectation)
graphNodeComplexKey expectFn _ =
    let
        tGlobal =
            tType "Global" []

        globalUnion : UnionDef
        globalUnion =
            { name = "Global"
            , args = []
            , ctors =
                [ { name = "Global", args = [] }
                ]
            }

        -- lookup : k -> List (k, v) -> v -> v
        lookupDef : TypedDef
        lookupDef =
            { name = "lookup"
            , args = [ pVar "key", pVar "pairs", pVar "default" ]
            , tipe =
                tLambda (tVar "k")
                    (tLambda (tList (tTuple (tVar "k") (tVar "v")))
                        (tLambda (tVar "v") (tVar "v"))
                    )
            , body = varExpr "default"
            }

        chainDefs : List Src.Def
        chainDefs =
            List.indexedMap
                (\i _ ->
                    define ("r" ++ String.fromInt (i + 1))
                        []
                        (callExpr (varExpr "lookup")
                            [ tupleExpr
                                (listExpr [ strExpr ("mod" ++ String.fromInt i) ])
                                (callExpr (ctorExpr "Global") [])
                            , listExpr []
                            , intExpr 0
                            ]
                        )
                )
                (List.repeat 6 ())

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                letExpr chainDefs
                    (varExpr "r1")
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ lookupDef, mainDef ]
                [ globalUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- MULTIPLE CALLS TO SAME POLYMORPHIC FUNCTION (original tests, kept)
-- ============================================================================


multiCallSamePolyCases : (Src.Module -> Expectation) -> List TestCase
multiCallSamePolyCases expectFn =
    [ { label = "foldl-like called 8 times over tuple-keyed structure"
      , run = foldlChain8 expectFn
      }
    , { label = "map-then-fold chain over nested type params"
      , run = mapFoldChain expectFn
      }
    , { label = "foldl from polymorphic caller (triggers __callee collision)"
      , run = foldlFromPolyCaller expectFn
      }
    ]


foldlChain8 : (Src.Module -> Expectation) -> (() -> Expectation)
foldlChain8 expectFn _ =
    let
        tGlobal =
            tType "Global" []

        globalUnion : UnionDef
        globalUnion =
            { name = "Global"
            , args = []
            , ctors =
                [ { name = "Global", args = [] }
                ]
            }

        -- myFoldl : (a -> b -> b) -> b -> List a -> b
        myFoldlDef : TypedDef
        myFoldlDef =
            { name = "myFoldl"
            , args = [ pVar "f", pVar "init", pVar "xs" ]
            , tipe =
                tLambda
                    (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                    (tLambda (tVar "b")
                        (tLambda (tList (tVar "a")) (tVar "b"))
                    )
            , body = varExpr "init"
            }

        -- step : (List String, Global) -> Int -> Int
        stepDef : TypedDef
        stepDef =
            { name = "step"
            , args = [ pVar "entry", pVar "acc" ]
            , tipe =
                tLambda (tTuple (tList tString) tGlobal)
                    (tLambda tInt tInt)
            , body = varExpr "acc"
            }

        chainDefs : List Src.Def
        chainDefs =
            define "entries" [] (listExpr [])
                :: List.indexedMap
                    (\i _ ->
                        let
                            prevName =
                                if i == 0 then
                                    "0"

                                else
                                    "r" ++ String.fromInt i

                            currName =
                                "r" ++ String.fromInt (i + 1)

                            initExpr =
                                if i == 0 then
                                    intExpr 0

                                else
                                    varExpr prevName
                        in
                        define currName
                            []
                            (callExpr (varExpr "myFoldl")
                                [ varExpr "step"
                                , initExpr
                                , varExpr "entries"
                                ]
                            )
                    )
                    (List.repeat 8 ())

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                letExpr chainDefs
                    (varExpr "r8")
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ myFoldlDef, stepDef, mainDef ]
                [ globalUnion ]
                []
    in
    expectFn modul


mapFoldChain : (Src.Module -> Expectation) -> (() -> Expectation)
mapFoldChain expectFn _ =
    let
        tGlobal =
            tType "Global" []

        globalUnion : UnionDef
        globalUnion =
            { name = "Global"
            , args = []
            , ctors =
                [ { name = "Global", args = [] }
                ]
            }

        -- myFilter : (a -> Bool) -> List a -> List a
        myFilterDef : TypedDef
        myFilterDef =
            { name = "myFilter"
            , args = [ pVar "myPred", pVar "xs" ]
            , tipe =
                tLambda
                    (tLambda (tVar "a") tBool)
                    (tLambda (tList (tVar "a")) (tList (tVar "a")))
            , body = varExpr "xs"
            }

        -- myLength : List a -> Int
        myLengthDef : TypedDef
        myLengthDef =
            { name = "myLength"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tList (tVar "a")) tInt
            , body = intExpr 0
            }

        -- isGood : (List String, Global) -> Bool
        isGoodDef : TypedDef
        isGoodDef =
            { name = "isGood"
            , args = [ pVar "x" ]
            , tipe = tLambda (tTuple (tList tString) tGlobal) tBool
            , body = callExpr (ctorExpr "True") []
            }

        -- Chain 6 filter calls
        chainDefs : List Src.Def
        chainDefs =
            define "entries" [] (listExpr [])
                :: List.indexedMap
                    (\i _ ->
                        let
                            prevName =
                                if i == 0 then
                                    "entries"

                                else
                                    "r" ++ String.fromInt i

                            currName =
                                "r" ++ String.fromInt (i + 1)
                        in
                        define currName
                            []
                            (callExpr (varExpr "myFilter")
                                [ varExpr "isGood", varExpr prevName ]
                            )
                    )
                    (List.repeat 6 ())

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                letExpr chainDefs
                    (callExpr (varExpr "myLength") [ varExpr "r6" ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ myFilterDef, myLengthDef, isGoodDef, mainDef ]
                [ globalUnion ]
                []
    in
    expectFn modul


{-| The real-world pattern: foldl called from a POLYMORPHIC caller.

    myFoldl : (a -> b -> b) -> b -> List a -> b

    summarize : a -> List a -> Int     -- poly caller, shares `a` and `b`
    summarize x xs =
        let
            r1 = myFoldl (\_ acc -> acc) 0 xs
            r2 = myFoldl (\_ acc -> acc) r1 xs
            r3 = myFoldl (\_ acc -> acc) r2 xs
        in r3

    testValue = summarize "hello" []

-}
foldlFromPolyCaller : (Src.Module -> Expectation) -> (() -> Expectation)
foldlFromPolyCaller expectFn _ =
    let
        -- myFoldl : (a -> b -> b) -> b -> List a -> b
        myFoldlDef : TypedDef
        myFoldlDef =
            { name = "myFoldl"
            , args = [ pVar "f", pVar "init", pVar "xs" ]
            , tipe =
                tLambda
                    (tLambda (tVar "a") (tLambda (tVar "b") (tVar "b")))
                    (tLambda (tVar "b")
                        (tLambda (tList (tVar "a")) (tVar "b"))
                    )
            , body = varExpr "init"
            }

        -- summarize : a -> List a -> Int
        -- POLYMORPHIC CALLER — shares var `a` with myFoldl
        summarizeDef : TypedDef
        summarizeDef =
            { name = "summarize"
            , args = [ pVar "x", pVar "xs" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tList (tVar "a")) tInt)
            , body =
                letExpr
                    [ define "r1" []
                        (callExpr (varExpr "myFoldl")
                            [ lambdaExpr [ pVar "elem", pVar "acc1" ] (varExpr "acc1")
                            , intExpr 0
                            , varExpr "xs"
                            ]
                        )
                    , define "r2" []
                        (callExpr (varExpr "myFoldl")
                            [ lambdaExpr [ pVar "elem2", pVar "acc2" ] (varExpr "acc2")
                            , varExpr "r1"
                            , varExpr "xs"
                            ]
                        )
                    , define "r3" []
                        (callExpr (varExpr "myFoldl")
                            [ lambdaExpr [ pVar "elem3", pVar "acc3" ] (varExpr "acc3")
                            , varExpr "r2"
                            , varExpr "xs"
                            ]
                        )
                    ]
                    (varExpr "r3")
            }

        -- testValue : Int
        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "summarize") [ strExpr "hello", listExpr [] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ myFoldlDef, summarizeDef, mainDef ]
                []
                []
    in
    expectFn modul
