module LiveHttpKillTest exposing (main)

{-| Killing the process that runs an `Http.task` withdraws the request
(plans/program-liveness-rule.md §5.3, L5): the transfer is aborted and keeps the program
running no longer. The server answers after 120 s, so a request that kept holding would be
stopped by the 60 s watchdog.
-}

-- CHECK: killed
-- EXIT: 0

import Http
import Process
import System
import Task
import TestServerConfig


type Msg
    = Killed


slowTask : TestServerConfig.Server -> Task.Task Http.Error ()
slowTask server =
    Http.task
        { method = "GET"
        , headers = []
        , url = server.baseUrl ++ "/slow?ms=120000"
        , body = Http.emptyBody
        , resolver = Http.stringResolver (\_ -> Ok ())
        , timeout = Nothing
        }


main : Platform.Program System.Environment () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , TestServerConfig.server
                    |> Task.andThen (\server -> Process.spawn (slowTask server))
                    |> Task.andThen (\pid -> Process.sleep 200 |> Task.andThen (\_ -> Process.kill pid))
                    |> Task.perform (\_ -> Killed)
                )
        , update =
            \Killed () ->
                let
                    _ =
                        Debug.log "killed" ()
                in
                ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
