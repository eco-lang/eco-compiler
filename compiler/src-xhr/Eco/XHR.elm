module Eco.XHR exposing
    ( Failure
    , stringTask, jsonTask, bytesTask, unitTask
    , sendBytesTask, rawBytesRecvTask
    , orCrash
    )

{-| Lets a program running on stock Elm, which has no direct access to files,
processes or other host facilities, perform IO by asking an HTTP server to do
it.

An IO operation is sent as a POST request to the relative URL `eco-io`, and the
server answering there is called _eco-io_ below. A request names its operation
by an _op_, a string such as `"File.readString"`. This module is the one place
that builds these requests and reads their replies. No request sets a timeout.

Most requests carry a JSON body `{ "op": op, "args": payload }`.
`sendBytesTask` instead sends raw bytes as the body, with the op in an
`X-Eco-Op` header and any other arguments in headers its caller supplies.

A reply with a 2xx status carries the operation's result. `stringTask` and
`jsonTask` read it from the `value` field of a JSON body, `bytesTask` decodes
the body as bytes, `rawBytesRecvTask` returns the body as it is, and `unitTask`
and `sendBytesTask` ignore it.

Any other outcome fails the task with a `Failure`, the failure tuple
`( tag, path, message )` whose layout and tag numbering `Eco.IO.Error` sets out.
This module assumes that eco-io answers a failed operation with a non-2xx status
and a JSON body `{ "error": message, "code": code, "path": path }`, where `code`
is an error code string such as `"ENOENT"`. Such a reply fails with the tag
`Eco.IO.Error.tagFromCode code`, its `path` and its `message`; a `code` or
`path` that is missing, `null` or not a string is read as `""`. A non-2xx reply
whose body is not a JSON object with a string `error` field, a network error
and a bad URL each fail with tag 0, path `""` and a message naming the op.

Two cases crash the program, through `Utils.Crash.crash`, instead of failing the
task. A 2xx reply that `stringTask`, `jsonTask` or `bytesTask` cannot decode
crashes, with a message naming the op. And `orCrash` turns a task that can fail
into one that cannot, by crashing on any `Failure`, so a task built with it
crashes on every failure described above.

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


{-| The failure tuple `( tag, path, message )` that an eco-io request fails
with, laid out and numbered as `Eco.IO.Error` sets out. A failure reported
without a path carries `""`.

This is a name for a tuple, not a new type, so any `( Int, String, String )` is
accepted where a `Failure` is expected.

-}
type alias Failure =
    ( Int, String, String )


{-| Sends `op` with `payload` as its arguments, and returns the string in the
`value` field of the reply. A 2xx reply without a string `value` field crashes
the program.
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


{-| Sends `op` with `payload` as its arguments, and returns the `value` field of
the reply as `decoder` reads it. A 2xx reply whose `value` field is missing or
cannot be read by `decoder` crashes the program.
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


{-| Sends `op` with `payload` as its arguments, and returns the body of the reply
as `decoder` reads it. A 2xx reply that `decoder` cannot read crashes the
program.
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


{-| Sends `op` with `payload` as its arguments, and succeeds on any 2xx reply,
whatever its body.
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


{-| Sends `op` with `bytes` as the whole request body, and succeeds on any 2xx
reply, whatever its body. The op travels in an `X-Eco-Op` header, placed before
`headers`, which carry whatever other arguments the operation takes.
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


{-| Sends `op` with `payload` as its arguments, and returns the body of a 2xx
reply as it is, without decoding it.
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


{-| Builds the JSON body of a request, `{ "op": op, "args": payload }`.
-}
encodeRequest : String -> Encode.Value -> Encode.Value
encodeRequest op payload =
    Encode.object
        [ ( "op", Encode.string op )
        , ( "args", payload )
        ]


{-| Returns a task that succeeds as the given task does and, where that task
would fail, crashes the program instead. The crash message is the failure's
message prefixed with `"eco-io: "`; its tag and path are not shown.
-}
orCrash : Task Failure a -> Task Never a
orCrash =
    Task.onError (\( _, _, message ) -> crash ("eco-io: " ++ message))



-- ERROR MAPPING


{-| Returns the `Failure` for a request for `op` whose reply, if there is one,
was read as text.

A non-2xx reply whose body `errorDecoder` reads gives the tag that
`Eco.IO.Error.tagFromCode` returns for its code, with its path and message.
Any other outcome, whether a reply, a network error, a bad URL or a timeout,
gives tag 0, path `""` and a message naming `op`, which also quotes the body
when there is one: a non-2xx body that does not decode, or a 2xx body.

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


{-| Returns the `Failure` for a reply whose body was read as bytes, to a request
for `op`.

A non-2xx body is read as UTF-8 text and then as `stringFailure` reads it, with
the same result when it decodes. The tag-0 messages here never quote the body.

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


{-| Reads the whole of `bytes` as UTF-8 text.
-}
bytesToString : Bytes -> Maybe String
bytesToString bytes =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes


{-| A decoder for the JSON body of an eco-io error reply,
`{ "error": message, "code": code, "path": path }`, giving
`( message, code, path )`.

`error` must be a string, or the body does not decode. A `code` or `path` that
is missing, `null` or not a string is read as `""`.

-}
errorDecoder : Decode.Decoder ( String, String, String )
errorDecoder =
    Decode.map3 (\msg code path -> ( msg, code, path ))
        (Decode.field "error" Decode.string)
        (Decode.oneOf [ Decode.field "code" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "path" Decode.string, Decode.succeed "" ])
