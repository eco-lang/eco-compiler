module Momento exposing
    ( Ports
    , MomentoApi, momentoApi
    , CacheItem
    , OpenParams, MomentoSessionKey
    , PushListParams
    , WebhookParams
    , SubscribeParams, PublishParams
    , Error, errorToDetails, errorToString
    )

{-| A wrapper around the GoMomento serverless cache API.


# Ports

@docs Ports


# Packaged API

@docs MomentoApi, momentoApi
@docs CacheItem


# Synchronous operations

@docs OpenParams, MomentoSessionKey
@docs PushListParams
@docs WebhookParams


# Asynchronous operations

@docs SubscribeParams, PublishParams


# Error reporting

@docs Error, errorToDetails, errorToString

-}

import Json.Encode as Encode exposing (Value)
import Procedure
import Procedure.Channel as Channel
import Procedure.Program



-- API


{-| The ports that need to be wired up to momento.js
-}
type alias Ports msg =
    { open : { id : String, cache : String, apiKey : String } -> Cmd msg
    , close : { id : String, session : Value } -> Cmd msg
    , subscribe : { id : String, session : Value, topic : String } -> Cmd msg
    , publish : { id : String, session : Value, topic : String, payload : Value } -> Cmd msg
    , onMessage : ({ id : String, session : Value, payload : Value } -> msg) -> Sub msg
    , pushList : { id : String, session : Value, list : String, payload : Value } -> Cmd msg
    , popList : { id : String, session : Value, list : String } -> Cmd msg
    , createWebhook : { id : String, session : Value, name : String, topic : String, url : String } -> Cmd msg
    , response : ({ id : String, type_ : String, response : Value } -> msg) -> Sub msg
    , asyncError : ({ id : String, error : Value } -> msg) -> Sub msg
    }


{-| The Momento API.
-}
type alias MomentoApi msg =
    { open : OpenParams -> (Result Error MomentoSessionKey -> msg) -> Cmd msg
    , subscribe : MomentoSessionKey -> SubscribeParams -> (Result Error () -> msg) -> Cmd msg
    , pushList : MomentoSessionKey -> PushListParams -> (Result Error () -> msg) -> Cmd msg
    , popList : MomentoSessionKey -> PopListParams -> (Result Error (Maybe CacheItem) -> msg) -> Cmd msg
    , webhook : MomentoSessionKey -> WebhookParams -> (Result Error () -> msg) -> Cmd msg
    , publish : MomentoSessionKey -> PublishParams -> (Result Error () -> msg) -> Cmd msg
    , onMessage : (Value -> msg) -> Sub msg
    , asyncError : (Error -> msg) -> Sub msg
    }


{-| Creates an instance of the Momento API.
-}
momentoApi : (Procedure.Program.Msg msg -> msg) -> Ports msg -> MomentoApi msg
momentoApi pt ports =
    { open = open pt ports
    , subscribe = subscribe pt ports
    , pushList = pushList pt ports
    , popList = popList pt ports
    , webhook = webhook pt ports
    , publish = publish pt ports
    , onMessage = onMessage ports
    , asyncError = asyncError ports
    }


{-| A key containing session details that must be passed to all Momento operations after opening a Cache.
-}
type MomentoSessionKey
    = MomentoSessionKey Value


{-| Parameters for the Cache Open operation
-}
type alias OpenParams =
    { cache : String, apiKey : String }


{-| Parameters for the Topic Subscribe operation
-}
type alias SubscribeParams =
    { topic : String }


{-| Parameters for the Topic Publish operation
-}
type alias PublishParams =
    { topic : String, payload : Value }


{-| Parameters for the PushList operation
-}
type alias PushListParams =
    { list : String, payload : Value }


{-| Parameters for the PopList operation
-}
type alias PopListParams =
    { list : String }


{-| A JSON item in the Momento cache.
-}
type alias CacheItem =
    { payload : Value }


{-| Parameters for the Topic CreateWebhook operation.
-}
type alias WebhookParams =
    { name : String, topic : String, url : String }


{-| Possible errors arising from Momento operations.
-}
type Error
    = MomentoError { message : String, details : Value }


{-| Turns Momento errors into strings.
-}
errorToString : Error -> String
errorToString _ =
    "Momento Error"


{-| Turns Momento errors into a format with a message and further details as JSON.

The details should provide some way to trace the error, such as a stacktrace
or parameters and so on.

-}
errorToDetails : Error -> { message : String, details : Value }
errorToDetails (MomentoError err) =
    err



-- Implementation


decodeResponse : { a | type_ : String, response : Value } -> Result Error ()
decodeResponse res =
    case res.type_ of
        "Ok" ->
            Ok ()

        "Error" ->
            MomentoError
                { message = "MomentoError"
                , details = res.response
                }
                |> Err

        _ ->
            MomentoError
                { message = "Momento Unknown response type: " ++ res.type_
                , details = Encode.null
                }
                |> Err


decodeResponseWithSessionKey : { a | type_ : String, response : Value } -> Result Error MomentoSessionKey
decodeResponseWithSessionKey res =
    case res.type_ of
        "Ok" ->
            MomentoSessionKey res.response |> Ok

        "Error" ->
            MomentoError
                { message = "MomentoError"
                , details = res.response
                }
                |> Err

        _ ->
            MomentoError
                { message = "Momento Unknown response type: " ++ res.type_
                , details = Encode.null
                }
                |> Err


decodeItemResponse : { a | type_ : String, response : Value } -> Result Error (Maybe CacheItem)
decodeItemResponse res =
    case res.type_ of
        "Item" ->
            Just { payload = res.response } |> Ok

        "ItemNotFound" ->
            Ok Nothing

        "Error" ->
            MomentoError
                { message = "MomentoError"
                , details = res.response
                }
                |> Err

        _ ->
            MomentoError
                { message = "Momento Unknown response type: " ++ res.type_
                , details = Encode.null
                }
                |> Err


open :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> OpenParams
    -> (Result Error MomentoSessionKey -> msg)
    -> Cmd msg
open pt ports openParams dt =
    Channel.open (\key -> ports.open { id = key, cache = openParams.cache, apiKey = openParams.apiKey })
        |> Channel.connect ports.response
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeResponseWithSessionKey res |> dt)


subscribe :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MomentoSessionKey
    -> SubscribeParams
    -> (Result Error () -> msg)
    -> Cmd msg
subscribe pt ports (MomentoSessionKey sessionKey) subscribeParams dt =
    Channel.open (\key -> ports.subscribe { id = key, session = sessionKey, topic = subscribeParams.topic })
        |> Channel.connect ports.response
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeResponse res |> dt)


{-| Pushes to the back of the list.
-}
pushList :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MomentoSessionKey
    -> PushListParams
    -> (Result Error () -> msg)
    -> Cmd msg
pushList pt ports (MomentoSessionKey sessionKey) { list, payload } dt =
    Channel.open (\key -> ports.pushList { id = key, session = sessionKey, list = list, payload = payload })
        |> Channel.connect ports.response
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeResponse res |> dt)


{-| Pops from the front of the list.
-}
popList :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MomentoSessionKey
    -> PopListParams
    -> (Result Error (Maybe CacheItem) -> msg)
    -> Cmd msg
popList pt ports (MomentoSessionKey sessionKey) { list } dt =
    Channel.open (\key -> ports.popList { id = key, session = sessionKey, list = list })
        |> Channel.connect ports.response
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeItemResponse res |> dt)


webhook :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MomentoSessionKey
    -> WebhookParams
    -> (Result Error () -> msg)
    -> Cmd msg
webhook pt ports (MomentoSessionKey sessionKey) { name, topic, url } dt =
    Channel.open (\key -> ports.createWebhook { id = key, session = sessionKey, name = name, topic = topic, url = url })
        |> Channel.connect ports.response
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeResponse res |> dt)


{-| Publishes a message on a topic. Publish is asynchronous and will not generate a response message in Elm,
but may report errors on the asyncError subscription.
-}
publish :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MomentoSessionKey
    -> PublishParams
    -> (Result Error () -> msg)
    -> Cmd msg
publish pt ports (MomentoSessionKey sessionKey) { topic, payload } dt =
    --ports.publish { id = "", session = sessionKey, topic = topic, payload = payload }
    Channel.open
        (\key -> ports.publish { id = key, session = sessionKey, topic = topic, payload = payload })
        |> Channel.connect ports.response
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeResponse res |> dt)


{-| Receives new incoming messages on a topic subscription.
-}
onMessage : Ports msg -> (Value -> msg) -> Sub msg
onMessage ports dt =
    ports.onMessage
        (\{ session, payload } ->
            let
                _ =
                    Debug.log "Momento.onMessage" "called"
            in
            dt payload
        )


asyncError : Ports msg -> (Error -> msg) -> Sub msg
asyncError ports dt =
    ports.asyncError
        (\{ error } ->
            { message = "MomentoPorts Async Error", details = error } |> MomentoError |> dt
        )
