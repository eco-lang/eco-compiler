module Compiler.Generate.MLIR.KernelAbi exposing
    ( KernelBackendAbiPolicy(..), kernelBackendAbiPolicy
    , KernelInstanceKey, KernelInstanceAbi
    , deriveKernelInstanceAbi
    )

{-| Per-instance kernel ABI lowering for the MLIR backend.

This is the MLIR-facing half of kernel ABI handling. It maps a
`KernelInstanceKey` (the `(prefix, home, name)` plus monomorphized argument
and result types of one kernel instantiation) to the concrete C symbol name
and the `MlirType` ABI that the kernel's declaration and call sites must use.

It deliberately lives in the generate/MLIR layer rather than in
`Compiler.Monomorphize.KernelAbi`: the result type `KernelInstanceAbi` carries
`MlirType` values, so the derivation is backend-specific. The monomorphize-layer
`KernelAbi` keeps only the backend-neutral ABI-mode decisions (which type
variables stay boxed), which is all that `Compiler.Monomorphize.Specialize`
needs.

See plans/per-instance-kernel-abi.md for the rollout phases.


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



-- ============================================================================
-- KERNEL BACKEND ABI POLICY
-- ============================================================================
--
-- During the per-instance kernel ABI rollout (see plans/per-instance-kernel-abi.md)
-- this table acts as a coarse "always boxed" guardrail. As each kernel migrates
-- to monomorphic variants, its broad-policy entry is replaced with explicit
-- per-name entries for the kernels that *stay* AllBoxed. Phase E retires the
-- table entirely.
-- ============================================================================


{-| Backend ABI policy for kernel function calls.

    AllBoxed   -> All args and result are !eco.value in MLIR, regardless of
                  the monomorphized Elm wrapper type. Used for kernels whose
                  C++ implementation uniformly takes boxed uint64_t values
                  (e.g., List.cons).

    ElmDerived -> ABI is derived from the Elm wrapper's funcType via
                  monoTypeToAbi. Used for kernels with typed C++ signatures
                  (e.g., Basics.fdiv takes double, String.cons takes uint16_t).

-}
type KernelBackendAbiPolicy
    = ElmDerived


{-| Determine the backend ABI policy for a kernel call.

Only kernels whose C++ implementation takes ALL arguments as boxed
uint64\_t (eco.value) and returns uint64\_t should be marked AllBoxed.
When in doubt, use ElmDerived (safe default — preserves current behavior).

-}
kernelBackendAbiPolicy : String -> String -> KernelBackendAbiPolicy
kernelBackendAbiPolicy _ _ =
    -- Phase F step 3 + step 5: every kernel now derives its ABI from the
    -- call-site monomorphized type via `monoTypeToAbi`. Kernels with no
    -- primitive-capable parameters (List.fromArray/toArray/map2-5/
    -- sortBy/sortWith, Utils.append, JsArray.empty/length/map/foldl/
    -- foldr) produce identical wire format under either policy, so the
    -- explicit `AllBoxed` arms were redundant. The `Basics.add/sub/mul/
    -- pow` arms moved to ElmDerived in Phase E.2 to match the new
    -- per-instance C symbols. Debug.* is handled separately via
    -- `alwaysPolymorphicModules`.
    ElmDerived



-- ============================================================================
-- PER-INSTANCE KERNEL ABI
-- ============================================================================
--
-- A KernelInstanceKey identifies one specific monomorphic instantiation of a
-- kernel. deriveKernelInstanceAbi maps a key to the C symbol name and MLIR
-- ABI types that its declaration and call sites must use.
--
-- Phase A behaviour: every kernel returns its today's symbol (no suffix).
-- Phase B onwards: per-instance suffixes (e.g. "_Int", "_Float", "_Char")
-- are introduced kernel-by-kernel.
-- ============================================================================


{-| Identifies a logical instantiation of a kernel: same `(prefix, home, name)`
with different MonoTypes maps to different instances. `prefix` is the package
namespace prefix (`"Elm"` for elm-core kernels, `"Eco"` for user-package
kernels via `Eco.Kernel.*`); the resulting C symbol begins with
`<prefix>_Kernel_`.
-}
type alias KernelInstanceKey =
    { prefix : String
    , home : String
    , name : String
    , argTypes : List Mono.MonoType
    , resultType : Mono.MonoType
    }


{-| The C symbol name and MLIR ABI types that a kernel call site must use for
a given `KernelInstanceKey`.
-}
type alias KernelInstanceAbi =
    { symbolName : String
    , abiArgTypes : List MlirType
    , abiResultType : MlirType
    }


{-| Compute the C symbol name plus MLIR ABI types for a per-instance kernel
call.

Phase A: the symbol is exactly the legacy `Elm_Kernel_<home>_<name>` and the
ABI types are determined by `kernelBackendAbiPolicy` (AllBoxed → all
`!eco.value`; ElmDerived → `monoTypeToAbi` of each argument and the result).
This produces the same wire format as today.

Phase B onwards adds suffix branches for primitive instantiations (see
Appendix A of `plans/per-instance-kernel-abi.md`).

-}
deriveKernelInstanceAbi : KernelInstanceKey -> KernelInstanceAbi
deriveKernelInstanceAbi key =
    let
        symbolName : String
        symbolName =
            kernelInstanceSymbol key

        policy : KernelBackendAbiPolicy
        policy =
            kernelBackendAbiPolicy key.home key.name

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


{-| Compute the C symbol name for a per-instance kernel call.

Phase B onwards adds suffixes for kernels that have been migrated to
per-primitive C++ variants. For unmigrated kernels and for kernel
instantiations that don't match a known primitive specialization (e.g.
`compare "a" "b"`), the legacy `Elm_Kernel_<home>_<name>` is returned.

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
        --
        -- Phase B (Utils.compare): primitive comparables get a typed
        -- monomorphic C++ entry point. All other comparables (String,
        -- List, Tuple, ...) keep the boxed root symbol.
        --
        ( "Utils", "compare", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Utils", "compare", [ Mono.MFloat, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Utils", "compare", [ Mono.MChar, Mono.MChar ] ) ->
            suffixed "_Char"

        --
        -- Phase C (Utils.equal/notEqual/lt/le/gt/ge): equality and ordering
        -- on primitive values. Result type is `Bool` (boxed at ABI).
        --
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

        --
        -- Phase C (String.fromNumber): number → String specialised by Int / Float.
        --
        ( "String", "fromNumber", [ Mono.MInt ] ) ->
            suffixed "_Int"

        ( "String", "fromNumber", [ Mono.MFloat ] ) ->
            suffixed "_Float"

        --
        -- Phase E.2 (Basics.add/sub/mul/pow): per-instance Int / Float
        -- variants for the arithmetic operators. Direct uses are
        -- intrinsic-lowered before reaching here; these arms are reached
        -- by indirect uses (e.g. `(+)` captured into a PAP by
        -- `List.foldl`) so the unboxed primitive ABI is used end-to-end.
        --
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

        --
        -- Phase C (List.cons): primitive head element drives a typed C++
        -- variant; non-primitive heads keep the boxed root.
        --
        ( "List", "cons", [ Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "List", "cons", [ Mono.MFloat, _ ] ) ->
            suffixed "_Float"

        ( "List", "cons", [ Mono.MChar, _ ] ) ->
            suffixed "_Char"

        --
        -- Phase C (Json.wrap): element axis. Polymorphic uses (String, Bool,
        -- Object) keep the boxed root.
        --
        ( "Json", "wrap", [ Mono.MInt ] ) ->
            suffixed "_Int"

        ( "Json", "wrap", [ Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "Json", "wrap", [ Mono.MChar ] ) ->
            suffixed "_Char"

        --
        -- Phase C (JsArray element-axis kernels): singleton, push, unsafeSet.
        -- The element type drives suffix selection. JsArray.unsafeSet's
        -- index parameter (Int) is always typed via ElmDerived; the suffix
        -- only encodes the element axis.
        --
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

        ( "JsArray", "unsafeSet", [ Mono.MInt, Mono.MInt, _ ] ) ->
            suffixed "_Int"

        ( "JsArray", "unsafeSet", [ Mono.MInt, Mono.MFloat, _ ] ) ->
            suffixed "_Float"

        ( "JsArray", "unsafeSet", [ Mono.MInt, Mono.MChar, _ ] ) ->
            suffixed "_Char"

        --
        -- Phase C (JsArray Int-axis kernels): unsafeGet, slice, appendN,
        -- initialize, initializeFromList, indexedMap. Each has at least one
        -- `Int` parameter that becomes typed `int64_t` at the C boundary.
        -- The suffix is `_Int` because the discriminator is the Int axis.
        -- These kernels' signatures always have concrete `Int` parameters,
        -- so the suffix always fires; the boxed root is unreachable for
        -- these names.
        --
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

        --
        -- Eco kernels (key.prefix = "Eco"). MVar.put specialises on the
        -- value-type axis; the Int id parameter is always concrete and only
        -- the second argument drives suffix selection.
        --
        ( "MVar", "put", [ Mono.MInt, Mono.MInt ] ) ->
            suffixed "_Int"

        ( "MVar", "put", [ Mono.MInt, Mono.MFloat ] ) ->
            suffixed "_Float"

        ( "MVar", "put", [ Mono.MInt, Mono.MChar ] ) ->
            suffixed "_Char"

        _ ->
            rootSymbol


{-| Self-check (REP\_ABI\_001 / KERN\_006): an `MInt`/`MFloat`/`MChar` parameter
or result must be paired with the corresponding primitive MLIR type, and a
non-primitive Mono type must not be paired with a primitive MLIR type. Crashes
if the invariant is violated; otherwise returns the abi unchanged.
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
                    -- Non-primitive Mono types: ABI may be either !eco.value
                    -- (the common case) or any other MLIR type allowed by
                    -- monoTypeToAbi. Nothing further to check here.
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


{-| Short tag string for a MonoType, used in error messages produced by
`ensurePrimitiveAbi`.
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

        Mono.MList _ ->
            "MList"

        Mono.MTuple _ ->
            "MTuple"

        Mono.MRecord _ ->
            "MRecord"

        Mono.MCustom _ n _ ->
            "MCustom " ++ n

        Mono.MFunction _ _ ->
            "MFunction"

        Mono.MVar _ Mono.CEcoValue ->
            "MVar CEcoValue"

        Mono.MVar _ Mono.CNumber ->
            "MVar CNumber"
