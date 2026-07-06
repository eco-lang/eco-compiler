module Eco.XHR exposing
    ( Failure
    , stringTask, jsonTask, bytesTask, unitTask
    , sendBytesTask, rawBytesRecvTask
    , orCrash
    )

{-| Shared HTTP plumbing for XHR-based IO operations.

Each function sends a POST request to the Node.js eco-io handler endpoint and
decodes the response. On failure the task fails with the neutral IO failure
tuple `( classificationTag, path, message )` (see IO\_ERR\_002); the eco-io server
forwards the libuv `code` and `path` on its error responses, which we classify
via `Eco.IO.Error.tagFromCode`. Genuine protocol/decoding faults (which indicate
a bug in the bootstrap harness rather than a user IO error) still crash.

@docs Failure
@docs stringTask, jsonTask, bytesTask, unitTask
@docs sendBytesTask, rawBytesRecvTask
@docs orCrash

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Eco.IO.Error as IOErr
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)
import Utils.Crash exposing (crash)


{-| The neutral IO failure tuple carried as a Task error.
-}
type alias Failure =
    ( Int, String, String )


{-| Send a POST request and decode the response as a string.
-}
stringTask : String -> Encode.Value -> Task Failure String
stringTask op payload =
    Http.task
        { method = "POST"
        , headers = []
        , url = "eco-io"
        , body = Http.jsonBody (encodeRequest op payload)
        , resolver =
            Http.stringResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ _ body ->
                            case Decode.decodeString (Decode.field "value" Decode.string) body of
                                Ok value ->
                                    Ok value

                                Err err ->
                                    crash ("eco-io decode error (" ++ op ++ "): " ++ Decode.errorToString err)

                        _ ->
                            Err (stringFailure op response)
                )
        , timeout = Nothing
        }


{-| Send a POST request and decode the response using a JSON decoder.
-}
jsonTask : String -> Encode.Value -> Decode.Decoder a -> Task Failure a
jsonTask op payload decoder =
    Http.task
        { method = "POST"
        , headers = []
        , url = "eco-io"
        , body = Http.jsonBody (encodeRequest op payload)
        , resolver =
            Http.stringResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ _ body ->
                            case Decode.decodeString (Decode.field "value" decoder) body of
                                Ok value ->
                                    Ok value

                                Err err ->
                                    crash ("eco-io decode error (" ++ op ++ "): " ++ Decode.errorToString err)

                        _ ->
                            Err (stringFailure op response)
                )
        , timeout = Nothing
        }


{-| Send a JSON POST request and decode the response as raw bytes using
a Bytes.Decode.Decoder.
-}
bytesTask : String -> Encode.Value -> Bytes.Decode.Decoder a -> Task Failure a
bytesTask op payload decoder =
    Http.task
        { method = "POST"
        , headers = []
        , url = "eco-io"
        , body = Http.jsonBody (encodeRequest op payload)
        , resolver =
            Http.bytesResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ _ body ->
                            case Bytes.Decode.decode decoder body of
                                Just value ->
                                    Ok value

                                Nothing ->
                                    crash ("eco-io bytes decode error: " ++ op)

                        _ ->
                            Err (bytesFailure op response)
                )
        , timeout = Nothing
        }


{-| Send a POST request and ignore the response (return unit).
-}
unitTask : String -> Encode.Value -> Task Failure ()
unitTask op payload =
    Http.task
        { method = "POST"
        , headers = []
        , url = "eco-io"
        , body = Http.jsonBody (encodeRequest op payload)
        , resolver =
            Http.stringResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ _ _ ->
                            Ok ()

                        _ ->
                            Err (stringFailure op response)
                )
        , timeout = Nothing
        }


{-| Send raw bytes to eco-io with the op name and metadata in headers.
Used by File.writeBytes, MVar.put — operations that send binary data.
-}
sendBytesTask : String -> List Http.Header -> Bytes -> Task Failure ()
sendBytesTask op headers bytes =
    Http.task
        { method = "POST"
        , headers = Http.header "X-Eco-Op" op :: headers
        , url = "eco-io"
        , body = Http.bytesBody "application/octet-stream" bytes
        , resolver =
            Http.stringResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ _ _ ->
                            Ok ()

                        _ ->
                            Err (stringFailure op response)
                )
        , timeout = Nothing
        }


{-| Send a JSON POST request and receive the response as raw Bytes
without decoding. Used by File.readBytes.
-}
rawBytesRecvTask : String -> Encode.Value -> Task Failure Bytes
rawBytesRecvTask op payload =
    Http.task
        { method = "POST"
        , headers = []
        , url = "eco-io"
        , body = Http.jsonBody (encodeRequest op payload)
        , resolver =
            Http.bytesResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ _ body ->
                            Ok body

                        _ ->
                            Err (bytesFailure op response)
                )
        , timeout = Nothing
        }


encodeRequest : String -> Encode.Value -> Encode.Value
encodeRequest op payload =
    Encode.object
        [ ( "op", Encode.string op )
        , ( "args", payload )
        ]


{-| For operations that are semantically infallible (queries that always
return, e.g. fileExists, getCwd): a transport-level failure indicates a broken
bootstrap harness, so crash with the message rather than surfacing an IOError.
Mirrors the pre-existing XHR behaviour of crashing on unexpected responses.
-}
orCrash : Task Failure a -> Task Never a
orCrash =
    Task.onError (\( _, _, message ) -> crash ("eco-io: " ++ message))



-- ERROR MAPPING


{-| Build the neutral IO failure tuple from a string-bodied HTTP response. The
eco-io server reports IO errors as HTTP 500 with body
`{ "error": <message>, "code": <libuv code|null>, "path": <path|null> }`.
-}
stringFailure : String -> Http.Response String -> Failure
stringFailure op response =
    case response of
        Http.BadStatus_ _ body ->
            case Decode.decodeString errorDecoder body of
                Ok ( message, code, path ) ->
                    ( IOErr.tagFromCode code, path, message )

                Err _ ->
                    ( 0, "", "eco-io request failed (" ++ op ++ "): " ++ body )

        Http.Timeout_ ->
            ( 0, "", "eco-io request timed out (" ++ op ++ ")" )

        Http.NetworkError_ ->
            ( 0, "", "eco-io network error (" ++ op ++ ")" )

        Http.BadUrl_ url ->
            ( 0, "", "eco-io bad url (" ++ op ++ "): " ++ url )

        Http.GoodStatus_ _ body ->
            ( 0, "", "eco-io unexpected response (" ++ op ++ "): " ++ body )


{-| Build the neutral IO failure tuple from a bytes-bodied HTTP response. The
error body (when present) is a JSON string, so decode the bytes to text first.
-}
bytesFailure : String -> Http.Response Bytes -> Failure
bytesFailure op response =
    case response of
        Http.BadStatus_ _ body ->
            case bytesToString body |> Maybe.andThen (Decode.decodeString errorDecoder >> Result.toMaybe) of
                Just ( message, code, path ) ->
                    ( IOErr.tagFromCode code, path, message )

                Nothing ->
                    ( 0, "", "eco-io request failed (" ++ op ++ ")" )

        Http.Timeout_ ->
            ( 0, "", "eco-io request timed out (" ++ op ++ ")" )

        Http.NetworkError_ ->
            ( 0, "", "eco-io network error (" ++ op ++ ")" )

        Http.BadUrl_ url ->
            ( 0, "", "eco-io bad url (" ++ op ++ "): " ++ url )

        Http.GoodStatus_ _ _ ->
            ( 0, "", "eco-io unexpected response (" ++ op ++ ")" )


bytesToString : Bytes -> Maybe String
bytesToString bytes =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes


errorDecoder : Decode.Decoder ( String, String, String )
errorDecoder =
    Decode.map3 (\msg code path -> ( msg, code, path ))
        (Decode.field "error" Decode.string)
        (Decode.oneOf [ Decode.field "code" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "path" Decode.string, Decode.succeed "" ])
