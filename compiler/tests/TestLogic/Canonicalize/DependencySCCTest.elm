module TestLogic.Canonicalize.DependencySCCTest exposing (suite)

{-| Tests meant to catch a canonicalizer that groups a module's top-level
definitions wrongly. What they can catch is narrower: one of three small
modules failing to get through the front end of the compiler.

The canonicalizer groups the top-level definitions into the strongly connected
components (SCCs) of their dependency graph, as
`TestLogic.Canonicalize.DependencySCC` describes. Each test builds a module with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, whose definitions carry no type
annotations, and passes it to
`TestLogic.Canonicalize.DependencySCC.expectValidSCCs`, whose docstring states
what it checks. What that means here is that a test passes when its module gets
through canonicalization, type checking and the PostSolve pass that follows type
checking, and fails when one of those stages fails.

The tests, all in `sccTests`:

  - "independent definitions have separate SCCs" runs a module of `a = 1`,
    `b = 2` and `c = 3`, none referring to another.
  - "linear dependency chain" runs a module of `a = 1`, `b = a` and `c = b`.
  - "simple function dependency" runs a module of `helper x = x` and
    `result = helper 42`.

Among what is not tested:

  - how the definitions are grouped or in what order the groups come, so the
    first test does not show that its definitions are in separate groups;
  - a definition that refers to itself, or definitions that refer to each
    other.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Canonicalize.DependencySCC exposing (expectValidSCCs)


{-| The tests of this module, under one label.
-}
suite : Test
suite =
    Test.describe "Dependency SCCs are correctly computed (CANON_005)"
        [ sccTests
        ]


{-| Three tests, each running a module of unannotated definitions with no
cycle among them through `expectValidSCCs`.
-}
sccTests : Test
sccTests =
    Test.describe "SCC computation"
        [ Test.test "independent definitions have separate SCCs" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Independent"
                            [ ( "a", [], SB.intExpr 1 )
                            , ( "b", [], SB.intExpr 2 )
                            , ( "c", [], SB.intExpr 3 )
                            ]
                in
                expectValidSCCs modul
        , Test.test "linear dependency chain" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Chain"
                            [ ( "a", [], SB.intExpr 1 )
                            , ( "b", [], SB.varExpr "a" )
                            , ( "c", [], SB.varExpr "b" )
                            ]
                in
                expectValidSCCs modul
        , Test.test "simple function dependency" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "FnDep"
                            [ ( "helper", [ SB.pVar "x" ], SB.varExpr "x" )
                            , ( "result"
                              , []
                              , SB.callExpr (SB.varExpr "helper") [ SB.intExpr 42 ]
                              )
                            ]
                in
                expectValidSCCs modul
        ]
