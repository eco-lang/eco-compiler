module LiveListenerHeldTest exposing (main)

{-| A held connection holds nothing (plans/program-liveness-rule.md N4, LIVE-2): the program
listens, starts a Detached Node client that connects and then keeps its connection open for
120 s without sending anything, and sleeps one second, so the connection has arrived (natively it
waits in the listener's backlog; on Node the listener has accepted it into its held FIFO). With no
`accept` and no `onConnection` subscription, nothing holds after the sleep and the program ends.
A held connection that kept the program running would be killed by the watchdog (120 s > 60 s).
-}

-- CHECK: listening
-- CHECK: slept
-- EXIT: 0

import LiveTestHelp as L
import Process
import Socket
import SocketTestHelp as H
import System
import Task


type Msg
    = Listening (Result Socket.Error Socket.Listener)
    | Slept
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
                            [ L.log env Logged "listening"
                            , L.node Peer (client (H.portOf l))
                            , Task.perform (\_ -> Slept) (Process.sleep 1000)
                            ]
                        )

                    Listening (Err e) ->
                        ( env, L.log env Logged ("error " ++ Socket.errorToString e) )

                    Slept ->
                        ( env, L.log env Logged "slept" )

                    Logged ->
                        ( env, Cmd.none )

                    Peer ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
