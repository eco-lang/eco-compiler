module Compiler.GenerateMlir.KernelAbiTest exposing (suite)

{-| Tests that pin the C symbol and the MLIR argument and result types that
`Compiler.GenerateMlir.KernelAbi.deriveKernelInstanceAbi` chooses for one use
of a kernel function. Where the code generator routes a kernel call through
`Compiler.GenerateMlir.Context.registerKernelInstance`, it declares and calls
the kernel with that choice, so a change to it changes which C function
generated code calls, or the MLIR type a value is passed to it in. These tests
make such a change visible for the cases below.

A use of a kernel is described by a key: a prefix (`"Elm"` for elm/core
kernels, `"Eco"` for `Eco.Kernel.*` ones), the kernel's home module and name,
and the monomorphic types of its arguments and result. The symbol is
`<prefix>_Kernel_<home>_<name>`, with an `_Int`, `_Float` or `_Char` suffix for
the combinations of kernel and argument types that
`Compiler.GenerateMlir.KernelAbi` lists. The unsuffixed form is called here
the boxed root symbol. The ABI type of each argument and of the result is its
MLIR type at the kernel boundary: `i64` for `Int`, `f64` for `Float`, `i32`
for `Char`, and `!eco.value` for every other type these tests use, as
`Compiler.GenerateMlir.Types.monoTypeToAbi` gives it. An argument or result
passed as `!eco.value` is called boxed here, and one passed as `i64`, `f64` or
`i32` unboxed.

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
  - `JsArray.map`, `initialize`, `indexedMap` and `initializeFromList` take
    the element suffix from their result: an array of `Int`, `Float` or
    `Char` (for `initializeFromList`, the pair's array) gives `map_Int`,
    `initialize_Int_Float`, `indexedMap_Int_Char` or
    `initializeFromList_Int_Int`, and a boxed element keeps `map` or
    `initialize_Int`. `callInstanceResultType` keys those four by the call's
    own result type, and every other kernel by its ABI result type.
  - `List.map2` to `map5` take the element suffix from the list they return:
    a `List Int` gives `map2_Int`, a `List Char` `map5_Char`, and a `List
    String` keeps `map3`; `callInstanceResultType` keys them by the call's own
    result type too.
  - `MVar.put` with prefix `"Eco"`, an `Int` first argument and an `Int`,
    `Float` or `Char` value gets the `_Int`, `_Float` or `_Char` symbol, with
    the first argument `i64` and the value unboxed; with a `String` value it
    gets `Eco_Kernel_MVar_put`, the first argument still `i64`.

Among what is not tested: `Utils.notEqual`, `lt`, `le`, `gt` and `ge`;
`Utils.equal` at `Float` or `Char`; `String.fromNumber`, `Json.wrap` and
`List.cons` at `Float` or `Char`; `JsArray.singleton`, `push`, `unsafeGet`
and `slice`; a `number` type
variable, which `monoTypeToAbi` makes `i64`; a key whose prefix is not the
kernel's own, such as `MVar.put` with prefix `"Elm"`; and the compile-time
crash for an argument or result whose ABI type does not match its primitive
type.

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.GenerateMlir.KernelAbi as KernelAbi
import Compiler.IR.Mono as Mono
import Expect
import Mlir.Mlir as Mlir
import Test exposing (Test, describe, test)


{-| The kernel ABI tests, in groups by the kernels they cover. The outer label
names `Compiler.Monomorphize.KernelAbi`, but every test calls
`Compiler.GenerateMlir.KernelAbi.deriveKernelInstanceAbi`.
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
            , test "Char instantiation selects the _Char variant with i32 ABI" <|
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
            , test "Utils.append on String args gets the root symbol and all-!eco.value ABI" <|
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
            , test "Char value selects the _Char variant with i32 ABI on the value axis" <|
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
        , describe "deriveKernelInstanceAbi for the JsArray builders (element suffix from the result)"
            [ test "JsArray.map to an Array Int selects map_Int" <|
                \_ ->
                    Expect.equal
                        { symbolName = "Elm_Kernel_JsArray_map_Int"
                        , abiArgTypes = [ ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        (KernelAbi.deriveKernelInstanceAbi
                            (jsArrayKey "map" [ Mono.MUnit, Mono.MUnit ] (jsArrayOf Mono.MInt))
                        )
            , test "JsArray.map to an Array String keeps the root symbol" <|
                \_ ->
                    Expect.equal "Elm_Kernel_JsArray_map"
                        (KernelAbi.deriveKernelInstanceAbi
                            (jsArrayKey "map" [ Mono.MUnit, Mono.MUnit ] (jsArrayOf Mono.MString))
                        ).symbolName
            , test "JsArray.initialize to an Array Float selects initialize_Int_Float" <|
                \_ ->
                    Expect.equal
                        { symbolName = "Elm_Kernel_JsArray_initialize_Int_Float"
                        , abiArgTypes = [ ecoInt, ecoInt, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        (KernelAbi.deriveKernelInstanceAbi
                            (jsArrayKey "initialize" [ Mono.MInt, Mono.MInt, Mono.MUnit ] (jsArrayOf Mono.MFloat))
                        )
            , test "JsArray.initialize with a boxed element keeps initialize_Int" <|
                \_ ->
                    Expect.equal "Elm_Kernel_JsArray_initialize_Int"
                        (KernelAbi.deriveKernelInstanceAbi
                            (jsArrayKey "initialize" [ Mono.MInt, Mono.MInt, Mono.MUnit ] Mono.MUnit)
                        ).symbolName
            , test "JsArray.indexedMap to an Array Char selects indexedMap_Int_Char" <|
                \_ ->
                    Expect.equal "Elm_Kernel_JsArray_indexedMap_Int_Char"
                        (KernelAbi.deriveKernelInstanceAbi
                            (jsArrayKey "indexedMap" [ Mono.MUnit, Mono.MInt, Mono.MUnit ] (jsArrayOf Mono.MChar))
                        ).symbolName
            , test "JsArray.initializeFromList takes the element from the pair's array" <|
                \_ ->
                    Expect.equal "Elm_Kernel_JsArray_initializeFromList_Int_Int"
                        (KernelAbi.deriveKernelInstanceAbi
                            (jsArrayKey "initializeFromList"
                                [ Mono.MInt, Mono.MUnit ]
                                (Mono.mTuple [ jsArrayOf Mono.MInt, Mono.mList Mono.MInt ])
                            )
                        ).symbolName
            , test "callInstanceResultType keys a JsArray builder by the call's own result" <|
                \_ ->
                    Expect.equal (jsArrayOf Mono.MInt)
                        (KernelAbi.callInstanceResultType "JsArray" "map" Mono.MUnit (jsArrayOf Mono.MInt))
            , test "List.map2 to a List Int selects map2_Int" <|
                \_ ->
                    Expect.equal
                        { symbolName = "Elm_Kernel_List_map2_Int"
                        , abiArgTypes = [ ecoValue, ecoValue, ecoValue ]
                        , abiResultType = ecoValue
                        }
                        (KernelAbi.deriveKernelInstanceAbi
                            (listMapKey "map2" 2 (Mono.mList Mono.MInt))
                        )
            , test "List.map5 to a List Char selects map5_Char" <|
                \_ ->
                    Expect.equal "Elm_Kernel_List_map5_Char"
                        (KernelAbi.deriveKernelInstanceAbi
                            (listMapKey "map5" 5 (Mono.mList Mono.MChar))
                        ).symbolName
            , test "List.map3 to a List String keeps the root symbol" <|
                \_ ->
                    Expect.equal "Elm_Kernel_List_map3"
                        (KernelAbi.deriveKernelInstanceAbi
                            (listMapKey "map3" 3 (Mono.mList Mono.MString))
                        ).symbolName
            , test "callInstanceResultType keys List.map4 by the call's own result" <|
                \_ ->
                    Expect.equal (Mono.mList Mono.MFloat)
                        (KernelAbi.callInstanceResultType "List" "map4" (Mono.mList Mono.MUnit) (Mono.mList Mono.MFloat))
            , test "callInstanceResultType keeps the ABI result for other kernels" <|
                \_ ->
                    Expect.equal Mono.MUnit
                        (KernelAbi.callInstanceResultType "Debug" "log" Mono.MUnit Mono.MInt)
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


{-| Builds the key for the elm/core `JsArray` kernel `name` at the given
argument and result types.
-}
jsArrayKey : String -> List Mono.MonoType -> Mono.MonoType -> KernelAbi.KernelInstanceKey
jsArrayKey name argTypes resultType =
    { prefix = "Elm"
    , home = "JsArray"
    , name = name
    , argTypes = argTypes
    , resultType = resultType
    }


{-| Builds the key for elm/core's `List.<name>`, one of `map2` to `map5`, taking
a closure and `lists` lists (all given as `()`, whose ABI type is
`!eco.value` like a list's) and returning `resultType`.
-}
listMapKey : String -> Int -> Mono.MonoType -> KernelAbi.KernelInstanceKey
listMapKey name lists resultType =
    { prefix = "Elm"
    , home = "List"
    , name = name
    , argTypes = List.repeat (lists + 1) Mono.MUnit
    , resultType = resultType
    }


{-| The monomorphic type of an elm/core `JsArray` of `element`.
-}
jsArrayOf : Mono.MonoType -> Mono.MonoType
jsArrayOf element =
    Mono.mCustom (ModuleName.Canonical ( "elm", "core" ) "Elm.JsArray") "JsArray" [ element ]


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
    Mlir.I32
