module UnhandledTaskFailWarnsTest exposing (main)

{-| A `Task.fail` that no `Task.onError` catches ends only its own process
(SCHED_002, plans/unhandled-task-fail.md). The runtime prints a warning to
stderr and the program carries on, matching stock Elm, which ends the failed
process silently. The main process logs after the spawned one has failed, and
the program exits 0.
-}

-- CHECK: before failing
-- CHECK: [eco-runtime] unhandled top-level Task.fail
-- CHECK: still running
-- CHECK-NOT: Eco crash
-- EXIT: 0

import Process
import Stream
import System
import Task


type Msg
    = Done


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init =
            \env ->
                ( env
                , Stream.logLine "before failing" env.stdout
                    |> Task.andThen (\_ -> Process.spawn (Task.fail "boom"))
                    |> Task.andThen (\_ -> Process.sleep 20)
                    |> Task.andThen (\_ -> Stream.logLine "still running" env.stdout)
                    |> Task.perform (\_ -> Done)
                )
        , update = \_ env -> ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
