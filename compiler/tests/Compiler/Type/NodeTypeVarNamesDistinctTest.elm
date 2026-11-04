module Compiler.Type.NodeTypeVarNamesDistinctTest exposing (suite)

{-| Pins, for two programs, that a let-bound polymorphic helper is specialized
at the types of its own uses and not at the type of an enclosing argument
whose type variable could share its name.

Within one top-level definition, one type variable name in the solver's node
types must stand for one solver variable, because monomorphization identifies
type variables by name within a definition
(`Compiler.PreMono.AssignMVarIds.ensureBinder`). That rule is checked over the
whole standard catalogue by `TestLogic.Type.NodeTypeVarNamesDistinctTest`,
whose programs include the two let-polymorphism programs of
`SourceIR.LetPolyNameCases` this module first held. What stays here are the
two outcomes after monomorphization that the rule protects, each pinned for
one program built with `Compiler.AST.SourceBuilder.makeModuleWithDefs`:

  - The substitution engine test runs `wrapIntModule` through
    `TestPipeline.runToMonoStage5` and requires the printed mono graph to
    contain a specialization with parameter `y` at `MInt` and none with `y`
    at `MFloat`.
  - The solver engine test runs `captureModule` through
    `TestPipeline.runToGlobalOpt` and requires the printed mono graph not to
    contain `[MInt,MInt]`; the program has no `( Int, Int )` tuple, so such
    text would mean a specialization of `h` typed with one.

A third test pins a fixed bug: with a two-parameter helper,
`wrapInt x = let h y z = y * z in ( x * 1, h 4 5 )` and `testValue = wrapInt 2.5`,
type checking named `h`'s generalized `number` variable like `x`'s, and the
substitution engine, run through `TestPipeline.runToMonoStage5`, specialized
`h` at `MFloat` although it is called with `Int` literals; the solver engine
specialized it at `MInt`. The test requires a specialization with parameters
`y` and `z` at `MInt` and none with `y` at `MFloat`.

Among what is not tested: the generated MLIR.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.IR.Source as Src
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The three tests described in the module docstring.
-}
suite : Test
suite =
    Test.describe "Node type variable names are unique per solver variable (toCanTypeBatch)"
        [ Test.test "substitution engine specializes a let helper at its own use's type, not the enclosing argument's" <|
            \_ ->
                case Pipeline.runToMonoStage5 wrapIntModule of
                    Err msg ->
                        Expect.fail msg

                    Ok result ->
                        let
                            graph =
                                Debug.toString result.monoGraph
                        in
                        Expect.all
                            [ \() ->
                                String.contains "params = [(\"y\",MInt)]" graph
                                    |> Expect.equal True
                                    |> Expect.onFail "h is used at Int (h 4) but no specialization of h takes an Int"
                            , \() ->
                                String.contains "params = [(\"y\",MFloat)]" graph
                                    |> Expect.equal False
                                    |> Expect.onFail "h was specialized at Float, the type of the enclosing argument x that shares h's variable name"
                            ]
                            ()
        , Test.test "substitution engine specializes a two-parameter let helper at its own use's type" <|
            \_ ->
                case Pipeline.runToMonoStage5 wrapIntPairModule of
                    Err msg ->
                        Expect.fail msg

                    Ok result ->
                        let
                            graph =
                                Debug.toString result.monoGraph
                        in
                        Expect.all
                            [ \() ->
                                String.contains "params = [(\"y\",MInt),(\"z\",MInt)]" graph
                                    |> Expect.equal True
                                    |> Expect.onFail "h is used at Int (h 4 5) but no specialization of h takes Ints"
                            , \() ->
                                String.contains "params = [(\"y\",MFloat)" graph
                                    |> Expect.equal False
                                    |> Expect.onFail "h was specialized at Float, the type of the enclosing argument x"
                            ]
                            ()
        , Test.test "solver engine gives a let helper closure the type its body has" <|
            \_ ->
                case Pipeline.runToGlobalOpt captureModule of
                    Err msg ->
                        Expect.fail msg

                    Ok result ->
                        -- The program has no ( Int, Int ) tuple anywhere.
                        String.contains "[MInt,MInt]" (Debug.toString result.monoGraph)
                            |> Expect.equal False
                            |> Expect.onFail "a specialization of h is typed Int -> ( Int, Int ); its body builds ( String, Int )"
        ]


{-| A module defining `wrapInt x = let h y = y * 2147483648 * 2147483648 in ( x * 1, h 4 )` and
`testValue = wrapInt 2.5`.
-}
wrapIntModule : Src.Module
wrapIntModule =
    SB.makeModuleWithDefs "WrapInt"
        [ ( "wrapInt"
          , [ SB.pVar "x" ]
          , SB.letExpr
                [ SB.define "h"
                    [ SB.pVar "y" ]
                    (SB.binopsExpr [ ( SB.varExpr "y", "*" ), ( SB.intExpr 2147483648, "*" ) ] (SB.intExpr 2147483648))
                ]
                (SB.tupleExpr
                    (SB.binopsExpr [ ( SB.varExpr "x", "*" ) ] (SB.intExpr 1))
                    (SB.callExpr (SB.varExpr "h") [ SB.intExpr 4 ])
                )
          )
        , ( "testValue", [], SB.callExpr (SB.varExpr "wrapInt") [ SB.floatExpr 2.5 ] )
        ]


{-| A module defining `capture x = let h y = ( x, y ) in ( h 1, h 2.5 )` and
`testValue = capture "s"`.
-}
captureModule : Src.Module
captureModule =
    SB.makeModuleWithDefs "Capture"
        [ ( "capture"
          , [ SB.pVar "x" ]
          , SB.letExpr [ SB.define "h" [ SB.pVar "y" ] (SB.tupleExpr (SB.varExpr "x") (SB.varExpr "y")) ]
                (SB.tupleExpr
                    (SB.callExpr (SB.varExpr "h") [ SB.intExpr 1 ])
                    (SB.callExpr (SB.varExpr "h") [ SB.floatExpr 2.5 ])
                )
          )
        , ( "testValue", [], SB.callExpr (SB.varExpr "capture") [ SB.strExpr "s" ] )
        ]


{-| A module defining `wrapInt x = let h y z = y * z in ( x * 1, h 4 5 )` and
`testValue = wrapInt 2.5`.
-}
wrapIntPairModule : Src.Module
wrapIntPairModule =
    SB.makeModuleWithDefs "WrapIntPair"
        [ ( "wrapInt"
          , [ SB.pVar "x" ]
          , SB.letExpr
                [ SB.define "h" [ SB.pVar "y", SB.pVar "z" ] (SB.binopsExpr [ ( SB.varExpr "y", "*" ) ] (SB.varExpr "z")) ]
                (SB.tupleExpr
                    (SB.binopsExpr [ ( SB.varExpr "x", "*" ) ] (SB.intExpr 1))
                    (SB.callExpr (SB.varExpr "h") [ SB.intExpr 4, SB.intExpr 5 ])
                )
          )
        , ( "testValue", [], SB.callExpr (SB.varExpr "wrapInt") [ SB.floatExpr 2.5 ] )
        ]
