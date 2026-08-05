module Compiler.Generate.MLIR.KernelAbiTest exposing (suite)

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
import Compiler.Generate.MLIR.KernelAbi as KernelAbi
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
                                (utilsCompareKey [ Mono.mList Mono.MInt, Mono.mList Mono.MInt ])
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_compare"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            ]
        , describe "deriveKernelInstanceAbi for Phase C migrated kernels"
            [ test "Utils.equal on Int args selects _Int variant with i64 ABI" <|
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
                        { symbolName = "Elm_Kernel_Utils_equal_Int"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "Utils.equal on String args falls back to boxed root" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "Utils"
                                , name = "equal"
                                , argTypes = [ Mono.MString, Mono.MString ]
                                , resultType = boolType
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_equal"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "JsArray.appendN selects _Int variant with typed Int index" <|
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
                        { symbolName = "Elm_Kernel_JsArray_appendN_Int"
                        , abiArgTypes = [ ecoInt, ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "Utils.append on String args stays AllBoxed (not migrated)" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "Utils"
                                , name = "append"
                                , argTypes = [ Mono.MString, Mono.MString ]
                                , resultType = Mono.MString
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Utils_append"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "List.cons selects _Int variant on primitive head" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "List"
                                , name = "cons"
                                , argTypes = [ Mono.MInt, Mono.mList Mono.MInt ]
                                , resultType = Mono.mList Mono.MInt
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_List_cons_Int"
                        , abiArgTypes = [ ecoInt, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "List.cons on String head falls back to boxed root" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "List"
                                , name = "cons"
                                , argTypes = [ Mono.MString, Mono.mList Mono.MString ]
                                , resultType = Mono.mList Mono.MString
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_List_cons"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "String.fromNumber selects _Int variant on Int" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "String"
                                , name = "fromNumber"
                                , argTypes = [ Mono.MInt ]
                                , resultType = Mono.MString
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_String_fromNumber_Int"
                        , abiArgTypes = [ ecoInt ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "Json.wrap on Int selects _Int variant" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "Json"
                                , name = "wrap"
                                , argTypes = [ Mono.MInt ]
                                , resultType = Mono.MUnit
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Json_wrap_Int"
                        , abiArgTypes = [ ecoInt ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "JsArray.unsafeSet selects _Float variant for Float element" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "JsArray"
                                , name = "unsafeSet"
                                , argTypes = [ Mono.MInt, Mono.MFloat, Mono.MUnit ]
                                , resultType = Mono.MUnit
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_JsArray_unsafeSet_Float"
                        , abiArgTypes = [ ecoInt, ecoFloat, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "JsArray.unsafeSet on String element keeps typed Int index but boxed element" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi
                                { prefix = "Elm"
                                , home = "JsArray"
                                , name = "unsafeSet"
                                , argTypes = [ Mono.MInt, Mono.MString, Mono.MUnit ]
                                , resultType = Mono.MUnit
                                }
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_JsArray_unsafeSet"
                        , abiArgTypes = [ ecoInt, ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
            ]
        , describe "deriveKernelInstanceAbi for Phase E.2 Basics arithmetic"
            [ test "Basics.add on Int selects _Int variant with i64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "add" Mono.MInt)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_add_Int"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoInt
                        }
                        abi
            , test "Basics.add on Float selects _Float variant with f64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "add" Mono.MFloat)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_add_Float"
                        , abiArgTypes = [ ecoFloat, ecoFloat ]
                        , abiResultType = ecoFloat
                        }
                        abi
            , test "Basics.sub on Int selects _Int variant with i64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "sub" Mono.MInt)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_sub_Int"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoInt
                        }
                        abi
            , test "Basics.sub on Float selects _Float variant with f64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "sub" Mono.MFloat)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_sub_Float"
                        , abiArgTypes = [ ecoFloat, ecoFloat ]
                        , abiResultType = ecoFloat
                        }
                        abi
            , test "Basics.mul on Int selects _Int variant with i64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "mul" Mono.MInt)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_mul_Int"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoInt
                        }
                        abi
            , test "Basics.mul on Float selects _Float variant with f64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "mul" Mono.MFloat)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_mul_Float"
                        , abiArgTypes = [ ecoFloat, ecoFloat ]
                        , abiResultType = ecoFloat
                        }
                        abi
            , test "Basics.pow on Int selects _Int variant with i64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "pow" Mono.MInt)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_pow_Int"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoInt
                        }
                        abi
            , test "Basics.pow on Float selects _Float variant with f64 ABI" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (basicsBinopKey "pow" Mono.MFloat)
                    in
                    Expect.equal
                        { symbolName = "Elm_Kernel_Basics_pow_Float"
                        , abiArgTypes = [ ecoFloat, ecoFloat ]
                        , abiResultType = ecoFloat
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
        , describe "deriveKernelInstanceAbi for Eco.Kernel.MVar.put"
            [ test "Int value selects the _Int variant with i64 ABI on the value axis" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (mvarPutKey [ Mono.MInt, Mono.MInt ])
                    in
                    Expect.equal
                        { symbolName = "Eco_Kernel_MVar_put_Int"
                        , abiArgTypes = [ ecoInt, ecoInt ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "Float value selects the _Float variant with f64 ABI on the value axis" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (mvarPutKey [ Mono.MInt, Mono.MFloat ])
                    in
                    Expect.equal
                        { symbolName = "Eco_Kernel_MVar_put_Float"
                        , abiArgTypes = [ ecoInt, ecoFloat ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "Char value selects the _Char variant with i16 ABI on the value axis" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (mvarPutKey [ Mono.MInt, Mono.MChar ])
                    in
                    Expect.equal
                        { symbolName = "Eco_Kernel_MVar_put_Char"
                        , abiArgTypes = [ ecoInt, ecoChar ]
                        , abiResultType = ecoValue
                        }
                        abi
            , test "String value falls back to the boxed root symbol" <|
                \_ ->
                    let
                        abi =
                            KernelAbi.deriveKernelInstanceAbi (mvarPutKey [ Mono.MInt, Mono.MString ])
                    in
                    Expect.equal
                        { symbolName = "Eco_Kernel_MVar_put"
                        , abiArgTypes = [ ecoInt, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        abi
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


mvarPutKey : List Mono.MonoType -> KernelAbi.KernelInstanceKey
mvarPutKey args =
    { prefix = "Eco"
    , home = "MVar"
    , name = "put"
    , argTypes = args
    , resultType = Mono.MUnit
    }


basicsBinopKey : String -> Mono.MonoType -> KernelAbi.KernelInstanceKey
basicsBinopKey opName operandType =
    { prefix = "Elm"
    , home = "Basics"
    , name = opName
    , argTypes = [ operandType, operandType ]
    , resultType = operandType
    }


orderType : Mono.MonoType
orderType =
    Mono.mCustom elmCoreBasics "Order" []


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
