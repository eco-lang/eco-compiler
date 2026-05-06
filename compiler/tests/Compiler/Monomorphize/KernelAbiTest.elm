module Compiler.Monomorphize.KernelAbiTest exposing (suite)

{-| Unit tests for `deriveKernelInstanceAbi` and the per-instance kernel ABI
machinery introduced in Phase B of the per-instance kernel ABI rollout.

These tests exercise the derivation function directly with hand-built
`KernelInstanceKey` values rather than relying on a full compilation pipeline.
At Phase B the existing test corpus does not trigger the `_Int` / `_Float` /
`_Char` symbol variants because the intrinsic dispatcher in
`Compiler.Generate.MLIR.Intrinsics` lowers `compare` on primitive operands
to `eco.{int,float,char}.cmp_order` before any kernel call is emitted; so the
direct unit test is the only place these branches are observed today. They
become observable end-to-end in Phase D when generic apply stops collapsing
through the intrinsic path.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Expect
import Mlir.Mlir as Mlir
import System.TypeCheck.IO as IO
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Compiler.Monomorphize.KernelAbi"
        [ describe "deriveKernelInstanceAbi for Utils.compare"
            [ test "Int instantiation selects the _Int variant with i64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (utilsCompareKey [ Mono.MInt, Mono.MInt ])
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_compare_Int"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "Float instantiation selects the _Float variant with f64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (utilsCompareKey [ Mono.MFloat, Mono.MFloat ])
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_compare_Float"
                        , abiArgTypes = [ ecoFloat, ecoFloat ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "Char instantiation selects the _Char variant with i16 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (utilsCompareKey [ Mono.MChar, Mono.MChar ])
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_compare_Char"
                        , abiArgTypes = [ ecoChar, ecoChar ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "String instantiation falls back to the boxed root symbol" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (utilsCompareKey [ Mono.MString, Mono.MString ])
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_compare"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "List instantiation falls back to the boxed root symbol" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                (utilsCompareKey [ Mono.MList Mono.MInt, Mono.MList Mono.MInt ])
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_compare"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            ]
        , describe "deriveKernelInstanceAbi keeps unmigrated AllBoxed kernels boxed"
            [ test "Utils.equal on Int args stays !eco.value at the ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "Utils"
                                , name = "equal"
                                , argTypes = [ Mono.MInt, Mono.MInt ]
                                , resultType = boolType
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_equal"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "JsArray.appendN on Int args stays !eco.value at the ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "JsArray"
                                , name = "appendN"
                                , argTypes = [ Mono.MInt, Mono.MUnit, Mono.MUnit ]
                                , resultType = Mono.MUnit
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_JsArray_appendN"
                        , abiArgTypes = [ ecoValue, ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            ]
        , describe "deriveKernelInstanceAbi for ElmDerived monomorphic kernels"
            [ test "Basics.modBy keeps i64 ABI on its concrete signature" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "Basics"
                                , name = "modBy"
                                , argTypes = [ Mono.MInt, Mono.MInt ]
                                , resultType = Mono.MInt
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_modBy"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoInt
                        }
                        abi
            ]
        , describe "deriveKernelInstanceAbi honours the user-package prefix"
            [ test "Eco.Kernel.MVar.put uses Eco_Kernel_ prefix" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Eco"
                                , home = "MVar"
                                , name = "put"
                                , argTypes = [ Mono.MInt, Mono.MUnit ]
                                , resultType = Mono.MUnit
                                }
                    in
                    Expect.equal "Eco_Kernel_MVar_put" abi.symbolName
            ]
        ]



-- HELPERS ----------------------------------------------------------------


utilsCompareKey : List Mono.MonoType -> KernelAbi.KernelInstanceKey
utilsCompareKey args =
    { prefix = "Elm"
    , home = "Utils"
    , name = "compare"
    , argTypes = args
    , resultType = orderType
    }


orderType : Mono.MonoType
orderType =
    Mono.MCustom elmCoreBasics "Order" []


boolType : Mono.MonoType
boolType =
    Mono.MBool


elmCoreBasics : IO.Canonical
elmCoreBasics =
    IO.Canonical ( "elm", "core" ) "Basics"


ecoValue : Mlir.MlirType
ecoValue =
    Mlir.NamedStruct "eco.value"


ecoInt : Mlir.MlirType
ecoInt =
    Mlir.I64


ecoFloat : Mlir.MlirType
ecoFloat =
    Mlir.F64


ecoChar : Mlir.MlirType
ecoChar =
    Mlir.I16
