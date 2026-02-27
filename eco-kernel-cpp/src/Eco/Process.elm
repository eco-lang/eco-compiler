module Eco.Process exposing
    ( ExitCode(..)
    , ProcessHandle(..)
    , StdStream(..)
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


{-| How to handle a standard stream when spawning a process.
-}
type StdStream
    = Inherit
    | CreatePipe


{-| Exit the current process with the given exit code. Never returns.
-}
exit : ExitCode -> Task Never ()
exit code =
    Eco.Kernel.Process.exit code


{-| Spawn an external process with inherited stdio. Returns a process handle.
-}
spawn : String -> List String -> Task Never ProcessHandle
spawn cmd args =
    Eco.Kernel.Process.spawn cmd args
        |> Task.map ProcessHandle


{-| Spawn an external process with configurable stdio.
Returns a process handle and optionally a stdin handle ID (if stdin was CreatePipe).
-}
spawnProcess :
    { cmd : String
    , args : List String
    , stdin : StdStream
    , stdout : StdStream
    , stderr : StdStream
    }
    -> Task Never { stdinHandle : Maybe Int, processHandle : ProcessHandle }
spawnProcess config =
    Eco.Kernel.Process.spawnProcess config.cmd config.args config.stdin config.stdout config.stderr
        |> Task.map
            (\result ->
                { stdinHandle = result.stdinHandle
                , processHandle = ProcessHandle result.processHandle
                }
            )


{-| Wait for a process to complete and return its exit code.
-}
wait : ProcessHandle -> Task Never ExitCode
wait (ProcessHandle ph) =
    Eco.Kernel.Process.wait ph
