module SourceIR.PolyChainCases exposing (expectSuite, suite)

{-| Programs that call a polymorphic helper several times, some of them from a
polymorphic caller written with the same type variable names, for checking that
specialization keeps the type variables of separate calls, and of caller and
helper, apart.

When a polymorphic function is specialized, each call it makes to a polymorphic
helper needs its own copy of the helper's type variables. In the first group of
programs, and in one other, the caller and the helper are written with the same
type variable names (`buildTree : a -> a -> Tree a` calls
`insertTree : a -> Tree a -> Tree a`), and the helper is called more than once,
often with one call's result passed to the next. A specializer that mixed up
the caller's `a` with the helper's, or carried one call's binding into the
next, could bind `a` to a type that contains `a`, such as `Tree a`. No finite
type solves such a binding, and detecting one is called the _occurs check_,
after which the first group is named. The other programs call polymorphic
helpers repeatedly from `testValue` itself. The substitution engine gives a
helper's type variables fresh ids when it builds the helper's type scheme, and
fresh ones again each time it reuses that scheme, as
`Compiler.Monomorphize.TypeSubst.buildSchemeInfo` and `refreshSchemeInfo`
describe.

The module asserts nothing itself. `expectSuite` hands the programs, in order,
to the expectation it is given, stopping at the first that fails, so what is
checked depends on the caller.
`SourceIR.Suite.StandardTestSuites` includes it in the standard suite, which
stage tests run with their own expectations, and `suite` runs it with
`TestLogic.TestPipeline.expectMonomorphization`.

Each program is a module `TestMod` built with
`makeModuleWithTypedDefsUnionsAliases`, so it has the standard imports. Every
top-level definition is annotated, and the program's `testValue` is annotated
with a type that has no type variables. Most helper bodies ignore some of their
arguments, so what matters in a program is its types rather than what it
computes. The sketches in the docstrings below are Elm source, not the trees
as built: for example, a constructor with no arguments is built as a call with
no arguments, which source text cannot express, and a parenthesised argument
has no `Parens` node around it. The `case` in `sizeTree` and `size`, as sketched
and as built, has two variable branches, the second of which can never match.

The fourteen cases fall into four groups:

  - `occursCheckCases`: six programs where a polymorphic caller that shares
    type variable names with a polymorphic helper calls it two or four times.
    The shared variables sit inside a custom type, a tuple, or a tuple inside a
    constructor field.
  - `chainedInsertCases`: three programs that insert into a dictionary-like
    custom type five or ten times in a row, from `testValue` rather than from a
    polymorphic caller.
  - `nestedContainerCases`: two programs that pass `( List String, Global )`
    tuples to a polymorphic helper repeatedly: eight `singleton` calls whose
    sets are combined by `union`, and six `lookup` calls.
  - `multiCallSamePolyCases`: three programs that call a fold-like or
    filter-like helper three to eight times in a chain, one of them from a
    polymorphic caller.

Among what is not tested: nothing here inspects the specializations a program
produces, such as their types or how many there are, beyond what the given
expectation inspects. `expectMonomorphization`, which `suite` uses, checks only
that monomorphization with the substitution engine succeeds and gives a graph
with a `main` and a node array that is not empty.

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
import TestLogic.TestPipeline exposing (expectMonomorphization)


{-| A test that checks the cases with
`TestLogic.TestPipeline.expectMonomorphization`, in order, stopping at the
first that fails.
-}
suite : Test
suite =
    Test.describe "Chained polymorphic calls over complex types"
        [ expectSuite expectMonomorphization "monomorphizes poly chains"
        ]


{-| Builds one test, named `Poly chain cases` followed by `condStr`, that applies
`expectFn` to each case's program in turn until one fails. It runs the cases
through `Compiler.BulkCheck.bulkCheck`, so a failure names only the first case
that fails.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Poly chain cases " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the cases of `occursCheckCases`, `chainedInsertCases`,
`nestedContainerCases` and `multiCallSamePolyCases`, in that order, each
checking its program with `expectFn`.
-}
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


{-| The type `Int`, named without qualification.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The type `String`, named without qualification.
-}
tString : Src.Type
tString =
    tType "String" []


{-| Returns the type `List a`, with `List` named without qualification.
-}
tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]


{-| The type `Bool`, named without qualification.
-}
tBool : Src.Type
tBool =
    tType "Bool" []



-- ============================================================================
-- OCCURS CHECK CASES
-- ============================================================================


{-| Returns the six cases in which a polymorphic caller calls a polymorphic
helper that uses the same type variable names, each checking its program with
`expectFn`.
-}
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


{-| Applies `expectFn` to a program in which `buildTree` calls `insertTree` twice
and passes the first result to the second call, with both functions written in
terms of `a`. The type variable sits inside the custom type `Tree a`.

    type Tree a
        = Leaf
        | Node (Tree a) a (Tree a)

    insertTree : a -> Tree a -> Tree a
    insertTree val tree =
        Node tree val Leaf

    buildTree : a -> a -> Tree a
    buildTree x y =
        let
            t1 =
                insertTree x Leaf

            t2 =
                insertTree y t1
        in
        t2

    sizeTree : Tree a -> Int
    sizeTree t =
        case t of
            leaf ->
                0

            node ->
                1

    testValue : Int
    testValue =
        sizeTree (buildTree 1 2)

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
                    [ define "t1"
                        []
                        (callExpr (varExpr "insertTree")
                            [ varExpr "x", callExpr (ctorExpr "Leaf") [] ]
                        )
                    , define "t2"
                        []
                        (callExpr (varExpr "insertTree")
                            [ varExpr "y", varExpr "t1" ]
                        )
                    ]
                    (varExpr "t2")
            }

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


{-| Applies `expectFn` to a program in which `tagBoth` calls `tag` twice, with
both functions written in terms of `a`, and `tag` returns `a` inside the tuple
`( a, Int )`. Neither call's result is passed to the other, and the first is
unused.

    tag : a -> ( a, Int )
    tag x =
        ( x, 0 )

    tagBoth : a -> a -> ( a, Int )
    tagBoth x y =
        let
            r1 =
                tag x

            r2 =
                tag y
        in
        r2

    testValue : ( String, Int )
    testValue =
        tagBoth "hello" "world"

-}
tupleWrapFromPolyCaller : (Src.Module -> Expectation) -> (() -> Expectation)
tupleWrapFromPolyCaller expectFn _ =
    let
        tagDef : TypedDef
        tagDef =
            { name = "tag"
            , args = [ pVar "x" ]
            , tipe =
                tLambda (tVar "a")
                    (tTuple (tVar "a") tInt)
            , body = tupleExpr (varExpr "x") (intExpr 0)
            }

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


{-| Applies `expectFn` to a program in which `process` calls `combine` twice
with the same arguments, with both functions written in terms of `a` and `b`, so
that two type variables are shared. The first call's result is unused.

    type Pair a b
        = MkPair a b

    combine : a -> b -> Pair a b
    combine x y =
        MkPair x y

    process : a -> b -> Pair a b
    process x y =
        let
            r1 =
                combine x y

            r2 =
                combine x y
        in
        r2

    testValue : Pair Int String
    testValue =
        process 42 "hello"

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
                    [ define "r1"
                        []
                        (callExpr (varExpr "combine") [ varExpr "x", varExpr "y" ])
                    , define "r2"
                        []
                        (callExpr (varExpr "combine") [ varExpr "x", varExpr "y" ])
                    ]
                    (varExpr "r2")
            }

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


{-| Applies `expectFn` to a program in which `buildDict` calls `insert` twice and
passes the first result to the second call, with both functions written in
terms of `k` and `v`. The case's label counts three colliding type variables;
the two functions share two.

    type MyDict k v
        = Empty
        | Entry k v (MyDict k v)

    insert : k -> v -> MyDict k v -> MyDict k v
    insert key val dict =
        Entry key val dict

    buildDict : k -> v -> v -> MyDict k v
    buildDict key v1 v2 =
        let
            d0 =
                Empty

            d1 =
                insert key v1 d0

            d2 =
                insert key v2 d1
        in
        d2

    size : MyDict k v -> Int
    size d =
        case d of
            empty ->
                0

            entry ->
                1

    testValue : Int
    testValue =
        size (buildDict "key" 1 2)

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
                    , define "d1"
                        []
                        (callExpr (varExpr "insert")
                            [ varExpr "key", varExpr "v1", varExpr "d0" ]
                        )
                    , define "d2"
                        []
                        (callExpr (varExpr "insert")
                            [ varExpr "key", varExpr "v2", varExpr "d1" ]
                        )
                    ]
                    (varExpr "d2")
            }

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


{-| Applies `expectFn` to a program in which `chain4` calls `wrap` four times,
each call after the first taking the previous result, with both functions
written in terms of `a`. `wrap` ignores its second argument.

    type Box a
        = Box a

    wrap : a -> Box a -> Box a
    wrap x b =
        Box x

    chain4 : a -> Box a -> Box a
    chain4 x b =
        let
            r1 =
                wrap x b

            r2 =
                wrap x r1

            r3 =
                wrap x r2

            r4 =
                wrap x r3
        in
        r4

    testValue : Box Int
    testValue =
        chain4 42 (Box 0)

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
                    [ define "r1"
                        []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "b" ])
                    , define "r2"
                        []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "r1" ])
                    , define "r3"
                        []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "r2" ])
                    , define "r4"
                        []
                        (callExpr (varExpr "wrap") [ varExpr "x", varExpr "r3" ])
                    ]
                    (varExpr "r4")
            }

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


{-| Applies `expectFn` to a program in which `collect` calls `addEntry` twice and
passes the first result to the second call, with both functions written in
terms of `a`. The type variable appears on its own and inside the tuple
`( List a, Int )`, both in fields of the one constructor.

    type Entry a
        = MkEntry ( List a, Int ) a

    addEntry : a -> Entry a -> Entry a
    addEntry x e =
        MkEntry ( [], 0 ) x

    collect : a -> a -> Entry a
    collect x y =
        let
            e1 =
                addEntry x (MkEntry ( [], 0 ) x)

            e2 =
                addEntry y e1
        in
        e2

    testValue : Entry String
    testValue =
        collect "a" "b"

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
                    [ define "e1"
                        []
                        (callExpr (varExpr "addEntry")
                            [ varExpr "x"
                            , callExpr (ctorExpr "MkEntry")
                                [ tupleExpr (listExpr []) (intExpr 0)
                                , varExpr "x"
                                ]
                            ]
                        )
                    , define "e2"
                        []
                        (callExpr (varExpr "addEntry")
                            [ varExpr "y", varExpr "e1" ]
                        )
                    ]
                    (varExpr "e2")
            }

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
-- CHAINED INSERT CASES
-- ============================================================================


{-| Returns the three cases that insert into a `MyDict` several times in a row
from `testValue`, each checking its program with `expectFn`. All three use keys
of the same tuple type: the third case's label speaks of `List String` keys, but
`dictInsertChainN` ignores the key type it is given.
-}
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


{-| Applies `expectFn` to the `dictInsertChainN` program with five inserts.
-}
dictInsertChain5 : (Src.Module -> Expectation) -> (() -> Expectation)
dictInsertChain5 expectFn _ =
    dictInsertChainN 5 (tTuple tString tInt) expectFn


{-| Applies `expectFn` to the `dictInsertChainN` program with ten inserts.
-}
dictInsertChain10 : (Src.Module -> Expectation) -> (() -> Expectation)
dictInsertChain10 expectFn _ =
    dictInsertChainN 10 (tTuple tString tInt) expectFn


{-| Applies `expectFn` to the `dictInsertChainN` program with five inserts. The
`List String` key type it passes is ignored, so the program is the same as the
one `dictInsertChain5` checks.
-}
dictInsertChainListKey5 : (Src.Module -> Expectation) -> (() -> Expectation)
dictInsertChainListKey5 expectFn _ =
    dictInsertChainN 5 (tList tString) expectFn


{-| Applies `expectFn` to a program whose `testValue` inserts `n` entries into an
empty `MyDict`, each insert taking the previous dictionary, and returns the
`size` of the last.

The second argument, a key type, is not used. The insert numbered `i`, counting
from 0, has the key `( "k<i>", i )` and the value `i * 10`, written as integer
literals. `MyDict`, `insert` and `size` are as in `dictInsertFromPolyCaller`.

    testValue : Int
    testValue =
        let
            d0 =
                Empty

            d1 =
                insert ( "k0", 0 ) 0 d0

            d2 =
                insert ( "k1", 1 ) 10 d1

            -- and so on, up to dn
        in
        size dn

-}
dictInsertChainN : Int -> Src.Type -> (Src.Module -> Expectation) -> Expectation
dictInsertChainN n _ expectFn =
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
-- NESTED CONTAINER CASES
-- ============================================================================


{-| Returns the two cases that call polymorphic helpers several times with a
`( List String, Global )` tuple, each checking its program with `expectFn`.
-}
nestedContainerCases : (Src.Module -> Expectation) -> List TestCase
nestedContainerCases expectFn =
    [ { label = "Nested container: Set of (module, name) pairs with multiple ops"
      , run = setOfPairsMultiOps expectFn
      }
    , { label = "Nested container: Graph node with complex key, multiple lookups"
      , run = graphNodeComplexKey expectFn
      }
    ]


{-| Applies `expectFn` to a program that makes eight one-element sets of
`( List String, Global )` tuples with `singleton` and combines them with seven
nested calls to `union`. `union` returns its first argument, and `count` always
returns 0.

    type MySet a
        = MySet (List a)

    type Global
        = Global

    singleton : a -> MySet a
    singleton x =
        MySet [ x ]

    union : MySet a -> MySet a -> MySet a
    union s1 s2 =
        s1

    count : MySet a -> Int
    count s =
        0

    testValue : Int
    testValue =
        let
            s1 =
                singleton ( [ "0" ], Global )

            -- and so on, up to s8 = singleton ( [ "7" ], Global )
        in
        count (union s1 (union s2 (union s3 (union s4 (union s5 (union s6 (union s7 s8)))))))

-}
setOfPairsMultiOps : (Src.Module -> Expectation) -> (() -> Expectation)
setOfPairsMultiOps expectFn _ =
    let
        tMySet a =
            tType "MySet" [ a ]

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

        singletonDef : TypedDef
        singletonDef =
            { name = "singleton"
            , args = [ pVar "x" ]
            , tipe = tLambda (tVar "a") (tMySet (tVar "a"))
            , body = callExpr (ctorExpr "MySet") [ listExpr [ varExpr "x" ] ]
            }

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

        nestedUnion : Src.Expr
        nestedUnion =
            List.foldr
                (\i acc ->
                    callExpr (varExpr "union")
                        [ varExpr ("s" ++ String.fromInt i), acc ]
                )
                (varExpr "s8")
                (List.range 1 7)

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


{-| Applies `expectFn` to a program that calls `lookup` six times, each with a
`( List String, Global )` key, an empty list and 0, and returns the first
result. `lookup` returns its third argument.

    type Global
        = Global

    lookup : k -> List ( k, v ) -> v -> v
    lookup key pairs default =
        default

    testValue : Int
    testValue =
        let
            r1 =
                lookup ( [ "mod0" ], Global ) [] 0

            -- and so on, up to r6 = lookup ( [ "mod5" ], Global ) [] 0
        in
        r1

-}
graphNodeComplexKey : (Src.Module -> Expectation) -> (() -> Expectation)
graphNodeComplexKey expectFn _ =
    let
        globalUnion : UnionDef
        globalUnion =
            { name = "Global"
            , args = []
            , ctors =
                [ { name = "Global", args = [] }
                ]
            }

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
-- MULTIPLE CALLS TO SAME POLYMORPHIC FUNCTION
-- ============================================================================


{-| Returns the three cases that call one polymorphic helper repeatedly in a
chain, each checking its program with `expectFn`.
-}
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


{-| Applies `expectFn` to a program that calls `myFoldl` eight times from
`testValue`, the first call starting from 0 and each later call from the
previous result, all over the same empty list. `step` fixes the element type
to `( List String, Global )` and the accumulator to `Int`. `myFoldl` returns
its initial value.

    type Global
        = Global

    myFoldl : (a -> b -> b) -> b -> List a -> b
    myFoldl f init xs =
        init

    step : ( List String, Global ) -> Int -> Int
    step entry acc =
        acc

    testValue : Int
    testValue =
        let
            entries =
                []

            r1 =
                myFoldl step 0 entries

            r2 =
                myFoldl step r1 entries

            -- and so on, up to r8
        in
        r8

-}
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


{-| Applies `expectFn` to a program that calls `myFilter` six times from
`testValue`, the first call filtering the empty list `entries` and each later
call the previous result, and then takes `myLength` of the last. Despite the
case's label, it has no map and no fold. `isGood` fixes the element type to
`( List String, Global )`; `myFilter` returns its list unchanged and
`myLength` returns 0.

    type Global
        = Global

    myFilter : (a -> Bool) -> List a -> List a
    myFilter myPred xs =
        xs

    myLength : List a -> Int
    myLength xs =
        0

    isGood : ( List String, Global ) -> Bool
    isGood x =
        True

    testValue : Int
    testValue =
        let
            entries =
                []

            r1 =
                myFilter isGood entries

            -- and so on, up to r6 = myFilter isGood r5
        in
        myLength r6

-}
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

        myLengthDef : TypedDef
        myLengthDef =
            { name = "myLength"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tList (tVar "a")) tInt
            , body = intExpr 0
            }

        isGoodDef : TypedDef
        isGoodDef =
            { name = "isGood"
            , args = [ pVar "x" ]
            , tipe = tLambda (tTuple (tList tString) tGlobal) tBool
            , body = callExpr (ctorExpr "True") []
            }

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


{-| Applies `expectFn` to a program in which `summarize`, written in terms of
`a`, calls `myFoldl`, written in terms of `a` and `b`, three times, the first
call starting from 0 and each later call from the previous result. Only `a` is
shared. Each call passes a lambda that returns its accumulator.

    myFoldl : (a -> b -> b) -> b -> List a -> b
    myFoldl f init xs =
        init

    summarize : a -> List a -> Int
    summarize x xs =
        let
            r1 =
                myFoldl (\elem acc1 -> acc1) 0 xs

            r2 =
                myFoldl (\elem2 acc2 -> acc2) r1 xs

            r3 =
                myFoldl (\elem3 acc3 -> acc3) r2 xs
        in
        r3

    testValue : Int
    testValue =
        summarize "hello" []

-}
foldlFromPolyCaller : (Src.Module -> Expectation) -> (() -> Expectation)
foldlFromPolyCaller expectFn _ =
    let
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

        summarizeDef : TypedDef
        summarizeDef =
            { name = "summarize"
            , args = [ pVar "x", pVar "xs" ]
            , tipe =
                tLambda (tVar "a")
                    (tLambda (tList (tVar "a")) tInt)
            , body =
                letExpr
                    [ define "r1"
                        []
                        (callExpr (varExpr "myFoldl")
                            [ lambdaExpr [ pVar "elem", pVar "acc1" ] (varExpr "acc1")
                            , intExpr 0
                            , varExpr "xs"
                            ]
                        )
                    , define "r2"
                        []
                        (callExpr (varExpr "myFoldl")
                            [ lambdaExpr [ pVar "elem2", pVar "acc2" ] (varExpr "acc2")
                            , varExpr "r1"
                            , varExpr "xs"
                            ]
                        )
                    , define "r3"
                        []
                        (callExpr (varExpr "myFoldl")
                            [ lambdaExpr [ pVar "elem3", pVar "acc3" ] (varExpr "acc3")
                            , varExpr "r2"
                            , varExpr "xs"
                            ]
                        )
                    ]
                    (varExpr "r3")
            }

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
