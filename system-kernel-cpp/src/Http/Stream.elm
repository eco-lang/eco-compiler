module Http.Stream exposing
    ( request
    , Body, emptyBody, stringBody, jsonBody, bytesBody, streamBody
    , Expect, expectStream, expectStreamResponse
    , task, Resolver, streamResolver
    )

{-| Send HTTP requests whose bodies are streams.

This module extends [`elm/http`](/packages/elm/http/latest) with streaming: a request body can
be a [`Stream.Readable`](Stream#Readable) that is uploaded as it is read, and the response body
always arrives as a `Stream.Readable Bytes` that you can read chunk by chunk while it downloads.
Use it for large downloads and uploads, or for responses that arrive slowly over time.

Everything that is not about streams stays elm/http's: headers are built with `Http.header`, and
errors and responses are elm/http's `Http.Error`, `Http.Metadata` and `Http.Response`. This module
has its own [`Body`](#Body), [`Expect`](#Expect) and [`Resolver`](#Resolver) types, and its own
[`request`](#request) and [`task`](#task) functions shaped like elm/http's.

Differences from elm/http:

  - The `timeout` covers only the wait for the response headers. Once the headers have arrived
    the body may take as long as it needs, since a stream can be arbitrarily long.
  - There is no `tracker`, so `Http.track` and `Http.cancel` do not apply. To cancel a request,
    run it with [`task`](#task) in a process started with `Process.spawn` and stop it with
    `Process.kill`.
  - Response header names are lower-cased. If a header appears more than once its values are
    joined with `", "`, as in elm/http. After redirects, `Metadata.url` is the final URL and
    the headers are those of the final response.


# Requests

@docs request


# Body

@docs Body, emptyBody, stringBody, jsonBody, bytesBody, streamBody


# Expect

@docs Expect, expectStream, expectStreamResponse


# Tasks

@docs task, Resolver, streamResolver

-}

import Bytes exposing (Bytes)
import Http
import Json.Encode
import Stream
import Task exposing (Task)



-- REQUESTS


{-| Create a custom request whose response body is a stream. For example, to download a large
file:

    import Bytes exposing (Bytes)
    import Http
    import Http.Stream
    import Stream

    type Msg
        = GotStream (Result Http.Error ( Http.Metadata, Stream.Readable Bytes ))

    download : Cmd Msg
    download =
        Http.Stream.request
            { method = "GET"
            , headers = []
            , url = "https://example.com/large-file.csv"
            , body = Http.Stream.emptyBody
            , expect = Http.Stream.expectStream GotStream
            , timeout = Nothing
            }

It lets you set custom `headers` as needed. The `timeout` is the number of milliseconds you are
willing to wait for the response headers before giving up; `Nothing` means no timeout.

-}
request :
    { method : String
    , headers : List Http.Header
    , url : String
    , body : Body
    , expect : Expect msg
    , timeout : Maybe Float
    }
    -> Cmd msg
request r =
    Debug.todo "Implement System API"



-- BODY


{-| Represents the body of a request made with this module.
-}
type Body
    = EmptyBody
    | BytesBody String Bytes
    | StreamBody String Int


{-| Create an empty body for your request. This is useful for GET requests and POST requests
where you are not sending any data.
-}
emptyBody : Body
emptyBody =
    Debug.todo "Implement System API"


{-| Put some string in the body of your request. It is sent encoded as UTF-8.

The first argument is a [MIME type](https://en.wikipedia.org/wiki/Media_type) of the body, which
is sent as the `Content-Type` header. Some servers are strict about this!

-}
stringBody : String -> String -> Body
stringBody mimeType value =
    Debug.todo "Implement System API"


{-| Put some JSON value in the body of your request. This will automatically add the
`Content-Type: application/json` header.
-}
jsonBody : Json.Encode.Value -> Body
jsonBody value =
    Debug.todo "Implement System API"


{-| Put some `Bytes` in the body of your request. This allows you to use
[`elm/bytes`](/packages/elm/bytes/latest) to have full control over the binary representation
of the data you are sending. For example, you could send an `archive.zip` file like this:

    zipBody : Bytes -> Body
    zipBody bytes =
        Http.Stream.bytesBody "application/zip" bytes

The first argument is a [MIME type](https://en.wikipedia.org/wiki/Media_type) of the body.

-}
bytesBody : String -> Bytes -> Body
bytesBody mimeType bytes =
    Debug.todo "Implement System API"


{-| Use a readable stream of bytes as the body of your request. The stream is uploaded as it is
read, so you can send something large, like a file, without holding it all in memory:

    upload : Stream.Readable Bytes -> Cmd Msg
    upload fileStream =
        Http.Stream.request
            { method = "PUT"
            , headers = []
            , url = "https://example.com/upload"
            , body = Http.Stream.streamBody "text/csv" fileStream
            , expect = Http.Stream.expectStream Uploaded
            , timeout = Nothing
            }

The first argument is a [MIME type](https://en.wikipedia.org/wiki/Media_type) of the body. The
stream is locked while the request consumes it. No `Content-Length` is sent, so the body uses
chunked transfer encoding. If the stream is cancelled, the request fails with a network error.

-}
streamBody : String -> Stream.Readable Bytes -> Body
streamBody mimeType stream =
    Debug.todo "Implement System API"



-- EXPECT


{-| Logic for interpreting a response body, as with elm/http's `Http.Expect`. Here the body is
always delivered as a stream.
-}
type Expect msg
    = Expect Bool (Http.Response (Stream.Readable Bytes) -> msg)


{-| Expect the response body as a readable stream of bytes, together with the response
metadata.

If the server responds with a status code outside 200–299 you get `Err (Http.BadStatus code)` and
the response body is discarded. You also get `Http.BadUrl`, `Http.Timeout` or
`Http.NetworkError` when the request fails before the response headers arrive. A network error
after that point reaches the body stream instead, and reading it fails with `Stream.Cancelled`.

Read the body to the end, or cancel it with `Stream.cancelReadable` when you no longer need it.

-}
expectStream : (Result Http.Error ( Http.Metadata, Stream.Readable Bytes ) -> msg) -> Expect msg
expectStream toMsg =
    Debug.todo "Implement System API"


{-| Expect an `Http.Response` with a stream body.

It works just like elm/http's `Http.expectBytesResponse`, giving you access to the headers and
leeway in defining your own errors. Unlike [`expectStream`](#expectStream), every status code
comes with its real body stream, so you can read the error body of, say, a 404 response.

-}
expectStreamResponse : (Result x a -> msg) -> (Http.Response (Stream.Readable Bytes) -> Result x a) -> Expect msg
expectStreamResponse toMsg toResult =
    Debug.todo "Implement System API"



-- TASKS


{-| Just like [`request`](#request), but it creates a `Task`. This makes it possible to chain
the request with other tasks, for example opening a file stream first and then uploading it.

A task is also the way to cancel a request: start it with `Process.spawn` and stop it with
`Process.kill`, which aborts the transfer and cancels the body stream.

-}
task :
    { method : String
    , headers : List Http.Header
    , url : String
    , body : Body
    , resolver : Resolver x a
    , timeout : Maybe Float
    }
    -> Task x a
task r =
    Debug.todo "Implement System API"


{-| Describes how to resolve an HTTP task. You can create a resolver with
[`streamResolver`](#streamResolver).
-}
type Resolver x a
    = Resolver (Http.Response (Stream.Readable Bytes) -> Result x a)


{-| Turn a response with a stream body into a result. Similar to
[`expectStreamResponse`](#expectStreamResponse), every status code comes with its real body
stream.
-}
streamResolver : (Http.Response (Stream.Readable Bytes) -> Result x a) -> Resolver x a
streamResolver toResult =
    Debug.todo "Implement System API"
