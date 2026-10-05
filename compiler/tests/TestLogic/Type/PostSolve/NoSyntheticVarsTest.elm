module TestLogic.Type.PostSolve.NoSyntheticVarsTest exposing (suite)

{-| Guards against a synthetic placeholder variable that no constraint
reached surviving PostSolve in the node types of four small programs.

The check, `TestLogic.Type.PostSolve.NoSyntheticVars.expectNoSyntheticVars`,
says what a synthetic placeholder is and how one left unconstrained is
recognised: a variable that is the whole type of a placeholder node and occurs
nowhere else. It fails on such a variable left in a node type after PostSolve,
and on a program that fails to canonicalize or type check.

Each program is built with `Compiler.AST.SourceBuilder.makeModuleWithDefs`: a
module importing `Basics` and `List` with one unannotated top-level value.

The tests:

  - `x = 1 + 2` in module `FullyConstrained`.
  - `id x = x` in module `Polymorphic`: the reference to `x` is a placeholder
    node whose type is a type variable, legitimately, since it is also the
    argument's.
  - `f = let x = 1 in let y = x in y` in module `NestedLet`: a `let` that is
    the body of another, the inner one using the outer one's binding.
  - `pick d = if True then 1 else (if d then 2 else 3)` in module
    `IfChainVars`: `True` and the reference to `d` are placeholder nodes typed
    only by being conditions. The outer condition's constraint was once dropped
    under the JavaScript backend, leaving the placeholder of `True`
    unconstrained.

Among what is not tested: a placeholder left unconstrained inside a larger
type, and annotated definitions.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.PostSolve.NoSyntheticVars exposing (expectNoSyntheticVars)


{-| The synthetic type variable tests, grouped under one label.
-}
suite : Test
suite =
    Test.describe "No synthetic type variables remain (POST_003)"
        [ syntheticVarTests
        ]


{-| The four programs, each run through `expectNoSyntheticVars`.
-}
syntheticVarTests : Test
syntheticVarTests =
    Test.describe "Synthetic variable elimination"
        [ Test.test "fully constrained expression has no synthetic vars" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "FullyConstrained"
                            [ ( "x"
                              , []
                              , SB.binopsExpr [ ( SB.intExpr 1, "+" ) ] (SB.intExpr 2)
                              )
                            ]
                in
                expectNoSyntheticVars modul
        , Test.test "polymorphic function generalizes properly" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Polymorphic"
                            [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" ) ]
                in
                expectNoSyntheticVars modul
        , Test.test "nested let with type propagation" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "NestedLet"
                            [ ( "f"
                              , []
                              , SB.letExpr
                                    [ SB.define "x" [] (SB.intExpr 1) ]
                                    (SB.letExpr
                                        [ SB.define "y" [] (SB.varExpr "x") ]
                                        (SB.varExpr "y")
                                    )
                              )
                            ]
                in
                expectNoSyntheticVars modul
        , Test.test "if chain conditions are constrained" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "IfChainVars"
                            [ ( "pick"
                              , [ SB.pVar "d" ]
                              , SB.ifExpr (SB.boolExpr True)
                                    (SB.intExpr 1)
                                    (SB.parensExpr (SB.ifExpr (SB.varExpr "d") (SB.intExpr 2) (SB.intExpr 3)))
                              )
                            ]
                in
                expectNoSyntheticVars modul
        ]
