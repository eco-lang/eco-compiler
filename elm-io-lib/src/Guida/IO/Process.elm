module Guida.IO.Process exposing
    ( Ports
    , ProcessApi, processApi
    , lookupEnv, getArgs, findExecutable
    , exit
    , Error(..), errorToString
    )

{-| Process and environment operations for Guida IO.

@docs Ports
@docs ProcessApi, processApi


# Environment

@docs lookupEnv, getArgs, findExecutable


# Process Control

@docs exit


# Error Handling

@docs Error, errorToString

-}

import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)
import Procedure
import Procedure.Channel as Channel
import Procedure.Program



-- PORTS


{-| The ports that need to be wired up to the TypeScript process handlers.
-}
type alias Ports msg =
    { -- Environment (call-and-response)
      procLookupEnv : { id : String, name : String } -> Cmd msg
    , procGetArgs : { id : String } -> Cmd msg
    , procFindExecutable : { id : String, name : String } -> Cmd msg

    -- Process control (fire-and-forget)
    , procExit : { response : Value } -> Cmd msg

    -- Response subscription
    , procResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg
    }



-- API


{-| The Process API providing environment and process operations.
-}
type alias ProcessApi msg =
    { lookupEnv : String -> (Maybe String -> msg) -> Cmd msg
    , getArgs : (List String -> msg) -> Cmd msg
    , findExecutable : String -> (Maybe String -> msg) -> Cmd msg
    , exit : Value -> Cmd msg
    }


{-| Creates an instance of the Process API.
-}
processApi : (Procedure.Program.Msg msg -> msg) -> Ports msg -> ProcessApi msg
processApi pt ports =
    { lookupEnv = lookupEnv pt ports
    , getArgs = getArgs pt ports
    , findExecutable = findExecutable pt ports
    , exit = exit ports
    }



-- ERROR HANDLING


{-| Possible errors from process operations.
-}
type Error
    = ProcessError String
    | DecodeError String


{-| Convert an error to a human-readable string.
-}
errorToString : Error -> String
errorToString error =
    case error of
        ProcessError msg ->
            "Process error: " ++ msg

        DecodeError msg ->
            "Decode error: " ++ msg



-- RESPONSE DECODERS


decodeMaybeStringResponse : { a | type_ : String, payload : Value } -> Maybe String
decodeMaybeStringResponse res =
    case res.type_ of
        "Value" ->
            case Decode.decodeValue (Decode.nullable Decode.string) res.payload of
                Ok maybeStr ->
                    maybeStr

                Err _ ->
                    Nothing

        "NotFound" ->
            Nothing

        _ ->
            Nothing


decodeArgsResponse : { a | type_ : String, payload : Value } -> List String
decodeArgsResponse res =
    case res.type_ of
        "Args" ->
            case Decode.decodeValue (Decode.list Decode.string) res.payload of
                Ok args ->
                    args

                Err _ ->
                    []

        _ ->
            []



-- ENVIRONMENT OPERATIONS


{-| Look up an environment variable.
Returns Nothing if the variable is not set.
-}
lookupEnv :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Maybe String -> msg)
    -> Cmd msg
lookupEnv pt ports name toMsg =
    Channel.open (\key -> ports.procLookupEnv { id = key, name = name })
        |> Channel.connect ports.procResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeMaybeStringResponse res |> toMsg)


{-| Get the command-line arguments.
-}
getArgs :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> (List String -> msg)
    -> Cmd msg
getArgs pt ports toMsg =
    Channel.open (\key -> ports.procGetArgs { id = key })
        |> Channel.connect ports.procResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeArgsResponse res |> toMsg)


{-| Find an executable in the system PATH.
Returns Nothing if the executable is not found.
-}
findExecutable :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Maybe String -> msg)
    -> Cmd msg
findExecutable pt ports name toMsg =
    Channel.open (\key -> ports.procFindExecutable { id = key, name = name })
        |> Channel.connect ports.procResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeMaybeStringResponse res |> toMsg)



-- PROCESS CONTROL


{-| Exit the process with a JSON response.
This is a fire-and-forget operation that terminates the program.
The response value is passed to the host environment.
-}
exit : Ports msg -> Value -> Cmd msg
exit ports response =
    ports.procExit { response = response }
