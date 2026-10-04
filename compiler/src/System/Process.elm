module System.Process exposing
    ( CreateProcess, CmdSpec, StdStream(..), proc
    , withCreateProcess, ProcessHandle, waitForProcess
    )

{-| The compiler can run another program and wait for it to end, and this
module is how it does so, through an interface whose names follow Haskell's
`System.Process`.

A program started this way is a _child_. Starting one is a request to
`Eco.Process.spawnProcess`, and waiting for it is a request to
`Eco.Process.wait`; that module describes how each request is carried out and
what its answers mean. This module is a small part of the Haskell interface laid
over those two requests.

A child is described by a `CreateProcess`: the command to run, and what to do
with each of its three standard streams. `proc` gives one in which the child
shares all three streams with the compiler. `withCreateProcess` starts the child
and hands a callback what it needs to talk to it, and waiting for the child,
with `waitForProcess`, is left to the callback. Only standard input can be
handed back as a handle; asking for a pipe on standard output or standard error
creates one that nothing here gives a way to read.

When `Eco.Process.spawnProcess` fails, the result is not a failed task:
`withCreateProcess` writes the reason to standard error and gives exit
code 127.


# Process Configuration

@docs CreateProcess, CmdSpec, StdStream, proc


# Running Processes

@docs withCreateProcess, ProcessHandle, waitForProcess

-}

import Eco.Process
import Eco.Process.Error as ProcErr exposing (ProcessError)
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)


{-| A command to run.

`RawCommand` carries the program and the list of arguments to start it with,
which are passed on to `Eco.Process.spawnProcess` as they are. It is the only
form, so there is no way to give a command as one line of text. The
constructor is not exposed, so outside this module a `CmdSpec` is made only by
`proc`.

-}
type CmdSpec
    = RawCommand String (List String)


{-| Everything needed to start a child: the command, and a `StdStream` for each
of its standard input, standard output and standard error.

`std_out` and `std_err` can be set to `CreatePipe`, but `withCreateProcess`
never hands back a handle for either, so such a pipe cannot be read.

-}
type alias CreateProcess =
    { cmdspec : CmdSpec
    , std_in : StdStream
    , std_out : StdStream
    , std_err : StdStream
    }


{-| What to do with one of a child's standard streams.

`Inherit` has the child share the compiler's own stream. `CreatePipe` asks for
a new pipe in its place, and it is only for standard input that
`withCreateProcess` can hand the pipe back as a handle.

-}
type StdStream
    = Inherit
    | CreatePipe


{-| A child started by `withCreateProcess`, for passing to `waitForProcess`.

The only way to get one is as the argument `withCreateProcess` passes to its
callback, so every `ProcessHandle` names a child that this module asked to
start. How waiting on the same handle twice behaves is decided by
`Eco.Process.wait`.

-}
type ProcessHandle
    = ProcessHandle Int


{-| Returns the `CreateProcess` that runs `cmd` with the arguments `args`, with
all three standard streams set to `Inherit`.
-}
proc : String -> List String -> CreateProcess
proc cmd args =
    { cmdspec = RawCommand cmd args
    , std_in = Inherit
    , std_out = Inherit
    , std_err = Inherit
    }


{-| Starts the child that `createProcess` describes, and returns the exit code
the callback `f` gives for it.

`f` receives the child's standard input, its standard output, its standard
error and its `ProcessHandle`. Standard input is `Just` a handle when
`Eco.Process.spawnProcess` replies with one, which `Eco.Process` describes.
Standard output and standard error are always `Nothing`, whatever `std_out` and
`std_err` ask for. This function neither waits for the child nor closes its
standard input; both are left to `f`, and `waitForProcess` is how it waits.

If `Eco.Process.spawnProcess` fails, `f` is not called. Instead a line made of
`error: cannot run process:`, a space and `Eco.Process.Error.toString` of the
failure is written to standard error, and the result is `ExitFailure 127`.

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
                    |> Task.mapError never
            )
        |> Task.onError handleSpawnFailure


{-| Writes a line describing `err`, starting `error: cannot run process:`, to
standard error, and gives `ExitFailure 127` whatever kind of failure `err` is.
-}
handleSpawnFailure : ProcessError -> Task Never Exit.ExitCode
handleSpawnFailure err =
    IO.writeLn IO.stderr ("error: cannot run process: " ++ ProcErr.toString err)
        |> Task.map (\_ -> Exit.ExitFailure 127)


{-| Waits for the child `ProcessHandle` names to end, and returns its exit code
as `Eco.Process.wait` gives it: `ExitSuccess` for 0 and `ExitFailure` for any
other number.

`Eco.Process.wait` describes the cases in which the code it reports is not the
child's own, the case in which it never answers, and what a failed request
does.

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


{-| Returns the number an `Eco.Process.ProcessHandle` names its child by.
-}
unwrapProcessHandle : Eco.Process.ProcessHandle -> Int
unwrapProcessHandle (Eco.Process.ProcessHandle ph) =
    ph
