module Eco.Process exposing
    ( ExitCode(..)
    , ProcessHandle
    , exit, spawn, wait
    )

{-| Process management: exit, spawn external processes, and wait for completion.

All operations are atomic IO primitives backed by kernel implementations.


# Types

@docs ExitCode, ProcessHandle


# Operations

@docs exit, spawn, wait

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


{-| Exit the current process with the given exit code. Never returns.
-}
exit : ExitCode -> Task Never ()
exit code =
    Eco.Kernel.Process.exit code


{-| Spawn an external process. Returns a process handle for waiting.
-}
spawn : String -> List String -> Task Never ProcessHandle
spawn cmd args =
    Eco.Kernel.Process.spawn cmd args
        |> Task.map ProcessHandle


{-| Wait for a process to complete and return its exit code.
-}
wait : ProcessHandle -> Task Never ExitCode
wait (ProcessHandle ph) =
    Eco.Kernel.Process.wait ph
