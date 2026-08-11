module Compiler.Generate.MLIR.IntrinsicsListConsTest exposing (suite)

{-| kernel-opt-01: the `("List", "cons")` intrinsic classifier.

Driven through the EXPOSED `Intrinsics.kernelIntrinsic`, not through the
internal `listIntrinsic` — the module's `exposing` list is deliberately not
widened for a test.

This is the _authoritative_ decline coverage. `consIntrinsicFor` (Expr.elm)
applies the config flag and the SSA-type admissibility test on top; everything
below is the type-level classification that must hold before that gate is even
consulted. The head kinds must reproduce the axis `kernelInstanceSymbol` uses
for the `_Int`/`_Float`/`_Char` C variants (Generate/MLIR/KernelAbi.elm:310-317)
— a disagreement here is a heap-layout bug (REP\_BOUNDARY\_002), not a missed
optimization.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Types as Types
import Expect
import Test exposing (Test, describe, test)


{-| A boxed list type usable as a tail / result slot.
-}
listOfInt : Mono.MonoType
listOfInt =
    Mono.MList 0 Mono.MInt


consOf : Mono.MonoType -> Mono.MonoType -> Mono.MonoType -> Maybe Intrinsics.Intrinsic
consOf headTy tailTy resultTy =
    Intrinsics.kernelIntrinsic "List" "cons" [ headTy, tailTy ] resultTy


suite : Test
suite =
    describe "Generate.MLIR.Intrinsics — List.cons"
        [ describe "admits, with the head kind taken from the head MonoType"
            [ test "boxed head (String) -> !eco.value slot" <|
                \_ ->
                    consOf Mono.MString (Mono.MList 0 Mono.MString) (Mono.MList 0 Mono.MString)
                        |> Expect.equal (Just (Intrinsics.ConstructList { headMlirType = Types.ecoValue }))
            , test "Int head -> i64 slot (the _Int axis)" <|
                \_ ->
                    consOf Mono.MInt listOfInt listOfInt
                        |> Expect.equal (Just (Intrinsics.ConstructList { headMlirType = Types.ecoInt }))
            , test "Float head -> f64 slot (the _Float axis)" <|
                \_ ->
                    consOf Mono.MFloat (Mono.MList 0 Mono.MFloat) (Mono.MList 0 Mono.MFloat)
                        |> Expect.equal (Just (Intrinsics.ConstructList { headMlirType = Types.ecoFloat }))
            , test "Char head -> i16 slot (the _Char axis)" <|
                \_ ->
                    consOf Mono.MChar (Mono.MList 0 Mono.MChar) (Mono.MList 0 Mono.MChar)
                        |> Expect.equal (Just (Intrinsics.ConstructList { headMlirType = Types.ecoChar }))
            , test "Bool head is boxed, not a primitive slot (REP: Bool is never unboxed in heap fields)" <|
                \_ ->
                    consOf Mono.MBool (Mono.MList 0 Mono.MBool) (Mono.MList 0 Mono.MBool)
                        |> Expect.equal (Just (Intrinsics.ConstructList { headMlirType = Types.ecoValue }))
            ]
        , describe "declines (⇒ the site keeps today's kernel call)"
            [ test "unsettled CNumber head — maps to i64 under monoTypeToAbi but is NOT the _Int axis" <|
                \_ ->
                    consOf (Mono.MVar TypeIds.firstMVarId Mono.CNumber) listOfInt listOfInt
                        |> Expect.equal Nothing
            , test "scalar tail (the kernelDevirtShapeOk hazard)" <|
                \_ ->
                    consOf Mono.MInt Mono.MInt listOfInt
                        |> Expect.equal Nothing
            , test "scalar result" <|
                \_ ->
                    consOf Mono.MInt listOfInt Mono.MInt
                        |> Expect.equal Nothing
            , test "unsaturated / wrong arity" <|
                \_ ->
                    Intrinsics.kernelIntrinsic "List" "cons" [ Mono.MInt ] listOfInt
                        |> Expect.equal Nothing
            , test "no args at all (the unapplied `cons` value path, Expr.elm:775)" <|
                \_ ->
                    Intrinsics.kernelIntrinsic "List" "cons" [] listOfInt
                        |> Expect.equal Nothing
            , test "a different List kernel is not claimed" <|
                \_ ->
                    Intrinsics.kernelIntrinsic "List" "reverse" [ listOfInt ] listOfInt
                        |> Expect.equal Nothing
            , test "a different home is not claimed" <|
                \_ ->
                    Intrinsics.kernelIntrinsic "Platform" "cons" [ Mono.MInt, listOfInt ] listOfInt
                        |> Expect.equal Nothing
            ]
        ]
