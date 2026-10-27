module Builder.Http exposing
    ( Manager, getManager, managerEncoder, managerDecoder
    , get, post
    , toUrl
    , Header
    , getArchive, Sha, shaToChars
    , Error(..), errorEncoder, errorDecoder
    )

{-| Gives the package-manager code one way to make HTTP requests, and one
error type for their failures.

The requests themselves are made by `Eco.Http`, whose docstring says which
failures come back as an `Err` and which crash the program. This module adds
two request headers to every `get` and `post`, hands the response body to the
caller's continuation, and turns a failure into an `Error`. `get`, `post` and
`getArchive` return `Task Never (Result e a)`. `get` and `post` take a
function from `Error` to the caller's error type, while `getArchive` takes a
fixed error value that it returns for any failure.

A _manager_ is the value a caller threads through to every request. It carries
nothing, and no function here reads it.

Archives are fetched by `getArchive`, which returns the archive's SHA and its
entries as a `Codec.Archive.Zip.Archive`.

@docs Manager, getManager, managerEncoder, managerDecoder
@docs get, post
@docs toUrl
@docs Header
@docs getArchive, Sha, shaToChars
@docs Error, errorEncoder, errorDecoder

-}

import Basics.Extra exposing (uncurry)
import Bytes.Decode
import Bytes.Encode
import Codec.Archive.Zip as Zip
import Compiler.Elm.Version_Build as Version_Build
import Eco.Http
import Eco.Http.Error as HttpErr exposing (HttpError)
import Task exposing (Task)
import Url.Builder
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils exposing (SomeException)



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



-- ====== URL ======


{-| Returns `url` with `params` appended as a percent-encoded query string
beginning with `?`, or `url` unchanged when `params` is empty.

`url` is expected to have no query string of its own; one is not detected.

-}
toUrl : String -> List ( String, String ) -> String
toUrl url params =
    case params of
        [] ->
            url

        _ :: _ ->
            url ++ urlEncodeVars params


{-| Returns `params` as a percent-encoded query string, including the leading
`?`.
-}
urlEncodeVars : List ( String, String ) -> String
urlEncodeVars params =
    Url.Builder.toQuery (List.map (uncurry Url.Builder.string) params)



-- ====== FETCH ======


{-| An HTTP request header: its name, then its value.
-}
type alias Header =
    ( String, String )


{-| Sends a GET request to the URL with `headers`, and runs the continuation
on the response body.

A `User-Agent` of `elm/` and the compiler's version and an `Accept-Encoding`
of `gzip` are added in front of `headers`. A failure gives `Err` of the
`Error`, converted by the caller's function: a failure `Eco.Http` reports as
a bad URL gives `BadUrl`, and every other failure gives `BadHttp` with a
`StatusCodeException` whose status is the response's, or code 0 with the
failure's detail as its text when no status was received. The exception's
headers and body are always empty.

-}
get : Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
get =
    fetch "GET"


{-| Sends a POST request with no body, otherwise exactly as `get` does.
-}
post : Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
post =
    fetch "POST"


{-| Sends a request with `method`, adding the default headers, and returns
the continuation's result on success or the converted `Error` on failure.
-}
fetch : String -> Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
fetch method _ url headers onError onSuccess =
    Eco.Http.fetch method url (addDefaultHeaders headers)
        |> Task.andThen
            (\result ->
                case result of
                    Ok body ->
                        onSuccess body

                    Err httpErr ->
                        Task.succeed (Err (onError (fromHttpError url httpErr)))
            )


{-| Converts a failure of the request to `url` into an `Error`.

`BadUrl` stays `BadUrl`. A bad status keeps its code and text. Every other kind
of failure, network, timeout, TLS, body decoding or other, becomes status code
0 with the failure's detail or message as the status text, meaning that no
HTTP response was received.

-}
fromHttpError : String -> HttpError -> Error
fromHttpError url httpErr =
    case httpErr of
        HttpErr.BadUrl badUrl reason ->
            BadUrl badUrl reason

        HttpErr.BadStatus r ->
            statusException url r.statusCode r.statusText

        HttpErr.Network r ->
            statusException url 0 r.detail

        HttpErr.Timeout r ->
            statusException url 0 r.detail

        HttpErr.Tls r ->
            statusException url 0 r.detail

        HttpErr.BodyDecode r ->
            statusException url 0 r.detail

        HttpErr.OtherHttp r ->
            statusException url 0 r.message


{-| Builds a `BadHttp` error for `url` as a status-code exception with the
given code and text, no headers and an empty body.
-}
statusException : String -> Int -> String -> Error
statusException url statusCode statusText =
    BadHttp url
        (Utils.StatusCodeException
            (Utils.HttpResponse
                { responseStatus = Utils.HttpStatus statusCode statusText
                , responseHeaders = []
                }
            )
            ""
        )


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


{-| Why a request failed, each case carrying the URL that was requested.

`BadUrl` carries the URL and the reason it was rejected.

`BadHttp` carries the failure as an `HttpExceptionContent`. This module builds
it only as a status-code exception, where code 0 means no response arrived.

`BadMystery` carries an exception of unknown kind. Nothing in this module
produces one.

-}
type Error
    = BadUrl String String
    | BadHttp String Utils.HttpExceptionContent
    | BadMystery String SomeException



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
No headers are added. The meaning of the SHA is as `Eco.Http.getArchive`
describes.

-}
getArchive : String -> e -> (( Sha, Zip.Archive ) -> Task Never (Result e a)) -> Task Never (Result e a)
getArchive url defaultError onSuccess =
    Eco.Http.getArchive url
        |> Task.andThen
            (\result ->
                case result of
                    Ok { sha, archive } ->
                        onSuccess
                            ( sha
                            , List.map (\entry -> Zip.Entry entry.relativePath entry.data) archive
                            )

                    Err _ ->
                        Task.succeed (Err defaultError)
            )



-- ====== ENCODERS and DECODERS ======


{-| Encodes an error as a tag byte, 0, 1 or 2 in constructor order, then its
URL and payload.
-}
errorEncoder : Error -> Bytes.Encode.Encoder
errorEncoder error =
    case error of
        BadUrl url reason ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string url
                , BE.string reason
                ]

        BadHttp url httpExceptionContent ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string url
                , Utils.httpExceptionContentEncoder httpExceptionContent
                ]

        BadMystery url _ ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string url
                , Utils.someExceptionEncoder
                ]


{-| A decoder for an error as `errorEncoder` writes it. An unknown tag byte
fails.
-}
errorDecoder : Bytes.Decode.Decoder Error
errorDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 BadUrl
                            BD.string
                            BD.string

                    1 ->
                        Bytes.Decode.map2 BadHttp
                            BD.string
                            Utils.httpExceptionContentDecoder

                    2 ->
                        Bytes.Decode.map2 BadMystery
                            BD.string
                            Utils.someExceptionDecoder

                    _ ->
                        Bytes.Decode.fail
            )
