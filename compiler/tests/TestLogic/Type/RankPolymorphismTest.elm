module TestLogic.Type.RankPolymorphismTest exposing (suite)

{-| Tests that four small programs with unannotated, possibly polymorphic
definitions type check. Without them, a type checker that rejected an ordinary
`let`-bound function or top-level function would go unnoticed. The suite labels
the property TYPE\_005.

Each test builds a one-module program with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`: unannotated top-level
definitions, importing `Basics` and `List`. Each is checked with
`TestLogic.Type.RankPolymorphism.expectRankPolymorphismValid`, which fails with
the pipeline's message when the module fails to canonicalize or type check, and
otherwise passes, since its walk of the top-level annotations never reports
anything.

  - "monomorphic let binding" defines `f = let x = 42 in x`.
  - "polymorphic let binding used monomorphically" defines
    `f = let myId x = x in myId 42`.
  - "simple function" defines `double x = x + x`.
  - "function composition" defines `double` as above and
    `quadruple x = double (double x)`.

Among what is not tested: the type any definition is given, whether `myId` is
generalized (it is used at one type only, so it would type check either way),
the rejection of a program, and higher-rank types.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.RankPolymorphism exposing (expectRankPolymorphismValid)


{-| The TYPE\_005 tests, which are all in `rankTests`.
-}
suite : Test
suite =
    Test.describe "Rank polymorphism is correctly handled (TYPE_005)"
        [ rankTests
        ]


{-| The four tests, each passing when its program gets through PostSolve.
-}
rankTests : Test
rankTests =
    Test.describe "Rank polymorphism"
        [ Test.test "monomorphic let binding" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "MonoLet"
                            [ ( "f"
                              , []
                              , SB.letExpr
                                    [ SB.define "x" [] (SB.intExpr 42) ]
                                    (SB.varExpr "x")
                              )
                            ]
                in
                expectRankPolymorphismValid modul
        , Test.test "polymorphic let binding used monomorphically" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "PolyLet"
                            [ ( "f"
                              , []
                              , SB.letExpr
                                    [ SB.define "myId" [ SB.pVar "x" ] (SB.varExpr "x") ]
                                    (SB.callExpr (SB.varExpr "myId") [ SB.intExpr 42 ])
                              )
                            ]
                in
                expectRankPolymorphismValid modul
        , Test.test "simple function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "SimpleFunc"
                            [ ( "double"
                              , [ SB.pVar "x" ]
                              , SB.binopsExpr [ ( SB.varExpr "x", "+" ) ] (SB.varExpr "x")
                              )
                            ]
                in
                expectRankPolymorphismValid modul
        , Test.test "function composition" <|
            \_ ->
                let
                    modul =
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
                in
                expectRankPolymorphismValid modul
        ]
