module ProcessKillRunnableTest exposing (main)

{-| `Process.kill` stops a process that is waiting in the scheduler's queue to run, not only one
waiting on a task.

The parent spawns a child, kills it, and does the same with a second child:

  - `queuedChild` runs to completion before the parent's kill, because spawning makes the
    parent yield, so "survived queued" is logged (a control);
  - `runnableChild` starts with `Process.spawn` itself, so it yields too and is queued to run
    again when the parent kills it, and "survived runnable" must never be logged.

The parent then sleeps for 50 ms and logs "done".

-}

-- CHECK: kill: "survived queued"
-- CHECK: kill: "done"
-- CHECK-NOT: survived runnable

import Process
import Task


survive : String -> Task.Task Never ()
survive tag =
    let
        _ =
            Debug.log "kill" ("survived " ++ tag)
    in
    Task.succeed ()


queuedChild : Task.Task Never ()
queuedChild =
    Task.succeed () |> Task.andThen (\_ -> survive "queued")


runnableChild : Task.Task Never ()
runnableChild =
    Process.spawn (Task.succeed ()) |> Task.andThen (\_ -> survive "runnable")


spawnAndKill : Task.Task Never () -> Task.Task Never ()
spawnAndKill child =
    Process.spawn child |> Task.andThen Process.kill


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , spawnAndKill queuedChild
                    |> Task.andThen (\_ -> spawnAndKill runnableChild)
                    |> Task.andThen (\_ -> Process.sleep 50)
                    |> Task.perform (\_ -> ())
                )
        , update =
            \_ model ->
                let
                    _ =
                        Debug.log "kill" "done"
                in
                ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
