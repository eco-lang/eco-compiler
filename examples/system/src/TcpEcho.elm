module TcpEcho exposing (main)

{-| A TCP echo server: every connection gets back what it sends.

    eco make src/TcpEcho.elm --output=tcp-echo && ./tcp-echo 7000
    echo hello | nc -N 127.0.0.1 7000

The port is the first argument (default 7000). The server runs until the process is stopped.

-}

import Bytes exposing (Bytes)
import Socket
import Socket.Address as Address
import Socket.Tcp
import Stream
import Stream.Log
import System
import Task


type alias Model =
    { stdout : Stream.Writable Bytes
    , stderr : Stream.Writable Bytes
    , listener : Maybe Socket.Listener
    }


type Msg
    = Listening (Result Socket.Error Socket.Listener)
    | Connected Socket.Connection
    | Done


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
        -- args includes the program name first (the full C argv).
        port_ =
            env.args
                |> List.drop 1
                |> List.head
                |> Maybe.andThen String.toInt
                |> Maybe.withDefault 7000
    in
    ( { stdout = env.stdout, stderr = env.stderr, listener = Nothing }
    , Task.attempt Listening
        (Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback Address.IPv4) port_))
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok listener) ->
            ( { model | listener = Just listener }
            , System.endSimpleProgram
                (Stream.Log.line model.stdout ("listening on " ++ endpointToString (Socket.listenerEndpoint listener)))
            )

        Listening (Err err) ->
            ( model
            , Cmd.batch
                [ System.endSimpleProgram (Stream.Log.line model.stderr ("tcp-echo: " ++ Socket.errorToString err))
                , System.exitWithCode 1
                ]
            )

        Connected conn ->
            ( model
            , Stream.Log.line model.stdout ("connection from " ++ endpointToString (Socket.remoteEndpoint conn))
                |> Task.andThen (\_ -> Stream.pipeTo (Socket.writable conn) (Socket.readable conn))
                |> Task.attempt (\_ -> Done)
            )

        Done ->
            ( model, Cmd.none )


endpointToString : Address.Endpoint -> String
endpointToString endpoint =
    case endpoint of
        Address.Inet { address, port_ } ->
            Address.toString address ++ ":" ++ String.fromInt port_

        Address.Unix _ ->
            "a Unix socket"


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.listener of
        Just listener ->
            Socket.onConnection listener Connected

        Nothing ->
            Sub.none
