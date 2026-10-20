module LiveListenerAcceptTest exposing (main)

{-| A parked `accept` holds its listener (plans/program-liveness-rule.md L2, LIVE_001): the
program listens and accepts, and a Detached Node client connects 300 ms later. Nothing but the
waiting `accept` keeps the program running until then. The program logs `accepted`, closes the
connection and the listener, logs `closed` and ends.
-}

-- CHECK: accepted
-- CHECK: closed
-- EXIT: 0

import LiveTestHelp as L
import Socket
import SocketTestHelp as H
import System
import Task


type Msg
    = Listening (Result Socket.Error Socket.Listener)
    | Accepted Socket.Listener (Result Socket.Error Socket.Connection)
    | Closed
    | Logged
    | Peer


client : Int -> String
client port_ =
    String.join ""
        [ "setTimeout(()=>{const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1');"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));},300);"
        , "setTimeout(()=>process.exit(0),20000);"
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
                            [ Task.attempt (Accepted l) (Socket.accept l)
                            , L.node Peer (client (H.portOf l))
                            ]
                        )

                    Listening (Err e) ->
                        ( env, L.log env Logged ("error " ++ Socket.errorToString e) )

                    Accepted l (Ok conn) ->
                        ( env
                        , Cmd.batch
                            [ L.log env Logged "accepted"
                            , Socket.close conn
                                |> Task.andThen (\_ -> Socket.closeListener l)
                                |> Task.attempt (\_ -> Closed)
                            ]
                        )

                    Accepted _ (Err e) ->
                        ( env, L.log env Logged ("accept error " ++ Socket.errorToString e) )

                    Closed ->
                        ( env, L.log env Logged "closed" )

                    Logged ->
                        ( env, Cmd.none )

                    Peer ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
