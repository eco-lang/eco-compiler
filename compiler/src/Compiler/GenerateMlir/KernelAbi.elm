module Compiler.GenerateMlir.KernelAbi exposing
    ( KernelBackendAbiPolicy(..), kernelBackendAbiPolicy
    , KernelInstanceKey, KernelInstanceAbi
    , deriveKernelInstanceAbi, callInstanceResultType
    )

{-| A kernel function is implemented in C++, and the MLIR backend must declare
and call it with exactly the C symbol and argument types the C++ side exports.
This module decides both, for one use of a kernel at one set of types.

A _kernel instance_ is one kernel, named by `(prefix, home, name)`, used at one
list of monomorphized argument types and one result type. The same kernel used
at different types is a different instance, and may need a different symbol or
different ABI types. `KernelInstanceKey` names an instance, and
`deriveKernelInstanceAbi` turns it into a `KernelInstanceAbi`.

Two independent decisions are made for an instance.

The symbol is `<prefix>_Kernel_<home>_<name>`. For a fixed list of
`(home, name)` pairs, a primitive argument type selects a C++ variant whose
symbol carries a `_Int`, `_Float` or `_Char` suffix: `Utils.compare`, `equal`,
`notEqual`, `lt`, `le`, `gt` and `ge` on two arguments of the same primitive
type; `String.fromNumber` and `Json.wrap` by their argument; `Basics.add`,
`sub`, `mul` and `pow` on two Ints or two Floats; `List.cons` by its head;
`JsArray.singleton`, `push` and `unsafeSet` by the element; `MVar.put` by the
value; and `JsArray.unsafeGet`, `slice`, `appendN`, `initialize`,
`initializeFromList` and `indexedMap`, which take `_Int` from an Int
parameter. `JsArray.map`, `initialize`, `indexedMap` and `initializeFromList`
also take a second suffix, `_Int`, `_Float` or `_Char`, from the element type
of the array they return (as in `Elm_Kernel_JsArray_map_Int` and
`Elm_Kernel_JsArray_initialize_Int_Float`): those variants store every
element in that slot kind, which is how code compiled for an `Array Int`,
`Array Float` or `Array Char` reads it, whatever kind the closure returns its
result in. `List.map2` to `map5` take the same suffix from the element type of
the list they return (as in `Elm_Kernel_List_map2_Int`), for the same reason:
code compiled for a `List Int` reads each head as a raw Int (HEAP\_046). Every
other instance keeps the unsuffixed symbol. The match is on `home`, `name`, the
argument types and, for those eight, the result type; `prefix` is not
consulted.

The ABI types are `Types.monoTypeToAbi` of each argument type and of the
result type, whatever the symbol. An unsuffixed symbol therefore does not mean
boxed arguments: an Int argument of an unsuffixed kernel is still an `i64`.

This module is distinct from `Compiler.Monomorphize.KernelAbi`, which decides,
independently of the backend, which type variables of a kernel's type stay
boxed. The types chosen here are MLIR types, so this half belongs to the
backend.


# Backend ABI Policy

@docs KernelBackendAbiPolicy, kernelBackendAbiPolicy


# Per-Instance ABI

@docs KernelInstanceKey, KernelInstanceAbi
@docs deriveKernelInstanceAbi, callInstanceResultType

-}

import Compiler.GenerateMlir.Types as Types
import Compiler.IR.Mono as Mono
import Mlir.Mlir exposing (MlirType)



-- KERNEL BACKEND ABI POLICY


{-| The rule by which a kernel instance's ABI types are chosen.

There is one rule, `ElmDerived`: each argument and the result take the ABI type
`Types.monoTypeToAbi` gives for its monomorphized type, so Int is `i64`, Float
`f64`, Char `i32`, a `number` type variable `i64`, and every other type
`!eco.value`. A kernel with no Int, Float or Char argument or result type
therefore gets an all-`!eco.value` ABI under the same rule.

-}
type KernelBackendAbiPolicy
    = ElmDerived


{-| The ABI policy applied to every kernel instance, which is `ElmDerived`.
-}
kernelBackendAbiPolicy : KernelBackendAbiPolicy
kernelBackendAbiPolicy =
    ElmDerived



-- PER-INSTANCE KERNEL ABI


{-| One kernel at one set of monomorphized types: a kernel instance.

`prefix`, `home` and `name` are the three parts of the unsuffixed C symbol,
`<prefix>_Kernel_<home>_<name>`, as in `Elm_Kernel_List_cons`.

-}
type alias KernelInstanceKey =
    { prefix : String
    , home : String
    , name : String
    , argTypes : List Mono.MonoType
    , resultType : Mono.MonoType
    }


{-| The C symbol and the MLIR ABI types with which one kernel instance is
declared and called.
-}
type alias KernelInstanceAbi =
    { symbolName : String
    , abiArgTypes : List MlirType
    , abiResultType : MlirType
    }


{-| Returns the C symbol and MLIR ABI types for a kernel instance.

The symbol is `<prefix>_Kernel_<home>_<name>`, with a `_Int`, `_Float` or
`_Char` suffix for the `(home, name)` pairs and argument types listed in this
module's docstring. The ABI types are `Types.monoTypeToAbi` of each argument
type and of the result type (the `ElmDerived` policy), chosen independently of
the symbol, so an Int, Float or Char argument or result always has its own
primitive MLIR type.

-}
deriveKernelInstanceAbi : KernelInstanceKey -> KernelInstanceAbi
deriveKernelInstanceAbi key =
    { symbolName = kernelInstanceSymbol key
    , abiArgTypes = List.map Types.monoTypeToAbi key.argTypes
    , abiResultType = Types.monoTypeToAbi key.resultType
    }


{-| Returns the C symbol for a kernel instance:
`<prefix>_Kernel_<home>_<name>`, followed by `_Int`, `_Float` or `_Char` when
`home`, `name` and the argument types match one of the cases below, and for
the `JsArray` kernels that build an array from a function or a list, by the
element suffix `resultElementSuffix` reads from the result type, and for
`List.map2` to `map5` by the element suffix of the list they return. Any other
instance, such as `Utils.compare` on two Strings, gets the unsuffixed symbol.
-}
kernelInstanceSymbol : KernelInstanceKey -> String
kernelInstanceSymbol key =
    let
        rootSymbol : String
        rootSymbol =
            key.prefix ++ "_Kernel_" ++ key.home ++ "_" ++ key.name

        suffixed : String -> String
        suffixed s =
            rootSymbol ++ s
    in
    case ( key.home, key.name, key.argTypes ) of
        ( "Utils", "compare", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "compare", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "compare", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        ( "Utils", "equal", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "equal", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "equal", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        ( "Utils", "notEqual", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "notEqual", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "notEqual", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        ( "Utils", "lt", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "lt", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "lt", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        ( "Utils", "le", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "le", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "le", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        ( "Utils", "gt", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "gt", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "gt", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        ( "Utils", "ge", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "ge", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "ge", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        ( "String", "fromNumber", [ Mono.MInt ] ) ->
            suffixed "_Int"

        ( "String", "fromNumber", [ Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Basics", "add", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Basics", "add", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Basics", "sub", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Basics", "sub", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Basics", "mul", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Basics", "mul", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Basics", "pow", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Basics", "pow", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "List", "cons", [ Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "List", "cons", [ Mono.MFloat, _ ] ) ->
            suffixed "_Float"

        ( "List", "cons", [ Mono.MChar, _ ] ) ->
            suffixed "_Char"

        ( "Json", "wrap", [ Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Json", "wrap", [ Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Json", "wrap", [ Mono.MChar ] ) ->
            suffixed "_Char"

        ( "JsArray", "singleton", [ Mono.MInt ] ) ->
            suffixed "_Int"

        ( "JsArray", "singleton", [ Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "JsArray", "singleton", [ Mono.MChar ] ) ->
            suffixed "_Char"

        ( "JsArray", "push", [ Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "JsArray", "push", [ Mono.MFloat, _ ] ) ->
            suffixed "_Float"

        ( "JsArray", "push", [ Mono.MChar, _ ] ) ->
            suffixed "_Char"

        -- The first argument is the Int index; the suffix names the element.
        ( "JsArray", "unsafeSet", [ Mono.MInt, Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "JsArray", "unsafeSet", [ Mono.MInt, Mono.MFloat, _ ] ) ->
            suffixed "_Float"

        ( "JsArray", "unsafeSet", [ Mono.MInt, Mono.MChar, _ ] ) ->
            suffixed "_Char"

        -- These take `_Int` for an Int parameter, whatever the element type.
        ( "JsArray", "unsafeGet", [ Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "JsArray", "slice", [ Mono.MInt, Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "JsArray", "appendN", [ Mono.MInt, _, _ ] ) ->
            suffixed "_Int"

        -- These also take the element suffix of the array they build.
        ( "JsArray", "initialize", [ Mono.MInt, Mono.MInt, _ ] ) ->
            suffixed ("_Int" ++ resultElementSuffix key.resultType)

        ( "JsArray", "initializeFromList", [ Mono.MInt, _ ] ) ->
            suffixed ("_Int" ++ resultElementSuffix key.resultType)

        ( "JsArray", "indexedMap", [ _, Mono.MInt, _ ] ) ->
            suffixed ("_Int" ++ resultElementSuffix key.resultType)

        ( "JsArray", "map", [ _, _ ] ) ->
            suffixed (resultElementSuffix key.resultType)

        -- These take the element suffix of the list they build.
        ( "List", "map2", _ ) ->
            suffixed (listElementSuffix key.resultType)

        ( "List", "map3", _ ) ->
            suffixed (listElementSuffix key.resultType)

        ( "List", "map4", _ ) ->
            suffixed (listElementSuffix key.resultType)

        ( "List", "map5", _ ) ->
            suffixed (listElementSuffix key.resultType)

        -- The first argument is the Int id; the suffix names the value.
        ( "MVar", "put", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "MVar", "put", [ Mono.MInt, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "MVar", "put", [ Mono.MInt, Mono.MChar ] ) ->
            suffixed "_Char"

        _ ->
            rootSymbol


{-| Returns the suffix that names the element type of the array a `JsArray`
kernel builds: `"_Int"`, `"_Float"` or `"_Char"` when `resultType` is a
`JsArray` of Int, Float or Char, or a pair whose first component is one (the
result of `initializeFromList`), and `""` for any other element type, a type
variable included.
-}
resultElementSuffix : Mono.MonoType -> String
resultElementSuffix resultType =
    let
        elementSuffix : Mono.MonoType -> String
        elementSuffix arrayType =
            case arrayType of
                Mono.MCustom _ _ "JsArray" [ Mono.MInt ] ->
                    "_Int"

                Mono.MCustom _ _ "JsArray" [ Mono.MFloat ] ->
                    "_Float"

                Mono.MCustom _ _ "JsArray" [ Mono.MChar ] ->
                    "_Char"

                _ ->
                    ""
    in
    case resultType of
        Mono.MTuple _ (Mono.T2 arrayType _) ->
            elementSuffix arrayType

        _ ->
            elementSuffix resultType


{-| Returns the suffix that names the element type of the list a `List.mapN`
kernel builds: `"_Int"`, `"_Float"` or `"_Char"` when `resultType` is a list
of Int, Float or Char, and `""` for any other element type, a type variable
included.
-}
listElementSuffix : Mono.MonoType -> String
listElementSuffix resultType =
    case resultType of
        Mono.MList _ Mono.MInt ->
            "_Int"

        Mono.MList _ Mono.MFloat ->
            "_Float"

        Mono.MList _ Mono.MChar ->
            "_Char"

        _ ->
            ""


{-| Returns the result type under which a saturated call of the kernel
`home.name` is keyed, given the result type `abiResultType` of the kernel's
ABI and the call's own result type `callResultType`.

For `JsArray.map`, `initialize`, `indexedMap` and `initializeFromList`, and
for `List.map2` to `map5`, whose variant is chosen by the element type of the
array or list they build (see the module docstring), it is `callResultType`:
the kernel's ABI keeps that element a boxed type variable, while the call's
own type has it concrete. The two have the same
ABI type, `!eco.value`, so the declaration does not change; where they would
not, and for every other kernel, it is `abiResultType`.
-}
callInstanceResultType : String -> String -> Mono.MonoType -> Mono.MonoType -> Mono.MonoType
callInstanceResultType home name abiResultType callResultType =
    let
        selectsByElement : Bool
        selectsByElement =
            (home
                == "JsArray"
                && (name == "map" || name == "initialize" || name == "indexedMap" || name == "initializeFromList")
            )
                || (home == "List" && (name == "map2" || name == "map3" || name == "map4" || name == "map5"))
    in
    if selectsByElement && Types.monoTypeToAbi callResultType == Types.monoTypeToAbi abiResultType then
        callResultType

    else
        abiResultType
