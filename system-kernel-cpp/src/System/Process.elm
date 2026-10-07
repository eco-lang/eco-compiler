effect module System.Process where { command = MyCmd } exposing
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
import Eco.Kernel.ChildProcess
import Platform
import Process
import Stream
import Stream.Internal
import Task exposing (Task)



-- OPTIONS


{-| Options to customize the execution of a child process created with [`run`](#run).

  - `shell` is the shell to run the process in (if any).
  - `workingDirectory` specifies the working directory of the process.
  - `environmentVariables` specifies the environment variables the process has access to.
  - `maximumBytesWrittenToStreams` is an upper bound on the number of bytes the process may write
    to each of stdout and stderr. A process that writes more is terminated with `SIGTERM` and the
    run fails with a `ProgramError` whose `exitCode` is `-1`, holding the output collected so far
    (truncated at the limit). A value of `0` or less means no limit.
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
    { shell = DefaultShell
    , workingDirectory = InheritWorkingDirectory
    , environmentVariables = InheritEnvironmentVariables
    , maximumBytesWrittenToStreams = 1024 * 1024
    , runDuration = NoLimit
    }


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
otherwise. The program's standard input is empty (`/dev/null`). Killing the task with
`Process.kill` terminates the program with `SIGTERM`.

-}
run : String -> List String -> RunOptions -> Task FailedRun SuccessfulRun
run program arguments options =
    kRun program
        arguments
        (encodeShell options.shell)
        (encodeWorkingDirectory options.workingDirectory)
        (encodeEnvironmentVariables options.environmentVariables)
        ( max 0 options.maximumBytesWrittenToStreams, encodeRunDuration options.runDuration )
        |> Task.map (\( stdout, stderr ) -> { stdout = stdout, stderr = stderr })
        |> Task.mapError (decodeFailedRun program arguments)



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
    { shell = DefaultShell
    , workingDirectory = InheritWorkingDirectory
    , environmentVariables = InheritEnvironmentVariables
    , runDuration = NoLimit
    , connection = connection
    , onExit = onExit
    }


{-| Spawn a program with the given name, arguments and options, and let it run in the
background. This is mostly helpful for starting long-running processes.

    System.Process.spawn "tail" [ "-f", "my_file" ] mySpawnOptions

You receive the `connection` message once the process has started, and the `onExit` message
when it terminates. If the program cannot be started at all, you still receive the `connection`
message, immediately followed by `onExit` with a negative exit code: minus the number of the
system error (`-2` when the program does not exist), as in Node.

-}
spawn : String -> List String -> SpawnOptions msg -> Cmd msg
spawn program arguments options =
    command
        (Spawn
            ( ( program, arguments )
            , ( encodeShell options.shell, encodeWorkingDirectory options.workingDirectory )
            , ( encodeEnvironmentVariables options.environmentVariables
              , encodeRunDuration options.runDuration
              , connectionKind options.connection
              )
            )
            (onInitFor options.connection)
            (\( exitCode, _ ) -> options.onExit exitCode)
        )



-- ENCODING (plans/eco-system-library.md Appendix B.4 and C.3)


encodeShell : Shell -> ( Int, String )
encodeShell shell =
    case shell of
        NoShell ->
            ( 0, "" )

        DefaultShell ->
            ( 1, "" )

        CustomShell value ->
            ( 2, value )


encodeWorkingDirectory : WorkingDirectory -> ( Bool, String )
encodeWorkingDirectory workingDirectory =
    case workingDirectory of
        InheritWorkingDirectory ->
            ( True, "" )

        SetWorkingDirectory value ->
            ( False, value )


encodeEnvironmentVariables : EnvironmentVariables -> ( Int, List ( String, String ) )
encodeEnvironmentVariables environmentVariables =
    case environmentVariables of
        InheritEnvironmentVariables ->
            ( 0, [] )

        MergeWithEnvironmentVariables value ->
            ( 1, Dict.toList value )

        ReplaceEnvironmentVariables value ->
            ( 2, Dict.toList value )


{-| 0 means no limit.
-}
encodeRunDuration : RunDuration -> Int
encodeRunDuration runDuration =
    case runDuration of
        NoLimit ->
            0

        Milliseconds ms ->
            max 0 ms


decodeFailedRun : String -> List String -> ( Int, String, ( Int, Bytes, Bytes ) ) -> FailedRun
decodeFailedRun program arguments ( kind, errorCode, ( exitCode, stdout, stderr ) ) =
    if kind == 0 then
        InitError { program = program, arguments = arguments, errorCode = errorCode }

    else
        ProgramError { exitCode = exitCode, stdout = stdout, stderr = stderr }


connectionKind : Connection msg -> Int
connectionKind connection =
    case connection of
        Integrated _ ->
            0

        External _ ->
            1

        Ignored _ ->
            2

        Detached _ ->
            3


onInitFor : Connection msg -> ( Process.Id, Maybe ( Int, Int, Int ) ) -> msg
onInitFor connection ( processId, streams ) =
    case connection of
        Integrated toMsg ->
            toMsg processId

        External toMsg ->
            let
                ( input, output, error ) =
                    Maybe.withDefault ( 0, 0, 0 ) streams
            in
            toMsg
                { processId = processId
                , streams =
                    { input = Stream.Internal.Writable input
                    , output = Stream.Internal.Readable output
                    , error = Stream.Internal.Readable error
                    }
                }

        Ignored toMsg ->
            toMsg processId

        Detached toMsg ->
            toMsg processId



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "System.Process"
-- (src/eco-system/ChildProcess/ChildProcessManager.{hpp,cpp}, plans/eco-system-library.md
-- Appendix C.3) and ignores the Elm functions below. The JS backend runs them
-- (plans/eco-system-library.md Phase 10, D15): each Spawn starts the child through a
-- JS-only kernel, which also creates the Elm process standing for it, then delivers
-- onInit; the kernel delivers onExit when the child exits. The constructor layout of
-- MyCmd is mirrored by ChildProcessManager.hpp: keep them in sync.


type MyCmd msg
    = Spawn
        ( ( String, List String ), ( ( Int, String ), ( Bool, String ) ), ( ( Int, List ( String, String ) ), Int, Int ) )
        (( Process.Id, Maybe ( Int, Int, Int ) ) -> msg)
        (( Int, Int ) -> msg)


cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap f (Spawn spec onInit onExit) =
    Spawn spec (onInit >> f) (onExit >> f)


init : Task Never ()
init =
    Task.succeed ()


onEffects : Platform.Router msg Never -> List (MyCmd msg) -> () -> Task Never ()
onEffects router cmds _ =
    -- Effects arrive in reverse order of declaration.
    List.reverse cmds
        |> List.map (spawnChild router)
        |> Task.sequence
        |> Task.map (\_ -> ())


spawnChild : Platform.Router msg Never -> MyCmd msg -> Task Never ()
spawnChild router (Spawn spec onInit onExit) =
    kSpawn (\exit -> Platform.sendToApp router (onExit exit)) spec
        |> Task.andThen (\initArg -> Platform.sendToApp router (onInit initArg))


onSelfMsg : Platform.Router msg Never -> Never -> () -> Task Never ()
onSelfMsg _ _ _ =
    Task.succeed ()



-- KERNELS
-- The annotation fixes the kernel ABI (plans/eco-system-library.md Appendix B.4).


kRun :
    String
    -> List String
    -> ( Int, String )
    -> ( Bool, String )
    -> ( Int, List ( String, String ) )
    -> ( Int, Int )
    -> Task ( Int, String, ( Int, Bytes, Bytes ) ) ( Bytes, Bytes )
kRun =
    Eco.Kernel.ChildProcess.run



-- JS-only kernel, used by the effect-manager body above (the native backend drops that
-- body, so it has no C++ counterpart).


kSpawn :
    (( Int, Int ) -> Task Never ())
    -> ( ( String, List String ), ( ( Int, String ), ( Bool, String ) ), ( ( Int, List ( String, String ) ), Int, Int ) )
    -> Task Never ( Process.Id, Maybe ( Int, Int, Int ) )
kSpawn =
    Eco.Kernel.ChildProcess.spawn
