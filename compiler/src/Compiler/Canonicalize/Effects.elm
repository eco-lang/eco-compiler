module Compiler.Canonicalize.Effects exposing (canonicalize, checkPayload)

{-| A module's `port` declarations and its `effect module` header follow rules
that ordinary values do not, and this module checks those rules while turning
a module's `Src.Effects` into `Can.Effects`.

A module has no effects, a list of ports, or an effect manager.

A _port_ is a value whose annotation, once every alias is expanded, has one of
two shapes. An outgoing port is `payload -> Cmd msg`, where `msg` is a type
variable. An incoming port is `(payload -> msg) -> Sub msg`, where the
callback's result and the `Sub`'s argument are the same type variable. The
_payload_ is the type of the value the port carries, and only some types may
be one; `checkPayload` decides which.

An _effect manager_ is the module named by an `effect module` header. It must
define `init`, `onEffects` and `onSelfMsg`; `cmdMap` too if it manages commands,
and `subMap` if it manages subscriptions. The header names the type that
represents its commands, its subscriptions, or both, and each named type must
be one of the custom types passed in.

Problems are reported as `Compiler.Reporting.Error.Canonicalize` errors, with
the error-collecting behaviour of the `Compiler.Reporting.Result` combinators.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Type as Type
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Dict exposing (Dict)



-- ====== RESULT ======


{-| A canonicalization computation that fails with `Error.Error`s.
-}
type alias EResult i w a =
    ReportingResult.RResult i w Error.Error a



-- ====== CANONICALIZE ======


{-| Returns the canonical form of `effects`, checking it against the module's
top-level `values` and the custom types in `unions`.

Each port's annotation is canonicalized in `env` and classified as `Incoming`
or `Outgoing`; the ports are returned keyed by name.

For an effect manager, the result carries the regions of the names of the
`init`, `onEffects` and `onSelfMsg` definitions, in that order, and the names
of the effect types, each of which must be a key of `unions`. A missing function is
reported at the region of the effect module header. `cmdMap` and `subMap` are
looked for only after every effect type has been found, so a header naming an
unknown type reports that and not a missing `cmdMap` or `subMap`; for a manager
of both, `subMap` is looked for only once `cmdMap` has been found.

-}
canonicalize :
    Env.Env
    -> List (A.Located Src.Value)
    -> Dict Name.Name union
    -> Src.Effects
    -> EResult i w Can.Effects
canonicalize env values unions effects =
    case effects of
        Src.NoEffects ->
            ReportingResult.ok Can.NoEffects

        Src.Ports ports ->
            ReportingResult.traverse (canonicalizePort env) ports
                |> ReportingResult.map (Can.Ports << Dict.fromList)

        Src.Manager region manager ->
            let
                dict : Dict Name.Name A.Region
                dict =
                    Dict.fromList (List.map toNameRegion values)
            in
            ReportingResult.map Can.Manager (verifyManager region dict "init")
                |> ReportingResult.apply (verifyManager region dict "onEffects")
                |> ReportingResult.apply (verifyManager region dict "onSelfMsg")
                |> ReportingResult.apply
                    (case manager of
                        Src.Cmd ( _, ( _, cmdType ) ) ->
                            ReportingResult.map Can.Cmd (verifyEffectType cmdType unions)
                                |> ReportingResult.andThen
                                    (\result ->
                                        verifyManager region dict "cmdMap"
                                            |> ReportingResult.map (\_ -> result)
                                    )

                        Src.Sub ( _, ( _, subType ) ) ->
                            ReportingResult.map Can.Sub (verifyEffectType subType unions)
                                |> ReportingResult.andThen
                                    (\result ->
                                        verifyManager region dict "subMap"
                                            |> ReportingResult.map (\_ -> result)
                                    )

                        Src.Fx ( _, ( _, cmdType ) ) ( _, ( _, subType ) ) ->
                            ReportingResult.map Can.Fx (verifyEffectType cmdType unions)
                                |> ReportingResult.apply (verifyEffectType subType unions)
                                |> ReportingResult.andThen
                                    (\result ->
                                        verifyManager region dict "cmdMap"
                                            |> ReportingResult.map (\_ -> result)
                                    )
                                |> ReportingResult.andThen
                                    (\result ->
                                        verifyManager region dict "subMap"
                                            |> ReportingResult.map (\_ -> result)
                                    )
                    )



-- ====== CANONICALIZE PORT ======


{-| Returns a port's name and its canonical `Can.Port`, or the error saying why
its annotation is not an allowed port type.

The shape is read from the annotation with every alias expanded, while the
stored `func` is the canonical annotation as written. An outgoing port with no
payload argument, more than one argument, or a `Cmd` argument that is not a
type variable is rejected, as is an incoming port of any shape other than
`(payload -> msg) -> Sub msg` with the same variable `msg` in both places.

-}
canonicalizePort : Env.Env -> Src.Port -> EResult i w ( Name.Name, Can.Port )
canonicalizePort env (Src.Port _ ( _, A.At region portName ) tipe) =
    Type.toAnnotation env tipe
        |> ReportingResult.andThen
            (\(Can.Forall freeVars ctipe) ->
                case List.reverse (Type.delambda (Type.deepDealias ctipe)) of
                    (Can.TType home name [ msg ]) :: revArgs ->
                        if home == ModuleName.cmd && name == Name.cmd then
                            case revArgs of
                                [] ->
                                    ReportingResult.throw (Error.PortTypeInvalid region portName Error.CmdNoArg)

                                [ outgoingType ] ->
                                    case msg of
                                        Can.TVar _ ->
                                            case checkPayload outgoingType of
                                                Ok () ->
                                                    ReportingResult.ok
                                                        ( portName
                                                        , Can.Outgoing
                                                            { freeVars = freeVars
                                                            , payload = outgoingType
                                                            , func = ctipe
                                                            }
                                                        )

                                                Err ( badType, err ) ->
                                                    ReportingResult.throw (Error.PortPayloadInvalid region portName badType err)

                                        _ ->
                                            ReportingResult.throw (Error.PortTypeInvalid region portName Error.CmdBadMsg)

                                _ ->
                                    ReportingResult.throw (Error.PortTypeInvalid region portName (Error.CmdExtraArgs (List.length revArgs)))

                        else if home == ModuleName.sub && name == Name.sub then
                            case revArgs of
                                [ Can.TLambda _ incomingType (Can.TVar msg1) ] ->
                                    case msg of
                                        Can.TVar msg2 ->
                                            if msg1 == msg2 then
                                                case checkPayload incomingType of
                                                    Ok () ->
                                                        ReportingResult.ok
                                                            ( portName
                                                            , Can.Incoming
                                                                { freeVars = freeVars
                                                                , payload = incomingType
                                                                , func = ctipe
                                                                }
                                                            )

                                                    Err ( badType, err ) ->
                                                        ReportingResult.throw (Error.PortPayloadInvalid region portName badType err)

                                            else
                                                ReportingResult.throw (Error.PortTypeInvalid region portName Error.SubBad)

                                        _ ->
                                            ReportingResult.throw (Error.PortTypeInvalid region portName Error.SubBad)

                                _ ->
                                    ReportingResult.throw (Error.PortTypeInvalid region portName Error.SubBad)

                        else
                            ReportingResult.throw (Error.PortTypeInvalid region portName Error.NotCmdOrSub)

                    _ ->
                        ReportingResult.throw (Error.PortTypeInvalid region portName Error.NotCmdOrSub)
            )



-- ====== VERIFY MANAGER ======


{-| Returns `name` if it is a key of `unions`, and otherwise an
`EffectNotFound` error at `region`.
-}
verifyEffectType : A.Located Name.Name -> Dict Name.Name a -> EResult i w Name.Name
verifyEffectType (A.At region name) unions =
    if Dict.member name unions then
        ReportingResult.ok name

    else
        ReportingResult.throw (Error.EffectNotFound region name)


{-| Returns a value's name with the region of that name.
-}
toNameRegion : A.Located Src.Value -> ( Name.Name, A.Region )
toNameRegion (A.At _ (Src.Value v)) =
    let
        ( _, A.At region name ) =
            v.name
    in
    ( name, region )


{-| Returns the region of the name of the definition of `name` in `values`,
and otherwise an `EffectFunctionNotFound` error at `tagRegion`, the region of
the effect module header.
-}
verifyManager : A.Region -> Dict Name.Name A.Region -> Name.Name -> EResult i w A.Region
verifyManager tagRegion values name =
    case Dict.get name values of
        Just region ->
            ReportingResult.ok region

        Nothing ->
            ReportingResult.throw (Error.EffectFunctionNotFound tagRegion name)



-- ====== CHECK PAYLOAD TYPES ======


{-| Checks whether a type can be carried by a port.

The allowed types are `Int`, `Float`, `Bool`, `String`, `Json.Encode.Value`,
`Bytes.Bytes`, the unit type, a `List`, `Maybe` or `Array` of an allowed type,
and tuples and closed records whose parts are all allowed. Aliases are
expanded before checking. Every other type is rejected, including `Char`, type
variables, functions, extensible records and any other named type.

An `Err` carries the first offending part, not the whole type, and why it is
rejected. Tuple parts are checked left to right and record fields in the order
of their names.

-}
checkPayload : Can.Type Name -> Result ( Can.Type Name, Error.InvalidPayload ) ()
checkPayload tipe =
    case tipe of
        Can.TAlias _ _ args aliasedType ->
            checkPayload (Type.dealias args aliasedType)

        Can.TType home name args ->
            case args of
                [] ->
                    if isJson home name || isString home name || isIntFloatBool home name || isBytes home name then
                        Ok ()

                    else
                        Err ( tipe, Error.UnsupportedType name )

                [ arg ] ->
                    if isList home name || isMaybe home name || isArray home name then
                        checkPayload arg

                    else
                        Err ( tipe, Error.UnsupportedType name )

                _ ->
                    Err ( tipe, Error.UnsupportedType name )

        Can.TUnit ->
            Ok ()

        Can.TTuple a b cs ->
            checkPayload a
                |> Result.andThen (\_ -> checkPayload b)
                |> Result.andThen (\_ -> checkPayloadTupleCs cs)

        Can.TVar name ->
            Err ( tipe, Error.TypeVariable name )

        Can.TLambda _ _ _ ->
            Err ( tipe, Error.Function )

        Can.TRecord _ (Just _) ->
            Err ( tipe, Error.ExtendedRecord )

        Can.TRecord fields Nothing ->
            Dict.foldl
                (\_ field acc -> Result.andThen (\_ -> checkFieldPayload field) acc)
                (Ok ())
                fields


{-| Checks the third and later parts of a tuple, left to right, as
`checkPayload` does.
-}
checkPayloadTupleCs : List (Can.Type Name) -> Result ( Can.Type Name, Error.InvalidPayload ) ()
checkPayloadTupleCs types =
    case types of
        [] ->
            Ok ()

        tipe :: rest ->
            checkPayload tipe
                |> Result.andThen (\_ -> checkPayloadTupleCs rest)


{-| Checks the type of a record field as `checkPayload` does.
-}
checkFieldPayload : Can.FieldType Name -> Result ( Can.Type Name, Error.InvalidPayload ) ()
checkFieldPayload (Can.FieldType _ tipe) =
    checkPayload tipe


{-| Tells whether the type named `name` in module `home` is
`Basics.Int`, `Basics.Float` or `Basics.Bool`.
-}
isIntFloatBool : ModuleName.Canonical -> Name.Name -> Bool
isIntFloatBool home name =
    home
        == ModuleName.basics
        && (name == Name.int || name == Name.float || name == Name.bool)


{-| Tells whether the type named `name` in module `home` is `String.String`.
-}
isString : ModuleName.Canonical -> Name.Name -> Bool
isString home name =
    home
        == ModuleName.string
        && name
        == Name.string


{-| Tells whether the type named `name` in module `home` is `Json.Encode.Value`.
-}
isJson : ModuleName.Canonical -> Name.Name -> Bool
isJson home name =
    (home == ModuleName.jsonEncode)
        && (name == Name.value)


{-| Tells whether the type named `name` in module `home` is `List.List`.
-}
isList : ModuleName.Canonical -> Name.Name -> Bool
isList home name =
    home
        == ModuleName.list
        && name
        == Name.list


{-| Tells whether the type named `name` in module `home` is `Maybe.Maybe`.
-}
isMaybe : ModuleName.Canonical -> Name.Name -> Bool
isMaybe home name =
    home
        == ModuleName.maybe
        && name
        == Name.maybe


{-| Tells whether the type named `name` in module `home` is `Array.Array`.
-}
isArray : ModuleName.Canonical -> Name.Name -> Bool
isArray home name =
    home
        == ModuleName.array
        && name
        == Name.array


{-| Tells whether the type named `name` in module `home` is `Bytes.Bytes`.
-}
isBytes : ModuleName.Canonical -> Name.Name -> Bool
isBytes home name =
    home
        == ModuleName.bytes
        && name
        == Name.bytes
