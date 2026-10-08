module SocketTcpEchoTest exposing (main)

{-| TCP echo over loopback (plans/eco-system-sockets.md §4 S3): a listener on `127.0.0.1:0`
delivers the connection through `Socket.onConnection`; the server reads to `Closed` **then**
writes its reply and closes; the client writes, half-closes (`Stream.closeWritable`) and reads the
reply to `Closed`. The endpoints of both sides agree. The program closes its listener and exits by
itself.
-}

-- CHECK: server got: hello over tcp
-- CHECK: client got: echo: hello over tcp
-- CHECK: listener port nonzero: True
-- CHECK: client remote is the listener: True
-- CHECK: server remote is the client: True
-- CHECK: server local: inet 127.0.0.1
-- EXIT: 0

import Socket
import SocketTestHelp as H
import Stream.Log
import System
import Task


type Msg
    = Listening (Result String Socket.Listener)
    | ClientDone (Result String ( String, Socket.Connection ))
    | GotConnection Socket.Connection
    | ServerDone (Result String ( String, Socket.Connection ))
    | Finished


type alias Model =
    { env : System.Environment
    , listener : Maybe Socket.Listener
    , client : Maybe ( String, Socket.Connection )
    , server : Maybe ( String, Socket.Connection )
    , lines : List String
    }


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, listener = Nothing, client = Nothing, server = Nothing, lines = [] }
                , Task.attempt Listening (H.socketErr H.listenLocal)
                )
        , update = update
        , subscriptions =
            \model ->
                case model.listener of
                    Just l ->
                        Socket.onConnection l GotConnection

                    Nothing ->
                        Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok l) ->
            ( { model | listener = Just l }
            , H.socketErr (H.connectTo l)
                |> Task.andThen (\conn -> H.send "hello over tcp" conn |> Task.map (\reply -> ( reply, conn )))
                |> Task.attempt ClientDone
            )

        Listening (Err e) ->
            finish { model | lines = [ "listen failed: " ++ e ] }

        GotConnection conn ->
            ( model
            , H.streamErr (H.readAll (Socket.readable conn))
                |> Task.andThen
                    (\text ->
                        H.streamErr (H.writeAll ("echo: " ++ text) (Socket.writable conn))
                            |> Task.map (\_ -> ( text, conn ))
                    )
                |> Task.attempt ServerDone
            )

        ClientDone (Ok r) ->
            check { model | client = Just r }

        ServerDone (Ok r) ->
            check { model | server = Just r }

        ClientDone (Err e) ->
            finish { model | lines = [ "client failed: " ++ e ] }

        ServerDone (Err e) ->
            finish { model | lines = [ "server failed: " ++ e ] }

        Finished ->
            ( model, Cmd.none )


check : Model -> ( Model, Cmd Msg )
check model =
    case ( model.listener, model.client, model.server ) of
        ( Just l, Just ( reply, c ), Just ( got, s ) ) ->
            finish
                { model
                    | lines =
                        [ "server got: " ++ got
                        , "client got: " ++ reply
                        , "listener port nonzero: " ++ H.boolString (H.portOf l /= 0)
                        , "client remote is the listener: "
                            ++ H.boolString (H.endpointToString (Socket.remoteEndpoint c) == H.endpointToString (Socket.listenerEndpoint l))
                        , "server remote is the client: "
                            ++ H.boolString (H.endpointToString (Socket.remoteEndpoint s) == H.endpointToString (Socket.localEndpoint c))
                        , "server local: " ++ H.endpointToString (Socket.localEndpoint s)
                        ]
                }

        _ ->
            ( model, Cmd.none )


finish : Model -> ( Model, Cmd Msg )
finish model =
    ( { model | listener = Nothing }
    , Stream.Log.line model.env.stdout (String.join "\n" model.lines)
        |> Task.andThen
            (\_ ->
                case model.listener of
                    Just l ->
                        Socket.closeListener l |> Task.onError (\_ -> Task.succeed ())

                    Nothing ->
                        Task.succeed ()
            )
        |> Task.perform (\_ -> Finished)
    )
