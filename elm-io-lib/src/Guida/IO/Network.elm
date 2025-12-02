module Guida.IO.Network exposing
    ( Ports
    , NetworkApi, networkApi
    , getArchive
    , Archive, ArchiveEntry
    , Error(..), errorToString, errorToDetails
    )

{-| Network operations for Guida IO.
Currently provides archive fetching (ZIP download with SHA-1 verification).

@docs Ports
@docs NetworkApi, networkApi


# Archive Operations

@docs getArchive
@docs Archive, ArchiveEntry


# Error Handling

@docs Error, errorToString, errorToDetails

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Procedure
import Procedure.Channel as Channel
import Procedure.Program



-- PORTS


{-| The ports that need to be wired up to the TypeScript network handlers.
-}
type alias Ports msg =
    { -- Archive operations
      netGetArchive : { id : String, url : String } -> Cmd msg

    -- Response subscription
    , netResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg
    }



-- ARCHIVE TYPES


{-| A downloaded and extracted archive with its SHA-1 hash.
-}
type alias Archive =
    { sha : String
    , entries : List ArchiveEntry
    }


{-| An entry in an archive.
-}
type alias ArchiveEntry =
    { relativePath : String
    , data : String
    }



-- API


{-| The Network API providing network operations.
-}
type alias NetworkApi msg =
    { getArchive : String -> (Result Error Archive -> msg) -> Cmd msg
    }


{-| Creates an instance of the Network API.
-}
networkApi : (Procedure.Program.Msg msg -> msg) -> Ports msg -> NetworkApi msg
networkApi pt ports =
    { getArchive = getArchive pt ports
    }



-- ERROR HANDLING


{-| Possible errors from network operations.
-}
type Error
    = NetworkError { code : String, message : String }
    | DecodeError String
    | HttpError { statusCode : Int, message : String }


{-| Convert an error to a human-readable string.
-}
errorToString : Error -> String
errorToString error =
    case error of
        NetworkError { message } ->
            "Network error: " ++ message

        DecodeError msg ->
            "Decode error: " ++ msg

        HttpError { statusCode, message } ->
            "HTTP " ++ String.fromInt statusCode ++ ": " ++ message


{-| Convert an error to a structured format with details.
-}
errorToDetails : Error -> { message : String, details : Value }
errorToDetails error =
    case error of
        NetworkError { code, message } ->
            { message = message
            , details = Encode.object [ ( "code", Encode.string code ) ]
            }

        DecodeError msg ->
            { message = msg
            , details = Encode.null
            }

        HttpError { statusCode, message } ->
            { message = message
            , details = Encode.object [ ( "statusCode", Encode.int statusCode ) ]
            }



-- RESPONSE DECODERS


archiveDecoder : Decoder Archive
archiveDecoder =
    Decode.map2 Archive
        (Decode.field "sha" Decode.string)
        (Decode.field "entries" (Decode.list archiveEntryDecoder))


archiveEntryDecoder : Decoder ArchiveEntry
archiveEntryDecoder =
    Decode.map2 ArchiveEntry
        (Decode.field "relativePath" Decode.string)
        (Decode.field "data" Decode.string)


decodeArchiveResponse : { a | type_ : String, payload : Value } -> Result Error Archive
decodeArchiveResponse res =
    case res.type_ of
        "Archive" ->
            case Decode.decodeValue archiveDecoder res.payload of
                Ok archive ->
                    Ok archive

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "Error" ->
            Err (decodeErrorPayload res.payload)

        "HttpError" ->
            case Decode.decodeValue httpErrorDecoder res.payload of
                Ok { statusCode, message } ->
                    Err (HttpError { statusCode = statusCode, message = message })

                Err _ ->
                    Err (NetworkError { code = "UNKNOWN", message = "HTTP error" })

        _ ->
            Err (DecodeError ("Unknown response type: " ++ res.type_))


httpErrorDecoder : Decoder { statusCode : Int, message : String }
httpErrorDecoder =
    Decode.map2 (\statusCode message -> { statusCode = statusCode, message = message })
        (Decode.field "statusCode" Decode.int)
        (Decode.field "message" Decode.string)


decodeErrorPayload : Value -> Error
decodeErrorPayload payload =
    case Decode.decodeValue errorPayloadDecoder payload of
        Ok { code, message } ->
            NetworkError { code = code, message = message }

        Err _ ->
            NetworkError { code = "UNKNOWN", message = "Failed to decode error" }


errorPayloadDecoder : Decoder { code : String, message : String }
errorPayloadDecoder =
    Decode.map2 (\code message -> { code = code, message = message })
        (Decode.field "code" Decode.string)
        (Decode.field "message" Decode.string)



-- ARCHIVE OPERATIONS


{-| Fetch a ZIP archive from a URL, extract it, and compute its SHA-1 hash.
Returns the hash and list of files with their contents.
-}
getArchive :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error Archive -> msg)
    -> Cmd msg
getArchive pt ports url toMsg =
    Channel.open (\key -> ports.netGetArchive { id = key, url = url })
        |> Channel.connect ports.netResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeArchiveResponse res |> toMsg)
