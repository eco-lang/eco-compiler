module Eco.Process exposing
    ( ExitCode(..), ProcessHandle(..), StdStream(..)
    , exit, spawn, spawnProcess, wait
    )

{-| Process management: exit, spawn external processes, and wait for completion.

All operations are atomic IO primitives backed by kernel implementations.


# Types

@docs ExitCode, ProcessHandle, StdStream


# Operations

@docs exit, spawn, spawnProcess, wait

-}

import Eco.Kernel.Process
import Eco.Process.Error as ProcErr exposing (ProcessError)
import Task exposing (Task)


{-| The exit code of a completed process.
-}
type ExitCode
    = ExitSuccess
    | ExitFailure Int


{-| An opaque handle to a running external process.
-}
type ProcessHandle
    = ProcessHandle Int


{-| How to handle a child's standard input when spawning a process: share
this process's (`Inherit`) or give the child a new pipe (`CreatePipe`).
-}
type StdStream
    = Inherit
    | CreatePipe


{-| Exit the current process with the given exit code. Never returns.
-}
exit : ExitCode -> Task Never ()
exit code =
    Eco.Kernel.Process.exit (exitCodeToInt code)


{-| Spawn an external process with inherited stdio. Returns a process handle.
-}
spawn : String -> List String -> Task ProcessError ProcessHandle
spawn cmd args =
    Eco.Kernel.Process.spawn cmd args
        |> Task.mapError (ProcErr.ofKernelTuple cmd)
        |> Task.map ProcessHandle


{-| Spawn an external process with configurable stdin.
Returns a record with stdinHandle (a stdin handle ID if stdin was CreatePipe,
else Nothing) and processHandle. The stdin handle ID can be used with
Console.write and File.close. The child always shares this process's stdout
and stderr.
-}
spawnProcess :
    { cmd : String
    , args : List String
    , stdin : StdStream
    }
    -> Task ProcessError { stdinHandle : Maybe Int, processHandle : ProcessHandle }
spawnProcess config =
    Eco.Kernel.Process.spawnProcess
        config.cmd
        config.args
        (stdStreamToString config.stdin)
        |> Task.mapError (ProcErr.ofKernelTuple config.cmd)
        |> Task.map
            (\( stdinHandle, processHandle ) ->
                { stdinHandle = stdinHandle
                , processHandle = ProcessHandle processHandle
                }
            )


{-| Wait for a process to complete and return its exit code.

Killing the task that waits (`Process.kill`) stops the wait, so it no longer
keeps the program alive; the child process itself keeps running.
-}
wait : ProcessHandle -> Task Never ExitCode
wait (ProcessHandle ph) =
    Eco.Kernel.Process.wait ph
        |> Task.map intToExitCode


exitCodeToInt : ExitCode -> Int
exitCodeToInt code =
    case code of
        ExitSuccess ->
            0

        ExitFailure n ->
            n


intToExitCode : Int -> ExitCode
intToExitCode code =
    if code == 0 then
        ExitSuccess

    else
        ExitFailure code


stdStreamToString : StdStream -> String
stdStreamToString stream =
    case stream of
        Inherit ->
            "inherit"

        CreatePipe ->
            "pipe"
