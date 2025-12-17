module Builder.Http exposing
    ( Manager, getManager, managerEncoder, managerDecoder
    , get, post, upload
    , toUrl
    , Header, accept
    , getArchive, Sha, shaToChars
    , MultiPart, filePart, jsonPart, stringPart
    , Error(..), errorEncoder, errorDecoder
    )

{-| HTTP client utilities for package downloads and uploads.

This module provides a high-level HTTP interface for the Elm package manager,
handling package downloads, archive fetching with SHA verification, and
multipart uploads for package publishing.


# HTTP Manager

@docs Manager, getManager, managerEncoder, managerDecoder


# Making Requests

@docs get, post, upload


# URL Construction

@docs toUrl


# Headers

@docs Header, accept


# Archive Downloads

@docs getArchive, Sha, shaToChars


# Multipart Uploads

@docs MultiPart, filePart, jsonPart, stringPart


# Error Handling

@docs Error, errorEncoder, errorDecoder

-}

import Basics.Extra exposing (uncurry)
import Bytes.Decode
import Bytes.Encode
import Codec.Archive.Zip as Zip
import Compiler.Elm.Version as V
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)
import Url.Builder
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Impure as Impure
import Utils.Main as Utils exposing (SomeException)



-- MANAGER


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



-- URL


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



-- FETCH


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
fetch method _ url headers _ onSuccess =
    Impure.customTask method
        url
        (List.map (\( a, b ) -> Http.header a b) (addDefaultHeaders headers))
        Impure.EmptyBody
        (Impure.StringResolver identity)
        |> Task.andThen onSuccess


addDefaultHeaders : List Header -> List Header
addDefaultHeaders headers =
    ( "User-Agent", userAgent ) :: ( "Accept-Encoding", "gzip" ) :: headers


userAgent : String
userAgent =
    "elm/" ++ V.toChars V.compiler


{-| Creates an Accept header with the given MIME type.
-}
accept : String -> Header
accept mime =
    ( "Accept", mime )



-- EXCEPTIONS


{-| Represents HTTP request errors including URL problems, HTTP errors, and unexpected failures.
-}
type Error
    = BadUrl String String
    | BadHttp String Utils.HttpExceptionContent
    | BadMystery String SomeException



-- SHA


{-| Represents a SHA hash as a string for package integrity verification.
-}
type alias Sha =
    String


{-| Converts a SHA hash to its string representation.
-}
shaToChars : Sha -> String
shaToChars =
    identity



-- FETCH ARCHIVE


{-| Downloads a package archive from a URL, returning the SHA hash and archive contents.
-}
getArchive : Manager -> String -> (Error -> e) -> e -> (( Sha, Zip.Archive ) -> Task Never (Result e a)) -> Task Never (Result e a)
getArchive _ url _ _ onSuccess =
    Impure.task "getArchive"
        []
        (Impure.StringBody url)
        (Impure.DecoderResolver
            (Decode.map2 Tuple.pair
                (Decode.field "sha" Decode.string)
                (Decode.field "archive"
                    (Decode.list
                        (Decode.map2 Zip.Entry
                            (Decode.field "eRelativePath" Decode.string)
                            (Decode.field "eData" Decode.string)
                        )
                    )
                )
            )
        )
        |> Task.andThen onSuccess



-- UPLOAD


{-| Represents parts of a multipart form upload.
-}
type MultiPart
    = FilePart String String
    | JsonPart String String Encode.Value
    | StringPart String String


{-| Uploads multipart form data to a URL.
-}
upload : Manager -> String -> List MultiPart -> Task Never (Result Error ())
upload _ url parts =
    Impure.task "httpUpload"
        []
        (Impure.JsonBody
            (Encode.object
                [ ( "urlStr", Encode.string url )
                , ( "headers", Encode.object (List.map (Tuple.mapSecond Encode.string) (addDefaultHeaders [])) )
                , ( "parts"
                  , Encode.list
                        (\part ->
                            case part of
                                FilePart name filePath ->
                                    Encode.object
                                        [ ( "type", Encode.string "FilePart" )
                                        , ( "name", Encode.string name )
                                        , ( "filePath", Encode.string filePath )
                                        ]

                                JsonPart name filePath value ->
                                    Encode.object
                                        [ ( "type", Encode.string "JsonPart" )
                                        , ( "name", Encode.string name )
                                        , ( "filePath", Encode.string filePath )
                                        , ( "value", value )
                                        ]

                                StringPart name string ->
                                    Encode.object
                                        [ ( "type", Encode.string "StringPart" )
                                        , ( "name", Encode.string name )
                                        , ( "string", Encode.string string )
                                        ]
                        )
                        parts
                  )
                ]
            )
        )
        (Impure.Always (Ok ()))


{-| Creates a file part for multipart upload with a field name and file path.
-}
filePart : String -> String -> MultiPart
filePart name filePath =
    FilePart name filePath


{-| Creates a JSON part for multipart upload with a field name, file path, and JSON value.
-}
jsonPart : String -> String -> Encode.Value -> MultiPart
jsonPart name filePath value =
    JsonPart name filePath value


{-| Creates a string part for multipart upload with a field name and string value.
-}
stringPart : String -> String -> MultiPart
stringPart name string =
    StringPart name string



-- ENCODERS and DECODERS


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
