effect module ChildProcess where { command = MyCmd } exposing
    ( RunOptions, defaultRunOptions, Shell(..), WorkingDirectory(..), EnvironmentVariables(..), RunDuration(..)
    , run, SuccessfulRun, FailedRun(..)
    , spawn, SpawnOptions, StreamIO, Connection(..), defaultSpawnOptions
    )

{-| A program sometimes needs another program to do part of its work, and this module starts
one. A program started by the running program is its _child process_, or _child_.

There are two ways to start a child, and they differ in how its input, its output and its end
reach the program.

[`run`](#run) is a `Task` that waits for the child to end. The child's standard input is empty.
Everything it writes to its standard output and standard error is collected, up to a limit, and
handed over when it ends: as a [`SuccessfulRun`](#SuccessfulRun) when it exits with code 0
within its limits, and otherwise as a [`FailedRun`](#FailedRun).

[`spawn`](#spawn) is a `Cmd` that starts the child and lets it run alongside the program. Two
messages report on it: the [`Connection`](#Connection) message once it has started (or failed
to start), and the `onExit` message, with its exit code, once it has ended. The connection
decides what the child's standard input, output and error are: the program's own, new streams
handed to the program ([`StreamIO`](#StreamIO)), or the null device. A spawned child is identified
by a `Process.Id`: an Elm process that stands for the child until it exits. Until it exits, a
spawned child keeps the program running, unless it is `Detached`, as [`Connection`](#Connection)
describes ([`System`](System) describes when a program ends).

Three facts hold for both.

The program and its arguments reach the child unchanged only with the `NoShell`
[`Shell`](#Shell). The default shell, which both [`defaultRunOptions`](#defaultRunOptions) and
[`defaultSpawnOptions`](#defaultSpawnOptions) use, joins them with single spaces and no quoting
into one command line for `/bin/sh` (`%ComSpec%` on the native backend under Windows), so
spaces, quotes, globs and other shell syntax in an argument are interpreted by the shell. Under a
shell, a program that cannot be found is reported by the shell's exit code, not as a failure to
start.

The only signal this module sends is `SIGTERM`. It is sent, to a child that has not yet exited,
when a [`RunDuration`](#RunDuration) expires, when a `run` child writes more than its output limit,
and when `Process.kill` is called on a `run` task or on a spawned child's `Process.Id`. It goes to
the process that was started, which under a shell may be the shell rather than the program.

The two report exit codes differently. `run` reports a child that died from a signal, or that
reached one of its limits, as exit code `-1`. `spawn`'s `onExit` reports a death from signal
number `n` as `128 + n`, and a child that could not be started at all as a negative number
(`-2` for `ENOENT` on Linux and macOS).

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


{-| The options of [`run`](#run): how the child is started, and the limits on it.

`maximumBytesWrittenToStreams` limits standard output and standard error separately. When the
child writes more than that to either, it is sent `SIGTERM` if it is still running, and the run
fails with a `ProgramError` whose `exitCode` is `-1`, holding the output collected so far cut at
the limit. A value of 0 or less means no limit.

-}
type alias RunOptions =
    { shell : Shell
    , workingDirectory : WorkingDirectory
    , environmentVariables : EnvironmentVariables
    , maximumBytesWrittenToStreams : Int
    , runDuration : RunDuration
    }


{-| A starting set of options for [`run`](#run): the default shell, the running program's
working directory and environment variables, at most 1 MiB (1,048,576 bytes) on each of
standard output and standard error, and no time limit.
-}
defaultRunOptions : RunOptions
defaultRunOptions =
    { shell = DefaultShell
    , workingDirectory = InheritWorkingDirectory
    , environmentVariables = InheritEnvironmentVariables
    , maximumBytesWrittenToStreams = 1024 * 1024
    , runDuration = NoLimit
    }


{-| How the program and its arguments are turned into the process that is started.

`NoShell` starts the program itself, and passes it each argument exactly as given.

`DefaultShell` joins the program and its arguments into one command line, separated by single
spaces and with no quoting, and starts `/bin/sh -c` with that line. The shell splits the line
again by its own rules, so an argument holding a space becomes two, and quotes, globs, variables
and other shell syntax take effect. It is the shell that is started, so a program it cannot find
is reported by the shell's exit code.

`CustomShell` does the same with the named shell in place of `/bin/sh`. An empty name means the
same shell as `DefaultShell`.

On the native backend under Windows, the default shell is `%ComSpec%` (usually `cmd.exe`), and
both shells are given `/d /s /c` in place of `-c`.

-}
type Shell
    = NoShell
    | DefaultShell
    | CustomShell String


{-| The directory the child starts in.

`InheritWorkingDirectory` is the running program's current directory. `SetWorkingDirectory`
names another. Neither changes the running program's own directory.

-}
type WorkingDirectory
    = InheritWorkingDirectory
    | SetWorkingDirectory String


{-| The environment variables the child starts with.

`InheritEnvironmentVariables` gives it the running program's variables.

`MergeWithEnvironmentVariables` gives it the running program's variables together with those in
the `Dict`; a variable in both takes the `Dict`'s value.

`ReplaceEnvironmentVariables` gives it the variables in the `Dict` and no others.

-}
type EnvironmentVariables
    = InheritEnvironmentVariables
    | MergeWithEnvironmentVariables (Dict String String)
    | ReplaceEnvironmentVariables (Dict String String)


{-| How long the child may run before it is sent `SIGTERM`.

`Milliseconds` counts from the moment the child is started. A value of 0 or less is the same as
`NoLimit`.

When the limit expires, a [`run`](#run) fails with `exitCode` `-1`, while a [`spawn`](#spawn)'s
`onExit` gets whatever exit code the child then ends with.

-}
type RunDuration
    = NoLimit
    | Milliseconds Int



-- RUN


{-| Why a [`run`](#run) did not succeed: the child could not be started, or it was started and
did not succeed.

`InitError` means that no child was started. `program` and `arguments` are those given to
`run`, and `errorCode` names the error, usually by its errno name, such as `"ENOENT"`. Under a
shell, the shell is what is started, so a program the shell cannot find is a `ProgramError`
with the shell's exit code, not an `InitError`.

`ProgramError` means that the child ran. `exitCode` is `-1` when the child died from a signal,
and when it reached `runDuration` or `maximumBytesWrittenToStreams`, whatever exit code it then
ended with. Otherwise it is the child's non-zero exit code. `stdout` and `stderr` hold the output
collected from the child, each cut at `maximumBytesWrittenToStreams`. Once a limit has stopped the
run, output not yet read when the child exited is dropped. On the native backend under Windows,
`exitCode` is always `-1` and no output is collected, as [`run`](#run) says.

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


{-| What a [`run`](#run) that succeeded hands over: everything the child wrote to its standard
output and standard error. A run succeeds when the child exits with code 0 and reaches neither
limit of its [`RunOptions`](#RunOptions).
-}
type alias SuccessfulRun =
    { stdout : Bytes
    , stderr : Bytes
    }


{-| Starts `program` with `arguments`, as `options` say, and waits for it to end.

    ChildProcess.run "cat" [ "my_file" ] ChildProcess.defaultRunOptions

The task succeeds with a [`SuccessfulRun`](#SuccessfulRun) when the child exits with code 0
within both limits of `options`, and fails with a [`FailedRun`](#FailedRun) otherwise. The
child's standard input is the null device, so it reads the end of input at once.

The task ends only once the child has exited and, unless one of the limits of `options` has
stopped the run, its standard output and standard error have both reached their end. A process the
child started that keeps them open therefore delays the result until `runDuration` expires; the run
then fails with `exitCode` `-1` and the output collected so far.

Killing the task with `Process.kill` sends the child `SIGTERM` if it is still running, and the
task then never completes.

On the native backend under Windows, the output is not collected, and every run that starts a
child fails with `exitCode` `-1`.

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


{-| The options of [`spawn`](#spawn): how the child is started, how it is connected to the
program, and the message that reports its end.

`onExit` makes the message from the child's exit code. That is the child's own code when it
exits, `128 + n` when it dies from signal number `n`, and a negative number when it could not
be started: on Linux and macOS, minus the system error number (`-2` for `ENOENT`), and `-1` for a
failure that has no error number.

-}
type alias SpawnOptions msg =
    { shell : Shell
    , workingDirectory : WorkingDirectory
    , environmentVariables : EnvironmentVariables
    , runDuration : RunDuration
    , connection : Connection msg
    , onExit : Int -> msg
    }


{-| The three streams of a child spawned with `External`. `stdin` writes to the child's
standard input; `stdout` and `stderr` read what it writes to its standard output and standard
error. A failure on one of them arrives as a `Stream.Error`, as [`Stream`](Stream) describes.
(They are named `input`, `output` and `error` in gren-node.)
-}
type alias StreamIO =
    { stdin : Stream.Writable Bytes
    , stdout : Stream.Readable Bytes
    , stderr : Stream.Readable Bytes
    }


{-| How a spawned child's standard input, output and error are connected, together with the
message that reports its start.

Each constructor holds the function that makes that message. It is given a `Process.Id` for an
Elm process that stands for the child until the child exits; it is not the operating system's
process id. `Process.kill` on it sends the child `SIGTERM` if it has not yet exited, and the
`onExit` message still arrives when the child ends.

`Integrated` gives the child the running program's own standard input, output and error.

`External` gives the child three new pipes, and hands the program the other ends as a
[`StreamIO`](#StreamIO) alongside the `Process.Id`. When the child could not be started, the
message still arrives, and its streams are connected to no program.

`Ignored` connects the child's standard input, output and error to the null device: it reads the
end of input at once, and what it writes is discarded.

`Detached` is `Ignored` with the child in a new session. Unlike the others, a detached child does
not keep the program running, so the program can end while the child still runs. On the native
backend, a detached child with a `runDuration` does keep the program running, until the limit
expires or the child exits.

-}
type Connection msg
    = Integrated (Process.Id -> msg)
    | External ({ processId : Process.Id, streams : StreamIO } -> msg)
    | Ignored (Process.Id -> msg)
    | Detached (Process.Id -> msg)


{-| Builds [`spawn`](#spawn) options from `connection` and `onExit`, with the
default shell, the running program's working directory and environment variables, and no time
limit.
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


{-| Starts `program` with `arguments`, as `options` say, and lets it run alongside the program.

    ChildProcess.spawn "tail" [ "-f", "my_file" ] mySpawnOptions

The `connection` message arrives once the child has started, and the `onExit` message once it
has ended. When the program cannot be started at all, both still arrive: the `connection`
message first, then `onExit` with a negative number (`-2` when the program does not exist, on
Linux and macOS). Under a shell, a program the shell cannot find is reported by the shell's exit
code instead.

On the native backend under Windows, `spawn` stops the program with a fatal error.

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



-- ENCODING


{-| Encodes a shell as the kernels' `( kind, custom shell )` pair: kind 0 is `NoShell`, 1
`DefaultShell` and 2 `CustomShell`, whose name is the second component.
-}
encodeShell : Shell -> ( Int, String )
encodeShell shell =
    case shell of
        NoShell ->
            ( 0, "" )

        DefaultShell ->
            ( 1, "" )

        CustomShell value ->
            ( 2, value )


{-| Encodes a working directory as the kernels' `( inherit, directory )` pair; the directory is
ignored when `inherit` is `True`.
-}
encodeWorkingDirectory : WorkingDirectory -> ( Bool, String )
encodeWorkingDirectory workingDirectory =
    case workingDirectory of
        InheritWorkingDirectory ->
            ( True, "" )

        SetWorkingDirectory value ->
            ( False, value )


{-| Encodes environment variables as the kernels' `( mode, variables )` pair: mode 0 inherits,
1 merges and 2 replaces.
-}
encodeEnvironmentVariables : EnvironmentVariables -> ( Int, List ( String, String ) )
encodeEnvironmentVariables environmentVariables =
    case environmentVariables of
        InheritEnvironmentVariables ->
            ( 0, [] )

        MergeWithEnvironmentVariables value ->
            ( 1, Dict.toList value )

        ReplaceEnvironmentVariables value ->
            ( 2, Dict.toList value )


{-| Encodes a run duration as the kernels' limit in milliseconds, where 0 means no limit, so a
`Milliseconds` value of 0 or less becomes no limit.
-}
encodeRunDuration : RunDuration -> Int
encodeRunDuration runDuration =
    case runDuration of
        NoLimit ->
            0

        Milliseconds ms ->
            max 0 ms


{-| Builds a `FailedRun` from the failure the `run` kernel reports,
`( kind, errorCode, ( exitCode, stdout, stderr ) )`. Kind 0 is an `InitError`, given the
`program` and `arguments` of the run; any other kind is a `ProgramError`, and `errorCode` is
then ignored.
-}
decodeFailedRun : String -> List String -> ( Int, String, ( Int, Bytes, Bytes ) ) -> FailedRun
decodeFailedRun program arguments ( kind, errorCode, ( exitCode, stdout, stderr ) ) =
    if kind == 0 then
        InitError { program = program, arguments = arguments, errorCode = errorCode }

    else
        ProgramError { exitCode = exitCode, stdout = stdout, stderr = stderr }


{-| Returns the kernels' number for a connection's kind: 0 `Integrated`, 1 `External`, 2
`Ignored`, 3 `Detached`. The native manager's `CONN_*` constants in `ChildProcessManager.hpp`
use the same numbers.
-}
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


{-| Builds the `connection` message from what the kernel reports once a child has started: the
`Process.Id` standing for it and, for `External`, the stream ids of its standard input, output
and error. Stream ids the report lacks become 0, which names no stream.
-}
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
                    { stdin = Stream.Internal.Writable input
                    , stdout = Stream.Internal.Readable output
                    , stderr = Stream.Internal.Readable error
                    }
                }

        Ignored toMsg ->
            toMsg processId

        Detached toMsg ->
            toMsg processId



-- EFFECT MANAGER
--
-- On the native backend the Elm functions below are not used: the C++ manager registered as
-- "ChildProcess" (src/eco-system/ChildProcess/ChildProcessManager.{hpp,cpp}) takes their place
-- and reads MyCmd by constructor and field position, as ChildProcessManager.hpp spells out, so
-- the two must be kept in sync. The JS backend runs them, and starts each child through the
-- JS-only kSpawn.


{-| The one command of this effect manager: start a child.

`Spawn` carries the encoded program, arguments and options, as three nested tuples:
`( program, arguments )`, `( shell, working directory )` and
`( environment, runDuration in milliseconds, connection kind )`, then the function that makes
the `connection` message from the kernel's start report, and the function that makes the exit
message from the kernel's `( exitCode, signal )` pair.

-}
type MyCmd msg
    = Spawn
        ( ( String, List String ), ( ( Int, String ), ( Bool, String ) ), ( ( Int, List ( String, String ) ), Int, Int ) )
        (( Process.Id, Maybe ( Int, Int, Int ) ) -> msg)
        (( Int, Int ) -> msg)


{-| Applies `f` to both messages a `Spawn` command makes.
-}
cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap f (Spawn spec onInit onExit) =
    Spawn spec (onInit >> f) (onExit >> f)


{-| The manager's initial state, `()`: it keeps no state between commands.
-}
init : Task Never ()
init =
    Task.succeed ()


{-| Starts a child for each `Spawn` command, one after another, in the order the commands were
given.
-}
onEffects : Platform.Router msg Never -> List (MyCmd msg) -> () -> Task Never ()
onEffects router cmds _ =
    -- Effects arrive in reverse order of declaration.
    List.reverse cmds
        |> List.map (spawnChild router)
        |> Task.sequence
        |> Task.map (\_ -> ())


{-| Starts the child of one `Spawn` command through `kSpawn` and sends the program its
`connection` message; the kernel sends the exit message once the child has ended.
-}
spawnChild : Platform.Router msg Never -> MyCmd msg -> Task Never ()
spawnChild router (Spawn spec onInit onExit) =
    kSpawn (\exit -> Platform.sendToApp router (onExit exit)) spec
        |> Task.andThen (\initArg -> Platform.sendToApp router (onInit initArg))


{-| Ignores self-messages, of which this manager has none.
-}
onSelfMsg : Platform.Router msg Never -> Never -> () -> Task Never ()
onSelfMsg _ _ _ =
    Task.succeed ()



-- KERNELS
-- The annotations fix the kernel ABI: the kernels rely on exactly these argument and result
-- shapes.


{-| The kernel's `run`. Its last argument is `( output limit in bytes, runDuration in
milliseconds )`, where 0 means no limit for either. It succeeds with `( stdout, stderr )`, and
fails with `( kind, errorCode, ( exitCode, stdout, stderr ) )`, where kind 0 means the child
could not be started and `errorCode` names the error, and kind 1 means it ran and did not
succeed.
-}
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



-- JS-only kernel, used by the effect-manager body above (the native backend does not use that
-- body, so it has no C++ counterpart).


{-| The JS kernel's `spawn`. Given the function that sends the exit message and the encoded
spec, it starts the child and an Elm process that stands for it, and succeeds with that
process's id and, for `External`, `Just` the stream ids of the child's standard input, output
and error.
-}
kSpawn :
    (( Int, Int ) -> Task Never ())
    -> ( ( String, List String ), ( ( Int, String ), ( Bool, String ) ), ( ( Int, List ( String, String ) ), Int, Int ) )
    -> Task Never ( Process.Id, Maybe ( Int, Int, Int ) )
kSpawn =
    Eco.Kernel.ChildProcess.spawn
