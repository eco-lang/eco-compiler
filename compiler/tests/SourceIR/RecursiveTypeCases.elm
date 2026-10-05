module SourceIR.RecursiveTypeCases exposing (expectSuite, suite)

{-| Source programs whose custom types refer to themselves, so that a compiler
stage which follows a type into its constructors' arguments is run on a type
where that walk comes back to where it started.

A recursive type is one that is reached again by following its constructors'
arguments: directly (`Tree a` inside `Tree a`), from inside another type such
as a `List`, a `Maybe` or a record, or by way of a second declared type. Two
declared types that each refer to the other, such as `Forest a` and
`RoseTree a`, are called mutually recursive. A stage that expanded such a
type without noticing the cycle would never finish.

Each case builds one module, `TestMod`, with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`: the custom
types it declares, one annotated function taking a value of the recursive type
and returning an `Int`, and an annotated `testValue : Int` that applies that
function to a value built with one of the type's constructors. None of these
functions recurses, and none looks inside its argument beyond a `case` that
tells its constructors apart, so the recursion is in the types alone. The
module is handed to the caller's expectation function, which decides what is
checked; the cases are run with `Compiler.BulkCheck.bulkCheck`.

The cases, by the module each builds:

  - `directBinaryTree`: `Tree a`, with a `Branch` holding two `Tree a`.
  - `directLinkedList`: `LinkedList a`, with a `Cons` holding an `a` and a
    `LinkedList a`.
  - `mutualForestTree`: `Forest a` holding a `List (RoseTree a)`, and
    `RoseTree a` holding a `Forest a`.
  - `recursiveInTuple`: `Crumb a`, whose constructor holds a
    `List ( Crumb a, Int )`, so the recursion passes through a tuple.
  - `recursiveInRecord`: `Expr a`, whose `Compound` holds a record with a
    `List (Expr a)` field.
  - `recursiveViaAlias`: `Container a`, whose `Box` holds a `Node a`, a type
    alias for a record with a `Maybe (Container a)` field, `Maybe` being a
    union the module declares itself.

`suite` runs the six cases in order against
`TestLogic.TestPipeline.expectMonomorphization`, stopping at the first failure.
Its title names `resolveMonoVars` (in `Compiler.Monomorphize.TypeSubst`), but
nothing here observes which functions of the monomorphizer run. For each case,
`expectMonomorphization` passes when monomorphization succeeds and the
resulting graph has a `main` and at least one node.

Among what is not tested: any recursive function over these types, a pattern
that binds the recursive part of a value, and a value that holds another value
of its own type.

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
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| The six cases checked in order against
`TestLogic.TestPipeline.expectMonomorphization` as one test, which stops at the
first failing case.
-}
suite : Test
suite =
    Test.describe "Recursive type resolveMonoVars cycle detection"
        [ expectSuite expectMonomorphization "monomorphizes recursive types"
        ]


{-| Builds one test, named "Recursive types " followed by `condStr`, that
applies `expectFn` to the six modules in order, stops at the first whose
expectation fails, and fails with that case's label followed by its failure
description.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Recursive types " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each applying `expectFn` to its module: the
`directRecursionCases`, then `mutualRecursionTypeCases`, then
`nestedRecursionCases`.
-}
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


{-| The type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| Builds the type `List a`.
-}
tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]



-- ============================================================================
-- DIRECT RECURSIVE TYPE TESTS
-- ============================================================================


{-| Returns the two cases whose type is recursive directly: the binary tree
and the linked list.
-}
directRecursionCases : (Src.Module -> Expectation) -> List TestCase
directRecursionCases expectFn =
    [ { label = "Direct recursive type: binary tree", run = directBinaryTree expectFn }
    , { label = "Direct recursive type: linked list custom type", run = directLinkedList expectFn }
    ]


{-| Applies `expectFn` to a module declaring a binary tree, written here as
Elm source:

    type Tree a
        = Leaf a
        | Branch (Tree a) (Tree a)

    depth : Tree a -> Int
    depth t =
        case t of
            Leaf _ ->
                0

            Branch _ _ ->
                1

    testValue : Int
    testValue =
        depth (Leaf 42)

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

        depthDef : TypedDef
        depthDef =
            { name = "depth"
            , args = [ pVar "t" ]
            , tipe = tLambda (tTree (tVar "a")) tInt
            , body =
                caseExpr (varExpr "t")
                    [ ( pCtor "Leaf" [ pAnything ], intExpr 0 )
                    , ( pCtor "Branch" [ pAnything, pAnything ], intExpr 1 )
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


{-| Applies `expectFn` to a module declaring a linked list whose recursive
reference is the second argument of `Cons`, written here as Elm source:

    type LinkedList a
        = Empty
        | Cons a (LinkedList a)

    len : LinkedList a -> Int
    len xs =
        case xs of
            Empty ->
                0

            Cons _ _ ->
                1

    testValue : Int
    testValue =
        len Empty

The argument `Empty` is built as a call with no arguments, which source text
cannot express.

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

        lenDef : TypedDef
        lenDef =
            { name = "len"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tLinkedList (tVar "a")) tInt
            , body =
                caseExpr (varExpr "xs")
                    [ ( pCtor "Empty" [], intExpr 0 )
                    , ( pCtor "Cons" [ pAnything, pAnything ], intExpr 1 )
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


{-| Returns the case built around the mutually recursive types `Forest` and
`RoseTree`.
-}
mutualRecursionTypeCases : (Src.Module -> Expectation) -> List TestCase
mutualRecursionTypeCases expectFn =
    [ { label = "Mutually recursive types: Forest/Tree", run = mutualForestTree expectFn }
    ]


{-| Applies `expectFn` to a module declaring two types that each refer to the
other, the cycle passing through a `List`, written here as Elm source:

    type Forest a
        = Forest (List (RoseTree a))

    type RoseTree a
        = RoseNode a (Forest a)

    countNodes : Forest a -> Int
    countNodes f =
        0

    testValue : Int
    testValue =
        countNodes (Forest [])

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


{-| Returns three cases whose recursive reference is nested: in a tuple in a
`List`, in a `List` in a record field, and in a `Maybe` in a field of a record
named by a type alias.
-}
nestedRecursionCases : (Src.Module -> Expectation) -> List TestCase
nestedRecursionCases expectFn =
    [ { label = "Recursive type nested in tuple", run = recursiveInTuple expectFn }
    , { label = "Recursive type nested in record", run = recursiveInRecord expectFn }
    , { label = "Recursive type nested in type alias", run = recursiveViaAlias expectFn }
    ]


{-| Applies `expectFn` to a module whose recursion passes through a tuple in a
list, written here as Elm source:

    type Crumb a
        = Crumb a (List ( Crumb a, Int ))

    size : Crumb a -> Int
    size c =
        0

    testValue : Int
    testValue =
        size (Crumb 1 [])

-}
recursiveInTuple : (Src.Module -> Expectation) -> (() -> Expectation)
recursiveInTuple expectFn _ =
    let
        tCrumb a =
            tType "Crumb" [ a ]

        crumbUnion : UnionDef
        crumbUnion =
            { name = "Crumb"
            , args = [ "a" ]
            , ctors =
                [ { name = "Crumb"
                  , args = [ tVar "a", tList (tTuple (tCrumb (tVar "a")) tInt) ]
                  }
                ]
            }

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
                [ crumbUnion ]
                []
    in
    expectFn modul


{-| Applies `expectFn` to a module whose recursion passes through a field of a
record that is a constructor's argument, written here as Elm source:

    type Expr a
        = Lit a
        | Compound { tag : Int, children : List (Expr a) }

    eval : Expr a -> Int
    eval e =
        case e of
            Lit _ ->
                0

            Compound _ ->
                1

    testValue : Int
    testValue =
        eval (Lit 42)

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

        evalDef : TypedDef
        evalDef =
            { name = "eval"
            , args = [ pVar "e" ]
            , tipe = tLambda (tExpr (tVar "a")) tInt
            , body =
                caseExpr (varExpr "e")
                    [ ( pCtor "Lit" [ pAnything ], intExpr 0 )
                    , ( pCtor "Compound" [ pAnything ], intExpr 1 )
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


{-| Applies `expectFn` to a module whose recursion passes through a `Maybe`
inside a record named by a type alias that is a constructor's argument, written
here as Elm source:

    type alias Node a =
        { value : a, next : Maybe (Container a) }

    type Container a
        = Box (Node a)

    type Maybe a
        = Just a
        | Nothing

    depth : Container a -> Int
    depth c =
        0

    testValue : Int
    testValue =
        depth (Box { value = 1, next = Nothing })

`Nothing` is built as a call with no arguments, which source text cannot
express. The module declares its own `Maybe` alongside the imported one.

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
                [ { name = "Box", args = [ tType "Node" [ tVar "a" ] ] }
                ]
            }

        nodeAlias : AliasDef
        nodeAlias =
            { name = "Node"
            , args = [ "a" ]
            , tipe =
                tRecord
                    [ ( "value", tVar "a" )
                    , ( "next", tMaybe (tContainer (tVar "a")) )
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
                [ nodeAlias ]
    in
    expectFn modul
