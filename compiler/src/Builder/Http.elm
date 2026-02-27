module Builder.Http exposing
    ( Manager, getManager, managerEncoder, managerDecoder
    , get, post
    , toUrl
    , Header
    , getArchive, Sha, shaToChars
    , Error(..), errorEncoder, errorDecoder
    )

{-| HTTP client utilities for the Elm package manager.

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
import Compiler.Elm.Version as V
import Eco.Http
import Task exposing (Task)
import Url.Builder
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils exposing (SomeException)



-- ====== MANAGER ======


{-| Represents an HTTP client manager for making requests.
-}
type Manager
    = Manager


{-| Encodes an HTTP manager to bytes for serialization.
-}
managerEncoder : Manager -> Bytes.Encode.Encoder
managerEncoder _ =
    Bytes.Encode.unsignedInt8 0


{-| Decodes an HTTP manager from bytes.
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


{-| Creates a new HTTP manager for making requests.
-}
getManager : Task Never Manager
getManager =
    -- TODO newManager tlsManagerSettings
    Task.succeed Manager



-- ====== URL ======


{-| Constructs a URL with query parameters from a base URL and parameter list.
-}
toUrl : String -> List ( String, String ) -> String
toUrl url params =
    case params of
        [] ->
            url

        _ :: _ ->
            url ++ urlEncodeVars params


urlEncodeVars : List ( String, String ) -> String
urlEncodeVars params =
    -- includes the `?`
    Url.Builder.toQuery (List.map (uncurry Url.Builder.string) params)



-- ====== FETCH ======


{-| Represents an HTTP header as a name-value pair.
-}
type alias Header =
    ( String, String )


{-| Performs an HTTP GET request with the given headers and result handler.
-}
get : Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
get =
    fetch "GET"


{-| Performs an HTTP POST request with the given headers and result handler.
-}
post : Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
post =
    fetch "POST"


fetch : String -> Manager -> String -> List Header -> (Error -> e) -> (String -> Task Never (Result e a)) -> Task Never (Result e a)
fetch method _ url headers onError onSuccess =
    Eco.Http.fetch method url (addDefaultHeaders headers)
        |> Task.andThen
            (\result ->
                case result of
                    Ok body ->
                        onSuccess body

                    Err { statusCode, statusText } ->
                        Task.succeed
                            (Err
                                (onError
                                    (BadHttp url
                                        (Utils.StatusCodeException
                                            (Utils.HttpResponse
                                                { responseStatus = Utils.HttpStatus statusCode statusText
                                                , responseHeaders = []
                                                }
                                            )
                                            ""
                                        )
                                    )
                                )
                            )
            )


addDefaultHeaders : List Header -> List Header
addDefaultHeaders headers =
    ( "User-Agent", userAgent ) :: ( "Accept-Encoding", "gzip" ) :: headers


userAgent : String
userAgent =
    "elm/" ++ V.toChars V.compiler



-- ====== EXCEPTIONS ======


{-| Represents HTTP request errors including URL problems, HTTP errors, and unexpected failures.
-}
type Error
    = BadUrl String String
    | BadHttp String Utils.HttpExceptionContent
    | BadMystery String SomeException



-- ====== SHA ======


{-| Represents a SHA hash as a string for package integrity verification.
-}
type alias Sha =
    String


{-| Converts a SHA hash to its string representation.
-}
shaToChars : Sha -> String
shaToChars =
    identity



-- ====== FETCH ARCHIVE ======


{-| Downloads a package archive from a URL, returning the SHA hash and archive contents.
-}
getArchive : Manager -> String -> (Error -> e) -> e -> (( Sha, Zip.Archive ) -> Task Never (Result e a)) -> Task Never (Result e a)
getArchive _ url _ defaultError onSuccess =
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


{-| Encodes an HTTP error to bytes for serialization.
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

        BadMystery url someException ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string url
                , Utils.someExceptionEncoder someException
                ]


{-| Decodes an HTTP error from bytes.
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
