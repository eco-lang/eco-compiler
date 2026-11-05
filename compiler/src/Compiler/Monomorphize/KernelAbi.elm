module Compiler.Monomorphize.KernelAbi exposing
    ( KernelAbiMode(..), deriveKernelAbiMode
    , canTypeToMonoType_preserveVars, remapEcoVarsFresh
    , freeVarIds
    , sameTopLevelAbi
    )

{-| A kernel function is implemented in C++, not in Elm, so the types it is
called with cannot shape its machine-level signature the way they shape a
specialized Elm function's. This module supplies what decides, for each
reference to a kernel, which of its type variables are kept boxed.

The _kernel ABI_ is the MonoType a kernel reference carries; it decides which
arguments and results cross the call boundary boxed. A type variable kept as
`MVar _ CEcoValue` is always boxed, whatever type the call site supplies.

The rule rests on one distinction. A kernel whose canonical type has no type
variable (e.g. `Basics.modBy : Int -> Int -> Int`) has one signature, and its
ABI is simply its type after call-site substitution. A kernel with a type
variable (e.g. `List.cons : a -> List a -> List a`), or any kernel of a module
in `Compiler.IR.Kernel.Abi.alwaysPolymorphicModules`, has one boxed root implementation shared by every
instantiation, so its ABI turns each type variable into `MVar _ CEcoValue`.
`deriveKernelAbiMode` makes that choice and `canTypeToMonoType_preserveVars`
builds the boxed ABI.

The exception is _suffix selection_: a few kernels also have C++ variants
specialized to `Int`, `Float` or `Char`, named with an `_Int`, `_Float` or
`_Char` suffix. `Compiler.IR.Kernel.Abi.suffixSelectingKernels` lists the kernels for which a caller
may keep the concrete call-site type, so that the variant can be picked. How
the mode and the set combine is decided by the callers
(`Compiler.Monomorphize.Subst.Specialize.deriveKernelAbiType` and the kernel ABI
derivation in `Compiler.Monomorphize.Solver.Translate`), not here.

The rest of the module is support: finding the free type variables of a
canonical type, and renumbering the boxed variables of an ABI. The tables of
kernels, and the test for a type variable, are in `Compiler.IR.Kernel.Abi`, so
that the passes before monomorphization can use them.

This module is backend-neutral: it speaks only of `MonoType`. Choosing the C
symbol and the MLIR types of a kernel instantiation is the job of
`Compiler.GenerateMlir.KernelAbi`.


# ABI Mode Selection

@docs KernelAbiMode, deriveKernelAbiMode


# Type Converters

@docs canTypeToMonoType_preserveVars, remapEcoVarsFresh


# ABI Shape

@docs sameTopLevelAbi


# Free Type Variables

@docs freeVarIds

-}

import Compiler.Core.Id as Id
import Compiler.Core.Name exposing (Name)
import Compiler.Core.TypeIds exposing (MVarId)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Kernel.Abi as Abi
import Compiler.IR.Mono as Mono
import Compiler.Monomorphize.State exposing (MVarEnv)
import Data.Set as EverySet
import Dict
import Maybe.Extra as Maybe
import Set exposing (Set)



-- ============================================================================
-- ABI MODE
-- ============================================================================


{-| How a kernel's ABI is derived from its type.

`UseSubstitution` is for a kernel whose type has no type variable: its ABI is
its type with the call-site substitution applied.

`PreserveVars` is for a polymorphic kernel: each type variable becomes
`MVar _ CEcoValue`, so it is boxed whatever the call site supplies, unless the
caller applies the suffix-selection exception described in the module
docstring.

-}
type KernelAbiMode
    = UseSubstitution
    | PreserveVars


{-| Returns the ABI mode for the kernel `( home, name )` with canonical type
`canFuncType`: `PreserveVars` when `home` is in `Compiler.IR.Kernel.Abi.alwaysPolymorphicModules` or
the type has any free type variable, and `UseSubstitution` otherwise. The
kernel's name is not consulted.
-}
deriveKernelAbiMode : ( String, String ) -> Can.Type MVarId -> KernelAbiMode
deriveKernelAbiMode ( home, _ ) canFuncType =
    if EverySet.member List.singleton home Abi.alwaysPolymorphicModules then
        PreserveVars

    else if not (Abi.hasAnyFreeVar canFuncType) then
        UseSubstitution

    else
        PreserveVars



-- ============================================================================
-- ABI SHAPE
-- ============================================================================


{-| Returns whether two kernel types cross the call boundary alike: the same
number of arguments over all stages, and each argument and the final result
an `Int`, `Float` or `Char` in both or in neither, `number` variables counting
as `Int`. Types inside an argument or result are not compared.

A kernel in `Compiler.IR.Kernel.Abi.boxedAbiKernels` keeps a concrete type
only when it has the same top-level ABI as the boxed one.
-}
sameTopLevelAbi : Mono.MonoType -> Mono.MonoType -> Bool
sameTopLevelAbi a b =
    let
        ( argsA, resultA ) =
            Mono.decomposeFunctionType a

        ( argsB, resultB ) =
            Mono.decomposeFunctionType b
    in
    List.length argsA
        == List.length argsB
        && List.all identity (List.map2 samePrimitiveSlot (resultA :: argsA) (resultB :: argsB))


{-| Returns whether two top-level kernel slots cross as the same primitive.
-}
samePrimitiveSlot : Mono.MonoType -> Mono.MonoType -> Bool
samePrimitiveSlot x y =
    primitiveSlot x == primitiveSlot y


{-| The primitive a top-level kernel slot of type `t` crosses as: 1 for `Int`
or a `number` variable, 2 for `Float`, 3 for `Char`, 0 for anything else.
-}
primitiveSlot : Mono.MonoType -> Int
primitiveSlot t =
    case t of
        Mono.MInt ->
            1

        Mono.MVar _ Mono.CNumber ->
            1

        Mono.MFloat ->
            2

        Mono.MChar ->
            3

        _ ->
            0



-- ============================================================================
-- FREE TYPE VARIABLES
-- ============================================================================


{-| Adds the type variables of `canType` that are not in `acc` to the front of
`acc`, each once, the one met last in a left-to-right walk of the type first.
-}
freeVarIds : Can.Type MVarId -> List MVarId -> List MVarId
freeVarIds canType acc =
    let
        seen =
            List.foldl (\id s -> Set.insert (Id.toComparable id) s) Set.empty acc
    in
    Tuple.first (freeVarIdsHelp canType ( acc, seen ))


{-| Walks `canType` left to right, adding each type variable whose id is not in
the set to the front of the list and to the set.
-}
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

        Can.TLambda _ from to ->
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
            List.foldl (\t accPair -> freeVarIdsHelp t accPair) pair (a :: b :: Maybe.toList rest)

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
-- TYPE CONVERTERS
-- ============================================================================


{-| Converts a canonical type to the boxed kernel ABI used under
`PreserveVars`: every type variable becomes `MVar id CEcoValue` with its own id.

A record's extension variable is dropped, aliases are replaced by their bodies,
and each arrow becomes a one-argument function. `Int`, `Float`, `Bool`, `Char`,
`String` and `List` from `elm/core` become their primitive MonoTypes. The
environment is passed through unchanged.

-}
canTypeToMonoType_preserveVars : MVarEnv -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )
canTypeToMonoType_preserveVars env canType =
    case canType of
        Can.TVar mvarId ->
            ( Mono.MVar mvarId Mono.CEcoValue, env )

        Can.TLambda _ from to ->
            let
                ( fromMono, env1 ) =
                    canTypeToMonoType_preserveVars env from

                ( toMono, env2 ) =
                    canTypeToMonoType_preserveVars env1 to
            in
            ( Mono.mFunction Mono.topAbi [ fromMono ] toMono, env2 )

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
            ( Mono.mRecord monoFields, env1 )

        Can.TTuple a b rest ->
            let
                ( monoTypes, env1 ) =
                    Mono.tupleMapAccum
                        (\t e -> canTypeToMonoType_preserveVars e t)
                        env
                        (Mono.tupleOf a b rest)
            in
            ( Mono.mTuple monoTypes, env1 )

        Can.TUnit ->
            ( Mono.MUnit, env )

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoType_preserveVars env inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            canTypeToMonoType_preserveVars env inner


{-| Converts the type constructor `name` from module `canonical`, applied to
`args`, converting each argument with `convert` and threading the environment
through. The `elm/core` primitives map as `canTypeToMonoType_preserveVars`
describes; any other type becomes a custom type.
-}
convertTType : (MVarEnv -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )) -> MVarEnv -> ModuleName.Canonical -> Name -> List (Can.Type MVarId) -> ( Mono.MonoType, MVarEnv )
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
                ModuleName.Canonical ( "elm", "core" ) _ ->
                    True

                _ ->
                    False
    in
    if isElmCore then
        case ( name, monoArgs ) of
            ( "Int", _ ) ->
                ( Mono.MInt, env1 )

            ( "Float", _ ) ->
                ( Mono.MFloat, env1 )

            ( "Bool", _ ) ->
                ( Mono.MBool, env1 )

            ( "Char", _ ) ->
                ( Mono.MChar, env1 )

            ( "String", _ ) ->
                ( Mono.MString, env1 )

            ( "List", [ inner ] ) ->
                ( Mono.mList inner, env1 )

            _ ->
                ( Mono.mCustom canonical name monoArgs, env1 )

    else
        ( Mono.mCustom canonical name monoArgs, env1 )


{-| Replaces every `MVar _ CEcoValue` in a kernel ABI with a fresh id (one per
distinct source id, sharing preserved), starting at `nextId0`, and returns the
next unused id.

The variables of a preserved-vars kernel ABI are layout placeholders (always
boxed). Kept at their source ids they can be unified with a number variable
by the program's own unification, and `Compiler.Monomorphize.Prune` would then
close them to `MInt`; fresh ids make them immune, e.g. for `Debug` kernels.

Every `MVar _ CEcoValue` anywhere in the type is renamed; `CNumber` variables
are left unchanged.

-}
remapEcoVarsFresh : MVarId -> Mono.MonoType -> ( Mono.MonoType, MVarId )
remapEcoVarsFresh nextId0 abiType =
    let
        go t ( mapping, nextId ) =
            case t of
                Mono.MVar mid Mono.CEcoValue ->
                    case Dict.get (Id.toComparable mid) mapping of
                        Just fresh ->
                            ( Mono.MVar fresh Mono.CEcoValue, ( mapping, nextId ) )

                        Nothing ->
                            ( Mono.MVar nextId Mono.CEcoValue
                            , ( Dict.insert (Id.toComparable mid) nextId mapping, Id.succ nextId )
                            )

                Mono.MVar _ _ ->
                    ( t, ( mapping, nextId ) )

                Mono.MFunction _ anno args r ->
                    let
                        ( args1, acc1 ) =
                            List.foldr
                                (\a ( accL, accS ) ->
                                    let
                                        ( a1, accS1 ) =
                                            go a accS
                                    in
                                    ( a1 :: accL, accS1 )
                                )
                                ( [], ( mapping, nextId ) )
                                args

                        ( r1, acc2 ) =
                            go r acc1
                    in
                    ( Mono.mFunction anno args1 r1, acc2 )

                Mono.MList _ e ->
                    let
                        ( e1, acc1 ) =
                            go e ( mapping, nextId )
                    in
                    ( Mono.mList e1, acc1 )

                Mono.MTuple _ es ->
                    let
                        ( es1, acc1 ) =
                            Mono.tupleMapAccumR go ( mapping, nextId ) es
                    in
                    ( Mono.mTuple es1, acc1 )

                Mono.MCustom _ h n args ->
                    let
                        ( args1, acc1 ) =
                            List.foldr
                                (\a ( accL, accS ) ->
                                    let
                                        ( a1, accS1 ) =
                                            go a accS
                                    in
                                    ( a1 :: accL, accS1 )
                                )
                                ( [], ( mapping, nextId ) )
                                args
                    in
                    ( Mono.mCustom h n args1, acc1 )

                Mono.MRecord _ fields ->
                    let
                        ( fields1, acc1 ) =
                            Dict.foldr
                                (\k v ( accD, accS ) ->
                                    let
                                        ( v1, accS1 ) =
                                            go v accS
                                    in
                                    ( Dict.insert k v1 accD, accS1 )
                                )
                                ( Dict.empty, ( mapping, nextId ) )
                                fields
                    in
                    ( Mono.mRecord fields1, acc1 )

                _ ->
                    ( t, ( mapping, nextId ) )

        ( result, ( _, finalNext ) ) =
            go abiType ( Dict.empty, nextId0 )
    in
    ( result, finalNext )
