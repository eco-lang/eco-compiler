effect module System where { command = MyCmd, subscription = MySub } exposing
    ( program, simpleProgram
    , Environment, environmentVariables, Platform(..), CpuArchitecture(..)
    , exit, exitWithCode, setExitCode
    , onEmptyEventLoop, rearmEmptyEventLoop, onSignalInterrupt, onSignalTerminate
    )

{-| An Eco system program is an ordinary Elm `Platform.Program` that runs as a command-line tool
or a server, and this module is what makes it one: the [`Environment`](#Environment) it starts
with, and the controls that act on the whole running program, such as its exit code and the
signals sent to it.

The flags of such a program are an `Environment`. Eco recognises a `main` whose flags type is
`System.Environment` and builds the environment itself when the program starts, so any flags
JSON a host supplies is ignored. The environment tells you which platform the program is
running on, which arguments it was started with and when it started, and gives you its standard
input, output and error streams.

A long-running program, one that keeps state, reacts to messages and listens to
subscriptions, is made with [`program`](#program):

    main : Platform.Program System.Environment Model Msg
    main =
        System.program
            { init = \env -> ( initialModel env, Cmd.none )
            , update = update
            , subscriptions = subscriptions
            }

A _simple program_ runs a single task and then ends. It is made with
[`simpleProgram`](#simpleProgram):

    main : Platform.Program System.Environment () ()
    main =
        System.simpleProgram
            (\env -> Stream.logLine "Hello, world!" env.stdout)

A program runs while it is waiting for something it asked for, and ends when it is not. It is
waiting while a task it started has not finished, such as a read, a write, an `accept`, a
sleep, an HTTP request or a child process it spawned; while it subscribes to something that can
still deliver, such as new connections on an open listener, messages on an open WebSocket or
changes to a watched file; and while it owes an answer to an HTTP request it was given.
Opening something does not keep a program running: an open listener with no `accept` waiting
and no subscription, or an open connection with no read or write in progress, does not.
Connections, datagrams and requests that arrive while nothing asks for them are held for later
and do not keep a program running either. Some subscriptions never keep a program running,
because they wait for things the program did not ask for; their docs say so.

When nothing is left to wait for, the program has an _empty event loop_ and ends, unless it
subscribes to [`onEmptyEventLoop`](#onEmptyEventLoop), which is told once and can ask to be
told again with [`rearmEmptyEventLoop`](#rearmEmptyEventLoop). [`exit`](#exit) and
[`exitWithCode`](#exitWithCode) end the program at once, whatever it is waiting for.

The same rule covers the `elm/*` packages. A `Process.sleep` keeps the program running until it
ends, a `Time.every` subscription while it exists, and an `elm/http` request while it is in
flight. `Http.track` adds nothing of its own: a tracker with no request in flight does not keep
the program running.

Eco compiles a program either to native code or to JavaScript run by Node. Where the two
behave differently, the docstrings say so. A native program can also be embedded in a host
application, which then owns the process. An embedded program does not end when it runs out of
work: it runs until the host stops it or it calls [`exitWithCode`](#exitWithCode). Embedding
also changes what exiting and signals do, as the functions below describe.


# Programs

@docs program, simpleProgram


# Environment information

@docs Environment, environmentVariables, Platform, CpuArchitecture


# Exit

@docs exit, exitWithCode, setExitCode


# Subscriptions

@docs onEmptyEventLoop, rearmEmptyEventLoop, onSignalInterrupt, onSignalTerminate

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Eco.Kernel.System
import Platform
import Process
import Stream
import Stream.Internal
import Path exposing (Path)
import Json.Decode
import Task exposing (Task)
import Time



-- ENVIRONMENT


{-| What a program is told about itself when it starts: the platform it runs on, how it was
started, and its standard streams.

  - `applicationPath` is the path of the running program. On the native backend it is the
    executable, with symbolic links resolved where the system allows it, or `Path.empty` where
    it cannot be read, which includes every system other than Linux and macOS. On the
    JavaScript backend it is the path of the compiled JavaScript file, with symbolic links
    resolved where possible, or of the `node` executable when the program is not loaded as a
    CommonJS module. The text is read with [`Path.fromPosixString`](Path#fromPosixString) on every
    system.
  - `args` holds the command line arguments. On the native backend, on Linux, macOS and
    Windows, it is the process's C `argv`, so it starts with the program as it was invoked;
    elsewhere the list is empty. Embedded
    in a host application, it is the host's `argv`. On the JavaScript backend it is Node's
    `process.argv` without the `node` executable, so it starts with the script.
  - `startTime` is read once, when the environment is built just before `init`, so `init` does
    not need to ask for the time.
  - `stdout`, `stderr` and `stdin` are three separate streams over the process's standard
    output, error and input; the `Stream` module says what can be done with them, and
    `Stream.readLine` reads standard input a line at a time. Closing or cancelling one of them
    ends that stream but leaves the process's standard file descriptor open.

-}
type alias Environment =
    { platform : Platform
    , cpuArchitecture : CpuArchitecture
    , applicationPath : Path
    , args : List String
    , startTime : Time.Posix
    , stdout : Stream.Writable Bytes
    , stderr : Stream.Writable Bytes
    , stdin : Stream.Readable Bytes
    }


{-| The operating system a program is running on, spelled as Node's `process.platform` spells
it. `Win32` is Windows and `Darwin` is macOS; `Linux`, `FreeBSD`, `OpenBSD`, `SunOS` and
`Aix` are the systems they name.

`UnknownPlatform` carries the name of any other platform, as the backend reported it. On the
native backend the platform is fixed when the program is compiled, and one this type does not
name is reported as `UnknownPlatform "unknown"`.

-}
type Platform
    = Win32
    | Darwin
    | Linux
    | FreeBSD
    | OpenBSD
    | SunOS
    | Aix
    | UnknownPlatform String


{-| Returns the `Platform` a backend's platform name stands for, ignoring case, or
`UnknownPlatform` with the name as given.
-}
platformFromString : String -> Platform
platformFromString platform =
    case String.toLower platform of
        "win32" ->
            Win32

        "darwin" ->
            Darwin

        "linux" ->
            Linux

        "freebsd" ->
            FreeBSD

        "openbsd" ->
            OpenBSD

        "sunos" ->
            SunOS

        "aix" ->
            Aix

        _ ->
            UnknownPlatform platform


{-| The processor architecture a program is running on, spelled as Node's `process.arch` spells
it. `X64` is 64-bit x86 and `IA32` 32-bit x86; `Arm` and `Arm64` are 32-bit and 64-bit Arm;
`Mips` and `Mipsel` are big-endian and little-endian MIPS; `PPC` and `PPC64` are 32-bit and
64-bit PowerPC; `S390` and `S390x` are 31-bit and 64-bit IBM mainframe (s390) processors.

`UnknownArchitecture` carries the name of any other architecture, as the backend reported it.
On the native backend the architecture is fixed when the program is compiled; 64-bit RISC-V is
reported as `UnknownArchitecture "riscv64"`, and any other architecture this type does not
name as `UnknownArchitecture "unknown"`.

-}
type CpuArchitecture
    = Arm
    | Arm64
    | IA32
    | Mips
    | Mipsel
    | PPC
    | PPC64
    | S390
    | S390x
    | X64
    | UnknownArchitecture String


{-| Returns the `CpuArchitecture` a backend's architecture name stands for, ignoring case, or
`UnknownArchitecture` with the name as given.
-}
archFromString : String -> CpuArchitecture
archFromString arch =
    case String.toLower arch of
        "arm" ->
            Arm

        "arm64" ->
            Arm64

        "ia32" ->
            IA32

        "mips" ->
            Mips

        "mipsel" ->
            Mipsel

        "ppc" ->
            PPC

        "ppc64" ->
            PPC64

        "s390" ->
            S390

        "s390x" ->
            S390x

        "x64" ->
            X64

        _ ->
            UnknownArchitecture arch


{-| Reads the environment variables of the running process, mapping each variable's name to
its value.

The variables are read when the task runs, not when the program starts. On the native backend
an entry with no `=` is read as a name with the empty value.

-}
environmentVariables : Task x (Dict String String)
environmentVariables =
    kGetEnvironmentVariables
        |> Task.map Dict.fromList
        |> Task.mapError never


{-| The flags decoder of every program whose flags are an [`Environment`](#Environment).

It looks unused, but the Eco compiler refers to it by name and uses it in place of the JSON
decoder it would make for ordinary flags. It ignores the flags JSON and builds the environment
through the kernel. The JSON value is passed to the kernel only so that the call depends on the
decoder's argument and can never be hoisted out of it.

-}
environmentDecoder : Json.Decode.Decoder Environment
environmentDecoder =
    Json.Decode.map toEnvironment Json.Decode.value


{-| Builds the `Environment` from what the kernel reports, ignoring the flags `json` except to
pass it on.
-}
toEnvironment : Json.Decode.Value -> Environment
toEnvironment json =
    let
        ( ( platform, arch, applicationPath ), ( args, startMillis ), ( stdin, stdout, stderr ) ) =
            kEnvironmentNow json
    in
    { platform = platformFromString platform
    , cpuArchitecture = archFromString arch
    , applicationPath = Path.fromPosixString applicationPath
    , args = args
    , startTime = Time.millisToPosix startMillis
    , stdout = Stream.Internal.Writable stdout
    , stderr = Stream.Internal.Writable stderr
    , stdin = Stream.Internal.Readable stdin
    }



-- PROGRAMS


{-| Creates a long-running program from an `init`, an `update` and `subscriptions`, as
`Platform.worker` does, with the program's [`Environment`](#Environment) as its flags.

The program runs while it is waiting for something, as the module documentation describes,
and ends when it has an empty event loop that [`onEmptyEventLoop`](#onEmptyEventLoop) does not
take over.

-}
program :
    { init : Environment -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }
    -> Platform.Program Environment model msg
program =
    Platform.worker


{-| Creates a simple program: one that runs the task `run` makes from the
[`Environment`](#Environment), and has no state, messages or subscriptions.

The task's result is ignored. If the task fails, the program's exit code is set to 1, as
[`setExitCode`](#setExitCode) sets it; if it succeeds, the exit code is left as it is, which is
0 unless the task set another. The program ends as any program does, so it waits for IO the
task started even after the task has finished. To end with a particular non-zero exit code,
finish the task with [`setExitCode`](#setExitCode):

    main : Platform.Program System.Environment () ()
    main =
        System.simpleProgram
            (\env ->
                case List.drop 1 env.args of
                    [] ->
                        Stream.logLine "usage: greet NAME" env.stderr
                            |> Task.andThen (\_ -> System.setExitCode 2)

                    name :: _ ->
                        Stream.logLine ("Hello, " ++ name ++ "!") env.stdout
            )

-}
simpleProgram : (Environment -> Task x a) -> Platform.Program Environment () ()
simpleProgram run =
    Platform.worker
        { init =
            \env ->
                ( ()
                , command
                    (Execute
                        (run env
                            |> Task.map (\_ -> ())
                            |> Task.onError (\_ -> kSetExitCode 1)
                        )
                    )
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }




-- EXIT


{-| Ends the program at once with exit code 0, as `exitWithCode 0` does.
-}
exit : Cmd msg
exit =
    exitWithCode 0


{-| Ends the program at once with exit `code`.

It does not wait for work still in progress, such as an HTTP request, a file write, a stream
write that has not yet succeeded, or a value `Stream.enqueue` has queued but not yet written,
so it is for a state where continuing makes no sense; to end once that work is done, use
[`setExitCode`](#setExitCode) instead. The exit code can be read by the process that started
the program.

On the native backend, when the program is embedded in a host application, the process is not
ended: the program stops and the host receives `code`.

-}
exitWithCode : Int -> Cmd msg
exitWithCode code =
    command (Execute (kExitWithCode code))


{-| Sets the exit code the program ends with, without ending it.

A later `setExitCode` replaces the code, and [`exitWithCode`](#exitWithCode) ends the program
with its own.

-}
setExitCode : Int -> Task x ()
setExitCode code =
    kSetExitCode code
        |> Task.mapError never



-- SUBSCRIPTIONS


{-| Creates a subscription that receives `msg` when the program has an empty event loop:
nothing it is waiting for is left, so the program would otherwise end.

The message arrives once. Work started while handling it runs to completion, and the next time
the event loop is empty the program ends. To receive the message again at the next empty
event loop, issue [`rearmEmptyEventLoop`](#rearmEmptyEventLoop). If the program has several
`onEmptyEventLoop` subscriptions, each receives its message at the same moment.

Whether the message is due is one setting for the whole run of the program. It starts on, so a
program that subscribes some time after it starts still receives the message once. Delivering
the message turns it off, and only `rearmEmptyEventLoop` turns it on again: subscribing anew
after a delivery is not enough.

The subscription does not keep the program running. On the native backend it never fires
when the program is embedded in a host application.

-}
onEmptyEventLoop : msg -> Sub msg
onEmptyEventLoop msg =
    subscription (OnEmptyEventLoop msg)


{-| Asks for [`onEmptyEventLoop`](#onEmptyEventLoop) to deliver its message again the next
time the program has an empty event loop.

Issue it while handling that message, or in any later update before the event loop is next
empty, for example once more jobs have been queued. If the program issues it and then starts
no work, the event loop is empty again at once, so the message arrives again at once; a
program that issues it on every delivery without starting work never ends. Issuing it when
there is no `onEmptyEventLoop` subscription has no effect until the program subscribes.

-}
rearmEmptyEventLoop : Cmd msg
rearmEmptyEventLoop =
    command (Execute kRearmEmptyEventLoop)


{-| Creates a subscription that receives `msg` when the process is sent an interrupt
signal (`SIGINT`, the signal a terminal sends on Ctrl+C).

While the subscription exists, the signal no longer ends the program, so ending it is up to the
program. The subscription does not keep the program running. On the native backend it has no
effect on Windows or when the program is embedded in a host application: it never fires, and
the signal is handled as it would be without it.

-}
onSignalInterrupt : msg -> Sub msg
onSignalInterrupt msg =
    subscription (OnSignalInterrupt msg)


{-| Creates a subscription that receives `msg` when the process is sent a terminate
signal (`SIGTERM`, the request to shut down that service managers and the `kill` command send).

While the subscription exists, the signal no longer ends the program, so ending it is up to the
program. The subscription does not keep the program running. On the native backend it has no
effect on Windows or when the program is embedded in a host application: it never fires, and
the signal is handled as it would be without it.

-}
onSignalTerminate : msg -> Sub msg
onSignalTerminate msg =
    subscription (OnSignalTerminate msg)



-- EFFECT MANAGER
--
-- The Elm effect-manager bodies in this package run only on the JS backend. On the native
-- backend each effect module is served by a C++ manager registered under the module's name,
-- here "System" (src/eco-system/System/SystemManager.{hpp,cpp}), which replaces init,
-- onEffects, onSelfMsg, cmdMap and subMap below and reads MyCmd and MySub by constructor position
-- and field layout: keep SystemManager.hpp in sync with them. On JS, each kind of subscription
-- keeps one listener process while it has subscribers: a kernel binding that never completes,
-- killed when the last subscription of that kind goes away, that notifies the manager through
-- `Platform.sendToSelf`. An event that arrives with no subscriber is dropped.


{-| The one command this module's manager runs: `Execute` spawns its task as a process of its
own, whose result is ignored.
-}
type MyCmd msg
    = Execute (Task Never ())


{-| A subscription to one of the events this module reports, carrying the message to send when
it occurs.

`OnEmptyEventLoop` is for an empty event loop, `OnSignalInterrupt` for `SIGINT` and
`OnSignalTerminate` for `SIGTERM`.

-}
type MySub msg
    = OnEmptyEventLoop msg
    | OnSignalInterrupt msg
    | OnSignalTerminate msg


{-| Returns the command unchanged, since `Execute` carries no message.
-}
cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ (Execute task) =
    Execute task


{-| Applies `f` to the message the subscription carries.
-}
subMap : (a -> b) -> MySub a -> MySub b
subMap f sub =
    case sub of
        OnEmptyEventLoop msg ->
            OnEmptyEventLoop (f msg)

        OnSignalInterrupt msg ->
            OnSignalInterrupt (f msg)

        OnSignalTerminate msg ->
            OnSignalTerminate (f msg)


{-| The JS manager's state: the subscribers and listener of each kind of event.
-}
type alias State msg =
    { emptyEventLoop : Listeners msg
    , signalInterrupt : Listeners msg
    , signalTerminate : Listeners msg
    }


{-| The subscribers to one kind of event, as the messages to send them in subscription order,
and the listener process that runs while there are any.
-}
type alias Listeners msg =
    { msgs : List msg
    , listener : Maybe Process.Id
    }


{-| The self-message a listener process sends when its event occurs.

`NotifyEmptyEventLoop` reports an empty event loop, `NotifySignalInterrupt` a `SIGINT` and
`NotifySignalTerminate` a `SIGTERM`.

-}
type Event
    = NotifyEmptyEventLoop
    | NotifySignalInterrupt
    | NotifySignalTerminate


{-| The manager's starting state, with no subscribers and no listeners.
-}
init : Task Never (State msg)
init =
    Task.succeed
        { emptyEventLoop = noListeners
        , signalInterrupt = noListeners
        , signalTerminate = noListeners
        }


{-| The state of a kind of event with no subscribers and no listener process.
-}
noListeners : Listeners msg
noListeners =
    { msgs = [], listener = Nothing }


{-| Spawns each command's task, in the order the commands were given, then brings each kind
of event's subscribers and listener process up to date with `subs`.
-}
onEffects : Platform.Router msg Event -> List (MyCmd msg) -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router cmds subs state =
    let
        -- Effects arrive in reverse order of declaration.
        ordered =
            List.reverse subs

        emptyMsgs =
            List.filterMap
                (\sub ->
                    case sub of
                        OnEmptyEventLoop msg ->
                            Just msg

                        _ ->
                            Nothing
                )
                ordered

        interruptMsgs =
            List.filterMap
                (\sub ->
                    case sub of
                        OnSignalInterrupt msg ->
                            Just msg

                        _ ->
                            Nothing
                )
                ordered

        terminateMsgs =
            List.filterMap
                (\sub ->
                    case sub of
                        OnSignalTerminate msg ->
                            Just msg

                        _ ->
                            Nothing
                )
                ordered
    in
    List.reverse cmds
        |> List.map (\(Execute task) -> Process.spawn task)
        |> Task.sequence
        |> Task.andThen
            (\_ ->
                Task.map3 State
                    (updateListeners emptyMsgs
                        state.emptyEventLoop
                        (kAttachEmptyEventLoopListener (Platform.sendToSelf router NotifyEmptyEventLoop))
                    )
                    (updateListeners interruptMsgs
                        state.signalInterrupt
                        (kAttachSignalListener "SIGINT" (Platform.sendToSelf router NotifySignalInterrupt))
                    )
                    (updateListeners terminateMsgs
                        state.signalTerminate
                        (kAttachSignalListener "SIGTERM" (Platform.sendToSelf router NotifySignalTerminate))
                    )
            )


{-| Returns the new state of one kind of event with subscribers `msgs`: the listener process
is started with `attach` when the first subscriber appears, kept while there are any, and
killed when the last one goes away.
-}
updateListeners : List msg -> Listeners msg -> Task Never () -> Task Never (Listeners msg)
updateListeners msgs current attach =
    case ( msgs, current.listener ) of
        ( [], Just pid ) ->
            Process.kill pid
                |> Task.map (\_ -> noListeners)

        ( [], Nothing ) ->
            Task.succeed noListeners

        ( _, Just pid ) ->
            Task.succeed { msgs = msgs, listener = Just pid }

        ( _, Nothing ) ->
            Process.spawn attach
                |> Task.map (\pid -> { msgs = msgs, listener = Just pid })


{-| Sends the message of every current subscriber to the event that occurred, in subscription
order.
-}
onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router event state =
    let
        listeners =
            case event of
                NotifyEmptyEventLoop ->
                    state.emptyEventLoop

                NotifySignalInterrupt ->
                    state.signalInterrupt

                NotifySignalTerminate ->
                    state.signalTerminate
    in
    listeners.msgs
        |> List.map (Platform.sendToApp router)
        |> Task.sequence
        |> Task.map (\_ -> state)



-- KERNELS
-- The annotations fix the kernel ABI: both kernels rely on exactly these argument and result
-- shapes.



{-| Reports, in one call, the platform and architecture names, the application path, the
arguments, the start time in milliseconds since the epoch, and the ids of the stdin, stdout
and stderr stream pairs. It returns a plain tuple, not a task, because it runs while the flags
are decoded. The stream pairs are made on the first call, and later calls reuse them while they
exist.
-}
kEnvironmentNow : Json.Decode.Value -> ( ( String, String, String ), ( List String, Int ), ( Int, Int, Int ) )
kEnvironmentNow =
    Eco.Kernel.System.environmentNow


{-| A task that reads the process's environment variables as name and value pairs.
-}
kGetEnvironmentVariables : Task Never (List ( String, String ))
kGetEnvironmentVariables =
    Eco.Kernel.System.getEnvironmentVariables


{-| Makes a task that ends the process at once with the given code. Natively, when the program
is embedded in a host, it records the code, stops the program and succeeds instead.
-}
kExitWithCode : Int -> Task Never ()
kExitWithCode =
    Eco.Kernel.System.exitWithCode


{-| Makes a task that records the code the process ends with.
-}
kSetExitCode : Int -> Task Never ()
kSetExitCode =
    Eco.Kernel.System.setExitCode


{-| Makes a task that arms the empty-event-loop hook, so that `onEmptyEventLoop` delivers its
message at the next empty event loop.
-}
kRearmEmptyEventLoop : Task Never ()
kRearmEmptyEventLoop =
    Eco.Kernel.System.rearmEmptyEventLoop


-- JS-only kernels, used by the effect-manager bodies above (the native backend drops those
-- bodies, so these have no C++ counterpart).


{-| Makes a task that never completes and, each time the program has an empty event loop while
the empty-event-loop hook is armed, disarms the hook and spawns the given task. Killing its
process detaches it.
-}
kAttachEmptyEventLoopListener : Task Never () -> Task Never ()
kAttachEmptyEventLoopListener =
    Eco.Kernel.System.attachEmptyEventLoopListener


{-| Makes a task that never completes and spawns the given task each time the process is sent
the named signal (`"SIGINT"` or `"SIGTERM"`), which then no longer ends the process. Killing its
process detaches it.
-}
kAttachSignalListener : String -> Task Never () -> Task Never ()
kAttachSignalListener =
    Eco.Kernel.System.attachSignalListener
