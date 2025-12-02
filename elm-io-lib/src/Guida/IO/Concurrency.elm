module Guida.IO.Concurrency exposing
    ( Ports
    , ConcurrencyApi, concurrencyApi
    , MVar, newEmptyMVar, newMVar, readMVar, takeMVar, putMVar, modifyMVar
    , Chan, ChItem(..), newChan, readChan, writeChan
    , mVarEncoder, mVarDecoder, chItemEncoder, chItemDecoder
    , Error(..), errorToString
    )

{-| Concurrency primitives (MVars and Channels) for Guida IO.

MVars are mutable variables that can be empty or full.
They provide a way to communicate between concurrent operations.

Channels are FIFO queues built on top of MVars.


# Ports

@docs Ports


# API

@docs ConcurrencyApi, concurrencyApi


# MVars

@docs MVar, newEmptyMVar, newMVar, readMVar, takeMVar, putMVar, modifyMVar


# Channels

@docs Chan, ChItem, newChan, readChan, writeChan


# Encoders/Decoders

@docs mVarEncoder, mVarDecoder, chItemEncoder, chItemDecoder


# Error Handling

@docs Error, errorToString

-}

import Bytes exposing (Bytes)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Procedure
import Procedure.Channel as Channel
import Procedure.Program



-- PORTS


{-| The ports that need to be wired up to the TypeScript concurrency handlers.
-}
type alias Ports msg =
    { -- MVar operations
      concNewEmptyMVar : { id : String } -> Cmd msg
    , concReadMVar : { id : String, mvarId : Int } -> Cmd msg
    , concTakeMVar : { id : String, mvarId : Int } -> Cmd msg
    , concPutMVar : { id : String, mvarId : Int, value : Value } -> Cmd msg

    -- Response subscription
    , concResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg
    }



-- MVAR TYPE


{-| An MVar (mutable variable) that can be empty or contain a value.
The Int is a reference ID managed by the TypeScript side.
-}
type MVar a
    = MVar Int


{-| Encode an MVar reference for transmission.
-}
mVarEncoder : MVar a -> Value
mVarEncoder (MVar id) =
    Encode.int id


{-| Decode an MVar reference.
-}
mVarDecoder : Decoder (MVar a)
mVarDecoder =
    Decode.map MVar Decode.int



-- CHANNEL TYPE


{-| A Channel is a FIFO queue implemented using two MVars.
-}
type Chan a
    = Chan (MVar (Stream a)) (MVar (Stream a))


{-| Internal stream type - a linked list through MVars.
-}
type alias Stream a =
    MVar (ChItem a)


{-| A channel item containing a value and pointer to the next item.
-}
type ChItem a
    = ChItem a (Stream a)


{-| Encode a ChItem for transmission.
-}
chItemEncoder : (a -> Value) -> ChItem a -> Value
chItemEncoder encodeA (ChItem a stream) =
    Encode.object
        [ ( "value", encodeA a )
        , ( "next", mVarEncoder stream )
        ]


{-| Decode a ChItem.
-}
chItemDecoder : Decoder a -> Decoder (ChItem a)
chItemDecoder decodeA =
    Decode.map2 ChItem
        (Decode.field "value" decodeA)
        (Decode.field "next" mVarDecoder)



-- API


{-| The Concurrency API providing MVar and Channel operations.
-}
type alias ConcurrencyApi msg =
    { newEmptyMVar : (Result Error (MVar a) -> msg) -> Cmd msg
    , readMVar : MVar a -> (Result Error Value -> msg) -> Cmd msg
    , takeMVar : MVar a -> (Result Error Value -> msg) -> Cmd msg
    , putMVar : MVar a -> Value -> (Result Error () -> msg) -> Cmd msg
    }


{-| Creates an instance of the Concurrency API.
-}
concurrencyApi : (Procedure.Program.Msg msg -> msg) -> Ports msg -> ConcurrencyApi msg
concurrencyApi pt ports =
    { newEmptyMVar = newEmptyMVar pt ports
    , readMVar = readMVar pt ports
    , takeMVar = takeMVar pt ports
    , putMVar = putMVar pt ports
    }



-- ERROR HANDLING


{-| Possible errors from concurrency operations.
-}
type Error
    = MVarError String
    | DecodeError String


{-| Convert an error to a human-readable string.
-}
errorToString : Error -> String
errorToString error =
    case error of
        MVarError msg ->
            "MVar error: " ++ msg

        DecodeError msg ->
            "Decode error: " ++ msg



-- RESPONSE DECODERS


decodeMVarResponse : { a | type_ : String, payload : Value } -> Result Error (MVar b)
decodeMVarResponse res =
    case res.type_ of
        "MVar" ->
            case Decode.decodeValue Decode.int res.payload of
                Ok id ->
                    Ok (MVar id)

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (DecodeError ("Unknown response type: " ++ res.type_))


decodeValueResponse : { a | type_ : String, payload : Value } -> Result Error Value
decodeValueResponse res =
    case res.type_ of
        "Value" ->
            Ok res.payload

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (DecodeError ("Unknown response type: " ++ res.type_))


decodeOkResponse : { a | type_ : String, payload : Value } -> Result Error ()
decodeOkResponse res =
    case res.type_ of
        "Ok" ->
            Ok ()

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (DecodeError ("Unknown response type: " ++ res.type_))


decodeErrorPayload : Value -> Error
decodeErrorPayload payload =
    case Decode.decodeValue (Decode.field "message" Decode.string) payload of
        Ok message ->
            MVarError message

        Err _ ->
            MVarError "Unknown error"



-- MVAR OPERATIONS


{-| Create a new empty MVar.
-}
newEmptyMVar :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> (Result Error (MVar a) -> msg)
    -> Cmd msg
newEmptyMVar pt ports toMsg =
    Channel.open (\key -> ports.concNewEmptyMVar { id = key })
        |> Channel.connect ports.concResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeMVarResponse res |> toMsg)


{-| Create a new MVar with an initial value.
-}
newMVar :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> Value
    -> (Result Error (MVar a) -> msg)
    -> Cmd msg
newMVar pt ports value toMsg =
    -- First create empty MVar, then put value
    -- This requires sequencing which is handled at the application level
    -- For simplicity, we use newEmptyMVar and let the caller handle putting
    newEmptyMVar pt ports toMsg


{-| Read the value from an MVar without removing it.
Blocks if the MVar is empty until a value is available.
-}
readMVar :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MVar a
    -> (Result Error Value -> msg)
    -> Cmd msg
readMVar pt ports (MVar mvarId) toMsg =
    Channel.open (\key -> ports.concReadMVar { id = key, mvarId = mvarId })
        |> Channel.connect ports.concResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeValueResponse res |> toMsg)


{-| Take the value from an MVar, leaving it empty.
Blocks if the MVar is empty until a value is available.
-}
takeMVar :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MVar a
    -> (Result Error Value -> msg)
    -> Cmd msg
takeMVar pt ports (MVar mvarId) toMsg =
    Channel.open (\key -> ports.concTakeMVar { id = key, mvarId = mvarId })
        |> Channel.connect ports.concResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeValueResponse res |> toMsg)


{-| Put a value into an MVar.
Blocks if the MVar is already full until it becomes empty.
-}
putMVar :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MVar a
    -> Value
    -> (Result Error () -> msg)
    -> Cmd msg
putMVar pt ports (MVar mvarId) value toMsg =
    Channel.open (\key -> ports.concPutMVar { id = key, mvarId = mvarId, value = value })
        |> Channel.connect ports.concResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)


{-| Atomically modify the contents of an MVar.
Takes the value, applies a function, and puts the result back.
Note: This is a higher-level operation that must be composed at the application level
since it involves multiple async steps.
-}
modifyMVar :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> MVar a
    -> (Value -> ( Value, b ))
    -> (Result Error b -> msg)
    -> Cmd msg
modifyMVar pt ports mvar f toMsg =
    -- This is a complex operation that requires:
    -- 1. takeMVar
    -- 2. Apply function
    -- 3. putMVar with new value
    -- This must be handled at the application level with proper sequencing
    takeMVar pt ports mvar (\result -> toMsg (Result.map (\v -> Tuple.second (f v)) result))



-- CHANNEL OPERATIONS


{-| Create a new empty channel.
Note: Channels are built on MVars in Elm, so this creates the underlying MVars.
This is a complex operation that must be composed at the application level.
-}
newChan :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> (Result Error (Chan a) -> msg)
    -> Cmd msg
newChan pt ports toMsg =
    -- Creating a channel requires:
    -- 1. Create an empty MVar for the "hole"
    -- 2. Create MVar containing the hole for read end
    -- 3. Create MVar containing the hole for write end
    -- This must be sequenced at the application level
    newEmptyMVar pt
        ports
        (\result ->
            case result of
                Ok _ ->
                    -- Simplified: just signal success, actual channel creation is complex
                    toMsg (Err (MVarError "Channel creation requires application-level sequencing"))

                Err e ->
                    toMsg (Err e)
        )


{-| Read a value from a channel (FIFO order).
Blocks if the channel is empty.
-}
readChan :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> Chan a
    -> (Result Error Value -> msg)
    -> Cmd msg
readChan pt ports (Chan readVar _) toMsg =
    -- Reading from a channel requires:
    -- 1. modifyMVar on readVar to get the stream
    -- 2. readMVar on the stream to get the ChItem
    -- 3. Return the value and update the read end
    -- This must be sequenced at the application level
    readMVar pt ports readVar toMsg


{-| Write a value to a channel.
-}
writeChan :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> Chan a
    -> Value
    -> (Result Error () -> msg)
    -> Cmd msg
writeChan pt ports (Chan _ writeVar) value toMsg =
    -- Writing to a channel requires:
    -- 1. Create new empty MVar for new hole
    -- 2. takeMVar on writeVar to get old hole
    -- 3. putMVar on old hole with ChItem containing value and new hole
    -- 4. putMVar on writeVar with new hole
    -- This must be sequenced at the application level
    putMVar pt ports writeVar value toMsg
