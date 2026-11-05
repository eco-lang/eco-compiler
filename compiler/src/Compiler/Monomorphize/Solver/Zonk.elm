module Compiler.Monomorphize.Solver.Zonk exposing (canTypeToMono, canTypeToMonoI, canTypeToMonoWithI)

{-| Some types reach the solver engine already closed, needing no demand from
the union-find store, and this module turns those into monomorphized types
without consulting the store.

The input is a canonical type whose variables are MVarIds, and the output is a
`Mono.MonoType`. The conversion is a structural walk:

  - An elm/core type named `Int`, `Float`, `Bool`, `Char` or `String` becomes
    the matching primitive. The test is the package and the type name; the
    module is not looked at. An elm/core `List` becomes a list type, and one
    with other than one argument becomes a list of unit. Every other named type
    becomes a custom type of its converted arguments.
  - A chain of arrows becomes nested one-argument function types, each carrying
    the lambda-set annotation `Mono.topDeclZonk`, which says nothing is known
    about which lambdas the function may be.
  - A type variable is replaced by its binding in a substitution if it has one.
    Otherwise it stays a _residual_, an `MVar ... CEcoValue` left in the result.
    Every caller passes either a type with no unbound number variable (a ground
    type, or a union field type whose parameters the substitution binds) or a
    seed annotation, whose only unbound variable is a `Program`'s open `msg`.
  - A `Filled` alias is replaced by its body. A `Holey` alias binds each of its
    parameter ids to the converted argument before converting its body.
  - A record's extension variable contributes the fields of the record it is
    bound to in the substitution; bound to anything else, or unbound, it is
    dropped and the record is closed.

The substitution is keyed by `Id.toComparable` of an MVarId. It is empty
except where a caller of `canTypeToMonoWithI` supplies one or a `Holey` alias
extends it.

The forms ending in `I` thread an `Intern` table, so each composite is
hash-consed as it is built; `canTypeToMono` uses `Intern.disabled`. What a
table shares, and why sharing never affects correctness, is stated in
`Compiler.IR.Mono.Intern`.

-}

import Compiler.Core.Id as Id
import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Intern as Intern exposing (Intern)
import Dict exposing (Dict)
import Maybe.Extra as Maybe


{-| Converts a canonical type to a monomorphized type with an empty
substitution and no intern table.
-}
canTypeToMono : Can.Type TypeIds.MVarId -> Mono.MonoType
canTypeToMono canType =
    Tuple.first (canTypeToMonoWithI Dict.empty canType Intern.disabled)


{-| Converts a canonical type to a monomorphized type with an empty
substitution, hash-consing each composite in the given table.
-}
canTypeToMonoI : Can.Type TypeIds.MVarId -> Intern -> ( Mono.MonoType, Intern )
canTypeToMonoI canType intern =
    canTypeToMonoWithI Dict.empty canType intern


{-| Converts a canonical type to a monomorphized type, replacing each type
variable bound in `subst` by its binding and hash-consing each composite in the
given table.

A binding is used as it stands; it is not converted again. A field written in
the record type replaces a field of the same name taken from the extension
variable's binding.

-}
canTypeToMonoWithI : Dict Int Mono.MonoType -> Can.Type TypeIds.MVarId -> Intern -> ( Mono.MonoType, Intern )
canTypeToMonoWithI subst canType intern0 =
    case canType of
        Can.TVar mvarId ->
            case Dict.get (Id.toComparable mvarId) subst of
                Just monoType ->
                    ( monoType, intern0 )

                Nothing ->
                    ( Mono.MVar mvarId Mono.CEcoValue, intern0 )

        Can.TLambda _ from to ->
            lambdaChain subst [ from ] to intern0

        Can.TType canonical name args ->
            let
                ( monoArgs, intern1 ) =
                    listToMono subst args intern0

                isElmCore =
                    case canonical of
                        ModuleName.Canonical ( "elm", "core" ) _ ->
                            True

                        _ ->
                            False
            in
            if isElmCore then
                case name of
                    "Int" ->
                        ( Mono.MInt, intern1 )

                    "Float" ->
                        ( Mono.MFloat, intern1 )

                    "Bool" ->
                        ( Mono.MBool, intern1 )

                    "Char" ->
                        ( Mono.MChar, intern1 )

                    "String" ->
                        ( Mono.MString, intern1 )

                    "List" ->
                        case monoArgs of
                            [ inner ] ->
                                Intern.hashCons (Mono.mList inner) intern1

                            _ ->
                                Intern.hashCons (Mono.mList Mono.MUnit) intern1

                    _ ->
                        Intern.hashCons (Mono.mCustom canonical name monoArgs) intern1

            else
                Intern.hashCons (Mono.mCustom canonical name monoArgs) intern1

        Can.TRecord fields maybeExtension ->
            let
                baseFields =
                    case maybeExtension of
                        Just extMvarId ->
                            case Dict.get (Id.toComparable extMvarId) subst of
                                Just (Mono.MRecord _ baseFieldsDict) ->
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                ( monoFields, intern1 ) =
                    Dict.foldl
                        (\k (Can.FieldType _ t) ( acc, i0 ) ->
                            let
                                ( mt, i1 ) =
                                    canTypeToMonoWithI subst t i0
                            in
                            ( Dict.insert k mt acc, i1 )
                        )
                        ( baseFields, intern0 )
                        fields
            in
            Intern.hashCons (Mono.mRecord monoFields) intern1

        Can.TTuple a b rest ->
            let
                ( monoElems, intern1 ) =
                    Mono.tupleMapAccum (canTypeToMonoWithI subst) intern0 (Mono.tupleOf a b rest)
            in
            Intern.hashCons (Mono.mTuple monoElems) intern1

        Can.TUnit ->
            ( Mono.MUnit, intern0 )

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoWithI subst inner intern0

        Can.TAlias _ _ args (Can.Holey inner) ->
            let
                ( newSubst, intern1 ) =
                    List.foldl
                        (\( paramId, t ) ( acc, i0 ) ->
                            let
                                ( mt, i1 ) =
                                    canTypeToMonoWithI subst t i0
                            in
                            ( Dict.insert (Id.toComparable paramId) mt acc, i1 )
                        )
                        ( subst, intern0 )
                        args
            in
            canTypeToMonoWithI newSubst inner intern1


{-| Converts each type in a list, in order, threading the intern table from
left to right.
-}
listToMono : Dict Int Mono.MonoType -> List (Can.Type TypeIds.MVarId) -> Intern -> ( List Mono.MonoType, Intern )
listToMono subst types intern0 =
    case types of
        [] ->
            ( [], intern0 )

        t :: rest ->
            let
                ( mt, intern1 ) =
                    canTypeToMonoWithI subst t intern0

                ( mRest, intern2 ) =
                    listToMono subst rest intern1
            in
            ( mt :: mRest, intern2 )


{-| Returns the function type for a chain of arrows whose argument types so far
are `argsAcc`, newest first, and whose remainder is `to`.

The result is nested one-argument functions, so `a -> b -> c` becomes a
function from `a` to a function from `b` to `c`, each arrow annotated
`Mono.topDeclZonk`. The result type is converted first, then the arguments
from last to first.

-}
lambdaChain : Dict Int Mono.MonoType -> List (Can.Type TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Intern -> ( Mono.MonoType, Intern )
lambdaChain subst argsAcc to intern0 =
    case to of
        Can.TLambda _ from innerTo ->
            lambdaChain subst (from :: argsAcc) innerTo intern0

        _ ->
            let
                ( resultType, intern1 ) =
                    canTypeToMonoWithI subst to intern0
            in
            List.foldl
                (\argType ( acc, i0 ) ->
                    let
                        ( mArg, i1 ) =
                            canTypeToMonoWithI subst argType i0
                    in
                    Intern.hashCons (Mono.mFunction Mono.topDeclZonk [ mArg ] acc) i1
                )
                ( resultType, intern1 )
                argsAcc
