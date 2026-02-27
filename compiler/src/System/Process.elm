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

import Eco.Process
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)


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
    let
        ( cmd, cmdArgs ) =
            case createProcess.cmdspec of
                RawCommand c a ->
                    ( c, a )

        toEcoStream stdStream =
            case stdStream of
                Inherit ->
                    Eco.Process.Inherit

                CreatePipe ->
                    Eco.Process.CreatePipe
    in
    Eco.Process.spawnProcess
        { cmd = cmd
        , args = cmdArgs
        , stdin = toEcoStream createProcess.std_in
        , stdout = toEcoStream createProcess.std_out
        , stderr = toEcoStream createProcess.std_err
        }
        |> Task.andThen
            (\result ->
                f (Maybe.map IO.Handle result.stdinHandle)
                    Nothing
                    Nothing
                    (ProcessHandle (unwrapProcessHandle result.processHandle))
            )


{-| Wait for a process to complete and return its exit code.
-}
waitForProcess : ProcessHandle -> Task Never Exit.ExitCode
waitForProcess (ProcessHandle ph) =
    Eco.Process.wait (Eco.Process.ProcessHandle ph)
        |> Task.map
            (\exitCode ->
                case exitCode of
                    Eco.Process.ExitSuccess ->
                        Exit.ExitSuccess

                    Eco.Process.ExitFailure n ->
                        Exit.ExitFailure n
            )


unwrapProcessHandle : Eco.Process.ProcessHandle -> Int
unwrapProcessHandle (Eco.Process.ProcessHandle ph) =
    ph
