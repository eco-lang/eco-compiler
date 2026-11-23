module Compiler.IR.Kernel.IntrinsicsJsArray2Test exposing (suite)

{-| Tests for the part of `KernelIntrinsics.kernelIntrinsicOn` that routes eco/system's `JsArray2`
kernel (`system-kernel-cpp/src/JsArray2.elm`) through `JsArray`'s array operations
(plans/seq-data-structures-performance.md A2): `unsafeGet`, `unsafeSet`, `length`, `push` and
`singleton` become the same operations as `JsArray`'s, with the element type read from the `JsArray2`
type; `unsafeInsert` and `removeIndex` stay kernel calls.
-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.GenerateMlir.Types as Types
import Compiler.IR.Kernel.Intrinsics as KernelIntrinsics
import Compiler.IR.Mono as Mono
import Expect
import Mlir.Mlir exposing (MlirType(..))
import Test exposing (Test, describe, test)


jsArray2Of : Mono.MonoType -> Mono.MonoType
jsArray2Of elt =
    Mono.MCustom 0 (ModuleName.Canonical Pkg.ecoSystem "JsArray2") "JsArray2" [ elt ]


slotType : Mono.MonoType
slotType =
    Mono.MCustom 0 (ModuleName.Canonical Pkg.ecoSystem "SeqDict") "Slot" [ Mono.MInt, Mono.MInt ]


callOf : String -> List Mono.MonoType -> Mono.MonoType -> Maybe (KernelIntrinsics.Intrinsic ())
callOf name argTypes resultType =
    KernelIntrinsics.kernelIntrinsicOn "JsArray2" name (List.map (Tuple.pair ()) argTypes) resultType


suite : Test
suite =
    describe "Generate.MLIR.Intrinsics — JsArray2"
        [ test "unsafeGet of a boxed element -> ArrayGet !eco.value" <|
            \_ ->
                callOf "unsafeGet" [ Mono.MInt, jsArray2Of slotType ] slotType
                    |> Expect.equal (Just (KernelIntrinsics.Operation (KernelIntrinsics.ArrayGet { elementMlirType = Types.ecoValue } () ())))
        , test "unsafeGet of an Int element -> ArrayGet i64" <|
            \_ ->
                callOf "unsafeGet" [ Mono.MInt, jsArray2Of Mono.MInt ] Mono.MInt
                    |> Expect.equal (Just (KernelIntrinsics.Operation (KernelIntrinsics.ArrayGet { elementMlirType = I64 } () ())))
        , test "unsafeSet -> ArraySet" <|
            \_ ->
                callOf "unsafeSet" [ Mono.MInt, slotType, jsArray2Of slotType ] (jsArray2Of slotType)
                    |> Expect.equal (Just (KernelIntrinsics.Operation (KernelIntrinsics.ArraySet { elementMlirType = Types.ecoValue } () () ())))
        , test "length -> ArrayLength" <|
            \_ ->
                callOf "length" [ jsArray2Of slotType ] Mono.MInt
                    |> Expect.equal (Just (KernelIntrinsics.Operation (KernelIntrinsics.ArrayLength ())))
        , test "unsafeInsert stays a kernel call" <|
            \_ -> callOf "unsafeInsert" [ Mono.MInt, slotType, jsArray2Of slotType ] (jsArray2Of slotType) |> Expect.equal Nothing
        , test "removeIndex stays a kernel call" <|
            \_ -> callOf "removeIndex" [ Mono.MInt, jsArray2Of slotType ] (jsArray2Of slotType) |> Expect.equal Nothing
        ]
