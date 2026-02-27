module Eco.Process exposing
    ( ExitCode(..)
    , ProcessHandle(..)
    , StdStream(..)
    , exit, spawn, spawnProcess, wait
    )

{-| Process management via XHR: exit, spawn external processes, and wait for completion.

This is the XHR-based bootstrap implementation. The kernel variant
(in eco-kernel-cpp) has identical type signatures but delegates to
Eco.Kernel.Process directly.


# Types

@docs ExitCode, ProcessHandle, StdStream


# Operations

@docs exit, spawn, spawnProcess, wait

-}

import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
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
    Eco.XHR.unitTask "Process.exit"
        (Encode.object
            [ ( "code", Encode.int (exitCodeToInt code) ) ]
        )


{-| Spawn an external process with inherited stdio. Returns a process handle.
-}
spawn : String -> List String -> Task Never ProcessHandle
spawn cmd args =
    Eco.XHR.jsonTask "Process.spawn"
        (Encode.object
            [ ( "cmd", Encode.string cmd )
            , ( "args", Encode.list Encode.string args )
            ]
        )
        Decode.int
        |> Task.map ProcessHandle


{-| Spawn an external process with configurable stdio.
Returns a process handle and optionally a stdin handle ID (if stdin was CreatePipe).
The stdin handle ID can be used with Console.write and File.close.
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
    Eco.XHR.jsonTask "Process.spawnProcess"
        (Encode.object
            [ ( "cmd", Encode.string config.cmd )
            , ( "args", Encode.list Encode.string config.args )
            , ( "stdin", encodeStdStream config.stdin )
            , ( "stdout", encodeStdStream config.stdout )
            , ( "stderr", encodeStdStream config.stderr )
            ]
        )
        (Decode.map2
            (\stdinHandle ph ->
                { stdinHandle = stdinHandle
                , processHandle = ProcessHandle ph
                }
            )
            (Decode.field "stdinHandle" (Decode.nullable Decode.int))
            (Decode.field "processHandle" Decode.int)
        )


{-| Wait for a process to complete and return its exit code.
-}
wait : ProcessHandle -> Task Never ExitCode
wait (ProcessHandle ph) =
    Eco.XHR.jsonTask "Process.wait"
        (Encode.object [ ( "handle", Encode.int ph ) ])
        Decode.int
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


encodeStdStream : StdStream -> Encode.Value
encodeStdStream stream =
    case stream of
        Inherit ->
            Encode.string "inherit"

        CreatePipe ->
            Encode.string "pipe"
