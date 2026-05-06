module Compiler.Monomorphize.KernelAbi exposing
    ( KernelAbiMode(..), deriveKernelAbiMode
    , canTypeToMonoType_preserveVars, canTypeToMonoType_numberBoxed
    , concreteTypeAwareKernels, comparePair
    , freeVarIds
    , KernelBackendAbiPolicy(..), kernelBackendAbiPolicy
    , KernelInstanceKey, KernelInstanceAbi
    , deriveKernelInstanceAbi, kernelInstanceSymbol
    )

{-| Kernel ABI type derivation for monomorphization.

This module implements the algorithm that determines the MonoType used for
kernel function ABIs. The key insight is that polymorphic kernels must use
a consistent ABI (all `eco.value`) regardless of call-site type instantiation.

Three cases:

1.  **Monomorphic kernels** (e.g., `Basics.modBy : Int -> Int -> Int`):
    ABI matches the concrete types. Use call-site substitution.

2.  **Polymorphic kernels** (e.g., `List.cons : a -> List a -> List a`):
    Type variables become `MVar _ CEcoValue`, always boxed.

3.  **Number-boxed kernels** (e.g., `Basics.add : number -> number -> number`):
    `CNumber` variables treated as `CEcoValue` for ABI purposes.


# ABI Mode Selection

@docs KernelAbiMode, deriveKernelAbiMode


# Type Converters

@docs canTypeToMonoType_preserveVars, canTypeToMonoType_numberBoxed


# Concrete-Type-Aware Kernels

@docs concreteTypeAwareKernels, comparePair


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
import Compiler.Monomorphize.State as State exposing (MVarEnv)
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
  - `NumberBoxed`: Number-boxed kernel - treat `CNumber` vars as `CEcoValue`

-}
type KernelAbiMode
    = UseSubstitution
    | PreserveVars
    | NumberBoxed


{-| Determine which ABI mode to use for a kernel function.

Arguments:

  - `(home, name)`: Kernel identifier (e.g., `("List", "cons")`)
  - `canFuncType`: Canonical function type (Can.Type MVarId)
  - `mvarEnv`: MVarEnv for constraint lookups

Returns the appropriate `KernelAbiMode`.

-}
deriveKernelAbiMode : ( String, String ) -> Can.Type MVarId -> MVarEnv -> KernelAbiMode
deriveKernelAbiMode ( home, name ) canFuncType mvarEnv =
    -- Debug kernels are always polymorphic
    if EverySet.member List.singleton home alwaysPolymorphicModules then
        PreserveVars

    else
        let
            varIds =
                freeVarIds canFuncType []

            hasNumberVars =
                List.any
                    (\mvarId ->
                        State.isNumberVar mvarId mvarEnv
                    )
                    varIds
        in
        if List.isEmpty varIds then
            -- Case A: Monomorphic kernel - use substitution
            UseSubstitution

        else if hasNumberVars && EverySet.member comparePair ( home, name ) numberBoxedKernels then
            -- Case C: Number-boxed kernel
            NumberBoxed

        else
            -- Case B: Polymorphic kernel
            PreserveVars



-- ============================================================================
-- CONSTANTS
-- ============================================================================


{-| Kernels whose C ABI must box numeric type variables as eco.value.

These are number-polymorphic kernels that go through the boxed C ABI
rather than intrinsic unboxed operations. The intrinsic path in MLIR.elm
handles the fast unboxed Int/Float cases; this ABI is the fallback.

-}
numberBoxedKernels : EverySet (List String) ( String, String )
numberBoxedKernels =
    EverySet.fromList comparePair
        [ ( "Basics", "add" )
        , ( "Basics", "sub" )
        , ( "Basics", "mul" )
        , ( "Basics", "pow" )
        , ( "String", "fromNumber" )
        ]


{-| Kernels whose call-site `MonoType` should retain its *concrete*
monomorphic shape when fully resolved, rather than being erased to
`CEcoValue`-typed type variables by `canTypeToMonoType_preserveVars`.

Two distinct downstream consumers benefit:

  - **Element-aware container kernels** (e.g. `List.cons`): the concrete
    MonoType drives Elm-level wrapper generation — different
    `List_cons_$_N` closures per element type — even though the underlying
    C++ kernel ABI is still all-boxed.

  - **Primitive-specialized kernels** (e.g. `Utils.compare`, Phase B of the
    per-instance kernel ABI rollout): the concrete MonoType lets
    `deriveKernelInstanceAbi` pattern-match on `[MInt, MInt]` /
    `[MFloat, MFloat]` / `[MChar, MChar]` and select the `_Int` / `_Float` /
    `_Char` C++ symbol variants.

For polymorphic call sites (e.g. `compare "a" "b"` reaching `Utils.compare`
with `[MString, MString]`), the kernel ABI falls back to the all-boxed
`KernelBackendAbiPolicy.AllBoxed` path via the policy table.

-}
concreteTypeAwareKernels : EverySet (List String) ( String, String )
concreteTypeAwareKernels =
    EverySet.fromList comparePair
        [ ( "List", "cons" )
        , ( "Utils", "compare" )
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


{-| Convert canonical type to MonoType, treating CNumber vars as CEcoValue.

Used for number-boxed kernels (add, sub, mul, pow) where the C ABI is boxed
but the result type should still resolve to MInt or MFloat.

-}
canTypeToMonoType_numberBoxed : MVarEnv -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
canTypeToMonoType_numberBoxed env canType =
    case canType of
        Can.TVar mvarId ->
            -- Treat ALL vars as CEcoValue for ABI purposes
            ( Mono.MVar mvarId Mono.CEcoValue, env )

        Can.TLambda from to ->
            let
                ( fromMono, env1 ) =
                    canTypeToMonoType_numberBoxed env from

                ( toMono, env2 ) =
                    canTypeToMonoType_numberBoxed env1 to
            in
            ( Mono.MFunction [ fromMono ] toMono, env2 )

        Can.TType canonical name args ->
            convertTType canTypeToMonoType_numberBoxed env canonical name args

        Can.TRecord fields _ ->
            let
                ( monoFields, env1 ) =
                    Dict.foldl
                        (\k (Can.FieldType _ t) ( acc, e ) ->
                            let
                                ( monoT, e1 ) =
                                    canTypeToMonoType_numberBoxed e t
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
                                    canTypeToMonoType_numberBoxed e t
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
            canTypeToMonoType_numberBoxed env inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            canTypeToMonoType_numberBoxed env inner


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
kernelBackendAbiPolicy home name =
    case ( home, name ) of
        --
        -- AllBoxed: C++ ABI is uniformly uint64_t for all params and return.
        -- Audited against elm-kernel-cpp/src/KernelExports.h.
        --
        -- List: cons, fromArray, toArray, map2..map5, sortBy, sortWith
        ( "List", _ ) ->
            AllBoxed

        -- Utils: equal, notEqual, lt, le, gt, ge, append.
        -- Phase B (per-instance kernel ABI rollout): Utils.compare is now
        -- governed by deriveKernelInstanceAbi (which selects _Int / _Float /
        -- _Char monomorphic variants for primitive comparables, falling back
        -- to the boxed root for String/List/Tuple). The other Utils kernels
        -- still use the all-boxed C++ ABI; they migrate in Phase C.
        ( "Utils", "equal" ) ->
            AllBoxed

        ( "Utils", "notEqual" ) ->
            AllBoxed

        ( "Utils", "lt" ) ->
            AllBoxed

        ( "Utils", "le" ) ->
            AllBoxed

        ( "Utils", "gt" ) ->
            AllBoxed

        ( "Utils", "ge" ) ->
            AllBoxed

        ( "Utils", "append" ) ->
            AllBoxed

        -- String.fromNumber: number-polymorphic, C++ takes boxed uint64_t
        ( "String", "fromNumber" ) ->
            AllBoxed

        -- JsArray: C++ ABI now uniformly uint64_t for all params and return.
        -- Integer arguments (index, length, etc.) are boxed Elm Int HPointers
        -- and unboxed inside the C++ implementations.
        ( "JsArray", _ ) ->
            AllBoxed

        -- Json.wrap: polymorphic (a -> Value), C++ inspects heap tag at runtime.
        ( "Json", "wrap" ) ->
            AllBoxed

        -- Basics.add/sub/mul/pow: number-boxed polymorphic kernels.
        -- C++ inspects the HPointer tag to dispatch Int vs Float at runtime.
        ( "Basics", "add" ) ->
            AllBoxed

        ( "Basics", "sub" ) ->
            AllBoxed

        ( "Basics", "mul" ) ->
            AllBoxed

        ( "Basics", "pow" ) ->
            AllBoxed

        _ ->
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
