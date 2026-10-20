module LiveStreamCancelTest exposing (main)

{-| Closing a stream's resource withdraws the read waiting on it (plans/program-liveness-rule.md
LIVE-5, Q4: a socket the program accepted from an external client, not stdin). A Detached Node
client connects and keeps its connection open for 120 s without sending anything; the program
accepts it, starts a `Stream.read` on it, and 50 ms later closes the connection. The waiting read
fails, its hold ends, and nothing else holds (the listener holds nothing), so the program ends; a
read that kept holding would be killed by the watchdog. (`Stream.cancelReadable` cannot be used
here: while a read is waiting it fails with `Locked` and cancels nothing, as documented.)
-}

-- CHECK: accepted
-- CHECK: read failed
-- CHECK: closed
-- EXIT: 0

import Bytes
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
    | ReadDone (Result Stream.Error Bytes.Bytes)
    | Closed
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
                            , Task.attempt ReadDone (Stream.read (Socket.readable conn))
                            , Process.sleep 50
                                |> Task.andThen (\_ -> Socket.close conn)
                                |> Task.perform (\_ -> Closed)
                            ]
                        )

                    Accepted (Err e) ->
                        ( env, L.log env Logged ("accept error " ++ Socket.errorToString e) )

                    ReadDone (Ok _) ->
                        ( env, L.log env Logged "read: data" )

                    ReadDone (Err _) ->
                        ( env, L.log env Logged "read failed" )

                    Closed ->
                        ( env, L.log env Logged "closed" )

                    Logged ->
                        ( env, Cmd.none )

                    Peer ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
