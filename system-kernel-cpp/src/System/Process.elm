module System.Process exposing
    ( RunOptions, defaultRunOptions, Shell(..), WorkingDirectory(..), EnvironmentVariables(..), RunDuration(..)
    , run, SuccessfulRun, FailedRun(..)
    , spawn, SpawnOptions, StreamIO, Connection(..), defaultSpawnOptions
    )

{-| A running program is a process. A process started from another process is known as a
child process.

This module lets you start child processes, either waiting for them to finish with [`run`](#run)
or letting them run in the background with [`spawn`](#spawn).

Unlike gren-node's `ChildProcess` module, there is no permission value to obtain first: every
function can be called directly.


## Running processes

@docs RunOptions, defaultRunOptions, Shell, WorkingDirectory, EnvironmentVariables, RunDuration
@docs run, SuccessfulRun, FailedRun


## Spawning processes

@docs spawn, SpawnOptions, StreamIO, Connection, defaultSpawnOptions

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Process
import Stream
import Task exposing (Task)



-- OPTIONS


{-| Options to customize the execution of a child process created with [`run`](#run).

  - `shell` is the shell to run the process in (if any).
  - `workingDirectory` specifies the working directory of the process.
  - `environmentVariables` specifies the environment variables the process has access to.
  - `maximumBytesWrittenToStreams` is an upper bound on the number of bytes the process may write
    to each of stdout and stderr. A process that writes more is terminated with `SIGTERM` and the
    run fails with a `ProgramError` whose `exitCode` is `-1`, holding the output collected so far.
  - `runDuration` specifies a maximum amount of time the process is allowed to run before it is
    terminated.

-}
type alias RunOptions =
    { shell : Shell
    , workingDirectory : WorkingDirectory
    , environmentVariables : EnvironmentVariables
    , maximumBytesWrittenToStreams : Int
    , runDuration : RunDuration
    }


{-| A nice default set of options for the [`run`](#run) function: the default shell, the
inherited working directory and environment variables, at most 1 MiB of output per stream, and
no time limit.
-}
defaultRunOptions : RunOptions
defaultRunOptions =
    Debug.todo "Implement System API"


{-| Which shell should the child process run in?

  - `NoShell` executes the program directly, without any shell. This is a little more efficient,
    but you lose shell conveniences such as glob patterns in arguments.
  - `DefaultShell` executes the program in the default shell of the running system (`/bin/sh`
    on POSIX systems). The program and its arguments are joined with spaces into a single
    command line.
  - `CustomShell` executes the program in the specified shell.

-}
type Shell
    = NoShell
    | DefaultShell
    | CustomShell String


{-| What should be the working directory of the process?

  - `InheritWorkingDirectory` inherits the working directory from its parent.
  - `SetWorkingDirectory` sets the working directory to the specified value (this does not affect
    the parent).

-}
type WorkingDirectory
    = InheritWorkingDirectory
    | SetWorkingDirectory String


{-| What should be the environment variables of the process?

  - `InheritEnvironmentVariables` inherits the environment variables from its parent.
  - `MergeWithEnvironmentVariables` inherits the environment variables from its parent, with the
    specified variables added or overridden.
  - `ReplaceEnvironmentVariables` sets the environment variables to exactly the specified
    dictionary.

-}
type EnvironmentVariables
    = InheritEnvironmentVariables
    | MergeWithEnvironmentVariables (Dict String String)
    | ReplaceEnvironmentVariables (Dict String String)


{-| How long is the process allowed to run before it is forcefully terminated?

  - `NoLimit` means it can run forever.
  - `Milliseconds` sets the limit to the specified number of milliseconds. When the limit expires
    the process is terminated with `SIGTERM`.

-}
type RunDuration
    = NoLimit
    | Milliseconds Int



-- RUN


{-| Return value when a process terminates due to an error.

Running a child process can either fail due to a system error, like the requested program not
being installed, or due to an error in the program itself, like calling it with arguments it
does not recognize.

  - `InitError` means the process could not be started. `errorCode` is the name of the system
    error, such as `"ENOENT"`.
  - `ProgramError` means the process ran but exited with a non-zero exit code. `exitCode` is `-1`
    when the process was terminated because it exceeded `runDuration` or
    `maximumBytesWrittenToStreams`.

-}
type FailedRun
    = InitError
        { program : String
        , arguments : List String
        , errorCode : String
        }
    | ProgramError
        { exitCode : Int
        , stdout : Bytes
        , stderr : Bytes
        }


{-| Return value when a process terminates without error, that is with exit code 0. It holds
everything the process wrote to stdout and stderr.
-}
type alias SuccessfulRun =
    { stdout : Bytes
    , stderr : Bytes
    }


{-| Execute a program with the given name, arguments and options, and wait for it to terminate.

    System.Process.run "cat" [ "my_file" ] System.Process.defaultRunOptions

The task succeeds if the program exits with code 0, and fails with a [`FailedRun`](#FailedRun)
otherwise.

-}
run : String -> List String -> RunOptions -> Task FailedRun SuccessfulRun
run program arguments options =
    Debug.todo "Implement System API"



-- SPAWN


{-| Options to customize the execution of a child process created with [`spawn`](#spawn).

  - `shell` is the shell to run the process in (if any).
  - `workingDirectory` specifies the working directory of the process.
  - `environmentVariables` specifies the environment variables the process has access to.
  - `runDuration` specifies a maximum amount of time the process is allowed to run before it is
    terminated.
  - `connection` lets you specify how the new process is connected to the application, and which
    message to receive when the process starts.
  - `onExit` is the message that is triggered when the process exits. The message receives the
    exit code; a process killed by a signal reports `128 + signal`.

-}
type alias SpawnOptions msg =
    { shell : Shell
    , workingDirectory : WorkingDirectory
    , environmentVariables : EnvironmentVariables
    , runDuration : RunDuration
    , connection : Connection msg
    , onExit : Int -> msg
    }


{-| Streams that can be used to communicate with a spawned child process: `input` is connected to
the child's stdin, `output` to its stdout and `error` to its stderr.
-}
type alias StreamIO =
    { input : Stream.Writable Bytes
    , output : Stream.Readable Bytes
    , error : Stream.Readable Bytes
    }


{-| What relation should the newly spawned process have with the running application?

  - `Integrated` means that the spawned process shares the application's stdin, stdout and stderr.
  - `External` means that new streams are created for stdin, stdout and stderr and passed to the
    application, which can use them to communicate with the new process.
  - `Ignored` means the same as `External`, but anything written to stdin, stdout and stderr is
    discarded.
  - `Detached` means the same as `Ignored`, but the child runs in its own session and the
    application will exit even if the child process has not finished executing.

Every variant receives the `Process.Id` of the spawned process. Calling `Process.kill` on it
terminates the child with `SIGTERM`.

-}
type Connection msg
    = Integrated (Process.Id -> msg)
    | External ({ processId : Process.Id, streams : StreamIO } -> msg)
    | Ignored (Process.Id -> msg)
    | Detached (Process.Id -> msg)


{-| A nice default set of options for the [`spawn`](#spawn) function, given the connection and
the exit message: the default shell, the inherited working directory and environment variables,
and no time limit.
-}
defaultSpawnOptions : Connection msg -> (Int -> msg) -> SpawnOptions msg
defaultSpawnOptions connection onExit =
    Debug.todo "Implement System API"


{-| Spawn a program with the given name, arguments and options, and let it run in the
background. This is mostly helpful for starting long-running processes.

    System.Process.spawn "tail" [ "-f", "my_file" ] mySpawnOptions

You receive the `connection` message once the process has started, and the `onExit` message
when it terminates.

-}
spawn : String -> List String -> SpawnOptions msg -> Cmd msg
spawn program arguments options =
    Debug.todo "Implement System API"
