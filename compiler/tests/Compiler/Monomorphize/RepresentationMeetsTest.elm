module Compiler.Monomorphize.RepresentationMeetsTest exposing (suite)

{-| Tests for the slot kinds and components of
`Compiler.Monomorphize.RepresentationMeets` (plans/constructor-representation-levels.md
unit V).

The tests establish that only Int, Float and Char have unboxed slot kinds, that
two types joined by a meet are in one component and a third joined to either is
in it too, and that a type no meet involves is its own component.

They also cover `movesOnly` (plans/constructor-representation-followups.md F4):
it holds only for a type variable on the node side of a `global->` meet of a
kernel alias that `Visibility.kernelUse` lists and that is not `Debug`. And a
program that joins lists of a wrapper `P Int` with `++` compiles with
`repr.validate` on, which fails the build on any violation, and builds no `P`.
That test passes with `movesOnly` switched off too: in this environment the
program has no type-variable meet. The E2E test `EraseWrapperMoveOnlyTest`
(`CHECK-MLIR-NOT` of `P`'s and `Q`'s construction, both built before F4) is
what shows the rule's effect.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , ctorExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , qualVarExpr
        , tType
        )
import Compiler.Config as Config
import Compiler.Core.TypeIds as TypeIds
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Compiler.Monomorphize.RepresentationMeets as RM
import Expect
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


var : Mono.MonoType
var =
    Mono.MVar TypeIds.firstMVarId Mono.CEcoValue


suite : Test
suite =
    describe "Compiler.Monomorphize.RepresentationMeets"
        [ test "slot kinds" <|
            \_ ->
                List.map RM.slotKindOf [ Mono.MInt, Mono.MFloat, Mono.MChar, Mono.MBool, Mono.MString, var ]
                    |> Expect.equal [ RM.KInt, RM.KFloat, RM.KChar, RM.KBoxed, RM.KBoxed, RM.KBoxed ]
        , test "components join meets transitively" <|
            \_ ->
                let
                    comps =
                        RM.components (\_ -> True)
                            [ { a = Mono.mList Mono.MInt, b = Mono.mList var, root = True, spec = 0, site = "", via = RM.ViaOther }
                            , { a = Mono.mList var, b = Mono.mList Mono.MString, root = True, spec = 0, site = "", via = RM.ViaOther }
                            ]
                in
                RM.componentOf comps (Mono.mList Mono.MInt)
                    |> List.length
                    |> Expect.equal 3
        , test "movesOnly: a type variable on the node side of a listed kernel alias" <|
            \_ ->
                let
                    meet via b =
                        { a = Mono.MInt, b = b, root = False, spec = 0, site = "global->1", via = via }
                in
                List.map RM.movesOnly
                    [ meet (RM.ViaKernelAlias "JsArray" "push") var
                    , meet (RM.ViaKernelAlias "List" "append") var
                    , meet (RM.ViaKernelAlias "Debug" "toString") var
                    , meet (RM.ViaKernelAlias "Debugger" "unsafeCoerce") var
                    , meet RM.ViaOther var
                    , meet (RM.ViaKernelAlias "JsArray" "push") (Mono.mList var)
                    , { a = var, b = Mono.MInt, root = False, spec = 0, site = "global->1", via = RM.ViaKernelAlias "JsArray" "push" }
                    ]
                    |> Expect.equal [ True, True, False, False, False, False, False ]
        , test "a wrapper joined with ++ passes repr.validate and is erased" <|
            \_ ->
                case Pipeline.runToMlirWith validating movedThroughAppend of
                    Err msg ->
                        Expect.fail ("Compilation failed: " ++ msg)

                    Ok { mlirOutput } ->
                        String.contains "constructor = \"P\"" mlirOutput |> Expect.equal False
        , test "a type in no meet is its own component" <|
            \_ ->
                RM.componentOf (RM.components (\_ -> True) []) Mono.MInt
                    |> Expect.equal [ Mono.MInt ]
        ]


validating : Config.EcoConfig
validating =
    let
        cfg =
            Pipeline.productionConfig

        repr =
            cfg.repr
    in
    { cfg | repr = { repr | validate = True } }


{-| `testValue = List.length ([ P 4 ] ++ [ P 5 ])`.
-}
movedThroughAppend : Src.Module
movedThroughAppend =
    let
        testValue : TypedDef
        testValue =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "List" "length")
                    [ binopsExpr [ ( listExpr [ callExpr (ctorExpr "P") [ intExpr 4 ] ], "++" ) ] (listExpr [ callExpr (ctorExpr "P") [ intExpr 5 ] ]) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ testValue ]
        [ { name = "P", args = [], ctors = [ { name = "P", args = [ tType "Int" [] ] } ] } ]
        []
