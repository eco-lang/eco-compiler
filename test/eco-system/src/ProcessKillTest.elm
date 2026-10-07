module ProcessKillTest exposing (main)

{-| `Process.kill` on a spawned child's `Process.Id` (plans/eco-system-library.md
Phase 5 step 5.4; validates the Phase 2 `Process.kill` fix end to end): the
id the connection message carries is the snapshot `rawSpawn` returned, which
is stale by the time Elm kills it; the kill must still reach the parked
binding's kill handle (latestProcessById), which SIGTERMs the child. `onExit`
then reports 128 + 15. A `run` task killed while its child runs never
completes, and the program still ends (the child's exit releases its count).
-}

-- CHECK: spawned
-- CHECK: exit: 143
-- CHECK-NOT: run completed
-- EXIT: 0

import Process
import Stream.Log
import System
import System.Process as P
import Task


type Msg
    = Started Process.Id
    | Killed
    | Exited Int
    | Logged


noShell : P.SpawnOptions Msg -> P.SpawnOptions Msg
noShell o =
    { o | shell = P.NoShell }


main : System.Program System.Environment Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( env
                , Cmd.batch
                    [ P.spawn "sleep" [ "30" ] (noShell (P.defaultSpawnOptions (P.Integrated Started) Exited))
                    , Process.spawn
                        (P.run "sleep" [ "30" ] { shell = P.NoShell, workingDirectory = P.InheritWorkingDirectory, environmentVariables = P.InheritEnvironmentVariables, maximumBytesWrittenToStreams = 0, runDuration = P.NoLimit }
                            |> Task.map (\_ -> "ok")
                            |> Task.onError (\_ -> Task.succeed "err")
                            |> Task.andThen (\r -> Stream.Log.line env.stdout ("run completed: " ++ r))
                        )
                        |> Task.andThen (\pid -> Process.sleep 100 |> Task.andThen (\_ -> Process.kill pid))
                        |> Task.perform (\_ -> Logged)
                    ]
                )
        , update =
            \msg env ->
                case msg of
                    Started pid ->
                        ( env
                        , Cmd.batch
                            [ Task.perform (\_ -> Logged) (Stream.Log.line env.stdout "spawned")
                            , Task.perform (\_ -> Killed) (Process.sleep 50 |> Task.andThen (\_ -> Process.kill pid))
                            ]
                        )

                    Killed ->
                        ( env, Cmd.none )

                    Exited code ->
                        ( env, Task.perform (\_ -> Logged) (Stream.Log.line env.stdout ("exit: " ++ String.fromInt code)) )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
