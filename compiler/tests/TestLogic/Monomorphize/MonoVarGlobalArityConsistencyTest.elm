module TestLogic.Monomorphize.MonoVarGlobalArityConsistencyTest exposing (suite)

{-| These tests exist because, in a monomorphized graph, a `MonoVarGlobal`
reference to a specialized top-level function carries its own copy of the
function's type, and nothing in the graph makes that copy agree with the type
stored on the function's node. Without a check, a reference could claim a
different number of parameters from its node, or a call through it could
supply more arguments than the node takes, and no test would say so. The test
names call this property MONO\_027.

The check is `TestLogic.Monomorphize.MonoVarGlobalArityConsistency`'s
`expectVarGlobalArityConsistency`, whose docstring defines the _flattened
arity_ it compares, the three kinds of mismatch it looks for and what it leaves
out. It runs a program through global optimization with the substitution
engine, and a program that fails to compile fails the check.

The programs are of two kinds. The first is the standard catalogue of
`SourceIR` programs that `SourceIR.Suite.StandardTestSuites` assembles. The
second is three hand-built modules in which every function is a top-level
definition. A top-level function is specialized into a node of its own and
referred to by a `MonoVarGlobal`, so these modules put partially applied
references to such nodes in front of the check.

The tests establish:

  - "has consistent VarGlobal arities": the check passes on every program of
    the standard catalogue.
  - "Top-level SKI combinators (partial application)": the check passes on the
    three hand-built modules, `bCombinatorTopLevel`, `iCombinatorTopLevel` and
    `partialApp3TopLevel`. They run as one test with `Compiler.BulkCheck`, so a
    failure reports only the first module that fails.

Among what is not tested:

  - the solver engine's graph, and the graph before global optimization;
  - the value any program computes, since nothing is run.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , makeModuleWithDefs
        , pAnything
        , pVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoVarGlobalArityConsistency exposing (expectVarGlobalArityConsistency)


{-| The MONO\_027 tests: the check over the standard catalogue, and the check
over the three hand-built top-level modules as one test.
-}
suite : Test
suite =
    Test.describe "MonoVarGlobal arity consistency (MONO_027)"
        [ StandardTestSuites.expectSuite expectVarGlobalArityConsistency "has consistent VarGlobal arities"
        , Test.test "Top-level SKI combinators (partial application)" <|
            \_ -> bulkCheck (topLevelCombinatorCases expectVarGlobalArityConsistency)
        ]



-- ============================================================================
-- TOP-LEVEL COMBINATOR CASES
-- ============================================================================


{-| Returns the three hand-built top-level cases, labelled, each applying
`expectFn` to its module.
-}
topLevelCombinatorCases : (Src.Module -> Expectation) -> List TestCase
topLevelCombinatorCases expectFn =
    [ { label = "B combinator: b = s (k s) k (top-level)", run = bCombinatorTopLevel expectFn }
    , { label = "I combinator: i = s k k (top-level)", run = iCombinatorTopLevel expectFn }
    , { label = "Partial application of 3-arg function (top-level)", run = partialApp3TopLevel expectFn }
    ]


{-| Applies `expectFn` to a module in which the B combinator is defined at top
level from S and K, and then applied to two functions and an `Int`. `s` is
applied to two of its three arguments and `k` to one of its two, and `b` has
no parameters of its own but a type of flattened arity three.

The module is named `testValue` and has these top-level definitions, sketched
as Elm source:

    k a _ =
        a

    s bf uf x =
        bf x (uf x)

    b =
        s (k s) k

    square x =
        x * x

    inc x =
        x + 1

    testValue =
        b square inc 4

-}
bCombinatorTopLevel : (Src.Module -> Expectation) -> (() -> Expectation)
bCombinatorTopLevel expectFn _ =
    let
        modul =
            makeModuleWithDefs "testValue"
                [ ( "k", [ pVar "a", pAnything ], varExpr "a" )
                , ( "s"
                  , [ pVar "bf", pVar "uf", pVar "x" ]
                  , callExpr (varExpr "bf")
                        [ varExpr "x"
                        , callExpr (varExpr "uf") [ varExpr "x" ]
                        ]
                  )
                , ( "b"
                  , []
                  , callExpr (varExpr "s")
                        [ callExpr (varExpr "k") [ varExpr "s" ]
                        , varExpr "k"
                        ]
                  )
                , ( "square", [ pVar "x" ], binopsExpr [ ( varExpr "x", "*" ) ] (varExpr "x") )
                , ( "inc", [ pVar "x" ], binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) )
                , ( "testValue"
                  , []
                  , callExpr (varExpr "b") [ varExpr "square", varExpr "inc", intExpr 4 ]
                  )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module in which the I combinator is defined at top
level as `s k k`, which applies `s` to two of its three arguments, and then
applied to an `Int`.

The module is named `testValue` and has these top-level definitions, sketched
as Elm source:

    k a _ =
        a

    s bf uf x =
        bf x (uf x)

    i =
        s k k

    testValue =
        i 42

-}
iCombinatorTopLevel : (Src.Module -> Expectation) -> (() -> Expectation)
iCombinatorTopLevel expectFn _ =
    let
        modul =
            makeModuleWithDefs "testValue"
                [ ( "k", [ pVar "a", pAnything ], varExpr "a" )
                , ( "s"
                  , [ pVar "bf", pVar "uf", pVar "x" ]
                  , callExpr (varExpr "bf")
                        [ varExpr "x"
                        , callExpr (varExpr "uf") [ varExpr "x" ]
                        ]
                  )
                , ( "i"
                  , []
                  , callExpr (varExpr "s") [ varExpr "k", varExpr "k" ]
                  )
                , ( "testValue"
                  , []
                  , callExpr (varExpr "i") [ intExpr 42 ]
                  )
                ]
    in
    expectFn modul


{-| Applies `expectFn` to a module in which a top-level function of three
parameters is applied to one argument, and the resulting top-level value, which
has no parameters of its own, is applied to the other two.

The module is named `testValue` and has these top-level definitions, sketched
as Elm source:

    add3 a b c =
        (a + b) + c

    partialAdd =
        add3 1

    testValue =
        partialAdd 2 3

-}
partialApp3TopLevel : (Src.Module -> Expectation) -> (() -> Expectation)
partialApp3TopLevel expectFn _ =
    let
        modul =
            makeModuleWithDefs "testValue"
                [ ( "add3"
                  , [ pVar "a", pVar "b", pVar "c" ]
                  , binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b"), "+" ) ]
                        (varExpr "c")
                  )
                , ( "partialAdd"
                  , []
                  , callExpr (varExpr "add3") [ intExpr 1 ]
                  )
                , ( "testValue"
                  , []
                  , callExpr (varExpr "partialAdd") [ intExpr 2, intExpr 3 ]
                  )
                ]
    in
    expectFn modul
