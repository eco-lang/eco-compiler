module Realtime exposing
    ( Config
    , Model, Delta
    , RealtimeApi, realtimeApi
    , AsyncEvent(..), RTMessage(..), Snapshot, next
    , Error, errorToDetails, errorToString
    , SnapshotEvent, SnapshotRequestEvent, UnsavedEvent, encodePersistedEvent, encodeSnapshotEvent, encodeSnapshotRequestEvent, persistedEventDecoder, snapshotEventDecoder, snapshotRequestEventDecoder, transientEventDecoder, unsavedEventDecoder
    )

{-| Realtime channels.


# Set up and step the model.

@docs Config
@docs Model, Delta


# The Realtime API

@docs RealtimeApi, realtimeApi
@docs AsyncEvent, RTMessage, Snapshot, next


# Error reporting

@docs Error, errorToDetails, errorToString

-}

import Http exposing (Error(..))
import Json.Decode as Decode exposing (Decoder)
import Json.Decode.Extra as DE
import Json.Encode as Encode exposing (Value)
import Momento exposing (Error, MomentoSessionKey, OpenParams, SubscribeParams)
import Procedure exposing (Procedure)
import Procedure.Program
import Random


{-| Configuration parameters.
-}
type alias Config =
    { rtChannelApiUrl : String
    , momentoApiKey : String
    }


{-| The Realtime API.
-}
type alias RealtimeApi msg =
    { init : Config -> Model
    , join : Model -> (Delta (Result Error (List RTMessage)) -> msg) -> Cmd msg
    , publishPersisted : Model -> Value -> (Delta (Maybe Error) -> msg) -> Cmd msg
    , publishTransient : Model -> Value -> (Delta (Maybe Error) -> msg) -> Cmd msg
    , subscribe : Model -> (Delta AsyncEvent -> msg) -> Sub msg
    }


{-| Provides an instance of the Realtime API.
-}
realtimeApi : (Procedure.Program.Msg msg -> msg) -> Momento.Ports msg -> RealtimeApi msg
realtimeApi pt ports =
    { init = init
    , join = join pt ports
    , publishPersisted = publishPersisted pt ports
    , publishTransient = publishTransient pt ports
    , subscribe = subscribe pt ports
    }


{-| Applied a Delta to the Model to derive a new Model and a data element.
-}
next : Delta a -> Model -> ( Model, a )
next (Delta delta) model =
    delta model


{-| A Snapshot of a realtime distributed data model.

The seq number will match the sequence number of the persisted event in the event log that can be interpreted to
reach this snapshot state.

-}
type alias Snapshot a =
    { seq : Int
    , model : a
    }


{-| The Realtime model tracking the state of the messaging system.
-}
type Model
    = Private Implementation


type alias Implementation =
    { rtChannelApiUrl : String
    , momentoApiKey : String
    , state : State
    , preJoinEvents : List RTMessage
    }


{-| A Delta represents a change that can be applied to the Model and will also provide a data element when it is.
-}
type Delta a
    = Delta (Model -> ( Model, a ))


type State
    = StartState
    | RunningState RunningProps
    | FailedState Error


type alias JoiningProps =
    { sessionKey : MomentoSessionKey
    , seed : Random.Seed
    , channel : Channel
    , joinEvents : List RTMessage
    }


type alias RunningProps =
    { sessionKey : MomentoSessionKey
    , seed : Random.Seed
    , channel : Channel
    }


type alias Channel =
    { id : String
    , modelTopic : String
    , saveTopic : String
    , saveList : String
    , webhook : String
    }


channelDecoder : Decoder Channel
channelDecoder =
    Decode.succeed Channel
        |> DE.andMap (Decode.field "id" Decode.string)
        |> DE.andMap (Decode.field "modelTopic" Decode.string)
        |> DE.andMap (Decode.field "saveTopic" Decode.string)
        |> DE.andMap (Decode.field "saveList" Decode.string)
        |> DE.andMap (Decode.field "webhook" Decode.string)


buildMomentoApi : (Procedure.Program.Msg msg -> msg) -> Momento.Ports msg -> Momento.MomentoApi msg
buildMomentoApi pt ports =
    { open = ports.open
    , close = ports.close
    , subscribe = ports.subscribe
    , publish = ports.publish
    , onMessage = ports.onMessage
    , pushList = ports.pushList
    , popList = ports.popList
    , createWebhook = ports.createWebhook
    , response = ports.response
    , asyncError = ports.asyncError
    }
        |> Momento.momentoApi pt



-- Error reporting.


{-| Possible errors arising from Realtime operations.
-}
type Error
    = HttpError Http.Error
    | MomentoError Momento.Error
    | DecodeError Decode.Error
    | JoinError String


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        BadUrl val ->
            "Bad Url: " ++ val

        Timeout ->
            "HTTP Timeout"

        NetworkError ->
            "Network Error"

        BadStatus status ->
            "BadStatus: " ++ String.fromInt status

        BadBody val ->
            "Bad Body: " ++ val


{-| Turns Realtime errors into strings.
-}
errorToString : Error -> String
errorToString err =
    case err of
        HttpError httpError ->
            httpErrorToString httpError

        MomentoError momentoErr ->
            Momento.errorToString momentoErr

        DecodeError decodeErr ->
            Decode.errorToString decodeErr

        JoinError msg ->
            msg


{-| Turns Realtime errors into a format with a message and further details as JSON.

The details should provide some way to trace the error, such as a stacktrace
or parameters and so on.

-}
errorToDetails : Error -> { message : String, details : Value }
errorToDetails err =
    case err of
        HttpError _ ->
            Debug.todo "HttpError"

        MomentoError momentoErr ->
            Momento.errorToDetails momentoErr

        DecodeError decodeErr ->
            { message = Decode.errorToString decodeErr, details = Encode.null }

        JoinError msg ->
            { message = msg, details = Encode.null }



-- Initialization procedure.


{-| Initializeds the channel with its configuration.
-}
init : Config -> Model
init props =
    { rtChannelApiUrl = props.rtChannelApiUrl
    , momentoApiKey = props.momentoApiKey
    , state = StartState
    , preJoinEvents = []
    }
        |> Private


{-| Joins the realtime channel in order to start an event flow:

    * Fetches the channel details from the Channel API.
    * Opens a connection to Momento.
    * Subscribes to the model topic for the channel.
    * Keeps any persisted events on the model topic in a temporary buffer.
    * Invokes the join API to request a snapshot + later persisted events.
    * Checks that the snapshot and later events are all contiguous.

-}
join :
    (Procedure.Program.Msg msg -> msg)
    -> Momento.Ports msg
    -> Model
    -> (Delta (Result Error (List RTMessage)) -> msg)
    -> Cmd msg
join pt ports (Private model) rt =
    let
        _ =
            Debug.log "Realtime.join" "called"

        momentoApi =
            buildMomentoApi pt ports

        initProcedure : Procedure Error JoiningProps msg
        initProcedure =
            randomize
                |> Procedure.andThen (getChannelDetails (Private model))
                |> Procedure.andThen (openMomentoCache (Private model) momentoApi)
                |> Procedure.andThen (subscribeModelTopic momentoApi)
                -- Message flow may have started here.
                |> Procedure.andThen (joinChannel (Private model))
    in
    initProcedure |> Procedure.try pt (combine >> rt)


combine : Result Error JoiningProps -> Delta (Result Error (List RTMessage))
combine res =
    let
        joiner joinProps ((Private ({ state } as impl)) as mdl) =
            case state of
                StartState ->
                    let
                        runningState =
                            RunningState
                                { sessionKey = joinProps.sessionKey
                                , seed = joinProps.seed
                                , channel = joinProps.channel
                                }

                        startEvents =
                            joinProps.joinEvents ++ impl.preJoinEvents
                    in
                    ( { impl | state = runningState } |> Private
                    , Ok startEvents
                    )

                _ ->
                    let
                        joinError =
                            JoinError "Join against non start state."
                    in
                    ( { impl | state = FailedState joinError } |> Private
                    , joinError |> Err
                    )
    in
    case res of
        Err err ->
            resultError err

        Ok joinProps ->
            joiner joinProps |> Delta


randomize : Procedure e Random.Seed msg
randomize =
    let
        _ =
            Debug.log "Realtime.randomize" "called"
    in
    (\rt -> Random.generate rt Random.independentSeed)
        |> Procedure.fetch


getChannelDetails :
    Model
    -> Random.Seed
    ->
        Procedure Error
            { seed : Random.Seed
            , channel : Channel
            }
            msg
getChannelDetails (Private model) seed =
    let
        _ =
            Debug.log "Realtime.getChannelDetails" "called"
    in
    (\rt ->
        Http.get
            { url = model.rtChannelApiUrl ++ "/v1/channel"
            , expect = Http.expectJson rt channelDecoder
            }
    )
        |> Procedure.fetch
        |> Procedure.andThen
            (\getResult ->
                case getResult of
                    Ok channel ->
                        Procedure.provide channel

                    Err err ->
                        HttpError err |> Procedure.break
            )
        |> Procedure.map (\channel -> { seed = seed, channel = channel })


openMomentoCache :
    Model
    -> Momento.MomentoApi msg
    ->
        { seed : Random.Seed
        , channel : Channel
        }
    ->
        Procedure.Procedure Error
            { sessionKey : MomentoSessionKey
            , seed : Random.Seed
            , channel : Channel
            }
            msg
openMomentoCache (Private model) momentoApi state =
    let
        _ =
            Debug.log "Realtime.openMomentoCache" "called"
    in
    momentoApi.open
        { apiKey = model.momentoApiKey
        , cache = cacheName state.channel.id
        }
        |> Procedure.fetchResult
        |> Procedure.mapError MomentoError
        |> Procedure.map
            (\sessionKey ->
                { seed = state.seed
                , channel = state.channel
                , sessionKey = sessionKey
                }
            )


subscribeModelTopic :
    Momento.MomentoApi msg
    ->
        { sessionKey : MomentoSessionKey
        , seed : Random.Seed
        , channel : Channel
        }
    ->
        Procedure.Procedure Error
            { sessionKey : MomentoSessionKey
            , seed : Random.Seed
            , channel : Channel
            }
            msg
subscribeModelTopic momentoApi state =
    let
        _ =
            Debug.log "Realtime.subscribeModelTopic" "called"
    in
    momentoApi.subscribe
        state.sessionKey
        { topic = state.channel.modelTopic }
        |> Procedure.fetchResult
        |> Procedure.mapError MomentoError
        |> Procedure.map (always state)


joinChannel :
    Model
    ->
        { sessionKey : MomentoSessionKey
        , seed : Random.Seed
        , channel : Channel
        }
    ->
        Procedure Error
            { sessionKey : MomentoSessionKey
            , seed : Random.Seed
            , channel : Channel
            , joinEvents : List RTMessage
            }
            msg
joinChannel (Private model) state =
    let
        _ =
            Debug.log "Realtime.joinChannel" "called"
    in
    (\rt ->
        Http.get
            { url = model.rtChannelApiUrl ++ "/v1/channel/" ++ state.channel.id ++ "/join"
            , expect = Http.expectJson rt joinDecoder
            }
    )
        |> Procedure.fetch
        |> Procedure.andThen
            (\getResult ->
                case getResult of
                    Ok joinEvents ->
                        Procedure.provide joinEvents

                    Err err ->
                        HttpError err |> Procedure.break
            )
        |> Procedure.map
            (\joinEvents ->
                { seed = state.seed
                , channel = state.channel
                , sessionKey = state.sessionKey
                , joinEvents = joinEvents
                }
            )


joinDecoder : Decoder (List RTMessage)
joinDecoder =
    Decode.list rtMessageDecoder



-- Send realtime messages on the channel.


{-| Sends a persisted message. This message will be assigned a unique and contiguous sequence number and
saved into an event log, before being forwarded to all clients on the same channel.
-}
publishPersisted :
    (Procedure.Program.Msg msg -> msg)
    -> Momento.Ports msg
    -> Model
    -> Value
    -> (Delta (Maybe Error) -> msg)
    -> Cmd msg
publishPersisted pt ports (Private model) payload tag =
    let
        _ =
            Debug.log "Realtime.publishPersisted" "called"

        momentoApi =
            buildMomentoApi pt ports
    in
    case model.state of
        RunningState state ->
            momentoApi.pushList state.sessionKey
                { list = state.channel.saveList, payload = encodeUnsavedEvent payload }
                |> Procedure.fetchResult
                |> Procedure.andThen
                    (\_ ->
                        momentoApi.publish state.sessionKey
                            { topic = state.channel.saveTopic
                            , payload = encodeNotice
                            }
                            |> Procedure.fetchResult
                    )
                |> Procedure.mapError MomentoError
                |> Procedure.try pt (momentoResultToDelta state tag)

        _ ->
            Cmd.none


{-| Sends a transient message. This message will be forwarded to all clients on the same channel, but will
not be saved.
-}
publishTransient :
    (Procedure.Program.Msg msg -> msg)
    -> Momento.Ports msg
    -> Model
    -> Value
    -> (Delta (Maybe Error) -> msg)
    -> Cmd msg
publishTransient pt ports (Private model) payload tag =
    let
        _ =
            Debug.log "Realtime.publishTransient" "called"

        momentoApi =
            buildMomentoApi pt ports
    in
    case model.state of
        RunningState state ->
            momentoApi.publish state.sessionKey
                { topic = state.channel.modelTopic
                , payload = encodeTransientEvent payload
                }
                |> Procedure.fetchResult
                |> Procedure.mapError MomentoError
                |> Procedure.try pt (momentoResultToDelta state tag)

        _ ->
            Cmd.none


momentoResultToDelta : RunningProps -> (Delta (Maybe Error) -> msg) -> Result Error () -> msg
momentoResultToDelta state tag res =
    case res of
        Ok () ->
            makeDeltaFn
                (\m -> { m | state = state |> RunningState })
                Nothing
                |> tag

        Err err ->
            err |> justError |> tag



-- Receive messages from the channel.


{-| Events that can be reported asynchronously through a Realtime subscription.
-}
type AsyncEvent
    = OnMessage RTMessage
    | AsyncError Error
    | Internal


subscribe :
    (Procedure.Program.Msg msg -> msg)
    -> Momento.Ports msg
    -> Model
    -> (Delta AsyncEvent -> msg)
    -> Sub msg
subscribe pt ports (Private model) tag =
    let
        momentoApi =
            buildMomentoApi pt ports

        modfn val =
            case Decode.decodeValue rtMessageDecoder val of
                Ok rtm ->
                    (\m -> ( m, OnMessage rtm )) |> Delta |> tag

                Err err ->
                    DecodeError err |> asyncError |> tag

        errfn err =
            MomentoError err |> asyncError |> tag
    in
    case model.state of
        -- In Running state, forward all events to the application.
        RunningState _ ->
            [ momentoApi.onMessage modfn
            , momentoApi.asyncError errfn
            ]
                |> Sub.batch

        StartState ->
            -- In Start state, accumulate any events which may happen prior to completing the join.
            (\val ->
                case Decode.decodeValue rtMessageDecoder val of
                    Ok rtm ->
                        makeDeltaFn (\m -> { m | preJoinEvents = rtm :: m.preJoinEvents })
                            Internal
                            |> tag

                    Err err ->
                        asyncError (DecodeError err) |> tag
            )
                |> momentoApi.onMessage

        _ ->
            Sub.none


resultError : Error -> Delta (Result Error a)
resultError err =
    makeDeltaFn
        (\m -> { m | state = err |> FailedState })
        (Err err)


justError : Error -> Delta (Maybe Error)
justError err =
    makeDeltaFn
        (\m -> { m | state = err |> FailedState })
        (Just err)


asyncError : Error -> Delta AsyncEvent
asyncError err =
    makeDeltaFn
        (\m -> { m | state = err |> FailedState })
        (AsyncError err)


makeDeltaFn : (Implementation -> Implementation) -> a -> Delta a
makeDeltaFn stepFn res =
    (\(Private m) ->
        ( stepFn m |> Private
        , res
        )
    )
        |> Delta


cacheName : String -> String
cacheName _ =
    "elm-realtime-cache"



-- Client side messages.


{-| RTMessage is the client side message. These are the messages that can be received by the client of a
realtime channel.
-}
type RTMessage
    = RTPersisted Int Value
    | RTTransient Value
    | RTSnapshot Int Value


rtMessageDecoder : Decoder RTMessage
rtMessageDecoder =
    Decode.field "rt" Decode.string
        |> Decode.andThen
            (\ctor ->
                case ctor of
                    "P" ->
                        Decode.map2 RTPersisted
                            (Decode.field "seq" Decode.int)
                            (Decode.field "payload" Decode.value)

                    "T" ->
                        Decode.map RTTransient
                            (Decode.field "payload" Decode.value)

                    "R" ->
                        Decode.map2 RTSnapshot
                            (Decode.field "seq" Decode.int)
                            (Decode.field "payload" Decode.value)

                    _ ->
                        Decode.fail "Unrecognized constructor"
            )



-- Wire Message formats
--
-- === Message Key:
-- T: Transient message
-- U: Unsaved message
-- P: Persisted message
-- R: Recovered snapshot
-- N: Notification of unsaved message
-- S: Snapshot request


type alias PersistedEvent =
    { rt : String
    , seq : Int
    , payload : Value
    }


encodePersistedEvent : Int -> Value -> Value
encodePersistedEvent seq payload =
    [ ( "rt", Encode.string "P" )
    , ( "seq", Encode.int seq )
    , ( "payload", payload )
    ]
        |> Encode.object


persistedEventDecoder : Decoder PersistedEvent
persistedEventDecoder =
    Decode.field "rt" Decode.string
        |> Decode.andThen
            (\ctor ->
                case ctor of
                    "P" ->
                        Decode.succeed PersistedEvent
                            |> DE.andMap (Decode.succeed "P")
                            |> DE.andMap (Decode.field "seq" Decode.int)
                            |> DE.andMap (Decode.field "payload" Decode.value)

                    _ ->
                        Decode.fail "Unrecognized constructor"
            )


type alias TransientEvent =
    { rt : String
    , payload : Value
    }


encodeTransientEvent : Value -> Value
encodeTransientEvent payload =
    [ ( "rt", Encode.string "T" )
    , ( "payload", payload )
    ]
        |> Encode.object


transientEventDecoder : Decoder TransientEvent
transientEventDecoder =
    Decode.field "rt" Decode.string
        |> Decode.andThen
            (\ctor ->
                case ctor of
                    "T" ->
                        Decode.succeed TransientEvent
                            |> DE.andMap (Decode.succeed "T")
                            |> DE.andMap (Decode.field "payload" Decode.value)

                    _ ->
                        Decode.fail "Unrecognized constructor"
            )


type alias UnsavedEvent =
    { rt : String
    , payload : Value
    }


encodeUnsavedEvent : Value -> Value
encodeUnsavedEvent payload =
    [ ( "rt", Encode.string "U" )
    , ( "payload", payload )
    ]
        |> Encode.object


unsavedEventDecoder : Decoder UnsavedEvent
unsavedEventDecoder =
    Decode.field "rt" Decode.string
        |> Decode.andThen
            (\ctor ->
                case ctor of
                    "U" ->
                        Decode.succeed UnsavedEvent
                            |> DE.andMap (Decode.succeed "U")
                            |> DE.andMap (Decode.field "payload" Decode.value)

                    _ ->
                        Decode.fail "Unrecognized constructor"
            )


type alias SnapshotEvent =
    { rt : String
    , seq : Int
    , payload : Value
    }


encodeSnapshotEvent : Int -> Value -> Value
encodeSnapshotEvent seq payload =
    [ ( "rt", Encode.string "R" )
    , ( "seq", Encode.int seq )
    , ( "payload", payload )
    ]
        |> Encode.object


snapshotEventDecoder : Decoder SnapshotEvent
snapshotEventDecoder =
    Decode.field "rt" Decode.string
        |> Decode.andThen
            (\ctor ->
                case ctor of
                    "R" ->
                        Decode.succeed SnapshotEvent
                            |> DE.andMap (Decode.succeed "R")
                            |> DE.andMap (Decode.field "seq" Decode.int)
                            |> DE.andMap (Decode.field "payload" Decode.value)

                    _ ->
                        Decode.fail "Unrecognized constructor"
            )



-- Notifications


encodeNotice : Value
encodeNotice =
    [ ( "rt", Encode.string "N" )
    , ( "client", Encode.string "abcdef" )
    ]
        |> Encode.object


type alias SnapshotRequestEvent =
    { rt : String
    , channel : String
    , seq : Int
    }


encodeSnapshotRequestEvent : String -> Int -> Value
encodeSnapshotRequestEvent channel seq =
    [ ( "rt", Encode.string "S" )
    , ( "channel", Encode.string channel )
    , ( "seq", Encode.int seq )
    ]
        |> Encode.object


snapshotRequestEventDecoder : Decoder SnapshotRequestEvent
snapshotRequestEventDecoder =
    Decode.field "rt" Decode.string
        |> Decode.andThen
            (\ctor ->
                case ctor of
                    "S" ->
                        Decode.succeed SnapshotRequestEvent
                            |> DE.andMap (Decode.succeed "S")
                            |> DE.andMap (Decode.field "channel" Decode.string)
                            |> DE.andMap (Decode.field "seq" Decode.int)

                    _ ->
                        Decode.fail "Unrecognized constructor"
            )
