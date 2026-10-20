module LiveStreamReadKilledDataTest exposing (main)

{-| A withdrawn read loses no input (plans/program-liveness-rule.md LIVE-5). A Detached Node
client connects, sends `hello` after 300 ms and `world` after 900 ms, and keeps the connection
open for 120 s. The program accepts it and:

1.  spawns a `Stream.read`, kills it 50 ms later, and reads again at once: the second read waits
    behind the withdrawn one and gets `hello`;
2.  spawns another read, kills it 50 ms later, and waits 1 s before reading again, so `world`
    arrives while no read waits: the next read gets it;
3.  closes the connection. Nothing holds afterwards, so the program ends.
-}

-- CHECK: accepted
-- CHECK-NEXT: killed 1
-- CHECK-NEXT: got hello
-- CHECK-NEXT: killed 2
-- CHECK-NEXT: got world
-- CHECK-NEXT: closed
-- EXIT: 0

import Bytes
import Bytes.Decode
import LiveTestHelp as L
import Process
import Socket
import SocketTestHelp as H
import Stream
import System
import Task


type Msg
    = Listening (Result Socket.Error Socket.Listener)
    | Accepted (Result Socket.Error Socket.Connection)
    | Killed Int Socket.Connection
    | Got Socket.Connection (Result Stream.Error Bytes.Bytes)
    | Closed
    | Logged
    | Peer


type alias Model =
    { env : System.Environment, step : Int }


client : Int -> String
client port_ =
    String.join ""
        [ "const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1');"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));"
        , "setTimeout(()=>s.write('hello'),300);setTimeout(()=>s.write('world'),900);"
        , "setTimeout(()=>process.exit(0),120000);"
        ]


spawnAndKill : Int -> Socket.Connection -> Cmd Msg
spawnAndKill n conn =
    Process.spawn (Stream.read (Socket.readable conn))
        |> Task.andThen (\pid -> Process.sleep 50 |> Task.andThen (\_ -> Process.kill pid))
        |> Task.perform (\_ -> Killed n conn)


text : Bytes.Bytes -> String
text b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b |> Maybe.withDefault "?"


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init = \env -> ( { env = env, step = 0 }, Task.attempt Listening H.listenLocal )
        , update =
            \msg model ->
                let
                    env =
                        model.env
                in
                case msg of
                    Listening (Ok l) ->
                        ( model
                        , Cmd.batch
                            [ Task.attempt Accepted (Socket.accept l)
                            , L.node Peer (client (H.portOf l))
                            ]
                        )

                    Listening (Err e) ->
                        ( model, L.log env Logged ("error " ++ Socket.errorToString e) )

                    Accepted (Ok conn) ->
                        ( model, Cmd.batch [ L.log env Logged "accepted", spawnAndKill 1 conn ] )

                    Accepted (Err e) ->
                        ( model, L.log env Logged ("accept error " ++ Socket.errorToString e) )

                    Killed 1 conn ->
                        ( model
                        , Cmd.batch
                            [ L.log env Logged "killed 1"
                            , Task.attempt (Got conn) (Stream.read (Socket.readable conn))
                            ]
                        )

                    Killed _ conn ->
                        ( model
                        , Cmd.batch
                            [ L.log env Logged "killed 2"
                            , Process.sleep 1000
                                |> Task.andThen (\_ -> Stream.read (Socket.readable conn))
                                |> Task.attempt (Got conn)
                            ]
                        )

                    Got conn (Ok b) ->
                        if model.step == 0 then
                            ( { model | step = 1 }
                            , Cmd.batch [ L.log env Logged ("got " ++ text b), spawnAndKill 2 conn ]
                            )

                        else
                            ( model
                            , Cmd.batch
                                [ L.log env Logged ("got " ++ text b)
                                , Process.sleep 20
                                    |> Task.andThen (\_ -> Socket.close conn)
                                    |> Task.perform (\_ -> Closed)
                                ]
                            )

                    Got _ (Err e) ->
                        ( model, L.log env Logged ("read error " ++ Stream.errorToString e) )

                    Closed ->
                        ( model, L.log env Logged "closed" )

                    Logged ->
                        ( model, Cmd.none )

                    Peer ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
