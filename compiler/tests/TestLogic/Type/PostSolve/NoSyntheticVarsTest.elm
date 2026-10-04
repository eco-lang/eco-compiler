module TestLogic.Type.PostSolve.NoSyntheticVarsTest exposing (suite)

{-| Guards against a type variable with a generated-looking name surviving
PostSolve in the node types of three small programs.

A node is an expression or pattern of the canonical module that carries a node
id. PostSolve leaves an array of node types indexed by node id, with `Nothing`
at an id that has no type. The check,
`TestLogic.Type.PostSolve.NoSyntheticVars.expectNoSyntheticVars`, calls a type
variable _synthetic_ by its name alone: a name that is empty, starts with a
digit, or is an underscore followed by at least one more character. It fails
on a synthetic variable anywhere in a node type, other than a record's
extension variable, and on a program that fails to canonicalize or type check.

Each program is built with `Compiler.AST.SourceBuilder.makeModuleWithDefs`: a
module importing `Basics` and `List` with one unannotated top-level value.

The tests:

  - `x = 1 + 2` in module `FullyConstrained`: two integer literals joined by
    the operator `+` of the stand-in `Basics` interface the test pipeline
    compiles against (`Compiler.Elm.Interface.Basic`), typed
    `number -> number -> number`. Nothing pins the literals to `Int`.
  - `id x = x` in module `Polymorphic`: a function whose argument's type is a
    type variable. The test name says it "generalizes properly"; the assertion
    reads only the names of the variables in the node types.
  - `f = let x = 1 in let y = x in y` in module `NestedLet`: a `let` that is
    the body of another, the inner one using the outer one's binding.

Among what is not tested: whether a variable is constrained at all, since the
check reads only names and a variable the type checker invented under an
ordinary name passes; record extension variables; annotated definitions.

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


{-| The three programs, each run through `expectNoSyntheticVars`.
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
        ]
