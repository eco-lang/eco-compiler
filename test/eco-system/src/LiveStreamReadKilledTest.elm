module LiveStreamReadKilledTest exposing (main)

{-| Killing a task whose `Stream.read` is waiting withdraws the read (plans/program-liveness-rule.md
LIVE-5). A Detached Node client connects and keeps its connection open for 120 s without sending
anything; the program accepts it, spawns `Stream.read` on it in its own process, kills that
process 50 ms later and logs `killed`. The idle connection holds nothing and the killed read must
not hold either, so the program ends; a killed read that kept its hold would be killed by the
watchdog.
-}

-- CHECK: accepted
-- CHECK: killed
-- EXIT: 0

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
    | Killed
    | Logged
    | Peer


client : Int -> String
client port_ =
    String.join ""
        [ "const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1');"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));"
        , "setTimeout(()=>process.exit(0),120000);"
        ]


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.attempt Listening H.listenLocal )
        , update =
            \msg env ->
                case msg of
                    Listening (Ok l) ->
                        ( env
                        , Cmd.batch
                            [ Task.attempt Accepted (Socket.accept l)
                            , L.node Peer (client (H.portOf l))
                            ]
                        )

                    Listening (Err e) ->
                        ( env, L.log env Logged ("error " ++ Socket.errorToString e) )

                    Accepted (Ok conn) ->
                        ( env
                        , Cmd.batch
                            [ L.log env Logged "accepted"
                            , Process.spawn (Stream.read (Socket.readable conn))
                                |> Task.andThen (\pid -> Process.sleep 50 |> Task.andThen (\_ -> Process.kill pid))
                                |> Task.perform (\_ -> Killed)
                            ]
                        )

                    Accepted (Err e) ->
                        ( env, L.log env Logged ("accept error " ++ Socket.errorToString e) )

                    Killed ->
                        ( env, L.log env Logged "killed" )

                    Logged ->
                        ( env, Cmd.none )

                    Peer ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
