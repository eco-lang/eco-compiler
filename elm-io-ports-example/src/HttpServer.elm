module HttpServer exposing
    ( Ports, Protocol
    , HttpServerApi, httpServerApi
    , HttpSessionKey, ApiRequest
    , Error(..), errorToDetails, errorToString
    , sessionKeyFromCallback
    )

{-| An API for running the server side of an HTTP and implementing an HTTP API.


# Ports and Protocol

@docs Ports, Protocol


# Packaged API and related data models

@docs HttpServerApi, httpServerApi
@docs HttpSessionKey, ApiRequest


# Error reporting

@docs Error, errorToDetails, errorToString


# Special operations

@docs sessionKeyFromCallback

-}

import Http.Request as Request
import Http.Response as Response exposing (Response)
import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)
import Url exposing (Url)


{-| An HTTP Request to an API endpoint.
-}
type alias ApiRequest route =
    { route : route
    , request : Request.Request
    }


{-| An "session key" that spans an entire HTTP request.

A request will arrive with a session key, and outgoing responses must provide that same
key when responding in order to link the request and response together.

-}
type HttpSessionKey
    = HttpSessionKey Value -- This actually holds the `callback` in an util.promisify()


{-| The HttpSessionKey wraps a javascript object that is used to wrap a `callback` in an util.promisify().
It is intended to be fully opaque. But there is a need to allow other services, such as AWS Lambda functions
that can be triggered by SQS, EventBridge, SNS and so on. These services may respond via the HttpServer API
and therefore need an `HttpSessionKey`.

This function allows creation of an HttpSessionKey from a value. It is not intended for use in your
application.

-}
sessionKeyFromCallback : Value -> HttpSessionKey
sessionKeyFromCallback =
    HttpSessionKey


{-| The ports that need to be wired up to @the-sett/elm-httpserver.
-}
type alias Ports msg =
    { request : ({ session : Value, req : Value } -> msg) -> Sub msg
    , response : { session : Value, res : Value } -> Cmd msg
    }


{-| A protocol defining the ports and route parser neede to build the HttpServer API.
-}
type alias Protocol msg route =
    { ports : Ports msg
    , parseRoute : Url -> Maybe route
    }


{-| The HttpServer API.
-}
type alias HttpServerApi msg route =
    { request : (HttpSessionKey -> Result Error (ApiRequest route) -> msg) -> Sub msg
    , response : HttpSessionKey -> Response -> Cmd msg
    }


{-| Builds an instance of the HttpServer API.
-}
httpServerApi : Protocol msg route -> HttpServerApi msg route
httpServerApi protocol =
    { request = requestSub protocol
    , response = responseCmd protocol
    }


{-| Possible errors arising from HttpServer operations.
-}
type Error
    = NoMatchingRoute String
    | InvalidRequestFormat Decode.Error


{-| Turns HttpServer errors into strings.
-}
errorToString : Error -> String
errorToString error =
    case error of
        NoMatchingRoute url ->
            "No matching route for: " ++ url

        InvalidRequestFormat decodeError ->
            "Problem decoding the request: " ++ Decode.errorToString decodeError


{-| Turns HttpServer errors into a format with a message and further details as JSON.

The details should provide some way to trace the error, such as a stacktrace
or parameters and so on.

-}
errorToDetails : Error -> { message : String, details : Value }
errorToDetails error =
    case error of
        NoMatchingRoute url ->
            { message = "No matching route for: " ++ url
            , details = Encode.null
            }

        InvalidRequestFormat decodeError ->
            { message = "Problem decoding the request: " ++ Decode.errorToString decodeError
            , details = Encode.null
            }


requestSub :
    Protocol msg route
    -> (HttpSessionKey -> Result Error (ApiRequest route) -> msg)
    -> Sub msg
requestSub protocol requestFn =
    let
        fn { session, req } =
            decodeRequestAndRoute req protocol.parseRoute
                |> Result.map
                    (\( request, route ) ->
                        { request = request
                        , route = route
                        }
                    )
                |> requestFn (HttpSessionKey session)
    in
    Sub.map identity (protocol.ports.request fn)


decodeRequestAndRoute : Value -> (Url -> Maybe route) -> Result Error ( Request.Request, route )
decodeRequestAndRoute rawRequest parseRoute =
    Decode.decodeValue Request.decoder rawRequest
        |> Result.mapError InvalidRequestFormat
        |> Result.andThen
            (\req ->
                Request.url req
                    |> Url.fromString
                    |> Maybe.andThen parseRoute
                    |> (\maybeRoute ->
                            case maybeRoute of
                                Nothing ->
                                    Request.url req |> NoMatchingRoute |> Err

                                Just route ->
                                    Ok ( req, route )
                       )
            )


responseCmd : Protocol msg route -> HttpSessionKey -> Response -> Cmd msg
responseCmd protocol (HttpSessionKey session) response =
    protocol.ports.response { session = session, res = Response.encode response }
