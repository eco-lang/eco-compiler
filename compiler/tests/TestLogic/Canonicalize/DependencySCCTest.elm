module TestLogic.Canonicalize.DependencySCCTest exposing (suite)

{-| Tests that catch a canonicalizer that groups a module's top-level
definitions wrongly.

The canonicalizer groups the top-level definitions into the strongly connected
components (SCCs) of their dependency graph, as
`TestLogic.Canonicalize.DependencySCC` describes. Each test builds a module with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, whose definitions carry no type
annotations, and passes it to
`TestLogic.Canonicalize.DependencySCC.expectSCCGroups`, which checks the
grouping (no `Declare` depends on itself, dependencies point to earlier or the
same component, recursive groups are strongly connected) and compares the
components with the expected ones.

The tests, all in `sccTests`:

  - "independent definitions have separate SCCs": `a = 1`, `b = 2`, `c = 3`,
    three non-recursive components.
  - "linear dependency chain": `a = 1`, `b = a`, `c = b`.
  - "dependency written after its use": `c = b`, `b = a`, `a = 1`, so the
    canonicalizer must reorder the source.
  - "simple function dependency": `helper x = x` and `result = helper 42`.
  - "self-recursive function": `loop x = loop x`, a recursive group of one.
  - "mutually recursive functions": `ping x = pong x`, `pong x = ping x` and
    `user = ping 1`, a recursive group of two followed by its user.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Canonicalize.DependencySCC exposing (expectSCCGroups)


{-| The tests of this module, under one label.
-}
suite : Test
suite =
    Test.describe "Dependency SCCs are correctly computed (CANON_005)"
        [ sccTests
        ]


{-| Six tests, each running a module of unannotated definitions through
`expectSCCGroups` with the components it should be grouped into.
-}
sccTests : Test
sccTests =
    Test.describe "SCC computation"
        [ Test.test "independent definitions have separate SCCs" <|
            \_ ->
                SB.makeModuleWithDefs "Independent"
                    [ ( "a", [], SB.intExpr 1 )
                    , ( "b", [], SB.intExpr 2 )
                    , ( "c", [], SB.intExpr 3 )
                    ]
                    |> expectSCCGroups [ ( [ "a" ], False ), ( [ "b" ], False ), ( [ "c" ], False ) ]
        , Test.test "linear dependency chain" <|
            \_ ->
                SB.makeModuleWithDefs "Chain"
                    [ ( "a", [], SB.intExpr 1 )
                    , ( "b", [], SB.varExpr "a" )
                    , ( "c", [], SB.varExpr "b" )
                    ]
                    |> expectSCCGroups [ ( [ "a" ], False ), ( [ "b" ], False ), ( [ "c" ], False ) ]
        , Test.test "dependency written after its use" <|
            \_ ->
                SB.makeModuleWithDefs "Reversed"
                    [ ( "c", [], SB.varExpr "b" )
                    , ( "b", [], SB.varExpr "a" )
                    , ( "a", [], SB.intExpr 1 )
                    ]
                    |> expectSCCGroups [ ( [ "a" ], False ), ( [ "b" ], False ), ( [ "c" ], False ) ]
        , Test.test "simple function dependency" <|
            \_ ->
                SB.makeModuleWithDefs "FnDep"
                    [ ( "helper", [ SB.pVar "x" ], SB.varExpr "x" )
                    , ( "result"
                      , []
                      , SB.callExpr (SB.varExpr "helper") [ SB.intExpr 42 ]
                      )
                    ]
                    |> expectSCCGroups [ ( [ "helper" ], False ), ( [ "result" ], False ) ]
        , Test.test "self-recursive function" <|
            \_ ->
                SB.makeModuleWithDefs "SelfRec"
                    [ ( "loop", [ SB.pVar "x" ], SB.callExpr (SB.varExpr "loop") [ SB.varExpr "x" ] ) ]
                    |> expectSCCGroups [ ( [ "loop" ], True ) ]
        , Test.test "mutually recursive functions" <|
            \_ ->
                SB.makeModuleWithDefs "MutualRec"
                    [ ( "user", [], SB.callExpr (SB.varExpr "ping") [ SB.intExpr 1 ] )
                    , ( "ping", [ SB.pVar "x" ], SB.callExpr (SB.varExpr "pong") [ SB.varExpr "x" ] )
                    , ( "pong", [ SB.pVar "x" ], SB.callExpr (SB.varExpr "ping") [ SB.varExpr "x" ] )
                    ]
                    |> expectSCCGroups [ ( [ "ping", "pong" ], True ), ( [ "user" ], False ) ]
        ]
