effect module System where { command = MyCmd, subscription = MySub } exposing
    ( simpleProgram
    , Environment, environmentVariables, Platform(..), CpuArchitecture(..)
    , exit, exitWithCode, setExitCode
    , onEmptyEventLoop, onSignalInterrupt, onSignalTerminate
    )

{-| An Eco system program is an ordinary Elm `Platform.Program` whose flags are the
[`Environment`](#Environment). Eco builds the environment when the program starts and hands it
to `init`: it tells you which platform you are running on, which arguments the program was
invoked with and when it started, and gives you the standard input, output and error streams.

Long-lived programs that keep state, react to messages and listen to subscriptions are made
with `Platform.worker`:

    main : Platform.Program System.Environment Model Msg
    main =
        Platform.worker
            { init = \env -> ( initialModel env, Cmd.none )
            , update = update
            , subscriptions = subscriptions
            }

Short-lived programs that run a single task and then finish are made with
[`simpleProgram`](#simpleProgram):

    main : Platform.Program System.Environment () ()
    main =
        System.simpleProgram
            (\env -> Stream.logLine "Hello, world!" env.stdout)

The flags type `System.Environment` is supplied by the Eco compiler and runtime; it cannot be
passed in from JavaScript like ordinary JSON flags.

This module is a port of the `Node` module of gren-node. Every subsystem (files, processes, the
terminal, the HTTP server) can be used directly once the program has started; there is nothing
to set up first.


# Simple Program

@docs simpleProgram


# Environment information

@docs Environment, environmentVariables, Platform, CpuArchitecture


# Exit

@docs exit, exitWithCode, setExitCode


# Subscriptions

@docs onEmptyEventLoop, onSignalInterrupt, onSignalTerminate

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


{-| Contains information about the environment your application was started in.

  - `platform` and `cpuArchitecture` tell you about the operating system and machine your
    application is running on.
  - `applicationPath` is the real path of the currently executing program.
  - `args` is the full list of command line arguments, exactly as the C `argv` array. The
    first element, `args[0]`, is the program as it was invoked. This differs from gren-node,
    where the list starts with the path to the `node` binary followed by the script path, so a
    gren program that drops two leading arguments must drop only one here.
  - `startTime` is the time the program started, read once at startup, so `init` doesn't need
    to ask for the time first.
  - `stdout`, `stderr` and `stdin` are streams you can use to communicate with the outside
    world. Take a closer look at the `Stream` module for more information; `Stream.readLine`
    reads standard input line by line.

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


{-| The platform, or operating system, that your application is running on. Platforms that
are not recognised are reported as `UnknownPlatform`, carrying the platform's own name.
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


{-| The CPU architecture your application is running on. Architectures that are not
recognised are reported as `UnknownArchitecture`, carrying the architecture's own name.
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


{-| Get a `Dict` of the environment variables of the running process, mapping each variable
name to its value.
-}
environmentVariables : Task x (Dict String String)
environmentVariables =
    kGetEnvironmentVariables
        |> Task.map Dict.fromList
        |> Task.mapError never


{-| The flags decoder of every eco/system program (plans/eco-system-api-refactor.md D13).

The Eco compiler uses this decoder for a `main` whose flags are [`Environment`](#Environment)
(`Compiler.Elm.EcoEnvironment`) instead of synthesizing a JSON decoder. It ignores the host's
flags JSON and builds the environment through the kernel. The JSON value is passed to the kernel
only so that the call depends on the decoder's argument and can never be hoisted out of it.

-}
environmentDecoder : Json.Decode.Decoder Environment
environmentDecoder =
    Json.Decode.map toEnvironment Json.Decode.value


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


{-| Define a simple program that doesn't require long-lived state or the ability to respond to
messages or subscriptions. Ideal for simple and short-lived programs.

The function receives the [`Environment`](#Environment) and returns the task to run. The
result of the task is ignored: the program ends once the task, and any IO it started, has
completed. To end with a non-zero exit code, finish the task with
[`setExitCode`](#setExitCode).

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
simpleProgram : (Environment -> Task Never a) -> Platform.Program Environment () ()
simpleProgram run =
    Platform.worker
        { init = \env -> ( (), command (Execute (Task.map (\_ -> ()) (run env))) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }




-- EXIT


{-| Terminate the program immediately. Buffered standard output is flushed, but the program
will not wait for tasks like HTTP requests or file system writes to complete.

This function is equivalent to:

    exitWithCode 0

-}
exit : Cmd msg
exit =
    exitWithCode 0


{-| Terminate the program immediately with the given exit code. Buffered standard output is
flushed, but the program will not wait for tasks like HTTP requests or file system writes, so
only use this if you've reached a state where it makes no sense to continue.

The exit code can be read by other processes on your system. Any value other than 0 is
considered an error, but there are no other formal requirements for what makes an exit code.
If all you want is to signal that your application exited due to an error, 1 is a good option.

-}
exitWithCode : Int -> Cmd msg
exitWithCode code =
    command (Execute (kExitWithCode code))


{-| Set the exit code that the program will return once it finishes.

This will not terminate your program, so things like HTTP requests or writes to the file
system are allowed to complete. The program only exits once there is no ongoing work left.

-}
setExitCode : Int -> Task x ()
setExitCode code =
    kSetExitCode code
        |> Task.mapError never



-- SUBSCRIPTIONS


{-| Receive the given message when the program has run out of work: there are no queued
messages and no pending IO. This is the equivalent of Node's `beforeExit` event.

If handling the message starts new IO, the program keeps running and the message will be
delivered again the next time the program runs out of work. If it does not, the program exits.
This subscription never fires when the program is embedded in a host application.

-}
onEmptyEventLoop : msg -> Sub msg
onEmptyEventLoop msg =
    subscription (OnEmptyEventLoop msg)


{-| Receive the given message when the process receives an interrupt signal (`SIGINT`), which
usually happens when the user presses Ctrl+C in the terminal. While subscribed, the signal no
longer terminates the program, so you are expected to exit yourself.
-}
onSignalInterrupt : msg -> Sub msg
onSignalInterrupt msg =
    subscription (OnSignalInterrupt msg)


{-| Receive the given message when the process receives a terminate signal (`SIGTERM`), the
polite request to shut down sent by service managers and the `kill` command. While subscribed,
the signal no longer terminates the program, so you are expected to exit yourself.
-}
onSignalTerminate : msg -> Sub msg
onSignalTerminate msg =
    subscription (OnSignalTerminate msg)



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "System"
-- (src/eco-system/System/SystemManager.{hpp,cpp}, plans/eco-system-library.md Appendix C.1)
-- and ignores the Elm functions below. The JS backend runs them (plans/eco-system-library.md
-- Phase 10, D15): Execute spawns its task; each kind of subscription keeps one listener
-- process alive (a never-completing kernel binding, killed when the last subscription of
-- that kind goes away) that notifies the manager through `Platform.sendToSelf`. The
-- constructor layouts of MyCmd and MySub are mirrored by SystemManager.hpp: keep them in
-- sync.


type MyCmd msg
    = Execute (Task Never ())


type MySub msg
    = OnEmptyEventLoop msg
    | OnSignalInterrupt msg
    | OnSignalTerminate msg


cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ (Execute task) =
    Execute task


subMap : (a -> b) -> MySub a -> MySub b
subMap f sub =
    case sub of
        OnEmptyEventLoop msg ->
            OnEmptyEventLoop (f msg)

        OnSignalInterrupt msg ->
            OnSignalInterrupt (f msg)

        OnSignalTerminate msg ->
            OnSignalTerminate (f msg)


type alias State msg =
    { emptyEventLoop : Listeners msg
    , signalInterrupt : Listeners msg
    , signalTerminate : Listeners msg
    }


{-| The msgs of one kind of subscription, in subscription order, and the process running
its listener while there are any.
-}
type alias Listeners msg =
    { msgs : List msg
    , listener : Maybe Process.Id
    }


type Event
    = NotifyEmptyEventLoop
    | NotifySignalInterrupt
    | NotifySignalTerminate


init : Task Never (State msg)
init =
    Task.succeed
        { emptyEventLoop = noListeners
        , signalInterrupt = noListeners
        , signalTerminate = noListeners
        }


noListeners : Listeners msg
noListeners =
    { msgs = [], listener = Nothing }


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


{-| Starts the listener when the first subscription of its kind appears, and kills it when
the last one goes away.
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
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.1).



kEnvironmentNow : Json.Decode.Value -> ( ( String, String, String ), ( List String, Int ), ( Int, Int, Int ) )
kEnvironmentNow =
    Eco.Kernel.System.environmentNow


kGetEnvironmentVariables : Task Never (List ( String, String ))
kGetEnvironmentVariables =
    Eco.Kernel.System.getEnvironmentVariables


kExitWithCode : Int -> Task Never ()
kExitWithCode =
    Eco.Kernel.System.exitWithCode


kSetExitCode : Int -> Task Never ()
kSetExitCode =
    Eco.Kernel.System.setExitCode


-- JS-only kernels, used by the effect-manager bodies above (the native backend drops those
-- bodies, so these have no C++ counterpart).


kAttachEmptyEventLoopListener : Task Never () -> Task Never ()
kAttachEmptyEventLoopListener =
    Eco.Kernel.System.attachEmptyEventLoopListener


kAttachSignalListener : String -> Task Never () -> Task Never ()
kAttachSignalListener =
    Eco.Kernel.System.attachSignalListener
