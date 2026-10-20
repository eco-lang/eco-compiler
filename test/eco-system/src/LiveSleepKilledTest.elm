module LiveSleepKilledTest exposing (main)

{-| Killing a `Process.sleep` withdraws its timer (plans/program-liveness-rule.md §5.3,
LIVE-5): the killed sleep keeps the program running no longer, so the program ends right
after the kill. A 120 s sleep that kept holding would be stopped by the 60 s watchdog.
-}

-- CHECK: killed
-- EXIT: 0

import Process
import System
import Task


type Msg
    = Killed


main : Platform.Program System.Environment () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , Process.spawn (Process.sleep 120000)
                    |> Task.andThen Process.kill
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
