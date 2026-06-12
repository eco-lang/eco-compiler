module Compiler.Monomorphize.KernelAbi exposing
    ( KernelAbiMode(..), deriveKernelAbiMode
    , canTypeToMonoType_preserveVars
    , suffixSelectingKernels, comparePair
    , freeVarIds
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

This module is backend-neutral: it decides which type variables stay boxed,
expressed purely in terms of `MonoType`. The MLIR-specific lowering of a
kernel instantiation to a C symbol and `MlirType` ABI lives in
`Compiler.Generate.MLIR.KernelAbi`.


# ABI Mode Selection

@docs KernelAbiMode, deriveKernelAbiMode


# Type Converters

@docs canTypeToMonoType_preserveVars


# Suffix-Selecting Kernels

@docs suffixSelectingKernels, comparePair


# Free Variable Extraction (for AssignMVarIds, operates on Can.Type Name)


# Free Variable Ids

@docs freeVarIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.State exposing (MVarEnv)
import Data.Set as EverySet exposing (EverySet)
import Dict
import Set exposing (Set)
import System.TypeCheck.IO as IO



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
