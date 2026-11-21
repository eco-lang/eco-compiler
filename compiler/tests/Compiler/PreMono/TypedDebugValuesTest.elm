module Compiler.PreMono.TypedDebugValuesTest exposing (suite)

{-| Tests for `Compiler.PreMono.TypedDebugValues`
(plans/constructor-representation-followups.md F3), on source compiled through
the pipeline. The test environment has no `Debug` module, so the programs refer
to the kernels directly (`Elm.Kernel.Debug.toString`, as
`SourceIR.DebugKernelCases` does), which the pass matches as it matches the
`VarDebug` references of user code; the E2E tests `DebugToStringAsValueTest`
and `DebugValueContextTest` cover `VarDebug`.

  - `List.map Debug.toString [ 1, 2 ]`: one `Debug` value rewritten;
  - `List.map (Debug.log "x") [ 1 ]`: the partial application rewritten;
  - `(Debug.log "y") 2`: flattened into a saturated call, not wrapped;
  - `List.map (Debug.log (Debug.toString 3)) [ 1 ]`: a label that is a call,
    rewritten (and let-bound outside the lambda);
  - a saturated `Debug.toString 4`: left alone;
  - every node the pass builds has fresh ids (`Fresh.assertMinted`);
  - compiled to MLIR, under the solver engine and the substitution engine, a
    value use of `Debug.toString` reaches only the typed symbol
    `Elm_Kernel_Debug_toString_typed`, never the untyped
    `Elm_Kernel_Debug_toString` that prints without names.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , qualVarExpr
        , strExpr
        , tType
        )
import Compiler.PreMono.Fresh as Fresh
import Compiler.PreMono.TypedDebugValues as TypedDebugValues
import Compiler.IR.Source as Src
import Expect
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    describe "Compiler.PreMono.TypedDebugValues"
        [ test "Debug.toString as a value is rewritten" <|
            \_ -> expectMetrics (listMapOf (qualVarExpr "Elm.Kernel.Debug" "toString") [ intExpr 1, intExpr 2 ]) { rewritten = 1, flattened = 0 }
        , test "a partial Debug.log is rewritten" <|
            \_ -> expectMetrics (listMapOf (callExpr (qualVarExpr "Elm.Kernel.Debug" "log") [ strExpr "x" ]) [ intExpr 1 ]) { rewritten = 1, flattened = 0 }
        , test "(Debug.log label) x is flattened, not wrapped" <|
            \_ -> expectMetrics (callExpr (callExpr (qualVarExpr "Elm.Kernel.Debug" "log") [ strExpr "y" ]) [ intExpr 2 ]) { rewritten = 0, flattened = 1 }
        , test "a partial Debug.log with a call as its label is rewritten" <|
            \_ ->
                expectMetrics
                    (listMapOf (callExpr (qualVarExpr "Elm.Kernel.Debug" "log") [ callExpr (qualVarExpr "Elm.Kernel.Debug" "toString") [ intExpr 3 ] ]) [ intExpr 1 ])
                    { rewritten = 1, flattened = 0 }
        , test "a saturated Debug.toString is left alone" <|
            \_ -> expectMetrics (callExpr (qualVarExpr "Elm.Kernel.Debug" "toString") [ intExpr 4 ]) { rewritten = 0, flattened = 0 }
        , test "the rewritten graph has fresh ids" <|
            \_ ->
                case Pipeline.runToAssigned (programOf (listMapOf (qualVarExpr "Elm.Kernel.Debug" "toString") [ intExpr 1 ])) of
                    Err msg ->
                        Expect.fail ("Compilation failed: " ++ msg)

                    Ok assigned ->
                        let
                            ( graph, _, _ ) =
                                TypedDebugValues.run assigned.mvarState assigned.graph
                        in
                        Fresh.assertMinted graph |> Expect.equal (Ok ())
        , test "a Debug.toString value reaches only the typed symbol (solver engine)" <|
            \_ -> expectTypedOnly (Pipeline.runToMlir (programOf (listMapOf (qualVarExpr "Elm.Kernel.Debug" "toString") [ intExpr 1 ])))
        , test "a Debug.toString value reaches only the typed symbol (substitution engine)" <|
            \_ -> expectTypedOnly (Pipeline.runToMlirStage5 (programOf (listMapOf (qualVarExpr "Elm.Kernel.Debug" "toString") [ intExpr 1 ])))
        ]


expectMetrics : Src.Expr -> TypedDebugValues.Metrics -> Expect.Expectation
expectMetrics body expected =
    case Pipeline.runToAssigned (programOf body) of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok assigned ->
            let
                ( _, _, metrics ) =
                    TypedDebugValues.run assigned.mvarState assigned.graph
            in
            metrics |> Expect.equal expected


expectTypedOnly : Result String { a | mlirOutput : String } -> Expect.Expectation
expectTypedOnly result =
    case result of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { mlirOutput } ->
            let
                all =
                    List.length (String.indexes "Elm_Kernel_Debug_toString" mlirOutput)

                typed =
                    List.length (String.indexes "Elm_Kernel_Debug_toString_typed" mlirOutput)
            in
            Expect.all
                [ \_ -> typed |> Expect.atLeast 1
                , \_ -> (all - typed) |> Expect.equal 0
                ]
                ()


listMapOf : Src.Expr -> List Src.Expr -> Src.Expr
listMapOf f items =
    callExpr (qualVarExpr "List" "map") [ f, listExpr items ]


{-| A module whose `testValue` is `Debug.toString body`: a saturated call, which
the pass leaves alone, so that `testValue` is a `String` whatever `body`'s type.
-}
programOf : Src.Expr -> Src.Module
programOf body =
    let
        testValue : TypedDef
        testValue =
            { name = "testValue", args = [], tipe = tType "String" [], body = callExpr (qualVarExpr "Elm.Kernel.Debug" "toString") [ body ] }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod" [ testValue ] [] []
