module Compiler.Monomorphize.KernelAbi exposing
    ( KernelAbiMode(..), deriveKernelAbiMode
    , canTypeToMonoType_preserveVars, canTypeToMonoType_numberBoxed
    , containerSpecializedKernels, comparePair
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

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name exposing (Name)
import Data.Map as Dict
import Data.Set as EverySet exposing (EverySet)
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
  - `canFuncType`: Canonical function type from `TOpt.VarKernel`

Returns the appropriate `KernelAbiMode`.

-}
deriveKernelAbiMode : ( String, String ) -> Can.Type -> KernelAbiMode
deriveKernelAbiMode ( home, name ) canFuncType =
    -- Debug kernels are always polymorphic
    if EverySet.member List.singleton home alwaysPolymorphicModules then
        PreserveVars

    else
        let
            vars =
                freeTypeVariablesWithConstraints canFuncType

            hasNumberVars =
                List.any (\( _, c ) -> c == Mono.CNumber) vars
        in
        if List.isEmpty vars then
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
-- TYPE VARIABLE EXTRACTION
-- ============================================================================


{-| Extract free type variables with their constraints from a canonical type.
-}
freeTypeVariablesWithConstraints : Can.Type -> List ( Name, Mono.Constraint )
freeTypeVariablesWithConstraints canType =
    freeVarsHelper canType []
        |> List.map (\name -> ( name, constraintFromName name ))


freeVarsHelper : Can.Type -> List Name -> List Name
freeVarsHelper canType acc =
    case canType of
        Can.TVar name ->
            if List.member name acc then
                acc

            else
                name :: acc

        Can.TLambda from to ->
            freeVarsHelper to (freeVarsHelper from acc)

        Can.TType _ _ args ->
            List.foldl freeVarsHelper acc args

        Can.TRecord fields _ ->
            Dict.foldl compare (\_ (Can.FieldType _ t) a -> freeVarsHelper t a) acc fields

        Can.TTuple a b rest ->
            List.foldl freeVarsHelper acc (a :: b :: rest)

        Can.TUnit ->
            acc

        Can.TAlias _ _ _ (Can.Filled inner) ->
            freeVarsHelper inner acc

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                argVars =
                    List.foldl (\( _, t ) a -> freeVarsHelper t a) acc args
            in
            freeVarsHelper inner argVars


{-| Determine constraint from type variable name.
-}
constraintFromName : Name -> Mono.Constraint
constraintFromName name =
    if Name.isNumberType name then
        Mono.CNumber

    else
        Mono.CEcoValue



-- ============================================================================
-- TYPE CONVERTERS
-- ============================================================================


{-| Convert canonical type to MonoType, preserving all type variables as CEcoValue.

Used for polymorphic kernels where the ABI must be all-boxed.

-}
canTypeToMonoType_preserveVars : Can.Type -> Mono.MonoType
canTypeToMonoType_preserveVars canType =
    case canType of
        Can.TVar name ->
            Mono.MVar name Mono.CEcoValue

        Can.TLambda from to ->
            Mono.MFunction
                [ canTypeToMonoType_preserveVars from ]
                (canTypeToMonoType_preserveVars to)

        Can.TType canonical name args ->
            convertTType canTypeToMonoType_preserveVars canonical name args

        Can.TRecord fields _ ->
            let
                monoFields =
                    Dict.map (\_ (Can.FieldType _ t) -> canTypeToMonoType_preserveVars t) fields
            in
            Mono.MRecord monoFields

        Can.TTuple a b rest ->
            let
                monoTypes =
                    List.map canTypeToMonoType_preserveVars (a :: b :: rest)
            in
            Mono.MTuple monoTypes

        Can.TUnit ->
            Mono.MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoType_preserveVars inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            canTypeToMonoType_preserveVars inner


{-| Convert canonical type to MonoType, treating CNumber vars as CEcoValue.

Used for number-boxed kernels (add, sub, mul, pow) where the C ABI is boxed
but the result type should still resolve to MInt or MFloat.

-}
canTypeToMonoType_numberBoxed : Can.Type -> Mono.MonoType
canTypeToMonoType_numberBoxed canType =
    case canType of
        Can.TVar name ->
            -- Treat ALL vars as CEcoValue for ABI purposes
            Mono.MVar name Mono.CEcoValue

        Can.TLambda from to ->
            Mono.MFunction
                [ canTypeToMonoType_numberBoxed from ]
                (canTypeToMonoType_numberBoxed to)

        Can.TType canonical name args ->
            convertTType canTypeToMonoType_numberBoxed canonical name args

        Can.TRecord fields _ ->
            let
                monoFields =
                    Dict.map (\_ (Can.FieldType _ t) -> canTypeToMonoType_numberBoxed t) fields
            in
            Mono.MRecord monoFields

        Can.TTuple a b rest ->
            let
                monoTypes =
                    List.map canTypeToMonoType_numberBoxed (a :: b :: rest)
            in
            Mono.MTuple monoTypes

        Can.TUnit ->
            Mono.MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoType_numberBoxed inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            canTypeToMonoType_numberBoxed inner


{-| Helper for converting TType nodes with shared logic.
-}
convertTType : (Can.Type -> Mono.MonoType) -> IO.Canonical -> Name -> List Can.Type -> Mono.MonoType
convertTType convert canonical name args =
    let
        monoArgs =
            List.map convert args

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
                Mono.MInt

            "Float" ->
                Mono.MFloat

            "Bool" ->
                Mono.MBool

            "Char" ->
                Mono.MChar

            "String" ->
                Mono.MString

            "List" ->
                case monoArgs of
                    [ inner ] ->
                        Mono.MList inner

                    _ ->
                        Mono.MList Mono.MUnit

            _ ->
                Mono.MCustom canonical name monoArgs

    else
        Mono.MCustom canonical name monoArgs
