module SourceIR.RecursiveTreeTraversalCases exposing (expectSuite)

{-| Supplies source programs of three shapes for a caller's check to be run
on:

  - a function that recurses over a user-defined tree type, so that it calls
    itself from inside a `case` on that type;
  - a function applied in more stages than it declares parameters, so that a
    call to it takes fewer arguments than its type has;
  - a single-constructor type that holds a `Bool` beside a value of another
    custom type, so that one constructor has fields of two different kinds.

This module decides nothing about what is checked. `expectSuite` hands each of
eight programs to the caller's expectation function and combines the results
with `Compiler.BulkCheck.bulkCheck`, whose docstring says how a failure is
reported. Each program is a module named `TestMod` whose top-level values are
all annotated, and its value `testValue` is the expression the program is about.

Six of the programs declare the type `Tree`, which is either `Leaf` or a
`Node` holding a left subtree, an `Int` and a right subtree. In the
single-constructor program it is the second field of the wrapper.

A _multi-stage_ function is one whose body returns a function, so it takes its
arguments in more than one application. Both partial-application programs use
`curried x = \y -> x + y`: its annotation is `Int -> Int -> Int`, but it
declares one parameter, so its first stage takes one argument and returns a
function that takes the second. In the first of them, `applyPartial` is
multi-stage as well. The two labels that begin "PapExtend" refer to
extending a _partial application_, a function value that has been given some of
its arguments but not all, with more of them.

The cases, by label:

  - "countNodes on Leaf": `countNodes`, which gives 0 for `Leaf` and, for a
    `Node`, 1 plus the counts of both subtrees, applied to `Leaf`.
  - "countNodes on nested tree": the same `countNodes` applied to a tree of
    three nodes.
  - "sumTree on Leaf": `sumTree`, which gives 0 for `Leaf` and, for a `Node`,
    the sum of its left subtree, its `Int` and the sum of its right subtree,
    applied to `Leaf`.
  - "sumTree on nested tree": the same `sumTree` applied to a tree of three
    nodes holding 10, 20 and 30.
  - "Tree depth with accumulation": `maxDepth`, which binds the depths of both
    subtrees in a `let` and adds 1 to the larger, chosen by an `if`, applied to
    a tree of depth 3.
  - "PapExtend multi-stage via applyPartial": `curried`, passed as a value to
    `applyPartial f a = f a`, which applies it to one argument and returns the
    function that results; `testValue` applies that function to a second
    argument.
  - "PapExtend multi-stage with flip pattern": `curried`, passed as a value to
    `flip f b a`, which applies `f` to `a` and then applies the result to `b`.
  - "Single-ctor Bool wrapper with tree": a type `Tagged` whose one
    constructor holds a `Bool` and a `Tree`, and a function that takes the
    `Bool` back out. `SourceIR.CaseCases` has single-constructor wrappers of a
    `Bool` beside wrappers of other types; here the other field of the same
    constructor is a custom type.

Among what is not tested: anything a pipeline stage does with these programs,
which is decided by the expectation function the caller passes; and the value
of `testValue`. The results given in the docstrings below are what the
programs compute, and nothing here compares them with anything.

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


{-| Builds one test, named "Recursive tree traversal " followed by `condStr`,
that passes when `expectFn` passes every program this module builds. When
`expectFn` fails one, the failure names the label of the first it fails.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Recursive tree traversal " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the eight labelled cases, each of which, when run, gives the result
of `expectFn` on one program.
-}
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


{-| A reference to the type `Int`, for use in an annotation.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| A reference to the type `Tree`, which `treeUnion` declares, for use in an
annotation or a constructor's fields.
-}
tTree : Src.Type
tTree =
    tType "Tree" []


{-| The declaration of `Tree`, a binary tree with an `Int` at each node and no
type parameter. `Leaf` is the empty tree, and `Node` holds the left subtree, the
`Int` and the right subtree, in that order.
-}
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
-- RECURSIVE TREE TRAVERSAL
-- ============================================================================


{-| Runs `expectFn` on a module declaring `Tree`, `countNodes` and
`testValue = countNodes Leaf`, which is 0. `countNodes` gives 0 for `Leaf` and,
for a `Node`, 1 plus the counts of its two subtrees, so it calls itself twice.
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


{-| Runs `expectFn` on a module declaring `Tree`, the same `countNodes` as
`countNodesLeaf`, and
`testValue = countNodes (Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 Leaf))`,
which is 3.
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


{-| Runs `expectFn` on a module declaring `Tree`, `sumTree` and
`testValue = sumTree Leaf`, which is 0. `sumTree` gives 0 for `Leaf` and, for a
`Node`, the sum of its left subtree, its `Int` and the sum of its right subtree.
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


{-| Runs `expectFn` on a module declaring `Tree`, the same `sumTree` as
`sumTreeLeaf`, and
`testValue = sumTree (Node (Node Leaf 10 Leaf) 20 (Node Leaf 30 Leaf))`,
which is 60.
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


{-| Runs `expectFn` on a module declaring `Tree`, `maxDepth` and
`testValue = maxDepth (Node (Node (Node Leaf 1 Leaf) 2 Leaf) 3 Leaf)`, which
is 3. `maxDepth` gives 0 for `Leaf`; for a `Node` it binds the depths of the two
subtrees as `dl` and `dr` in a `let`, and gives 1 plus
`if dl > dr then dl else dr`.
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
-- PARTIAL APPLICATION OF MULTI-STAGE FUNCTIONS
-- ============================================================================


{-| Runs `expectFn` on a module declaring `curried x = \y -> x + y`, annotated
`Int -> Int -> Int`; `applyPartial f a = f a`, annotated
`(Int -> Int -> Int) -> Int -> Int -> Int`; and
`testValue = (applyPartial curried 3) 4`, which is 7.

Both `curried` and `applyPartial` are multi-stage: each declares one parameter
fewer than its annotation has arguments. Inside `applyPartial`, `f a` gives
`curried` one argument, which is all its first stage takes, and the function
that results is returned unapplied; `testValue` applies it to 4.

-}
papExtendMultiStage : (Src.Module -> Expectation) -> (() -> Expectation)
papExtendMultiStage expectFn _ =
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

        applyPartialDef : TypedDef
        applyPartialDef =
            { name = "applyPartial"
            , args = [ pVar "f", pVar "a" ]
            , tipe =
                tLambda (tLambda tInt (tLambda tInt tInt))
                    (tLambda tInt (tLambda tInt tInt))
            , body = callExpr (varExpr "f") [ varExpr "a" ]
            }

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


{-| Runs `expectFn` on a module declaring the same `curried` as
`papExtendMultiStage`; `flip f b a`, annotated `(a -> b -> c) -> b -> a -> c`,
whose body is `(f a) b`; and `testValue = flip curried 10 3`, which is
`curried 3 10`, or 13.

`flip` applies `f` one argument at a time, so `curried` is given one argument,
all its first stage takes, and the function that results is then applied to the
second.

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
-- SINGLE-CONSTRUCTOR BOOL BESIDE A TREE
-- ============================================================================


{-| Runs `expectFn` on a module declaring `Tree`; a type `Tagged` with one
constructor, `Tagged Bool Tree`; `extractBool` and `extractTree`, which take the
`Bool` and the `Tree` out of a `Tagged` with a `case`; and
`testValue = extractBool (Tagged True Leaf)`, which is `True`. `extractTree` is
declared but not used by `testValue`.
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

        extractBoolDef : TypedDef
        extractBoolDef =
            { name = "extractBool"
            , args = [ pVar "t" ]
            , tipe = tLambda (tType "Tagged" []) (tType "Bool" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pCtor "Tagged" [ pVar "b", pAnything ], varExpr "b" ) ]
            }

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
