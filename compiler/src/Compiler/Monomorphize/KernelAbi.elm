module Compiler.Monomorphize.KernelAbi exposing
    ( KernelAbiMode(..), deriveKernelAbiMode
    , canTypeToMonoType_preserveVars
    , suffixSelectingKernels, comparePair
    , freeVarIds
    , KernelBackendAbiPolicy(..), kernelBackendAbiPolicy
    , KernelInstanceKey, KernelInstanceAbi
    , deriveKernelInstanceAbi, kernelInstanceSymbol
    )

{-| Kernel ABI type derivation for monomorphization.

This module implements the algorithm that determines the MonoType used for
kernel function ABIs. The key insight is that polymorphic kernels must use
a consistent ABI (all `eco.value`) regardless of call-site type instantiation.

Two cases:

1.  **Monomorphic kernels** (e.g., `Basics.modBy : Int -> Int -> Int`):
    ABI matches the concrete types. Use call-site substitution.

2.  **Polymorphic kernels** (e.g., `List.cons : a -> List a -> List a`):
    Type variables become `MVar _ CEcoValue`, always boxed.


# ABI Mode Selection

@docs KernelAbiMode, deriveKernelAbiMode


# Type Converters

@docs canTypeToMonoType_preserveVars


# Suffix-Selecting Kernels

@docs suffixSelectingKernels, comparePair


# Free Variable Extraction (for AssignMVarIds, operates on Can.Type Name)


# Free Variable Ids

@docs freeVarIds


# Kernel Backend ABI Policy

@docs KernelBackendAbiPolicy, kernelBackendAbiPolicy


# Per-Instance Kernel ABI

@docs KernelInstanceKey, KernelInstanceAbi
@docs deriveKernelInstanceAbi, kernelInstanceSymbol

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Generate.MLIR.Types as MlirTypes
import Compiler.Monomorphize.State exposing (MVarEnv)
import Data.Set as EverySet exposing (EverySet)
import Dict
import Mlir.Mlir exposing (MlirType)
import Set exposing (Set)
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- ============================================================================
-- ABI MODE
-- ============================================================================


{-| The ABI mode determines how a kernel function's MonoType is derived.

  - `UseSubstitution`: Monomorphic kernel - apply call-site substitution normally
  - `PreserveVars`: Polymorphic kernel - preserve all type vars as `CEcoValue`

-}
type KernelAbiMode
    = UseSubstitution
    | PreserveVars


{-| Determine which ABI mode to use for a kernel function.

Arguments:

  - `(home, name)`: Kernel identifier (e.g., `("List", "cons")`)
  - `canFuncType`: Canonical function type (Can.Type MVarId)
  - `mvarEnv`: MVarEnv for constraint lookups

Returns the appropriate `KernelAbiMode`.

-}
deriveKernelAbiMode : ( String, String ) -> Can.Type MVarId -> MVarEnv -> KernelAbiMode
deriveKernelAbiMode ( home, _ ) canFuncType _ =
    -- Debug kernels are always polymorphic
    if EverySet.member List.singleton home alwaysPolymorphicModules then
        PreserveVars

    else
        let
            varIds =
                freeVarIds canFuncType []
        in
        if List.isEmpty varIds then
            -- Case A: Monomorphic kernel - use substitution
            UseSubstitution

        else
            -- Case B: Polymorphic kernel
            PreserveVars



-- ============================================================================
-- CONSTANTS
-- ============================================================================


{-| Kernels registered for **suffix selection** under per-instance kernel
ABIs. Membership is the registration mechanism: when a kernel is in this
set AND its call-site type is fully monomorphic,
`deriveKernelAbiType` keeps the concrete MonoType (rather than erasing
to `CEcoValue`-typed type variables via `canTypeToMonoType_preserveVars`).
The concrete type then flows into `kernelInstanceSymbol`, which pattern-
matches on `[MInt, MInt]` / `[MFloat, MFloat]` / `[MChar, MChar]` (etc.)
and picks the `_Int` / `_Float` / `_Char` C symbol variant.

This set is **load-bearing**, not a transitional shim. Without
`canTypeToMonoType_preserveVars` erases primitive type variables to
`CEcoValue` before the suffix selector sees them, and lookups like
`("List","cons",[MInt,_])` no longer match.

Two distinct downstream consumers benefit:

  - **Element-aware container kernels** (e.g. `List.cons`): the concrete
    MonoType drives Elm-level wrapper generation — different
    `List_cons_$_N` closures per element type.

  - **Primitive-specialized kernels** (e.g. `Utils.compare`,
    `Basics.add`): the concrete MonoType lets `kernelInstanceSymbol`
    select the per-instance C symbol variant.

For polymorphic call sites (e.g. `compare "a" "b"` reaching
`Utils.compare` with `[MString, MString]`), the suffix selector falls
through to the boxed root symbol.

(Phase F renamed this from `concreteTypeAwareKernels`.)

-}
suffixSelectingKernels : EverySet (List String) ( String, String )
suffixSelectingKernels =
    EverySet.fromList comparePair
        [ -- Element-aware wrapper specialization
          ( "List", "cons" )

        -- Phase B
        , ( "Utils", "compare" )

        -- Phase C: Utils equality and ordering (comparable / a)
        , ( "Utils", "equal" )
        , ( "Utils", "notEqual" )
        , ( "Utils", "lt" )
        , ( "Utils", "le" )
        , ( "Utils", "gt" )
        , ( "Utils", "ge" )

        -- Phase C: JSON value boxing (element axis)
        , ( "Json", "wrap" )

        -- Phase C: JsArray element-axis kernels
        , ( "JsArray", "singleton" )
        , ( "JsArray", "push" )
        , ( "JsArray", "unsafeSet" )

        -- Eco-kernel: MVar.put specialises on the value-type axis. Without
        -- this entry, deriveKernelAbiType under PreserveVars erases `a` to
        -- CEcoValue, hiding the Int/Float/Char axis from the suffix selector
        -- in kernelInstanceSymbol.
        , ( "MVar", "put" )

        -- Phase E.2: Basics.add/sub/mul/pow get per-instance _Int/_Float
        -- variants. Indirect uses (e.g. `List.foldl (+) 0 xs`) need this
        -- entry so PreserveVars keeps the concrete numeric type and the
        -- suffix selector can pick the unboxed C symbol. Direct uses are
        -- intrinsic-lowered upstream and never reach the kernel symbol.
        , ( "Basics", "add" )
        , ( "Basics", "sub" )
        , ( "Basics", "mul" )
        , ( "Basics", "pow" )

        -- Phase F step 1: String.fromNumber moved here from
        -- numberBoxedKernels. _Int / _Float per-instance variants exist
        -- in StringExports.cpp and the kernelInstanceSymbol selector
        -- picks them when the argument type is concrete; the boxed root
        -- handles any genuinely polymorphic uses.
        , ( "String", "fromNumber" )
        ]


{-| Modules whose kernels are always polymorphic regardless of type variables.

Debug kernels always use boxed ABI because they work with any type.

-}
alwaysPolymorphicModules : EverySet (List String) String
alwaysPolymorphicModules =
    EverySet.fromList List.singleton [ "Debug" ]


{-| Comparison function for (String, String) pairs.
-}
comparePair : ( String, String ) -> List String
comparePair ( a, b ) =
    [ a, b ]



-- ============================================================================
-- FREE VARIABLE EXTRACTION (Name-based, for AssignMVarIds)
-- ============================================================================
-- ============================================================================
-- FREE VARIABLE EXTRACTION (MVarId-based, for post-rewrite)
-- ============================================================================


{-| Collect all free type variable MVarIds from a canonical type.
-}
freeVarIds : Can.Type MVarId -> List MVarId -> List MVarId
freeVarIds canType acc =
    let
        seen =
            List.foldl (\id s -> Set.insert (Id.toComparable id) s) Set.empty acc
    in
    Tuple.first (freeVarIdsHelp canType ( acc, seen ))


freeVarIdsHelp : Can.Type MVarId -> ( List MVarId, Set Int ) -> ( List MVarId, Set Int )
freeVarIdsHelp canType (( acc, seen ) as pair) =
    case canType of
        Can.TVar mvarId ->
            let
                key =
                    Id.toComparable mvarId
            in
            if Set.member key seen then
                pair

            else
                ( mvarId :: acc, Set.insert key seen )

        Can.TLambda from to ->
            freeVarIdsHelp to (freeVarIdsHelp from pair)

        Can.TType _ _ args ->
            List.foldl (\a accPair -> freeVarIdsHelp a accPair) pair args

        Can.TRecord fields maybeExt ->
            let
                fieldPair =
                    Dict.foldl (\_ (Can.FieldType _ t) accPair -> freeVarIdsHelp t accPair) pair fields
            in
            case maybeExt of
                Just extId ->
                    let
                        extKey =
                            Id.toComparable extId

                        ( fieldAcc, fieldSeen ) =
                            fieldPair
                    in
                    if Set.member extKey fieldSeen then
                        fieldPair

                    else
                        ( extId :: fieldAcc, Set.insert extKey fieldSeen )

                Nothing ->
                    fieldPair

        Can.TTuple a b rest ->
            List.foldl (\t accPair -> freeVarIdsHelp t accPair) pair (a :: b :: rest)

        Can.TUnit ->
            pair

        Can.TAlias _ _ _ (Can.Filled inner) ->
            freeVarIdsHelp inner pair

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                argPair =
                    List.foldl (\( _, t ) accPair -> freeVarIdsHelp t accPair) pair args
            in
            freeVarIdsHelp inner argPair



-- ============================================================================
-- TYPE CONVERTERS (MVarId-based, for post-rewrite)
-- ============================================================================


{-| Convert canonical type to MonoType, preserving all type variables as CEcoValue.

Used for polymorphic kernels where the ABI must be all-boxed.

-}
canTypeToMonoType_preserveVars : MVarEnv -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
canTypeToMonoType_preserveVars env canType =
    case canType of
        Can.TVar mvarId ->
            -- Directly reuse the MVarId, force CEcoValue constraint for ABI
            ( Mono.MVar mvarId Mono.CEcoValue, env )

        Can.TLambda from to ->
            let
                ( fromMono, env1 ) =
                    canTypeToMonoType_preserveVars env from

                ( toMono, env2 ) =
                    canTypeToMonoType_preserveVars env1 to
            in
            ( Mono.MFunction [ fromMono ] toMono, env2 )

        Can.TType canonical name args ->
            convertTType canTypeToMonoType_preserveVars env canonical name args

        Can.TRecord fields _ ->
            let
                ( monoFields, env1 ) =
                    Dict.foldl
                        (\k (Can.FieldType _ t) ( acc, e ) ->
                            let
                                ( monoT, e1 ) =
                                    canTypeToMonoType_preserveVars e t
                            in
                            ( Dict.insert k monoT acc, e1 )
                        )
                        ( Dict.empty, env )
                        fields
            in
            ( Mono.MRecord monoFields, env1 )

        Can.TTuple a b rest ->
            let
                ( revMonoTypes, env1 ) =
                    List.foldl
                        (\t ( acc, e ) ->
                            let
                                ( monoT, e1 ) =
                                    canTypeToMonoType_preserveVars e t
                            in
                            ( monoT :: acc, e1 )
                        )
                        ( [], env )
                        (a :: b :: rest)
            in
            ( Mono.MTuple (List.reverse revMonoTypes), env1 )

        Can.TUnit ->
            ( Mono.MUnit, env )

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoType_preserveVars env inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            canTypeToMonoType_preserveVars env inner


{-| Helper for converting TType nodes with shared logic.
-}
convertTType : (MVarEnv -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )) -> MVarEnv -> IO.Canonical -> Name -> List (Can.Type MVarId) -> ( Mono.MonoType, MVarEnv )
convertTType convert env canonical name args =
    let
        ( revMonoArgs, env1 ) =
            List.foldl
                (\t ( acc, e ) ->
                    let
                        ( monoT, e1 ) =
                            convert e t
                    in
                    ( monoT :: acc, e1 )
                )
                ( [], env )
                args

        monoArgs =
            List.reverse revMonoArgs

        isElmCore =
            case canonical of
                IO.Canonical ( "elm", "core" ) _ ->
                    True

                _ ->
                    False
    in
    if isElmCore then
        case name of
            "Int" ->
                ( Mono.MInt, env1 )

            "Float" ->
                ( Mono.MFloat, env1 )

            "Bool" ->
                ( Mono.MBool, env1 )

            "Char" ->
                ( Mono.MChar, env1 )

            "String" ->
                ( Mono.MString, env1 )

            "List" ->
                case monoArgs of
                    [ inner ] ->
                        ( Mono.MList inner, env1 )

                    _ ->
                        ( Mono.MList Mono.MUnit, env1 )

            _ ->
                ( Mono.MCustom canonical name monoArgs, env1 )

    else
        ( Mono.MCustom canonical name monoArgs, env1 )



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
    = AllBoxed
    | ElmDerived


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
        _ =
            assertNoCNumberInKey key

        symbolName : String
        symbolName =
            kernelInstanceSymbol key

        policy : KernelBackendAbiPolicy
        policy =
            kernelBackendAbiPolicy key.home key.name

        ( abiArgTypes, abiResultType ) =
            case policy of
                AllBoxed ->
                    ( List.map (\_ -> MlirTypes.ecoValue) key.argTypes
                    , MlirTypes.ecoValue
                    )

                ElmDerived ->
                    ( List.map MlirTypes.monoTypeToAbi key.argTypes
                    , MlirTypes.monoTypeToAbi key.resultType
                    )

        abi : KernelInstanceAbi
        abi =
            { symbolName = symbolName
            , abiArgTypes = abiArgTypes
            , abiResultType = abiResultType
            }
    in
    case policy of
        AllBoxed ->
            -- Transitional path: primitives are intentionally boxed to match
            -- the unmigrated C++ all-uint64_t signature. The ensurePrimitiveAbi
            -- self-check only applies under ElmDerived, which is the
            -- end-state invariant (REP_ABI_001).
            abi

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


{-| Self-check (REP_ABI_001 / KERN_006): an `MInt`/`MFloat`/`MChar` parameter
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
                ++ MlirTypes.mlirTypeToString mlirTy

        checkSlot : String -> ( Mono.MonoType, MlirType ) -> Maybe String
        checkSlot where_ ( monoTy, mlirTy ) =
            case ( monoTy, mlirTy ) of
                ( Mono.MInt, _ ) ->
                    if mlirTy == MlirTypes.ecoInt then
                        Nothing

                    else
                        Just (slotErr where_ monoTy mlirTy)

                ( Mono.MFloat, _ ) ->
                    if mlirTy == MlirTypes.ecoFloat then
                        Nothing

                    else
                        Just (slotErr where_ monoTy mlirTy)

                ( Mono.MChar, _ ) ->
                    if mlirTy == MlirTypes.ecoChar then
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


{-| MONO_002 spot-check: any reachable kernel call site must have its numeric
type variables resolved to concrete `MInt`/`MFloat` before MLIR codegen. An
`MVar _ CNumber` in a `KernelInstanceKey` is a compiler bug.
-}
assertNoCNumberInKey : KernelInstanceKey -> ()
assertNoCNumberInKey key =
    let
        bad : List Mono.MonoType
        bad =
            (key.resultType :: key.argTypes)
                |> List.filter containsCNumber
    in
    case bad of
        [] ->
            ()

        _ ->
            crash
                ("KernelInstanceKey for "
                    ++ key.home
                    ++ "."
                    ++ key.name
                    ++ " contains MVar _ CNumber after monomorphization (MONO_002 violation)"
                )


{-| Predicate: does this MonoType contain any `MVar _ CNumber` in any
reachable position?
-}
containsCNumber : Mono.MonoType -> Bool
containsCNumber monoType =
    case monoType of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MVar _ _ ->
            False

        Mono.MList t ->
            containsCNumber t

        Mono.MTuple ts ->
            List.any containsCNumber ts

        Mono.MRecord fields ->
            Dict.foldl (\_ t acc -> acc || containsCNumber t) False fields

        Mono.MCustom _ _ args ->
            List.any containsCNumber args

        Mono.MFunction args result ->
            List.any containsCNumber args || containsCNumber result

        _ ->
            False


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
