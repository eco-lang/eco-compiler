module Compiler.Generate.MLIR.KernelAbi exposing
    ( KernelBackendAbiPolicy(..), kernelBackendAbiPolicy
    , KernelInstanceKey, KernelInstanceAbi
    , deriveKernelInstanceAbi
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
parameter. Every other instance keeps the unsuffixed symbol. The match is on
`home`, `name` and the argument types only; `prefix` is not consulted.

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
@docs deriveKernelInstanceAbi

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Types as Types
import Mlir.Mlir exposing (MlirType)
import Utils.Crash exposing (crash)



-- KERNEL BACKEND ABI POLICY


{-| The rule by which a kernel instance's ABI types are chosen.

There is one rule, `ElmDerived`: each argument and the result take the ABI type
`Types.monoTypeToAbi` gives for its monomorphized type, so Int is `i64`, Float
`f64`, Char `i16`, a `number` type variable `i64`, and every other type
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
type and of the result type, chosen independently of the symbol.

Crashes the compiler if an Int, Float or Char argument or result would be given
an ABI type other than its own primitive MLIR type.

-}
deriveKernelInstanceAbi : KernelInstanceKey -> KernelInstanceAbi
deriveKernelInstanceAbi key =
    let
        symbolName : String
        symbolName =
            kernelInstanceSymbol key

        policy : KernelBackendAbiPolicy
        policy =
            kernelBackendAbiPolicy

        ( abiArgTypes, abiResultType ) =
            case policy of
                ElmDerived ->
                    ( List.map Types.monoTypeToAbi key.argTypes
                    , Types.monoTypeToAbi key.resultType
                    )

        abi : KernelInstanceAbi
        abi =
            { symbolName = symbolName
            , abiArgTypes = abiArgTypes
            , abiResultType = abiResultType
            }
    in
    case policy of
        ElmDerived ->
            ensurePrimitiveAbi key abi


{-| Returns the C symbol for a kernel instance:
`<prefix>_Kernel_<home>_<name>`, followed by `_Int`, `_Float` or `_Char` when
`home`, `name` and the argument types match one of the cases below. Any other
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

        ( "JsArray", "initialize", [ Mono.MInt, Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "JsArray", "initializeFromList", [ Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "JsArray", "indexedMap", [ _, Mono.MInt, _ ] ) ->
            suffixed "_Int"

        -- The first argument is the Int id; the suffix names the value.
        ( "MVar", "put", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "MVar", "put", [ Mono.MInt, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "MVar", "put", [ Mono.MInt, Mono.MChar ] ) ->
            suffixed "_Char"

        _ ->
            rootSymbol


{-| Returns `abi` unchanged if every Int, Float and Char argument or result of
`key` has its own primitive MLIR type in `abi`, and crashes the compiler with a
message naming each mismatched slot otherwise.

Slots of any other type are not checked.

-}
ensurePrimitiveAbi : KernelInstanceKey -> KernelInstanceAbi -> KernelInstanceAbi
ensurePrimitiveAbi key abi =
    let
        slotErr : String -> Mono.MonoType -> MlirType -> String
        slotErr where_ monoTy mlirTy =
            "Kernel ABI primitive mismatch for "
                ++ key.home
                ++ "."
                ++ key.name
                ++ " "
                ++ where_
                ++ ": MonoType "
                ++ monoTypeTag monoTy
                ++ " paired with MLIR "
                ++ Types.mlirTypeToString mlirTy

        checkSlot : String -> ( Mono.MonoType, MlirType ) -> Maybe String
        checkSlot where_ ( monoTy, mlirTy ) =
            case ( monoTy, mlirTy ) of
                ( Mono.MInt, _ ) ->
                    if mlirTy == Types.ecoInt then
                        Nothing

                    else
                        Just (slotErr where_ monoTy mlirTy)

                ( Mono.MFloat, _ ) ->
                    if mlirTy == Types.ecoFloat then
                        Nothing

                    else
                        Just (slotErr where_ monoTy mlirTy)

                ( Mono.MChar, _ ) ->
                    if mlirTy == Types.ecoChar then
                        Nothing

                    else
                        Just (slotErr where_ monoTy mlirTy)

                _ ->
                    -- A `number` type variable is legitimately `i64` here.
                    Nothing

        argErrors : List String
        argErrors =
            List.indexedMap
                (\i pair ->
                    checkSlot ("arg" ++ String.fromInt i) pair
                )
                (List.map2 Tuple.pair key.argTypes abi.abiArgTypes)
                |> List.filterMap identity

        resultErrors : List String
        resultErrors =
            checkSlot "result" ( key.resultType, abi.abiResultType )
                |> Maybe.map List.singleton
                |> Maybe.withDefault []

        errors : List String
        errors =
            argErrors ++ resultErrors
    in
    case errors of
        [] ->
            abi

        _ ->
            crash ("ensurePrimitiveAbi: " ++ String.join "; " errors)


{-| Returns a short name for the outermost constructor of a type, for the
error message of `ensurePrimitiveAbi`.
-}
monoTypeTag : Mono.MonoType -> String
monoTypeTag monoType =
    case monoType of
        Mono.MInt ->
            "MInt"

        Mono.MFloat ->
            "MFloat"

        Mono.MBool ->
            "MBool"

        Mono.MChar ->
            "MChar"

        Mono.MString ->
            "MString"

        Mono.MUnit ->
            "MUnit"

        Mono.MList _ _ ->
            "Mono.mList"

        Mono.MTuple _ _ ->
            "Mono.mTuple"

        Mono.MRecord _ _ ->
            "Mono.mRecord"

        Mono.MCustom _ _ n _ ->
            "Mono.mCustom " ++ n

        Mono.MFunction _ _ _ _ ->
            "Mono.mFunction"

        Mono.MVar _ Mono.CEcoValue ->
            "MVar CEcoValue"

        Mono.MVar _ Mono.CNumber ->
            "MVar CNumber"
