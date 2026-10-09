module ProcessSpawnWaitTest exposing (main)

{-| `Eco.Process.spawn` / `spawnProcess` / `wait` (plans/spawn-not-fork.md Phase 2: the kernel
starts children with posix_spawnp, never fork). A program's exit status comes back through `wait`;
a missing program fails the spawn itself (`CommandNotFound`; with fork + execvp it used to be a
child that exited 127); `spawnProcess` with a piped stdin hands back a stdin handle.
-}

-- CHECK: exit 3: ExitFailure 3
-- CHECK: true: ExitSuccess
-- CHECK: missing: CommandNotFound
-- CHECK: piped stdin: handle True, ExitSuccess

import Eco.Process as P
import Eco.Process.Error as PE
import Platform
import Task exposing (Task)


type Msg
    = Done (List String)


exitString : P.ExitCode -> String
exitString code =
    case code of
        P.ExitSuccess ->
            "ExitSuccess"

        P.ExitFailure n ->
            "ExitFailure " ++ String.fromInt n


errorString : PE.ProcessError -> String
errorString err =
    case err of
        PE.CommandNotFound _ ->
            "CommandNotFound"

        PE.CommandNotExecutable _ ->
            "CommandNotExecutable"

        PE.SpawnIOError _ ->
            "SpawnIOError"

        PE.OtherProcessError s ->
            "OtherProcessError " ++ s


runAndWait : String -> List String -> Task Never String
runAndWait cmd args =
    P.spawn cmd args
        |> Task.andThen (\h -> P.wait h |> Task.mapError never)
        |> Task.map exitString
        |> Task.onError (\e -> Task.succeed ("spawn failed: " ++ errorString e))


piped : Task Never String
piped =
    P.spawnProcess { cmd = "true", args = [], stdin = P.CreatePipe, stdout = P.Inherit, stderr = P.Inherit }
        |> Task.andThen
            (\r ->
                P.wait r.processHandle
                    |> Task.mapError never
                    |> Task.map (\code -> "handle " ++ (if r.stdinHandle /= Nothing then "True" else "False") ++ ", " ++ exitString code)
            )
        |> Task.onError (\e -> Task.succeed ("spawn failed: " ++ errorString e))


missing : Task Never String
missing =
    P.spawn "eco-spawn-test-no-such-program" []
        |> Task.map (\_ -> "spawned")
        |> Task.onError (\e -> Task.succeed (errorString e))


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , [ runAndWait "sh" [ "-c", "exit 3" ] |> Task.map (\s -> "exit 3: " ++ s)
      , runAndWait "true" [] |> Task.map (\s -> "true: " ++ s)
      , missing |> Task.map (\s -> "missing: " ++ s)
      , piped |> Task.map (\s -> "piped stdin: " ++ s)
      ]
        |> Task.sequence
        |> Task.perform Done
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done lines) _ =
    let
        _ =
            List.map (\l -> Debug.log l ()) lines
    in
    ( (), Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
