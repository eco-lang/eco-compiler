module Compiler.Monomorphize.KernelAbi exposing
    ( KernelAbiMode(..), deriveKernelAbiMode
    , canTypeToMonoType_preserveVars, canTypeToMonoType_numberBoxed
    , containerSpecializedKernels, comparePair
    , freeTypeVariablesWithConstraints, constraintFromName
    , freeVarIds
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


# Container Specialized Kernels

@docs containerSpecializedKernels, comparePair


# Free Variable Extraction (for AssignMVarIds, operates on Can.Type Name)

@docs freeTypeVariablesWithConstraints, constraintFromName

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds exposing (MVarId)
import Compiler.Data.Id as Id
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Monomorphize.State as State exposing (MVarEnv)
import Set exposing (Set)
import Data.Set as EverySet exposing (EverySet)
import Dict
import System.TypeCheck.IO as IO



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


{-| Kernels that benefit from element-aware specialization at fully monomorphic
call sites. The specialized MonoType drives Elm-level wrapper generation
(different List\_cons\_$\_N closures per element type), NOT the C++ kernel ABI.

The actual C++ kernel ABI is determined by kernelBackendAbiPolicy in
MLIR codegen (Context.elm), which may force all-boxed !eco.value arguments
regardless of the wrapper's specialized types.

-}
containerSpecializedKernels : EverySet (List String) ( String, String )
containerSpecializedKernels =
    EverySet.fromList comparePair
        [ ( "List", "cons" )
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


{-| Extract free type variables with their constraints from a canonical type.
This operates on Can.Type Name and is used during AssignMVarIds
(before the rewrite to MVarId).
-}
freeTypeVariablesWithConstraints : Can.Type Name -> List ( Name, Mono.Constraint )
freeTypeVariablesWithConstraints canType =
    freeVarsHelper canType []
        |> List.map (\name -> ( name, constraintFromName name ))


freeVarsHelper : Can.Type Name -> List Name -> List Name
freeVarsHelper canType acc =
    let
        seen =
            Set.fromList acc
    in
    Tuple.first (freeVarsHelperWith canType ( acc, seen ))


freeVarsHelperWith : Can.Type Name -> ( List Name, Set String ) -> ( List Name, Set String )
freeVarsHelperWith canType (( acc, seen ) as pair) =
    case canType of
        Can.TVar name ->
            if Set.member name seen then
                pair

            else
                ( name :: acc, Set.insert name seen )

        Can.TLambda from to ->
            freeVarsHelperWith to (freeVarsHelperWith from pair)

        Can.TType _ _ args ->
            List.foldl (\a accPair -> freeVarsHelperWith a accPair) pair args

        Can.TRecord fields maybeExt ->
            let
                fieldPair =
                    Dict.foldl (\_ (Can.FieldType _ t) accPair -> freeVarsHelperWith t accPair) pair fields
            in
            case maybeExt of
                Just extName ->
                    let
                        ( fieldAcc, fieldSeen ) =
                            fieldPair
                    in
                    if Set.member extName fieldSeen then
                        fieldPair

                    else
                        ( extName :: fieldAcc, Set.insert extName fieldSeen )

                Nothing ->
                    fieldPair

        Can.TTuple a b rest ->
            List.foldl (\t accPair -> freeVarsHelperWith t accPair) pair (a :: b :: rest)

        Can.TUnit ->
            pair

        Can.TAlias _ _ _ (Can.Filled inner) ->
            freeVarsHelperWith inner pair

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                argPair =
                    List.foldl (\( _, t ) accPair -> freeVarsHelperWith t accPair) pair args
            in
            freeVarsHelperWith inner argPair


{-| Determine constraint from type variable name.
Used during AssignMVarIds (before the rewrite to MVarId).
-}
constraintFromName : Name -> Mono.Constraint
constraintFromName name =
    if Name.isNumberType name then
        Mono.CNumber

    else
        Mono.CEcoValue



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
