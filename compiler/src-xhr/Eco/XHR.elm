module Eco.XHR exposing
    ( stringTask, jsonTask, bytesTask, unitTask
    , sendBytesTask, rawBytesRecvTask
    )

{-| Shared HTTP plumbing for XHR-based IO operations.

Each function sends a POST request to the Node.js eco-io handler endpoint
and decodes the response.

@docs stringTask, jsonTask, bytesTask, unitTask
@docs sendBytesTask, rawBytesRecvTask

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)
import Utils.Crash exposing (crash)


{-| Send a POST request and decode the response as a string.
-}
stringTask : String -> Encode.Value -> Task Never String
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
                            crash ("eco-io request failed: " ++ op)
                )
        , timeout = Nothing
        }


{-| Send a POST request and decode the response using a JSON decoder.
-}
jsonTask : String -> Encode.Value -> Decode.Decoder a -> Task Never a
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
                            crash ("eco-io request failed: " ++ op)
                )
        , timeout = Nothing
        }


{-| Send a JSON POST request and decode the response as raw bytes using
a Bytes.Decode.Decoder.
-}
bytesTask : String -> Encode.Value -> Bytes.Decode.Decoder a -> Task Never a
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
                            crash ("eco-io request failed: " ++ op)
                )
        , timeout = Nothing
        }


{-| Send a POST request and ignore the response (return unit).
-}
unitTask : String -> Encode.Value -> Task Never ()
unitTask op payload =
    Http.task
        { method = "POST"
        , headers = []
        , url = "eco-io"
        , body = Http.jsonBody (encodeRequest op payload)
        , resolver = Http.stringResolver (\_ -> Ok ())
        , timeout = Nothing
        }


{-| Send raw bytes to eco-io with the op name and metadata in headers.
Used by File.writeBytes, MVar.put — operations that send binary data.
-}
sendBytesTask : String -> List Http.Header -> Bytes -> Task Never ()
sendBytesTask op headers bytes =
    Http.task
        { method = "POST"
        , headers = Http.header "X-Eco-Op" op :: headers
        , url = "eco-io"
        , body = Http.bytesBody "application/octet-stream" bytes
        , resolver = Http.stringResolver (\_ -> Ok ())
        , timeout = Nothing
        }


{-| Send a JSON POST request and receive the response as raw Bytes
without decoding. Used by File.readBytes.
-}
rawBytesRecvTask : String -> Encode.Value -> Task Never Bytes
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
                            crash ("eco-io request failed: " ++ op)
                )
        , timeout = Nothing
        }


encodeRequest : String -> Encode.Value -> Encode.Value
encodeRequest op payload =
    Encode.object
        [ ( "op", Encode.string op )
        , ( "args", payload )
        ]
