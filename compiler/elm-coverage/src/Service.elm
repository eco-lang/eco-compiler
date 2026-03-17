port module Service exposing (Flags, Format(..), Service, Version, create)

import Json.Decode as Decode exposing (Decoder, Value)
import Json.Encode as Encode


type alias Version =
    String


type Format
    = Html
    | Json


type alias Flags =
    { version : Version
    , format : Format
    }


port emit : Value -> Cmd msg


port receive : (Value -> msg) -> Sub msg


type Msg input
    = Receive input
    | Bad String


type alias Service input =
    Program Value Flags (Msg input)


create :
    { handle : Flags -> input -> output
    , receive : Decoder input
    , emit : output -> Value
    }
    -> Service input
create settings =
    Platform.worker
        { init = innerInit
        , update = handle settings.handle settings.emit
        , subscriptions = subscribe settings.receive
        }


innerInit : Value -> ( Flags, Cmd msg )
innerInit flagsValue =
    let
        version =
            flagsValue
                |> Decode.decodeValue (Decode.field "version" Decode.string)
                |> Result.withDefault "1.0.0"

        format =
            flagsValue
                |> Decode.decodeValue (Decode.field "format" Decode.string)
                |> Result.map
                    (\f ->
                        if f == "json" then
                            Json

                        else
                            Html
                    )
                |> Result.withDefault Html
    in
    ( { version = version, format = format }, Cmd.none )


handle : (Flags -> input -> output) -> (output -> Value) -> Msg input -> Flags -> ( Flags, Cmd msg )
handle handler encode msg flags =
    case msg of
        Receive input ->
            ( flags, emit <| encode <| handler flags input )

        Bad val ->
            ( flags
            , emit <|
                Encode.object
                    [ ( "type", Encode.string "error" )
                    , ( "message", Encode.string val )
                    ]
            )


subscribe : Decoder input -> a -> Sub (Msg input)
subscribe decoder _ =
    receive
        (\data ->
            case Decode.decodeValue decoder data of
                Ok input ->
                    Receive input

                Err e ->
                    Bad <| Decode.errorToString e
        )
