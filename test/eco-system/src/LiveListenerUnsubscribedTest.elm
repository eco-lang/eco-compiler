module LiveListenerUnsubscribedTest exposing (main)

{-| An open listener holds nothing of its own (plans/program-liveness-rule.md L2, LIVE_001): the
program listens, logs `listening` and starts nothing else, so its event loop is empty and it ends
although the listener is still open. A listener that kept the program running would be killed by
the watchdog.
-}

-- CHECK: listening
-- EXIT: 0

import LiveTestHelp as L
import Socket
import SocketTestHelp as H
import System
import Task


type Msg
    = Listening (Result Socket.Error Socket.Listener)
    | Logged


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.attempt Listening H.listenLocal )
        , update =
            \msg env ->
                case msg of
                    Listening (Ok _) ->
                        ( env, L.log env Logged "listening" )

                    Listening (Err e) ->
                        ( env, L.log env Logged ("error " ++ Socket.errorToString e) )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
