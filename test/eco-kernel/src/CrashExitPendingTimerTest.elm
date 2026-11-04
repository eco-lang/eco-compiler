module CrashExitPendingTimerTest exposing (main)

{-| CRASH-01 (plans/kernel-lib-bug-fixes.md), POSIX regression pin: `Eco.Crash.crash "boom"`
writes `Eco crash: boom` to stderr and ends the program with status 1 while a long timer is still
pending (the timer service thread is alive). CRASH-01 itself is a Windows-only hang (`::exit`
with live service threads, now `eco_terminate_process`); no test reaches it here. This pins the
POSIX behaviour across that refactor, next to ProcessExitPendingTimerTest (`Eco.Process.exit`).
-}

-- CHECK: before crash
-- CHECK: Eco crash: boom
-- CHECK-NOT: after crash
-- EXIT: 1

import Eco.Crash
import Process
import Task


type Msg
    = Crash
    | Late


main : Program () () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , Cmd.batch
                    [ Process.sleep 60000 |> Task.perform (\_ -> Late)
                    , Process.sleep 10 |> Task.perform (\_ -> Crash)
                    ]
                )
        , update =
            \msg model ->
                case msg of
                    Crash ->
                        let
                            _ =
                                Debug.log "before crash" ()
                        in
                        Eco.Crash.crash "boom"

                    Late ->
                        let
                            _ =
                                Debug.log "after crash" ()
                        in
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
