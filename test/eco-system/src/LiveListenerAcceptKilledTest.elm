module LiveListenerAcceptKilledTest exposing (main)

{-| Killing a parked `accept` withdraws its wait (plans/program-liveness-rule.md LIVE-5): the
program listens, spawns `Socket.accept` in its own process, kills that process 50 ms later and
logs `killed`. Nothing connects, so if the killed accept still held the listener the program would
never end (the watchdog would kill it).
-}

-- CHECK: killed
-- EXIT: 0

import LiveTestHelp as L
import Process
import Socket
import SocketTestHelp as H
import System
import Task


type Msg
    = Listening (Result Socket.Error Socket.Listener)
    | Killed
    | Logged


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.attempt Listening H.listenLocal )
        , update =
            \msg env ->
                case msg of
                    Listening (Ok l) ->
                        ( env
                        , Process.spawn (Socket.accept l)
                            |> Task.andThen (\pid -> Process.sleep 50 |> Task.andThen (\_ -> Process.kill pid))
                            |> Task.perform (\_ -> Killed)
                        )

                    Listening (Err e) ->
                        ( env, L.log env Logged ("error " ++ Socket.errorToString e) )

                    Killed ->
                        ( env, L.log env Logged "killed" )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
