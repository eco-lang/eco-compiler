module SourceIR.RecursiveTreeTraversalCases exposing (expectSuite)

{-| Test cases covering gaps from e2e-to-elmtest.md:

  - Gap 13: Recursive tree type with traversal and accumulation (countNodes, sumTree)
  - Gap 21: PapExtend arity for multi-stage functions
  - Gap 25: Single-constructor Bool alongside other single-ctor types (already
    covered in CaseCases, but we add a tree-context variant)

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
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Recursive tree traversal " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "countNodes on Leaf", run = countNodesLeaf expectFn }
    , { label = "countNodes on nested tree", run = countNodesNested expectFn }
    , { label = "sumTree on Leaf", run = sumTreeLeaf expectFn }
    , { label = "sumTree on nested tree", run = sumTreeNested expectFn }
    , { label = "Tree depth with accumulation", run = treeDepth expectFn }
    , { label = "PapExtend multi-stage via applyPartial", run = papExtendMultiStage expectFn }
    , { label = "PapExtend multi-stage with flip pattern", run = papExtendFlip expectFn }
    , { label = "Single-ctor Bool wrapper with tree", run = singleCtorBoolWithTree expectFn }
    ]



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


tInt : Src.Type
tInt =
    tType "Int" []


tTree : Src.Type
tTree =
    tType "Tree" []


treeUnion : UnionDef
treeUnion =
    { name = "Tree"
    , args = []
    , ctors =
        [ { name = "Leaf", args = [] }
        , { name = "Node", args = [ tType "Tree" [], tType "Int" [], tType "Tree" [] ] }
        ]
    }



-- ============================================================================
-- RECURSIVE TREE TRAVERSAL (Gap 13)
-- ============================================================================


{-| countNodes tree = case tree of
Leaf -> 0
Node l \_ r -> 1 + countNodes l + countNodes r

Test with Leaf.

-}
countNodesLeaf : (Src.Module -> Expectation) -> (() -> Expectation)
countNodesLeaf expectFn _ =
    let
        countNodesDef : TypedDef
        countNodesDef =
            { name = "countNodes"
            , args = [ pVar "tree" ]
            , tipe = tLambda tTree tInt
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [], intExpr 0 )
                    , ( pCtor "Node" [ pVar "l", pAnything, pVar "r" ]
                      , binopsExpr
                            [ ( intExpr 1, "+" )
                            , ( callExpr (varExpr "countNodes") [ varExpr "l" ], "+" )
                            ]
                            (callExpr (varExpr "countNodes") [ varExpr "r" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body = callExpr (varExpr "countNodes") [ ctorExpr "Leaf" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ countNodesDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| countNodes (Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 Leaf))
Tests recursive traversal with accumulation on a nested tree.
-}
countNodesNested : (Src.Module -> Expectation) -> (() -> Expectation)
countNodesNested expectFn _ =
    let
        countNodesDef : TypedDef
        countNodesDef =
            { name = "countNodes"
            , args = [ pVar "tree" ]
            , tipe = tLambda tTree tInt
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [], intExpr 0 )
                    , ( pCtor "Node" [ pVar "l", pAnything, pVar "r" ]
                      , binopsExpr
                            [ ( intExpr 1, "+" )
                            , ( callExpr (varExpr "countNodes") [ varExpr "l" ], "+" )
                            ]
                            (callExpr (varExpr "countNodes") [ varExpr "r" ])
                      )
                    ]
            }

        -- Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 Leaf)
        innerLeft =
            callExpr (ctorExpr "Node") [ ctorExpr "Leaf", intExpr 1, ctorExpr "Leaf" ]

        innerRight =
            callExpr (ctorExpr "Node") [ ctorExpr "Leaf", intExpr 3, ctorExpr "Leaf" ]

        tree =
            callExpr (ctorExpr "Node") [ innerLeft, intExpr 2, innerRight ]

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body = callExpr (varExpr "countNodes") [ tree ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ countNodesDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| sumTree tree = case tree of
Leaf -> 0
Node l val r -> sumTree l + val + sumTree r

Test with Leaf.

-}
sumTreeLeaf : (Src.Module -> Expectation) -> (() -> Expectation)
sumTreeLeaf expectFn _ =
    let
        sumTreeDef : TypedDef
        sumTreeDef =
            { name = "sumTree"
            , args = [ pVar "tree" ]
            , tipe = tLambda tTree tInt
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [], intExpr 0 )
                    , ( pCtor "Node" [ pVar "l", pVar "val", pVar "r" ]
                      , binopsExpr
                            [ ( callExpr (varExpr "sumTree") [ varExpr "l" ], "+" )
                            , ( varExpr "val", "+" )
                            ]
                            (callExpr (varExpr "sumTree") [ varExpr "r" ])
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body = callExpr (varExpr "sumTree") [ ctorExpr "Leaf" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ sumTreeDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| sumTree (Node (Node Leaf 10 Leaf) 20 (Node Leaf 30 Leaf))
Tests recursive accumulation producing 10 + 20 + 30 = 60.
-}
sumTreeNested : (Src.Module -> Expectation) -> (() -> Expectation)
sumTreeNested expectFn _ =
    let
        sumTreeDef : TypedDef
        sumTreeDef =
            { name = "sumTree"
            , args = [ pVar "tree" ]
            , tipe = tLambda tTree tInt
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [], intExpr 0 )
                    , ( pCtor "Node" [ pVar "l", pVar "val", pVar "r" ]
                      , binopsExpr
                            [ ( callExpr (varExpr "sumTree") [ varExpr "l" ], "+" )
                            , ( varExpr "val", "+" )
                            ]
                            (callExpr (varExpr "sumTree") [ varExpr "r" ])
                      )
                    ]
            }

        innerLeft =
            callExpr (ctorExpr "Node") [ ctorExpr "Leaf", intExpr 10, ctorExpr "Leaf" ]

        innerRight =
            callExpr (ctorExpr "Node") [ ctorExpr "Leaf", intExpr 30, ctorExpr "Leaf" ]

        tree =
            callExpr (ctorExpr "Node") [ innerLeft, intExpr 20, innerRight ]

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body = callExpr (varExpr "sumTree") [ tree ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ sumTreeDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| maxDepth tree = case tree of
Leaf -> 0
Node l \_ r ->
let dl = maxDepth l
dr = maxDepth r
in 1 + (if dl > dr then dl else dr)

Tests recursive traversal with let bindings and conditional accumulation.

-}
treeDepth : (Src.Module -> Expectation) -> (() -> Expectation)
treeDepth expectFn _ =
    let
        maxDepthDef : TypedDef
        maxDepthDef =
            { name = "maxDepth"
            , args = [ pVar "tree" ]
            , tipe = tLambda tTree tInt
            , body =
                caseExpr (varExpr "tree")
                    [ ( pCtor "Leaf" [], intExpr 0 )
                    , ( pCtor "Node" [ pVar "l", pAnything, pVar "r" ]
                      , letExpr
                            [ define "dl" [] (callExpr (varExpr "maxDepth") [ varExpr "l" ])
                            , define "dr" [] (callExpr (varExpr "maxDepth") [ varExpr "r" ])
                            ]
                            (binopsExpr [ ( intExpr 1, "+" ) ]
                                (ifExpr
                                    (binopsExpr [ ( varExpr "dl", ">" ) ] (varExpr "dr"))
                                    (varExpr "dl")
                                    (varExpr "dr")
                                )
                            )
                      )
                    ]
            }

        -- Node (Node (Node Leaf 1 Leaf) 2 Leaf) 3 Leaf  -- depth 3
        deepTree =
            callExpr (ctorExpr "Node")
                [ callExpr (ctorExpr "Node")
                    [ callExpr (ctorExpr "Node") [ ctorExpr "Leaf", intExpr 1, ctorExpr "Leaf" ]
                    , intExpr 2
                    , ctorExpr "Leaf"
                    ]
                , intExpr 3
                , ctorExpr "Leaf"
                ]

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body = callExpr (varExpr "maxDepth") [ deepTree ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ maxDepthDef, testValueDef ]
                [ treeUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- PAP EXTEND ARITY FOR MULTI-STAGE FUNCTIONS (Gap 21)
-- ============================================================================


{-| curried : Int -> Int -> Int
curried x = \\y -> x + y

applyPartial : (Int -> Int -> Int) -> Int -> (Int -> Int)
applyPartial f a = f a

Test: applyPartial curried 3 returns a closure, then applied to 4 = 7.
Tests that sourceArityForCallee uses first-stage arity, not total arity.

-}
papExtendMultiStage : (Src.Module -> Expectation) -> (() -> Expectation)
papExtendMultiStage expectFn _ =
    let
        -- curried x = \y -> x + y (multi-stage: Int -> (Int -> Int))
        curriedDef : TypedDef
        curriedDef =
            { name = "curried"
            , args = [ pVar "x" ]
            , tipe = tLambda tInt (tLambda tInt tInt)
            , body =
                lambdaExpr [ pVar "y" ]
                    (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
            }

        -- applyPartial f a = f a
        applyPartialDef : TypedDef
        applyPartialDef =
            { name = "applyPartial"
            , args = [ pVar "f", pVar "a" ]
            , tipe =
                tLambda (tLambda tInt (tLambda tInt tInt))
                    (tLambda tInt (tLambda tInt tInt))
            , body = callExpr (varExpr "f") [ varExpr "a" ]
            }

        -- testValue = (applyPartial curried 3) 4
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr
                    (callExpr (varExpr "applyPartial") [ varExpr "curried", intExpr 3 ])
                    [ intExpr 4 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ curriedDef, applyPartialDef, testValueDef ]
                []
                []
    in
    expectFn modul


{-| flip : (a -> b -> c) -> b -> a -> c
flip f b a = f a b

curried x = \\y -> x + y
testValue = flip curried 10 3 -- curried 3 10 = 13

Tests papExtend arity through a flip combinator with a multi-stage function.

-}
papExtendFlip : (Src.Module -> Expectation) -> (() -> Expectation)
papExtendFlip expectFn _ =
    let
        curriedDef : TypedDef
        curriedDef =
            { name = "curried"
            , args = [ pVar "x" ]
            , tipe = tLambda tInt (tLambda tInt tInt)
            , body =
                lambdaExpr [ pVar "y" ]
                    (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "y"))
            }

        -- flip f b a = f a b
        flipDef : TypedDef
        flipDef =
            { name = "flip"
            , args = [ pVar "f", pVar "b", pVar "a" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tLambda (tVar "b") (tVar "c")))
                    (tLambda (tVar "b")
                        (tLambda (tVar "a") (tVar "c"))
                    )
            , body = callExpr (callExpr (varExpr "f") [ varExpr "a" ]) [ varExpr "b" ]
            }

        -- flip curried 10 3 = curried 3 10 = 3 + 10 = 13
        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "flip")
                    [ varExpr "curried", intExpr 10, intExpr 3 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ curriedDef, flipDef, testValueDef ]
                []
                []
    in
    expectFn modul



-- ============================================================================
-- SINGLE-CONSTRUCTOR BOOL WITH TREE CONTEXT (Gap 25)
-- ============================================================================


{-| type Tagged = Tagged Bool Tree
extractBool (Tagged b \_) = b

Tests single-constructor type wrapping Bool alongside Tree (another custom type),
ensuring findSingleCtorUnboxedField distinguishes them correctly.

-}
singleCtorBoolWithTree : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorBoolWithTree expectFn _ =
    let
        taggedUnion : UnionDef
        taggedUnion =
            { name = "Tagged"
            , args = []
            , ctors =
                [ { name = "Tagged", args = [ tType "Bool" [], tTree ] }
                ]
            }

        -- extractBool : Tagged -> Bool
        -- extractBool t = case t of Tagged b _ -> b
        extractBoolDef : TypedDef
        extractBoolDef =
            { name = "extractBool"
            , args = [ pVar "t" ]
            , tipe = tLambda (tType "Tagged" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pCtor "Tagged" [ pVar "b", pAnything ], varExpr "b" ) ]
            }

        -- extractTree : Tagged -> Tree
        -- extractTree t = case t of Tagged _ tr -> tr
        extractTreeDef : TypedDef
        extractTreeDef =
            { name = "extractTree"
            , args = [ pVar "t" ]
            , tipe = tLambda (tType "Tagged" []) tTree
            , body =
                caseExpr (varExpr "t")
                    [ ( pCtor "Tagged" [ pAnything, pVar "tr" ], varExpr "tr" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Bool" []
            , body =
                callExpr (varExpr "extractBool")
                    [ callExpr (ctorExpr "Tagged") [ boolExpr True, ctorExpr "Leaf" ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ extractBoolDef, extractTreeDef, testValueDef ]
                [ treeUnion, taggedUnion ]
                []
    in
    expectFn modul
