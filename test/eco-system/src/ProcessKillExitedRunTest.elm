module ProcessKillExitedRunTest exposing (main)

{-| PROC-05 (plans/kernel-lib-bug-fixes.md, group 07): `Process.kill` on a `ChildProcess.run`
whose child has already exited while a process it started still holds the output pipes. The
killed task is no longer waited for (LIVE_001), so the run's hold must go at once. Natively
`cancelRunByToken` (system-kernel-cpp/src/eco-system/ChildProcess/ChildProcess.cpp) calls
`killJob`, which did nothing once the exit had been seen, so the job kept collecting until the
backgrounded `sleep 6` closed the pipes, and the program's event loop was first empty about 6 s
after the kill. Fixed on both backends: a kill after the exit stops the collector, as an expired
runDuration does.

The run is `sh -c "sleep 6 & exit 0"`; 300 ms in, `sh` has exited, and the run is killed.
`onEmptyEventLoop` then measures how long the program stays alive after the kill. POSIX only.

The JS backend had the same bug (`prompt: False` after about 6 s) and is fixed with it (D5).
-}

-- LINUX-ONLY: uses sh and a background job holding the run's pipes
-- CHECK: prompt: True
-- CHECK-NOT: run completed
-- EXIT: 0

import ChildProcess as P
import Process
import System
import Task
import Time


type Msg
    = Killed Time.Posix
    | Empty
    | Ended Time.Posix


main : Platform.Program System.Environment Int Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( 0
                , Process.spawn
                    (P.run "sh"
                        [ "-c", "sleep 6 & exit 0" ]
                        { shell = P.NoShell
                        , workingDirectory = P.InheritWorkingDirectory
                        , environmentVariables = P.InheritEnvironmentVariables
                        , maximumBytesWrittenToStreams = 0
                        , runDuration = P.NoLimit
                        }
                        |> Task.map (\_ -> "ok")
                        |> Task.onError (\_ -> Task.succeed "err")
                        |> Task.map (\r -> Debug.log "run completed" r)
                    )
                    |> Task.andThen (\pid -> Process.sleep 300 |> Task.andThen (\_ -> Process.kill pid))
                    |> Task.andThen (\_ -> Time.now)
                    |> Task.perform Killed
                )
        , update =
            \msg t1 ->
                case msg of
                    Killed t ->
                        ( Time.posixToMillis t, Cmd.none )

                    Empty ->
                        ( t1, Task.perform Ended Time.now )

                    Ended t ->
                        let
                            _ =
                                Debug.log "prompt" (t1 > 0 && Time.posixToMillis t - t1 < 3000)
                        in
                        ( t1, Cmd.none )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
