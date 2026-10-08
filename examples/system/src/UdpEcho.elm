module UdpEcho exposing (main)

{-| A UDP echo server: every datagram is sent back to its sender.

    eco make src/UdpEcho.elm --output=udp-echo && ./udp-echo 7001
    echo hello | nc -u -w1 127.0.0.1 7001

The port is the first argument (default 7001). The server runs until the process is stopped.

-}

import Bytes exposing (Bytes)
import Socket
import Socket.Address as Address
import Socket.Udp
import Stream
import Stream.Log
import System
import Task


type alias Model =
    { stdout : Stream.Writable Bytes
    , stderr : Stream.Writable Bytes
    , socket : Maybe Socket.Udp.Socket
    }


type Msg
    = Bound (Result Socket.Error Socket.Udp.Socket)
    | Received Socket.Udp.Datagram
    | Sent


main : System.Program Model Msg
main =
    System.defineProgram
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


init : System.Environment -> ( Model, Cmd Msg )
init env =
    let
        port_ =
            env.args
                |> List.drop 1
                |> List.head
                |> Maybe.andThen String.toInt
                |> Maybe.withDefault 7001
    in
    ( { stdout = env.stdout, stderr = env.stderr, socket = Nothing }
    , Task.attempt Bound
        (Socket.Udp.bind (Socket.Udp.defaultBindOptions (Address.loopback Address.IPv4) port_))
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model.socket ) of
        ( Bound (Ok socket), _ ) ->
            let
                local =
                    Socket.Udp.localEndpoint socket
            in
            ( { model | socket = Just socket }
            , System.endSimpleProgram
                (Stream.Log.line model.stdout
                    ("listening on " ++ Address.toString local.address ++ ":" ++ String.fromInt local.port_)
                )
            )

        ( Bound (Err err), _ ) ->
            ( model
            , Cmd.batch
                [ System.endSimpleProgram (Stream.Log.line model.stderr ("udp-echo: " ++ Socket.errorToString err))
                , System.exitWithCode 1
                ]
            )

        ( Received datagram, Just socket ) ->
            ( model
            , Socket.Udp.send datagram.from datagram.data socket
                |> Task.attempt (\_ -> Sent)
            )

        _ ->
            ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.socket of
        Just socket ->
            Socket.Udp.onMessage socket Received

        Nothing ->
            Sub.none
