module Compiler.Canonicalize.Effects exposing
    ( canonicalize
    , checkPayload
    )

{-| Canonicalization of effect managers, ports, and their type constraints.

This module handles the canonicalization of Elm's effects system, including:
- Port declarations and their payload validation
- Effect manager declarations (Cmd, Sub, and Fx managers)
- Verification that effect types are valid and properly declared

@docs canonicalize, checkPayload

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Type as Type
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Parse.SyntaxVersion exposing (SyntaxVersion)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Data.Map as Dict exposing (Dict)
import Maybe exposing (Maybe(..))
import System.TypeCheck.IO as IO



-- RESULT


type alias EResult i w a =
    ReportingResult.RResult i w Error.Error a



-- CANONICALIZE


{-| Canonicalize effect declarations, including ports and effect managers.

Validates that:
- Port types are either `Cmd msg` or `Sub msg` with valid payloads
- Effect managers declare all required functions (init, onEffects, onSelfMsg, cmdMap/subMap)
- Effect types reference declared union types

-}
canonicalize :
    SyntaxVersion
    -> Env.Env
    -> List (A.Located Src.Value)
    -> Dict String Name.Name union
    -> Src.Effects
    -> EResult i w Can.Effects
canonicalize syntaxVersion env values unions effects =
    case effects of
        Src.NoEffects ->
            ReportingResult.ok Can.NoEffects

        Src.Ports ports ->
            ReportingResult.traverse (canonicalizePort syntaxVersion env) ports
                |> ReportingResult.map (Can.Ports << Dict.fromList identity)

        Src.Manager region manager ->
            let
                dict : Dict String Name.Name A.Region
                dict =
                    Dict.fromList identity (List.map toNameRegion values)
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



-- CANONICALIZE PORT


canonicalizePort : SyntaxVersion -> Env.Env -> Src.Port -> EResult i w ( Name.Name, Can.Port )
canonicalizePort syntaxVersion env (Src.Port _ ( _, A.At region portName ) tipe) =
    Type.toAnnotation syntaxVersion env tipe
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
                                [ Can.TLambda incomingType (Can.TVar msg1) ] ->
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



-- VERIFY MANAGER


verifyEffectType : A.Located Name.Name -> Dict String Name.Name a -> EResult i w Name.Name
verifyEffectType (A.At region name) unions =
    if Dict.member identity name unions then
        ReportingResult.ok name

    else
        ReportingResult.throw (Error.EffectNotFound region name)


toNameRegion : A.Located Src.Value -> ( Name.Name, A.Region )
toNameRegion (A.At _ (Src.Value v)) =
    let
        ( _, A.At region name ) =
            v.name
    in
    ( name, region )


verifyManager : A.Region -> Dict String Name.Name A.Region -> Name.Name -> EResult i w A.Region
verifyManager tagRegion values name =
    case Dict.get identity name values of
        Just region ->
            ReportingResult.ok region

        Nothing ->
            ReportingResult.throw (Error.EffectFunctionNotFound tagRegion name)



-- CHECK PAYLOAD TYPES


{-| Verify that a type can be used as a port payload.

Valid port payloads include:
- Primitive types (Int, Float, Bool, String)
- Json.Encode.Value
- Lists, Arrays, and Maybes containing valid payloads
- Tuples and records containing valid payloads
- Bytes.Bytes

Invalid payloads include functions, type variables, and extensible records.

-}
checkPayload : Can.Type -> Result ( Can.Type, Error.InvalidPayload ) ()
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

        Can.TLambda _ _ ->
            Err ( tipe, Error.Function )

        Can.TRecord _ (Just _) ->
            Err ( tipe, Error.ExtendedRecord )

        Can.TRecord fields Nothing ->
            Dict.foldl compare
                (\_ field acc -> Result.andThen (\_ -> checkFieldPayload field) acc)
                (Ok ())
                fields


checkPayloadTupleCs : List Can.Type -> Result ( Can.Type, Error.InvalidPayload ) ()
checkPayloadTupleCs types =
    case types of
        [] ->
            Ok ()

        tipe :: rest ->
            checkPayload tipe
                |> Result.andThen (\_ -> checkPayloadTupleCs rest)


checkFieldPayload : Can.FieldType -> Result ( Can.Type, Error.InvalidPayload ) ()
checkFieldPayload (Can.FieldType _ tipe) =
    checkPayload tipe


isIntFloatBool : IO.Canonical -> Name.Name -> Bool
isIntFloatBool home name =
    home
        == ModuleName.basics
        && (name == Name.int || name == Name.float || name == Name.bool)


isString : IO.Canonical -> Name.Name -> Bool
isString home name =
    home
        == ModuleName.string
        && name
        == Name.string


isJson : IO.Canonical -> Name.Name -> Bool
isJson home name =
    (home == ModuleName.jsonEncode)
        && (name == Name.value)


isList : IO.Canonical -> Name.Name -> Bool
isList home name =
    home
        == ModuleName.list
        && name
        == Name.list


isMaybe : IO.Canonical -> Name.Name -> Bool
isMaybe home name =
    home
        == ModuleName.maybe
        && name
        == Name.maybe


isArray : IO.Canonical -> Name.Name -> Bool
isArray home name =
    home
        == ModuleName.array
        && name
        == Name.array


isBytes : IO.Canonical -> Name.Name -> Bool
isBytes home name =
    home
        == ModuleName.bytes
        && name
        == Name.bytes
