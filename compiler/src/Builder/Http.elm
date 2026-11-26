module Builder.Http exposing
    ( Manager, getManager, managerEncoder, managerDecoder
    , get, post
    , Header
    , getArchive, Sha, shaToChars
    , Error(..), errorEncoder, errorDecoder
    )

{-| Gives the package-manager code one way to make HTTP requests, and one
error type for their failures.

The requests themselves are made by eco/system's `Http.Stream`, and every
failure comes back as an `Err`. This module adds two request headers to every
`get` and `post`, reads the whole response body, decompresses it as its
`Content-Encoding` says (`gzip` or `deflate`), decodes it as UTF-8, hands it to
the caller's continuation, and turns a failure into an `Error`. `get`, `post` and
`getArchive` return `Task Never (Result e a)`. `get` and `post` take a
function from `Error` to the caller's error type, while `getArchive` takes a
fixed error value that it returns for any failure.

A _manager_ is the value a caller threads through to every request. It carries
nothing, and no function here reads it.

Archives are fetched by `getArchive`, which returns the archive's SHA-1 and its
entries as a `Codec.Archive.Zip.Archive`, unpacked in Elm by
`Codec.Archive.ZipReader` and hashed by `Codec.Sha1`.

@docs Manager, getManager, managerEncoder, managerDecoder
@docs get, post
@docs Header
@docs getArchive, Sha, shaToChars
@docs Error, errorEncoder, errorDecoder

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Codec.Archive.Zip as Zip
import Codec.Archive.ZipReader as ZipReader
import Codec.Sha1 as Sha1
import Codec.Utf8 as Utf8
import Compiler.Elm.Version_Build as Version_Build
import Dict
import Flate
import Http
import Http.Method
import Http.Stream
import Stream
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== MANAGER ======


{-| A handle that requests are made through. Every manager is the same, and
holding one gives no capability: the functions that take one ignore it.
-}
type Manager
    = Manager


{-| Encodes a manager as the single byte 0.
-}
managerEncoder : Manager -> Bytes.Encode.Encoder
managerEncoder _ =
    Bytes.Encode.unsignedInt8 0


{-| A decoder for a manager as `managerEncoder` writes it. Any byte other
than 0 fails.
-}
managerDecoder : Bytes.Decode.Decoder Manager
managerDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Manager

                    _ ->
                        Bytes.Decode.fail
            )


{-| A task that gives a manager. It always succeeds and does nothing else.
-}
getManager : Task Never Manager
getManager =
    Task.succeed Manager



-- ====== FETCH ======


{-| An HTTP request header: its name, then its value.
-}
type alias Header =
    ( String, String )


{-| Sends a GET request to the URL with `headers`, and runs the continuation
on the response body.

A `User-Agent` of `elm/` and the compiler's version and an `Accept-Encoding`
of `gzip` are added in front of `headers`. A failure gives `Err` of the
`Error`, converted by the caller's function: a `BadHttp` whose status is the
response's, or code 0 with the failure's detail as its text when no status was
received.

-}
get : Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
get =
    fetch Http.Method.GET


{-| Sends a POST request with no body, otherwise exactly as `get` does.
-}
post : Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
post =
    fetch Http.Method.POST


{-| Sends a request with `method`, adding the default headers, and returns
the continuation's result on success or the converted `Error` on failure.
-}
fetch : Http.Method.Method -> Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
fetch method _ url headers onError onSuccess =
    download method url (addDefaultHeaders headers)
        |> Task.map
            (\( encoding, body ) ->
                case decompress encoding body of
                    Just bytes ->
                        Ok (Utf8.decode bytes)

                    Nothing ->
                        Err (BadHttp url 0 "unable to decompress the response body")
            )
        |> Task.onError (\err -> Task.succeed (Err err))
        |> Task.andThen
            (\result ->
                case result of
                    Ok text ->
                        onSuccess text

                    Err err ->
                        Task.succeed (Err (onError err))
            )


{-| Sends a request with no body and gives the response's `Content-Encoding`
header (`""` for none) and its whole body, as sent.

A response with a status outside 200 to 299 fails with a `BadHttp` that keeps
its status code and text, and its body is not read. A failure without a
response fails with status code 0 and a short description as the text:
`bad URL: <url>`, `timeout` or `network error`, or the stream's error when the
body could not be read to its end.

-}
download : Http.Method.Method -> String -> List Header -> Task Error ( String, Bytes )
download method url headers =
    Http.Stream.task
        { method = method
        , headers = List.map (\( name, value ) -> Http.header name value) headers
        , url = url
        , body = Http.Stream.emptyBody
        , resolver = Http.Stream.streamResolver Ok
        , timeout = Nothing
        }
        |> Task.andThen
            (\response ->
                case response of
                    Http.GoodStatus_ meta body ->
                        readAll body
                            |> Task.map (\bytes -> ( Dict.get "content-encoding" meta.headers |> Maybe.withDefault "", bytes ))
                            |> Task.mapError (\err -> BadHttp url 0 (Stream.errorToString err))

                    Http.BadStatus_ meta body ->
                        Stream.cancelReadable "unused" body
                            |> Task.onError (\_ -> Task.succeed ())
                            |> Task.andThen (\_ -> Task.fail (BadHttp url meta.statusCode meta.statusText))

                    Http.BadUrl_ badUrl ->
                        Task.fail (BadHttp url 0 ("bad URL: " ++ badUrl))

                    Http.Timeout_ ->
                        Task.fail (BadHttp url 0 "timeout")

                    Http.NetworkError_ ->
                        Task.fail (BadHttp url 0 "network error")
            )


{-| Reads a body stream to its end and gives all of it.
-}
readAll : Stream.Readable Bytes -> Task Stream.Error Bytes
readAll body =
    Stream.readUntilClosed (\chunk acc -> Ok (chunk :: acc)) [] body
        |> Task.map
            (\chunks ->
                Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.bytes (List.reverse chunks)))
            )


{-| Undoes the `Content-Encoding` a server applied: `gzip`, and `deflate` (zlib
wrapped), as the old kernels' Node `zlib` did, and nothing for any other.
`Nothing` if the body does not decompress.
-}
decompress : String -> Bytes -> Maybe Bytes
decompress encoding body =
    case String.toLower (String.trim encoding) of
        "gzip" ->
            Flate.inflateGZip body

        "deflate" ->
            Flate.inflateZlib body

        _ ->
            Just body


{-| Returns `headers` with the `User-Agent` and `Accept-Encoding: gzip`
headers in front.
-}
addDefaultHeaders : List Header -> List Header
addDefaultHeaders headers =
    ( "User-Agent", userAgent ) :: ( "Accept-Encoding", "gzip" ) :: headers


{-| The `User-Agent` header value: `elm/` followed by the compiler's
user-facing version.
-}
userAgent : String
userAgent =
    "elm/" ++ Version_Build.userFacing



-- ====== EXCEPTIONS ======


{-| Why a request failed: the URL that was requested, the response's status
code and its status text. Code 0 means no response arrived, and the text is
then the failure's detail.
-}
type Error
    = BadHttp String Int String



-- ====== SHA ======


{-| The SHA hash of a downloaded archive, as text.

This is a name for `String`, not a new type: any string is accepted where a
`Sha` is expected.

-}
type alias Sha =
    String


{-| Returns the hash as text, unchanged.
-}
shaToChars : Sha -> String
shaToChars =
    identity



-- ====== FETCH ARCHIVE ======


{-| Downloads the ZIP archive at `url` and runs the continuation on its SHA
and its entries.

Any failure gives `Err defaultError`; the cause of the failure is discarded.
No headers are added. The SHA is the SHA-1 of the archive as downloaded, in 40
lowercase hexadecimal digits. The entries are in the order of the archive's
central directory, each with its contents decoded as UTF-8 text.

-}
getArchive : String -> e -> (( Sha, Zip.Archive ) -> Task Never (Result e a)) -> Task Never (Result e a)
getArchive url defaultError onSuccess =
    download Http.Method.GET url []
        |> Task.map (\( _, bytes ) -> Maybe.map (Tuple.pair (Sha1.hex bytes)) (ZipReader.entries bytes))
        |> Task.onError (\_ -> Task.succeed Nothing)
        |> Task.andThen
            (\result ->
                case result of
                    Just ( sha, entries ) ->
                        onSuccess
                            ( sha
                            , List.map (\entry -> Zip.Entry entry.name (Utf8.decode entry.data)) entries
                            )

                    Nothing ->
                        Task.succeed (Err defaultError)
            )



-- ====== ENCODERS and DECODERS ======


{-| Encodes an error as its URL, status code and status text.
-}
errorEncoder : Error -> Bytes.Encode.Encoder
errorEncoder (BadHttp url code text) =
    Bytes.Encode.sequence
        [ BE.string url
        , BE.int code
        , BE.string text
        ]


{-| A decoder for an error as `errorEncoder` writes it.
-}
errorDecoder : Bytes.Decode.Decoder Error
errorDecoder =
    Bytes.Decode.map3 BadHttp
        BD.string
        BD.int
        BD.string
