module TestLogic.Monomorphize.MonoVarGlobalArityConsistencyTest exposing (suite)

{-| Test suite for invariant MONO\_027: MonoVarGlobal type arity matches node arity.

Verifies that every MonoVarGlobal reference carries a MonoType whose flattened
function arity equals the flattened arity of the referenced node's actual type.

Uses both StandardTestSuites (let-binding based test cases) and targeted test cases
with top-level definitions to exercise partial application of module-level functions.

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


suite : Test
suite =
    Test.describe "MonoVarGlobal arity consistency (MONO_027)"
        [ StandardTestSuites.expectSuite expectVarGlobalArityConsistency "has consistent VarGlobal arities"
        , Test.test "Top-level SKI combinators (partial application)" <|
            \_ -> bulkCheck (topLevelCombinatorCases expectVarGlobalArityConsistency)
        ]



-- ============================================================================
-- TOP-LEVEL COMBINATOR CASES
-- These use makeModuleWithDefs to create top-level definitions (not let bindings)
-- which forces the monomorphizer to create separate specialization nodes.
-- ============================================================================


topLevelCombinatorCases : (Src.Module -> Expectation) -> List TestCase
topLevelCombinatorCases expectFn =
    [ { label = "B combinator: b = s (k s) k (top-level)", run = bCombinatorTopLevel expectFn }
    , { label = "I combinator: i = s k k (top-level)", run = iCombinatorTopLevel expectFn }
    , { label = "Partial application of 3-arg function (top-level)", run = partialApp3TopLevel expectFn }
    ]


{-| B combinator with top-level definitions:

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


{-| I combinator with top-level definitions (should pass — no truncation):

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


{-| Partial application of a 3-arg function at top level:

    add3 a b c =
        a + b + c

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
