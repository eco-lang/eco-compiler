module SqsLambda exposing
    ( Ports
    , SqsEventApi, sqsEventApi
    , SqsEvent
    , Error(..), errorToDetails, errorToString
    )

{-| An API for running the server side of an HTTP and implementing an HTTP API.


# Ports and Protocol

@docs Ports


# Packaged API and related data models

@docs SqsEventApi, sqsEventApi
@docs SqsEvent


# Error reporting

@docs Error, errorToDetails, errorToString

-}

import HttpServer exposing (HttpSessionKey)
import Json.Decode as Decode
import Json.Decode.Extra as DE
import Json.Encode as Encode exposing (Value)


{-| An HTTP Request to an API endpoint.
-}
type alias SqsEvent =
    List SqsMessage


type alias SqsMessage =
    { messageId : String
    , body : String
    }


{-| The ports that need to be wired up to @the-sett/elm-httpserver.
-}
type alias Ports msg =
    { sqsLambdaSubscribe : ({ session : Value, req : Value } -> msg) -> Sub msg
    }


{-| The SqsLambda API.
-}
type alias SqsEventApi msg =
    { event : (HttpSessionKey -> Result Error SqsEvent -> msg) -> Sub msg
    }


{-| Builds an instance of the SqsEventApi API.
-}
sqsEventApi : Ports msg -> SqsEventApi msg
sqsEventApi ports =
    { event = requestSub ports
    }


{-| Possible errors arising from SqsLambda operations.
-}
type Error
    = InvalidRequestFormat Decode.Error


{-| Turns SqsLambda errors into strings.
-}
errorToString : Error -> String
errorToString error =
    case error of
        InvalidRequestFormat decodeError ->
            "Problem decoding the request: " ++ Decode.errorToString decodeError


{-| Turns SqsLambda errors into a format with a message and further details as JSON.

The details should provide some way to trace the error, such as a stacktrace
or parameters and so on.

-}
errorToDetails : Error -> { message : String, details : Value }
errorToDetails error =
    case error of
        InvalidRequestFormat decodeError ->
            { message = "Problem decoding the request: " ++ Decode.errorToString decodeError
            , details = Encode.null
            }


requestSub :
    Ports msg
    -> (HttpSessionKey -> Result Error SqsEvent -> msg)
    -> Sub msg
requestSub ports requestFn =
    let
        fn { session, req } =
            decodeRequestAndRoute req
                |> requestFn (HttpServer.sessionKeyFromCallback session)
    in
    Sub.map identity (ports.sqsLambdaSubscribe fn)


decodeRequestAndRoute : Value -> Result Error SqsEvent
decodeRequestAndRoute rawRequest =
    let
        eventDecoder =
            Decode.succeed SqsMessage
                |> DE.andMap (Decode.field "messageId" Decode.string)
                |> DE.andMap (Decode.field "body" Decode.string)

        decoder =
            Decode.field "Records" (eventDecoder |> Decode.list)
    in
    Decode.decodeValue decoder rawRequest
        |> Result.mapError InvalidRequestFormat
