module SourceIR.RecursiveTypeCases exposing (expectSuite, suite)

{-| Test cases for recursive and mutually recursive data types in monomorphization.

These tests cover resolveMonoVars cycle detection for:

  - Direct recursive types (e.g. type Tree a = Leaf a | Branch (Tree a) (Tree a))
  - Mutually recursive types (e.g. Node/Tree like Elm's Array internals)
  - Recursive types nested inside tuples, records, and lists
  - Deep nesting where the recursive step is buried in complex type structure

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , UnionDef
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


suite : Test
suite =
    Test.describe "Recursive type resolveMonoVars cycle detection"
        [ expectSuite expectMonomorphization "monomorphizes recursive types"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Recursive types " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ directRecursionCases expectFn
        , mutualRecursionTypeCases expectFn
        , nestedRecursionCases expectFn
        ]



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


tInt : Src.Type
tInt =
    tType "Int" []


tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]



-- ============================================================================
-- DIRECT RECURSIVE TYPE TESTS
-- ============================================================================


directRecursionCases : (Src.Module -> Expectation) -> List TestCase
directRecursionCases expectFn =
    [ { label = "Direct recursive type: binary tree", run = directBinaryTree expectFn }
    , { label = "Direct recursive type: linked list custom type", run = directLinkedList expectFn }
    ]


{-| type Tree a = Leaf a | Branch (Tree a) (Tree a)

A function that pattern matches on this type forces resolveMonoVars
to traverse MCustom args containing the same type variable.

-}
directBinaryTree : (Src.Module -> Expectation) -> (() -> Expectation)
directBinaryTree expectFn _ =
    let
        tTree a =
            tType "Tree" [ a ]

        treeUnion : UnionDef
        treeUnion =
            { name = "Tree"
            , args = [ "a" ]
            , ctors =
                [ { name = "Leaf", args = [ tVar "a" ] }
                , { name = "Branch", args = [ tTree (tVar "a"), tTree (tVar "a") ] }
                ]
            }

        -- depth : Tree a -> Int
        -- depth t = case t of
        --     Leaf _ -> 0
        --     Branch l r -> 1 + depth l
        depthDef : TypedDef
        depthDef =
            { name = "depth"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTree (tVar "a")) tInt
            , body =
                caseExpr (varExpr "t")
                    [ ( pVar "leaf", intExpr 0 )
                    , ( pVar "branch", intExpr 1 )
                    ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "depth")
                    [ callExpr (ctorExpr "Leaf") [ intExpr 42 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ depthDef, mainDef ]
                [ treeUnion ]
                []
    in
    expectFn modul


{-| type LinkedList a = Nil | Cons a (LinkedList a)

Direct recursive custom type where the recursive reference is the second
constructor argument.

-}
directLinkedList : (Src.Module -> Expectation) -> (() -> Expectation)
directLinkedList expectFn _ =
    let
        tLinkedList a =
            tType "LinkedList" [ a ]

        myListUnion : UnionDef
        myListUnion =
            { name = "LinkedList"
            , args = [ "a" ]
            , ctors =
                [ { name = "Empty", args = [] }
                , { name = "Cons", args = [ tVar "a", tLinkedList (tVar "a") ] }
                ]
            }

        -- len : LinkedList a -> Int
        -- len xs = case xs of Nil -> 0; Cons _ rest -> 1
        lenDef : TypedDef
        lenDef =
            { name = "len"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tLinkedList (tVar "a")) tInt
            , body =
                caseExpr (varExpr "xs")
                    [ ( pVar "nil", intExpr 0 )
                    , ( pVar "cons", intExpr 1 )
                    ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "len")
                    [ callExpr (ctorExpr "Empty") [] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ lenDef, mainDef ]
                [ myListUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- MUTUALLY RECURSIVE TYPE TESTS
-- ============================================================================


mutualRecursionTypeCases : (Src.Module -> Expectation) -> List TestCase
mutualRecursionTypeCases expectFn =
    [ { label = "Mutually recursive types: Forest/Tree", run = mutualForestTree expectFn }
    ]


{-| type Forest a = Forest (List (RoseTree a))
type RoseTree a = RoseNode a (Forest a)

Mutually recursive types where Forest references RoseTree and vice versa.
This mirrors the Array/Node/Tree pattern that causes the original stack overflow.

-}
mutualForestTree : (Src.Module -> Expectation) -> (() -> Expectation)
mutualForestTree expectFn _ =
    let
        tForest a =
            tType "Forest" [ a ]

        tRoseTree a =
            tType "RoseTree" [ a ]

        forestUnion : UnionDef
        forestUnion =
            { name = "Forest"
            , args = [ "a" ]
            , ctors =
                [ { name = "Forest", args = [ tList (tRoseTree (tVar "a")) ] }
                ]
            }

        roseTreeUnion : UnionDef
        roseTreeUnion =
            { name = "RoseTree"
            , args = [ "a" ]
            , ctors =
                [ { name = "RoseNode", args = [ tVar "a", tForest (tVar "a") ] }
                ]
            }

        -- countNodes : Forest a -> Int
        countNodesDef : TypedDef
        countNodesDef =
            { name = "countNodes"
            , args = [ pVar "f" ]
            , tipe = tLambda (tForest (tVar "a")) tInt
            , body = intExpr 0
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "countNodes")
                    [ callExpr (ctorExpr "Forest") [ listExpr [] ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ countNodesDef, mainDef ]
                [ forestUnion, roseTreeUnion ]
                []
    in
    expectFn modul



-- ============================================================================
-- DEEPLY NESTED RECURSIVE TYPE TESTS
-- ============================================================================


nestedRecursionCases : (Src.Module -> Expectation) -> List TestCase
nestedRecursionCases expectFn =
    [ { label = "Recursive type nested in tuple", run = recursiveInTuple expectFn }
    , { label = "Recursive type nested in record", run = recursiveInRecord expectFn }
    , { label = "Recursive type nested in type alias", run = recursiveViaAlias expectFn }
    ]


{-| type Crumb a = Crumb a (List (Pair a))
type Pair a = MkPair (Crumb a) Int

The recursive step goes through a second custom type (Pair) which wraps
Crumb back. This tests cycle detection through nested custom type references.

-}
recursiveInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveInTuple expectFn _ =
    let
        tCrumb a =
            tType "Crumb" [ a ]

        tPair a =
            tType "Pair" [ a ]

        crumbUnion : UnionDef
        crumbUnion =
            { name = "Crumb"
            , args = [ "a" ]
            , ctors =
                [ { name = "Crumb"
                  , args = [ tVar "a", tList (tPair (tVar "a")) ]
                  }
                ]
            }

        pairUnion : UnionDef
        pairUnion =
            { name = "Pair"
            , args = [ "a" ]
            , ctors =
                [ { name = "MkPair"
                  , args = [ tCrumb (tVar "a"), tInt ]
                  }
                ]
            }

        -- size : Crumb a -> Int
        sizeDef : TypedDef
        sizeDef =
            { name = "size"
            , args = [ pVar "c" ]
            , tipe = tLambda (tCrumb (tVar "a")) tInt
            , body = intExpr 0
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "size")
                    [ callExpr (ctorExpr "Crumb") [ intExpr 1, listExpr [] ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ sizeDef, mainDef ]
                [ crumbUnion, pairUnion ]
                []
    in
    expectFn modul


{-| type Expr a = Lit a | Compound { tag : Int, children : List (Expr a) }

The recursive step is inside a record inside a constructor argument.
Tests cycle detection through record field types.

-}
recursiveInRecord : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveInRecord expectFn _ =
    let
        tExpr a =
            tType "Expr" [ a ]

        exprUnion : UnionDef
        exprUnion =
            { name = "Expr"
            , args = [ "a" ]
            , ctors =
                [ { name = "Lit", args = [ tVar "a" ] }
                , { name = "Compound"
                  , args =
                        [ tRecord
                            [ ( "tag", tInt )
                            , ( "children", tList (tExpr (tVar "a")) )
                            ]
                        ]
                  }
                ]
            }

        -- eval : Expr a -> Int
        evalDef : TypedDef
        evalDef =
            { name = "eval"
            , args = [ pVar "e" ]
            , tipe = tLambda (tExpr (tVar "a")) tInt
            , body =
                caseExpr (varExpr "e")
                    [ ( pVar "lit", intExpr 0 )
                    , ( pVar "compound", intExpr 1 )
                    ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "eval")
                    [ callExpr (ctorExpr "Lit") [ intExpr 42 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ evalDef, mainDef ]
                [ exprUnion ]
                []
    in
    expectFn modul


{-| type alias Wrapper a = { value : a, next : Maybe (Container a) }
type Container a = Box (Wrapper a)

The recursive step goes through a type alias, which should be expanded
before resolveMonoVars encounters it.

-}
recursiveViaAlias : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveViaAlias expectFn _ =
    let
        tContainer a =
            tType "Container" [ a ]

        tMaybe a =
            tType "Maybe" [ a ]

        containerUnion : UnionDef
        containerUnion =
            { name = "Container"
            , args = [ "a" ]
            , ctors =
                [ { name = "Box"
                  , args =
                        [ tRecord
                            [ ( "value", tVar "a" )
                            , ( "next", tMaybe (tContainer (tVar "a")) )
                            ]
                        ]
                  }
                ]
            }

        maybeUnion : UnionDef
        maybeUnion =
            { name = "Maybe"
            , args = [ "a" ]
            , ctors =
                [ { name = "Just", args = [ tVar "a" ] }
                , { name = "Nothing", args = [] }
                ]
            }

        -- depth : Container a -> Int
        depthDef : TypedDef
        depthDef =
            { name = "depth"
            , args = [ pVar "c" ]
            , tipe = tLambda (tContainer (tVar "a")) tInt
            , body = intExpr 0
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "depth")
                    [ callExpr (ctorExpr "Box")
                        [ recordExpr
                            [ ( "value", intExpr 1 )
                            , ( "next", callExpr (ctorExpr "Nothing") [] )
                            ]
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "TestMod"
                [ depthDef, mainDef ]
                [ containerUnion, maybeUnion ]
                []
    in
    expectFn modul
