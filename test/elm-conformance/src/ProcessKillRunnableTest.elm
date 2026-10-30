module ProcessKillRunnableTest exposing (main)

{-| `Process.kill` must stop a process that is queued to run, not only one parked on a Task binding
(cpp-review-bugs.md, "Scheduler: Binding re-step, dropped mailbox, wrong latest version", part (c)).
In elm/core's JS scheduler `_Scheduler_kill` sets the process's root to null, so a killed process
never takes another step, whatever state it was in. Recorded from Elm on node.

Two children are spawned, each then killed by the parent:

  - `queued`: `Process.spawn` is a binding, so the parent yields after spawning and this child runs to
    completion before the parent's kill: Elm logs "survived queued" (a control);
  - `runnable`: its own first step is `Process.spawn`, so it yields too and is runnable again (queued,
    not parked) when the parent kills it: Elm never logs "survived runnable".

The parent then sleeps and logs "done".

-}

-- XFAIL-NATIVE: cpp-review-bugs.md "Scheduler: Binding re-step ..." (c) -- Process.kill does not stop a runnable process (killBindingBody only calls a parked Binding's kill handle); not fixed yet
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
