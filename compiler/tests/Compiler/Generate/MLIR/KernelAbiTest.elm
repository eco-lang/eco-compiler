module Compiler.Generate.MLIR.KernelAbiTest exposing (suite)

{-| Tests that pin the C symbol and the MLIR argument and result types that
`Compiler.Generate.MLIR.KernelAbi.deriveKernelInstanceAbi` chooses for one use
of a kernel function. Where the code generator routes a kernel call through
`Compiler.Generate.MLIR.Context.registerKernelInstance`, it declares and calls
the kernel with that choice, so a change to it changes which C function
generated code calls, or the MLIR type a value is passed to it in. These tests
make such a change visible for the cases below.

A use of a kernel is described by a key: a prefix (`"Elm"` for elm/core
kernels, `"Eco"` for `Eco.Kernel.*` ones), the kernel's home module and name,
and the monomorphic types of its arguments and result. The symbol is
`<prefix>_Kernel_<home>_<name>`, with an `_Int`, `_Float` or `_Char` suffix for
the combinations of kernel and argument types that
`Compiler.Generate.MLIR.KernelAbi` lists. The unsuffixed form is called here
the boxed root symbol. The ABI type of each argument and of the result is its
MLIR type at the kernel boundary: `i64` for `Int`, `f64` for `Float`, `i16`
for `Char`, and `!eco.value` for every other type these tests use, as
`Compiler.Generate.MLIR.Types.monoTypeToAbi` gives it. An argument or result
passed as `!eco.value` is called boxed here, and one passed as `i64`, `f64` or
`i16` unboxed.

The fixture is hand-built keys; nothing is compiled. Where a kernel takes or
returns an array or another value whose type does not matter to the test,
`Mono.MUnit` stands in for it, and the tests rely only on its ABI type being
`!eco.value`. Expected results compare the whole returned record, except in
the one test that checks only the symbol.

What the tests establish:

  - `Utils.compare` at two `Int`s, two `Float`s or two `Char`s gets the `_Int`,
    `_Float` or `_Char` symbol with both arguments unboxed, and at two
    `String`s or two `List Int`s gets the boxed root symbol with both
    arguments boxed. Its `Order` result is boxed in every case.
  - `Utils.equal` at two `Int`s gets `_Int` with `i64` arguments and a boxed
    `Bool` result; at two `String`s it gets the boxed root symbol and every
    type boxed.
  - `JsArray.appendN` with an `Int` first argument gets `_Int`, with that
    argument `i64` and the other two boxed.
  - `Utils.append` at two `String`s gets the boxed root symbol, every type
    boxed.
  - `List.cons` with an `Int` head gets `_Int`, with the head `i64` and the
    `List Int` tail boxed; with a `String` head it gets the boxed root symbol.
  - `String.fromNumber` and `Json.wrap` at an `Int` get `_Int` with an `i64`
    argument and a boxed result.
  - `JsArray.unsafeSet` with a `Float` element gets `_Float`, with the `Int`
    index `i64` and the element `f64`; with a `String` element it gets the
    boxed root symbol but the index is still `i64`.
  - `Basics.add`, `sub`, `mul` and `pow` at two `Int`s or two `Float`s get the
    `_Int` or `_Float` symbol, and, since their result type is `Int` or
    `Float`, the result is `i64` or `f64` too.
  - `Basics.modBy` at two `Int`s keeps the unsuffixed symbol while its
    arguments and result are all `i64`.
  - With prefix `"Eco"`, `MVar.put` at an `Int` and a `()` gets the symbol
    `Eco_Kernel_MVar_put`; only the symbol is checked.
  - `MVar.put` with prefix `"Eco"`, an `Int` first argument and an `Int`,
    `Float` or `Char` value gets the `_Int`, `_Float` or `_Char` symbol, with
    the first argument `i64` and the value unboxed; with a `String` value it
    gets `Eco_Kernel_MVar_put`, the first argument still `i64`.

Among what is not tested: `Utils.notEqual`, `lt`, `le`, `gt` and `ge`;
`Utils.equal` at `Float` or `Char`; `String.fromNumber`, `Json.wrap` and
`List.cons` at `Float` or `Char`; `JsArray.singleton`, `push`, `unsafeGet`,
`slice`, `initialize`, `initializeFromList` and `indexedMap`; a `number` type
variable, which `monoTypeToAbi` makes `i64`; a key whose prefix is not the
kernel's own, such as `MVar.put` with prefix `"Elm"`; and the compile-time
crashes, for `CellStore.set` and `push` at an unboxed cell type and for an
argument or result whose ABI type does not match its primitive type.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.MLIR.KernelAbi as KernelAbi
import Expect
import Mlir.Mlir as Mlir
import Test exposing (Test, describe, test)


{-| The kernel ABI tests, in groups by the kernels they cover. The outer label
names `Compiler.Monomorphize.KernelAbi`, but every test calls
`Compiler.Generate.MLIR.KernelAbi.deriveKernelInstanceAbi`.
-}
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


{-| Builds the key for elm/core's `Utils.compare` at the argument types `args`,
with an `Order` result.
-}
utilsCompareKey : List Mono.MonoType -> KernelAbi.KernelInstanceKey
utilsCompareKey args =
    { prefix = "Elm"
    , home = "Utils"
    , name = "compare"
    , argTypes = args
    , resultType = orderType
    }


{-| Builds the key for `Eco.Kernel.MVar.put`, with prefix `"Eco"`, at the
argument types `args` and with a `()` result.
-}
mvarPutKey : List Mono.MonoType -> KernelAbi.KernelInstanceKey
mvarPutKey args =
    { prefix = "Eco"
    , home = "MVar"
    , name = "put"
    , argTypes = args
    , resultType = Mono.MUnit
    }


{-| Builds the key for the elm/core `Basics` kernel named `opName` taking two
values of `operandType` and returning one.
-}
basicsBinopKey : String -> Mono.MonoType -> KernelAbi.KernelInstanceKey
basicsBinopKey opName operandType =
    { prefix = "Elm"
    , home = "Basics"
    , name = opName
    , argTypes = [ operandType, operandType ]
    , resultType = operandType
    }


{-| The monomorphic type of elm/core's `Order`, the result of `Utils.compare`.
-}
orderType : Mono.MonoType
orderType =
    Mono.mCustom elmCoreBasics "Order" []


{-| The monomorphic type of `Bool`, the result of `Utils.equal`.
-}
boolType : Mono.MonoType
boolType =
    Mono.MBool


{-| The canonical name of elm/core's `Basics` module, the home of `Order`.
-}
elmCoreBasics : ModuleName.Canonical
elmCoreBasics =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


{-| The ABI type of a boxed value, `!eco.value`.
-}
ecoValue : Mlir.MlirType
ecoValue =
    Mlir.NamedStruct "eco.value"


{-| The ABI type of an `Int`, a 64-bit integer.
-}
ecoInt : Mlir.MlirType
ecoInt =
    Mlir.I64


{-| The ABI type of a `Float`, a 64-bit float.
-}
ecoFloat : Mlir.MlirType
ecoFloat =
    Mlir.F64


{-| The ABI type of a `Char`, a 16-bit integer.
-}
ecoChar : Mlir.MlirType
ecoChar =
    Mlir.I16
