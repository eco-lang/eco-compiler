module Builder.Http exposing
    ( Manager, getManager, managerEncoder, managerDecoder
    , get, post
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
@docs Header
@docs getArchive, Sha, shaToChars
@docs Error, errorEncoder, errorDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Codec.Archive.Zip as Zip
import Compiler.Elm.Version_Build as Version_Build
import Eco.Http
import Eco.Http.Error as HttpErr exposing (HttpError)
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

A bad status keeps its code and text. A network failure becomes status code 0
with the failure's detail as the status text, meaning that no HTTP response was
received.

-}
fromHttpError : String -> HttpError -> Error
fromHttpError url httpErr =
    case httpErr of
        HttpErr.BadStatus r ->
            BadHttp url r.statusCode r.statusText

        HttpErr.Network r ->
            BadHttp url 0 r.detail


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
