module Http.Stream exposing
    ( request
    , Body, emptyBody, stringBody, jsonBody, bytesBody, streamBody
    , Expect, expectStream, expectStreamResponse
    , task, Resolver, streamResolver
    , fromStreamFailure
    )

{-| Lets a program send HTTP requests whose bodies are streams, so that it can upload or
download something large, or something that arrives slowly, without holding all of it in
memory.

This module extends [`elm/http`](/packages/elm/http/latest). A request body can be a
[`Stream.Readable`](Stream#Readable) of bytes, sent as it is read, and a response body can be
handed to the program as a `Stream.Readable Bytes`, to be read chunk by chunk while it
downloads. Everything that is not about streams stays elm/http's: headers are made with
`Http.header`, and results are elm/http's `Http.Error`, `Http.Metadata` and `Http.Response`.
This module has its own [`Body`](#Body), [`Expect`](#Expect) and [`Resolver`](#Resolver)
types, and its own [`request`](#request) and [`task`](#task), shaped like elm/http's. The method
of a request is an [`Http.Method.Method`](Http-Method#Method) rather than elm/http's `String`.

A request has two stages, and a failure is reported differently in each. Until the headers of
the final response arrive, the request itself can fail, with `Http.BadUrl`, `Http.Timeout` or
`Http.NetworkError`. Once they have arrived the response is handed over. A failure after that
point, such as the connection closing before the body is complete, reaches the body stream
instead: once the bytes already received have been read, a read of the body fails with
`Stream.Failed`, which [`fromStreamFailure`](#fromStreamFailure) reads as `Http.NetworkError`.

Differences from elm/http:

  - A URL with a scheme other than `http:` or `https:` fails with `Http.BadUrl`. A URL with no
    scheme fails with `Http.BadUrl` on the JavaScript backend.
  - The `timeout` covers everything up to the arrival of the final response's headers,
    including connecting, following redirects and sending the body. Once the headers have
    arrived the body may take as long as it needs.
  - There is no `tracker`, so `Http.track` and `Http.cancel` do not apply. To cancel a request,
    run it with [`task`](#task) in a process started with `Process.spawn`, and stop it with
    `Process.kill` before the response headers arrive. After that, cancel the body stream
    with `Stream.cancelReadable`, which stops a transfer still running. While a read is
    waiting on the body stream, or a pipe is reading it, `cancelReadable` fails with `Locked`
    and does nothing.
  - Redirects are followed, at most 20 of them; one more fails with `Http.NetworkError`, and a
    redirect to a URL that is not `http:` or `https:` fails with `Http.BadUrl` carrying the URL
    of the request. The status, headers and `Metadata.url` are those of the final response.

Response header names are lower-cased, and a header that appears more than once has its values
joined with `", "` in the order they arrived, as elm/http joins them.


# Requests

@docs request


# Body

@docs Body, emptyBody, stringBody, jsonBody, bytesBody, streamBody


# Expect

@docs Expect, expectStream, expectStreamResponse


# Tasks

@docs task, Resolver, streamResolver


# Body stream failures

@docs fromStreamFailure

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Eco.Kernel.HttpStream
import Eco.Kernel.Stream
import Http
import Http.Method exposing (Method)
import Json.Encode
import Stream
import Stream.Internal
import Task exposing (Task)



-- REQUESTS


{-| Sends a request and turns its response into a message, as `expect` says. For example, to
download a large file:

    import Bytes exposing (Bytes)
    import Http
    import Http.Method exposing (Method(..))
    import Http.Stream
    import Stream

    type Msg
        = GotStream (Result Http.Error ( Http.Metadata, Stream.Readable Bytes ))

    download : Cmd Msg
    download =
        Http.Stream.request
            { method = GET
            , headers = []
            , url = "https://example.com/large-file.csv"
            , body = Http.Stream.emptyBody
            , expect = Http.Stream.expectStream GotStream
            , timeout = Nothing
            }

The `method` is sent as [`Http.Method.toString`](Http-Method#toString) gives its name, so
`UNKNOWN "PROPFIND"` sends `PROPFIND`.

The `timeout` is how many milliseconds to wait for the final response's headers before the
request fails with `Http.Timeout`. It is rounded to whole milliseconds, at least 1, and
`Nothing`, or a value of 0 or less, means no timeout. On the JavaScript backend a timeout above
2147483647 milliseconds fails the request after 1 millisecond.

A header in `headers` whose name is empty or holds a CR, LF or `:`, or whose value holds a CR or
LF, is not sent. On the JavaScript backend a header that Node rejects, such as one whose name holds
a space, is not sent either.

-}
request :
    { method : Method
    , headers : List Http.Header
    , url : String
    , body : Body
    , expect : Expect msg
    , timeout : Maybe Float
    }
    -> Cmd msg
request r =
    case r.expect of
        Expect discard toMsg ->
            Task.perform toMsg
                (sendRaw
                    { method = Http.Method.toString r.method
                    , headers = r.headers
                    , url = r.url
                    , body = r.body
                    , timeout = r.timeout
                    }
                    discard
                )



-- BODY


{-| The body of a request made with this module: nothing, a block of bytes, or a stream.

A body other than [`emptyBody`](#emptyBody) carries a MIME type, and a non-empty MIME type is
sent as the `Content-Type` header, unless it holds a CR or LF (or, on the JavaScript backend,
something else Node rejects in a header value). An empty MIME type adds no `Content-Type` header
on the JavaScript backend; on the native backend libcurl can add
`Content-Type: application/x-www-form-urlencoded` in its place. A body is made with
[`emptyBody`](#emptyBody), [`stringBody`](#stringBody), [`jsonBody`](#jsonBody),
[`bytesBody`](#bytesBody) or [`streamBody`](#streamBody).

-}
type Body
    = EmptyBody
    | BytesBody String Bytes
    | StreamBody String Int


{-| A body with nothing in it, and no MIME type, so it adds no `Content-Type` header of its own.
On the native backend libcurl can still add `Content-Type: application/x-www-form-urlencoded`
to a `POST`.
-}
emptyBody : Body
emptyBody =
    EmptyBody


{-| Makes a body holding `value` encoded as UTF-8, sent with the
[MIME type](https://en.wikipedia.org/wiki/Media_type) `mimeType` as its `Content-Type` (an empty
`mimeType` is treated as [`Body`](#Body) describes).

A lone surrogate in `value` is not valid in UTF-8, and the two backends differ: it is sent as
U+FFFD (the bytes `EF BF BD`) on the JavaScript backend, and in its 3-byte surrogate form on the
native backend.

-}
stringBody : String -> String -> Body
stringBody mimeType value =
    BytesBody mimeType (kStringToUtf8 value)


{-| Makes a body holding `value` as JSON text with no whitespace, sent with
`Content-Type: application/json`.
-}
jsonBody : Json.Encode.Value -> Body
jsonBody value =
    stringBody "application/json" (Json.Encode.encode 0 value)


{-| Makes a body holding `bytes`, sent with the
[MIME type](https://en.wikipedia.org/wiki/Media_type) `mimeType` as its `Content-Type` (an empty
`mimeType` is treated as [`Body`](#Body) describes). For example, to send an `archive.zip` file
made with [`elm/bytes`](/packages/elm/bytes/latest):

    zipBody : Bytes -> Http.Stream.Body
    zipBody bytes =
        Http.Stream.bytesBody "application/zip" bytes

-}
bytesBody : String -> Bytes -> Body
bytesBody mimeType bytes =
    BytesBody mimeType bytes


{-| Makes a body that sends what is read from a stream, sent with the
[MIME type](https://en.wikipedia.org/wiki/Media_type) `mimeType` as its `Content-Type` (an empty
`mimeType` is treated as [`Body`](#Body) describes). The stream is sent as it is read, so
something large, like a file, can be sent without holding it all in memory:

    upload : Stream.Readable Bytes -> Cmd Msg
    upload fileStream =
        Http.Stream.request
            { method = PUT
            , headers = []
            , url = "https://example.com/upload"
            , body = Http.Stream.streamBody "text/csv" fileStream
            , expect = Http.Stream.expectStream Uploaded
            , timeout = Nothing
            }

The end of the stream is the end of the body. The request reads the stream through a pipe, so
the stream is locked, as [`Stream`](Stream) describes, while the request runs. A stream that is
already locked when the request is sent makes the request fail at once with `Http.NetworkError`
(on the JavaScript backend, a bad URL is reported first).

If the stream fails, because it is cancelled from its writing side or the resource behind it
fails, a transfer still running is stopped: before the response headers the request fails with
`Http.NetworkError`, and after them a read of the response body fails with `Stream.Failed`, which
[`fromStreamFailure`](#fromStreamFailure) reads as `Http.NetworkError`.
If instead the transfer ends before the whole stream has been sent (the response is complete,
the request has failed, or it was stopped), the rest is not sent, and the stream is cancelled,
at the latest when it next has a value to send. A 307 or 308 redirect fails with
`Http.NetworkError`, because a stream cannot be sent twice. Other redirects differ between
backends: on the JavaScript backend a 303, or a 301 or 302 after a `POST`, is followed as a `GET`
without a body and any other fails with `Http.NetworkError`; on the native backend such a request
can wait until its `timeout`, so set one.

-}
streamBody : String -> Stream.Readable Bytes -> Body
streamBody mimeType (Stream.Internal.Readable id) =
    StreamBody mimeType id



-- EXPECT


{-| How a [`request`](#request) turns its response into a message, as elm/http's `Http.Expect`
does. One is made with [`expectStream`](#expectStream), which keeps only a successful response's
body, or [`expectStreamResponse`](#expectStreamResponse), which keeps the body of every response.
-}
type Expect msg
    = Expect Bool (Http.Response (Stream.Readable Bytes) -> msg)


{-| Makes an [`Expect`](#Expect) that gives `toMsg` the response's metadata and its body
stream when the status code is in 200–299.

A status code outside 200–299 gives `Err (Http.BadStatus code)`, and the body is not downloaded:
the transfer is stopped as soon as the headers have arrived. A request that fails before the
headers arrive gives `Http.BadUrl`, `Http.Timeout` or `Http.NetworkError`.

Read the body to the end, or cancel it with `Stream.cancelReadable` once it is no longer needed.
Only about 256 KiB of unread body is held, so a larger body left unread keeps the transfer open.

-}
expectStream : (Result Http.Error ( Http.Metadata, Stream.Readable Bytes ) -> msg) -> Expect msg
expectStream toMsg =
    Expect True (toMsg << toStreamResult)


{-| Returns the result [`expectStream`](#expectStream) gives for `response`: the metadata and
body stream of a 2xx response, or the `Http.Error` for anything else.
-}
toStreamResult : Http.Response (Stream.Readable Bytes) -> Result Http.Error ( Http.Metadata, Stream.Readable Bytes )
toStreamResult response =
    case response of
        Http.GoodStatus_ meta body ->
            Ok ( meta, body )

        Http.BadStatus_ meta _ ->
            Err (Http.BadStatus meta.statusCode)

        Http.BadUrl_ url ->
            Err (Http.BadUrl url)

        Http.Timeout_ ->
            Err Http.Timeout

        Http.NetworkError_ ->
            Err Http.NetworkError


{-| Makes an [`Expect`](#Expect) that turns the whole `Http.Response` into a result with
`toResult` and gives that to `toMsg`, as elm/http's `Http.expectBytesResponse` does.

Unlike [`expectStream`](#expectStream), a response of any status code comes with its body
stream, so the body of, say, a 404 response can be read.

-}
expectStreamResponse : (Result x a -> msg) -> (Http.Response (Stream.Readable Bytes) -> Result x a) -> Expect msg
expectStreamResponse toMsg toResult =
    Expect False (toMsg << toResult)



-- TASKS


{-| Makes a `Task` that sends the request, as [`request`](#request) does, and succeeds or fails
with what `resolver` makes of the response. A task can be chained with other tasks, for
example opening a file stream first and then uploading it.

A task is also the way to cancel a request: run it in a process started with `Process.spawn`,
and stop that process with `Process.kill` before the response headers arrive, which stops the
transfer. Killing the process after the task has received the response does not stop the
transfer; cancel the body stream with `Stream.cancelReadable` instead (which fails with
`Locked` while a read is waiting on the body stream, or a pipe is reading it).

-}
task :
    { method : Method
    , headers : List Http.Header
    , url : String
    , body : Body
    , resolver : Resolver x a
    , timeout : Maybe Float
    }
    -> Task x a
task r =
    case r.resolver of
        Resolver resolve ->
            sendRaw
                { method = Http.Method.toString r.method
                , headers = r.headers
                , url = r.url
                , body = r.body
                , timeout = r.timeout
                }
                False
                |> Task.mapError never
                |> Task.andThen
                    (\response ->
                        case resolve response of
                            Ok a ->
                                Task.succeed a

                            Err x ->
                                Task.fail x
                    )


{-| Reads a failure of a response body stream as elm/http's `Http.Error`. Returns `Nothing` for a
failure that another module's stream made.

    case streamError of
        Stream.Failed failure ->
            case Http.Stream.fromStreamFailure failure of
                Just Http.NetworkError ->
                    "the download was cut off"

                _ ->
                    Stream.failureToString failure

        _ ->
            ...

Every failure of a body stream is `Http.NetworkError`: the connection closing before the body is
complete, the transfer failing, or a [`streamBody`](#streamBody) whose stream failed. Once the
response headers have arrived, the request no longer has a timeout, so a body stream never fails
with `Http.Timeout`. `Stream.failureToString` gives the details, such as the message the network
library reported.

-}
fromStreamFailure : Stream.Failure -> Maybe Http.Error
fromStreamFailure (Stream.Internal.Failure f) =
    if f.origin == "http" then
        Just Http.NetworkError

    else
        Nothing


{-| How a [`task`](#task) turns its response into the task's result: success with an `a`, or
failure with an `x`. One is made with [`streamResolver`](#streamResolver).
-}
type Resolver x a
    = Resolver (Http.Response (Stream.Readable Bytes) -> Result x a)


{-| Makes a [`Resolver`](#Resolver) that turns the `Http.Response` into the task's result with
`toResult`. As with [`expectStreamResponse`](#expectStreamResponse), a response of any status
code comes with its body stream.
-}
streamResolver : (Http.Response (Stream.Readable Bytes) -> Result x a) -> Resolver x a
streamResolver toResult =
    Resolver toResult



-- SENDING


{-| A request as [`sendRaw`](#sendRaw) takes it: the fields that [`request`](#request) and
[`task`](#task) share, without the `expect` or `resolver`.
-}
type alias RawRequest =
    { method : String
    , headers : List Http.Header
    , url : String
    , body : Body
    , timeout : Maybe Float
    }


{-| Sends the request and returns its response, once the final response's headers have arrived
or the request has failed before that, in which case the response is a `BadUrl_`, `Timeout_` or
`NetworkError_`.

With `discard`, the body of a non-2xx response is not downloaded: the transfer is stopped at the
headers, and the body stream reads as already closed.

-}
sendRaw : RawRequest -> Bool -> Task Never (Http.Response (Stream.Readable Bytes))
sendRaw r discard =
    let
        -- The kernel reads 0 as no timeout.
        timeoutMs =
            case r.timeout of
                Nothing ->
                    0

                Just t ->
                    if t > 0 then
                        max 1 (round t)

                    else
                        0

        -- The kernel reads the bytes only of a bytes body and the stream id only of a stream
        -- body.
        bodyArg =
            case r.body of
                EmptyBody ->
                    ( 0, "", ( kStringToUtf8 "", -1 ) )

                BytesBody mime bytes ->
                    ( 1, mime, ( bytes, -1 ) )

                StreamBody mime id ->
                    ( 2, mime, ( kStringToUtf8 "", id ) )
    in
    kSend ( r.method, r.url, timeoutMs ) r.headers bodyArg discard
        |> Task.map toResponse


{-| Builds the elm/http response from the kernel's result. Kinds 0, 1 and 2 are a failure before
the headers (a bad URL, a timeout, a network error), 3 is a response with a status code outside
200–299, and any other kind is a response with a 2xx status code. Every kind other than 0, 1 and
2 has the stream `streamId` names as its body.
-}
toResponse : ( Int, String, ( ( Int, String, String ), List ( String, String ), Int ) ) -> Http.Response (Stream.Readable Bytes)
toResponse ( kind, badUrl, ( ( statusCode, statusText, url ), headers, streamId ) ) =
    let
        meta () =
            { url = url
            , statusCode = statusCode
            , statusText = statusText
            , headers = mergeHeaders headers
            }
    in
    case kind of
        0 ->
            Http.BadUrl_ badUrl

        1 ->
            Http.Timeout_

        2 ->
            Http.NetworkError_

        3 ->
            Http.BadStatus_ (meta ()) (Stream.Internal.Readable streamId)

        _ ->
            Http.GoodStatus_ (meta ()) (Stream.Internal.Readable streamId)


{-| Builds the response headers from the kernel's header lines, which come with lower-cased
names in the order they arrived. A name that appears more than once gets its values joined with
`", "` in that order, as elm/http joins them.
-}
mergeHeaders : List ( String, String ) -> Dict String String
mergeHeaders pairs =
    List.foldl
        (\( name, value ) dict ->
            Dict.update name
                (\old ->
                    case old of
                        Nothing ->
                            Just value

                        Just previous ->
                            Just (previous ++ ", " ++ value)
                )
                dict
        )
        Dict.empty
        pairs



-- KERNELS


{-| Asks the kernel (`Eco.Kernel.HttpStream.send`) to run a transfer. Its type fixes the kernel
ABI.

The arguments are the method, URL and timeout in milliseconds (0 for none); the headers; the
body as its kind (0 empty, 1 bytes, 2 stream), MIME type, bytes and stream id (-1 for no
stream); and whether to discard the body of a non-2xx response. The task succeeds when the
final response's headers arrive, or the request fails before that, with the kind
[`toResponse`](#toResponse) reads, the URL of the request for a bad URL (empty otherwise), the
status code, status text and final URL, the header lines, and the id of the body stream.

-}
kSend :
    ( String, String, Int )
    -> List Http.Header
    -> ( Int, String, ( Bytes, Int ) )
    -> Bool
    -> Task Never ( Int, String, ( ( Int, String, String ), List ( String, String ), Int ) )
kSend =
    Eco.Kernel.HttpStream.send


{-| Encodes a string as UTF-8 bytes, in the kernel (`Eco.Kernel.Stream.stringToUtf8`). A lone
surrogate becomes U+FFFD on the JavaScript backend and its 3-byte surrogate form natively.
-}
kStringToUtf8 : String -> Bytes
kStringToUtf8 =
    Eco.Kernel.Stream.stringToUtf8
