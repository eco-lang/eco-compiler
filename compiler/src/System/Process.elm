module System.Process exposing
    ( CreateProcess, CmdSpec, StdStream(..), proc
    , withCreateProcess, ProcessHandle, waitForProcess
    )

{-| External process creation and management for the Elm compiler.

This module provides functionality to spawn and control external processes,
allowing the compiler to invoke system tools, shell commands, and other
programs. It handles process configuration including standard stream redirection
and process lifetime management.

Ref.: <https://hackage.haskell.org/package/process-1.6.25.0/docs/System-Process.html>


# Process Configuration

@docs CreateProcess, CmdSpec, StdStream, proc


# Running Processes

@docs withCreateProcess, ProcessHandle, waitForProcess

-}

import Json.Decode as Decode
import Json.Encode as Encode
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)
import Utils.Impure as Impure


{-| Specification of a command to execute, with the executable and its arguments.
-}
type CmdSpec
    = RawCommand String (List String)


{-| Configuration for creating a new process, specifying command and standard stream handling.
-}
type alias CreateProcess =
    { cmdspec : CmdSpec
    , std_in : StdStream
    , std_out : StdStream
    , std_err : StdStream
    }


{-| Specification for how to handle a standard stream (stdin, stdout, or stderr) when creating a process.
-}
type StdStream
    = Inherit
    | CreatePipe


{-| Opaque handle to a running process, wrapping a process ID.
-}
type ProcessHandle
    = ProcessHandle Int


{-| Create a process configuration for running a command with arguments, inheriting all standard streams.
-}
proc : String -> List String -> CreateProcess
proc cmd args =
    { cmdspec = RawCommand cmd args
    , std_in = Inherit
    , std_out = Inherit
    , std_err = Inherit
    }


{-| Create and run a process with the given configuration, pass handles to a callback, and wait for completion.
-}
withCreateProcess : CreateProcess -> (Maybe IO.Handle -> Maybe IO.Handle -> Maybe IO.Handle -> ProcessHandle -> Task Never Exit.ExitCode) -> Task Never Exit.ExitCode
withCreateProcess createProcess f =
    Impure.task "withCreateProcess"
        []
        (Impure.JsonBody
            (Encode.object
                [ ( "cmdspec"
                  , case createProcess.cmdspec of
                        RawCommand cmd args ->
                            Encode.object
                                [ ( "type", Encode.string "RawCommand" )
                                , ( "cmd", Encode.string cmd )
                                , ( "args", Encode.list Encode.string args )
                                ]
                  )
                , ( "stdin"
                  , case createProcess.std_in of
                        Inherit ->
                            Encode.string "inherit"

                        CreatePipe ->
                            Encode.string "pipe"
                  )
                , ( "stdout"
                  , case createProcess.std_out of
                        Inherit ->
                            Encode.string "inherit"

                        CreatePipe ->
                            Encode.string "pipe"
                  )
                , ( "stderr"
                  , case createProcess.std_err of
                        Inherit ->
                            Encode.string "inherit"

                        CreatePipe ->
                            Encode.string "pipe"
                  )
                ]
            )
        )
        (Impure.DecoderResolver
            (Decode.map2 Tuple.pair
                (Decode.field "stdinHandle" (Decode.maybe Decode.int))
                (Decode.field "ph" Decode.int)
            )
        )
        |> Task.andThen
            (\( stdinHandle, ph ) ->
                f (Maybe.map IO.Handle stdinHandle) Nothing Nothing (ProcessHandle ph)
            )


{-| Wait for a process to complete and return its exit code.
-}
waitForProcess : ProcessHandle -> Task Never Exit.ExitCode
waitForProcess (ProcessHandle ph) =
    Impure.task "waitForProcess"
        []
        (Impure.StringBody (String.fromInt ph))
        (Impure.DecoderResolver
            (Decode.map
                (\int ->
                    if int == 0 then
                        Exit.ExitSuccess

                    else
                        Exit.ExitFailure int
                )
                Decode.int
            )
        )
