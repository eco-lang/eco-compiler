module Compiler.Type.RankPolymorphismTest exposing (suite)

{-| Tests that the type checker generalizes a let-bound definition over the type
variables that belong to it alone, and over nothing else (TYPE\_005). A checker
that never generalized would reject the second program below; one that
generalized too much would accept the rejected ones, or give the wrong types.

Each test builds a one-module program with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`: unannotated top-level
definitions, importing `Basics` and `List`. The expectations come from
`Compiler.Type.RankPolymorphism`.

Accepted, with the type of `f` (or of the named definition) checked:

  - "monomorphic let binding": `f = let x = 42 in x`, typed `number`.
  - "polymorphic let binding used at two types":
    `f = let myId x = x in ( myId 42, myId "s" )`, typed `( number, String )`.
    It type checks only if `myId` is generalized.
  - "let binding closing over an argument stays tied to it":
    `f x = let k y = x in ( k 1, k "s" )`, typed `a -> ( a, a )`. `k` is
    generalized over its own argument but not over `x`.
  - "simple function": `double x = x + x`, typed `number -> number`.
  - "function composition": `quadruple x = double (double x)`, typed
    `number -> number`.

Rejected with a type mismatch:

  - "a lambda-bound argument is not polymorphic": `f g = ( g 1, g "s" )`.
  - "a let binding of an argument is not generalized over it":
    `f x = let k = x in ( k + 1, k ++ "s" )`.

"Unannotated recursive groups" holds a program that was wrongly accepted
(finding B3 of plans/sourceir-catalogue-test-logic.md), now rejected:

  - "an earlier member of a recursive group is not generalized in a later
    one": `f x = g x` and `g y = if y then f 3 else f 4`. `y` is a `Bool`, and
    `f` passes its argument to `g` and is called with numbers, so the program
    is ill-typed. It was accepted with `f : number -> a`, as stock Elm 0.19.1
    accepts it, because `Compiler.Type.Constrain.Typed.Expression.recDefsHelpWithIds`
    declared `f`'s variables in `g`'s `CLet`, which generalized them; they are
    now declared once for the whole group.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.Type.RankPolymorphism exposing (expectInferredType, expectRejected)
import Test exposing (Test)


{-| The TYPE\_005 tests.
-}
suite : Test
suite =
    Test.describe "Rank polymorphism is correctly handled (TYPE_005)"
        [ acceptedTests
        , rejectedTests
        , Test.test "Unannotated recursive groups: an earlier member of a recursive group is not generalized in a later one" <|
            \_ ->
                SB.makeModuleWithDefs "RecGroupArgument"
                    [ ( "f", [ SB.pVar "x" ], SB.callExpr (SB.varExpr "g") [ SB.varExpr "x" ] )
                    , ( "g"
                      , [ SB.pVar "y" ]
                      , SB.ifExpr (SB.varExpr "y")
                            (SB.callExpr (SB.varExpr "f") [ SB.intExpr 3 ])
                            (SB.callExpr (SB.varExpr "f") [ SB.intExpr 4 ])
                      )
                    ]
                    |> expectRejected
        ]


{-| Programs that must type check, with the type each is given.
-}
acceptedTests : Test
acceptedTests =
    Test.describe "Rank polymorphism"
        [ Test.test "monomorphic let binding" <|
            \_ ->
                SB.makeModuleWithDefs "MonoLet"
                    [ ( "f"
                      , []
                      , SB.letExpr
                            [ SB.define "x" [] (SB.intExpr 42) ]
                            (SB.varExpr "x")
                      )
                    ]
                    |> expectInferredType "f" "number"
        , Test.test "polymorphic let binding used at two types" <|
            \_ ->
                SB.makeModuleWithDefs "PolyLet"
                    [ ( "f"
                      , []
                      , SB.letExpr
                            [ SB.define "myId" [ SB.pVar "x" ] (SB.varExpr "x") ]
                            (SB.tupleExpr
                                (SB.callExpr (SB.varExpr "myId") [ SB.intExpr 42 ])
                                (SB.callExpr (SB.varExpr "myId") [ SB.strExpr "s" ])
                            )
                      )
                    ]
                    |> expectInferredType "f" "( number, String )"
        , Test.test "let binding closing over an argument stays tied to it" <|
            \_ ->
                SB.makeModuleWithDefs "ClosingLet"
                    [ ( "f"
                      , [ SB.pVar "x" ]
                      , SB.letExpr
                            [ SB.define "k" [ SB.pVar "y" ] (SB.varExpr "x") ]
                            (SB.tupleExpr
                                (SB.callExpr (SB.varExpr "k") [ SB.intExpr 1 ])
                                (SB.callExpr (SB.varExpr "k") [ SB.strExpr "s" ])
                            )
                      )
                    ]
                    |> expectInferredType "f" "a -> ( a, a )"
        , Test.test "simple function" <|
            \_ ->
                SB.makeModuleWithDefs "SimpleFunc"
                    [ ( "double"
                      , [ SB.pVar "x" ]
                      , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "x")
                      )
                    ]
                    |> expectInferredType "double" "number -> number"
        , Test.test "function composition" <|
            \_ ->
                SB.makeModuleWithDefs "Compose"
                    [ ( "double"
                      , [ SB.pVar "x" ]
                      , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "x")
                      )
                    , ( "quadruple"
                      , [ SB.pVar "x" ]
                      , SB.callExpr (SB.varExpr "double")
                            [ SB.callExpr (SB.varExpr "double") [ SB.varExpr "x" ] ]
                      )
                    ]
                    |> expectInferredType "quadruple" "number -> number"
        ]


{-| Programs that need more polymorphism than rank-1 let-generalization gives,
and so must be rejected.
-}
rejectedTests : Test
rejectedTests =
    Test.describe "No polymorphism beyond let-generalization"
        [ Test.test "a lambda-bound argument is not polymorphic" <|
            \_ ->
                SB.makeModuleWithDefs "LambdaBound"
                    [ ( "f"
                      , [ SB.pVar "g" ]
                      , SB.tupleExpr
                            (SB.callExpr (SB.varExpr "g") [ SB.intExpr 1 ])
                            (SB.callExpr (SB.varExpr "g") [ SB.strExpr "s" ])
                      )
                    ]
                    |> expectRejected
        , Test.test "a let binding of an argument is not generalized over it" <|
            \_ ->
                SB.makeModuleWithDefs "LetOfArgument"
                    [ ( "f"
                      , [ SB.pVar "x" ]
                      , SB.letExpr
                            [ SB.define "k" [] (SB.varExpr "x") ]
                            (SB.tupleExpr
                                (SB.binopsExpr [ ( SB.varExpr "k", "+" ) ] (SB.intExpr 1))
                                (SB.binopsExpr [ ( SB.varExpr "k", "++" ) ] (SB.strExpr "s"))
                            )
                      )
                    ]
                    |> expectRejected
        ]
