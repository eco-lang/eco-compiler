module Compiler.IR.Kernel.IntrinsicsBitmapTest exposing (suite)

{-| Tests for the part of `KernelIntrinsics.kernelIntrinsicOn` that turns calls of eco/system's
`Bitmap` kernel (`system-kernel-cpp/src/Bitmap.elm`) into integer operations: `index` with two
Int arguments becomes `eco.int.bitmap_index`, and `popCount32` with one becomes
`eco.int.popcount32` (plans/seq-data-structures-performance.md A1). Any other name, argument count
or argument type is declined, so the call goes to the C++ export instead.
-}

import Compiler.Core.TypeIds as TypeIds
import Compiler.IR.Kernel.Intrinsics as KernelIntrinsics
import Compiler.IR.Mono as Mono
import Expect
import Test exposing (Test, describe, test)


callOf : String -> List Mono.MonoType -> Maybe (KernelIntrinsics.Intrinsic ())
callOf name argTypes =
    KernelIntrinsics.kernelIntrinsicOn "Bitmap" name (List.map (Tuple.pair ()) argTypes) Mono.MInt


suite : Test
suite =
    describe "Generate.MLIR.Intrinsics — Bitmap"
        [ test "index of two Ints -> eco.int.bitmap_index" <|
            \_ ->
                callOf "index" [ Mono.MInt, Mono.MInt ]
                    |> Expect.equal (Just (KernelIntrinsics.Operation (KernelIntrinsics.BinaryInt { op = "eco.int.bitmap_index" } () ())))
        , test "popCount32 of an Int -> eco.int.popcount32" <|
            \_ ->
                callOf "popCount32" [ Mono.MInt ]
                    |> Expect.equal (Just (KernelIntrinsics.Operation (KernelIntrinsics.UnaryInt { op = "eco.int.popcount32" } ())))
        , test "index with one argument is declined" <|
            \_ -> callOf "index" [ Mono.MInt ] |> Expect.equal Nothing
        , test "index of a Float is declined" <|
            \_ -> callOf "index" [ Mono.MFloat, Mono.MInt ] |> Expect.equal Nothing
        , test "popCount32 of a number type variable is declined" <|
            \_ -> callOf "popCount32" [ Mono.MVar TypeIds.firstMVarId Mono.CNumber ] |> Expect.equal Nothing
        , test "an unknown Bitmap function is declined" <|
            \_ -> callOf "count" [ Mono.MInt ] |> Expect.equal Nothing
        ]
