module ProcessStdinPipeWriteTest exposing (main)

{-| PROC-NEW-1 (plans/kernel-lib-bug-fixes.md, group 07): `Eco.Process.spawnProcess` with
`stdin = CreatePipe` hands back a stdin handle that, as its doc says, "can be used with
Console.write and File.close". Natively `Console.write` (eco-kernel-cpp/src/eco-kernel/Console.cpp
`writeBody`) only knew handles 1 and 2 and returned success for any other without writing, so the
data was silently lost: the child read end of input at once and printed `got:[]`. Fixed: the
native `writeBody` looks the handle up in Process's table of open stdin pipes, as the JS twin
does. Expected output from the Process.elm doc (eco/kernel API, no stock Elm reference). POSIX
only (`sh`). The record has no `stdout`/`stderr` fields since PROC-03 (D28 option A).
-}

-- LINUX-ONLY: uses sh
-- CHECK: got:[hello]
-- CHECK-NOT: got:[]
-- CHECK: waited: ExitSuccess, write ok, close ok
-- EXIT: 0

import Eco.Console as Console
import Eco.File as File
import Eco.Process as P
import Platform
import Task exposing (Task)


type Msg
    = Done String


exitString : P.ExitCode -> String
exitString code =
    case code of
        P.ExitSuccess ->
            "ExitSuccess"

        P.ExitFailure n ->
            "ExitFailure " ++ String.fromInt n


outcome : String -> Task x () -> Task Never String
outcome label task =
    task
        |> Task.map (\_ -> label ++ " ok")
        |> Task.onError (\_ -> Task.succeed (label ++ " error"))


run : Task Never String
run =
    P.spawnProcess
        { cmd = "sh"
        , args = [ "-c", "read line; echo \"got:[$line]\"" ]
        , stdin = P.CreatePipe
        }
        |> Task.andThen
            (\r ->
                case r.stdinHandle of
                    Nothing ->
                        Task.succeed "no stdin handle"

                    Just fd ->
                        outcome "write" (Console.write (Console.Handle fd) "hello\n")
                            |> Task.andThen
                                (\w ->
                                    outcome "close" (File.close (File.Handle fd))
                                        |> Task.andThen
                                            (\c ->
                                                P.wait r.processHandle
                                                    |> Task.map (\code -> exitString code ++ ", " ++ w ++ ", " ++ c)
                                            )
                                )
                            |> Task.mapError never
            )
        |> Task.onError (\_ -> Task.succeed "spawn failed")


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform Done run )
        , update =
            \(Done s) _ ->
                let
                    _ =
                        Debug.log ("waited: " ++ s) ()
                in
                ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
