effect module System where { command = MyCmd, subscription = MySub } exposing
    ( Program, ProgramConfiguration, defineProgram
    , SimpleProgram, defineSimpleProgram, endSimpleProgram
    , Environment, getEnvironmentVariables, Platform(..), getPlatform, CpuArchitecture(..), getCpuArchitecture
    , exit, exitWithCode, setExitCode
    , onEmptyEventLoop, onSignalInterrupt, onSignalTerminate
    )

{-| An Eco system program is defined much like an Elm `Platform.worker`, except that it is
handed an [`Environment`](#Environment) when it starts. The environment tells you which
platform you are running on, which arguments the program was invoked with, and gives you the
standard input, output and error streams.

Long-lived programs that keep state, react to messages and listen to subscriptions are made
with [`defineProgram`](#defineProgram). Short-lived programs that run a single task and then
finish are made with [`defineSimpleProgram`](#defineSimpleProgram):

    main : System.SimpleProgram msg
    main =
        System.defineSimpleProgram
            (\env ->
                System.endSimpleProgram
                    (Stream.Log.line env.stdout "Hello, world!")
            )

This module is a port of the `Node` module of gren-node. Every subsystem (files, processes, the
terminal, the HTTP server) can be used directly once the program has started; there is nothing
to set up first.


# Program

@docs Program, ProgramConfiguration, defineProgram


# Simple Program

@docs SimpleProgram, defineSimpleProgram, endSimpleProgram


# Environment information

@docs Environment, getEnvironmentVariables, Platform, getPlatform, CpuArchitecture, getCpuArchitecture


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
import System.File.Path exposing (Path)
import Task exposing (Task)



-- ENVIRONMENT


{-| Contains information about the environment your application was started in.

  - `platform` and `cpuArchitecture` tell you about the operating system and machine your
    application is running on.
  - `applicationPath` is the real path of the currently executing program.
  - `args` is the full list of command line arguments, exactly as the C `argv` array. The
    first element, `args[0]`, is the program as it was invoked. This differs from gren-node,
    where the list starts with the path to the `node` binary followed by the script path, so a
    gren program that drops two leading arguments must drop only one here.
  - `stdout`, `stderr` and `stdin` are streams you can use to communicate with the outside
    world. Take a closer look at the `Stream` module for more information.

-}
type alias Environment =
    { platform : Platform
    , cpuArchitecture : CpuArchitecture
    , applicationPath : Path
    , args : List String
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


{-| Retrieve the platform of the computer running the application. The same value is
available as `platform` in the [`Environment`](#Environment).
-}
getPlatform : Task x Platform
getPlatform =
    kGetPlatform
        |> Task.map platformFromString
        |> Task.mapError never


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


{-| Retrieve the CPU architecture of the computer running the application. The same value is
available as `cpuArchitecture` in the [`Environment`](#Environment).
-}
getCpuArchitecture : Task x CpuArchitecture
getCpuArchitecture =
    kGetCpuArchitecture
        |> Task.map archFromString
        |> Task.mapError never


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
getEnvironmentVariables : Task x (Dict String String)
getEnvironmentVariables =
    kGetEnvironmentVariables
        |> Task.map Dict.fromList
        |> Task.mapError never


{-| Gather the [`Environment`](#Environment). The standard streams are created once per
process; every program sees the same three streams.
-}
initializeEnvironment : Task Never Environment
initializeEnvironment =
    kEnvironment
        |> Task.map
            (\( ( platform, arch, applicationPath ), args, ( stdin, stdout, stderr ) ) ->
                { platform = platformFromString platform
                , cpuArchitecture = archFromString arch
                , applicationPath = System.File.Path.fromPosixString applicationPath
                , args = args
                , stdout = Stream.Internal.Writable stdout
                , stderr = Stream.Internal.Writable stderr
                , stdin = Stream.Internal.Readable stdin
                }
            )



-- PROGRAMS


{-| The definition of an Eco system program. Create one with
[`defineProgram`](#defineProgram) or [`defineSimpleProgram`](#defineSimpleProgram).

The program's flags are always `()`, and its model and messages are wrapped so that your own
`init` only runs once the [`Environment`](#Environment) has been gathered.

-}
type alias Program model msg =
    Platform.Program () (Model model) (Msg model msg)


type Model model
    = Uninitialized
    | Initialized model


type Msg model msg
    = InitDone ( model, Cmd msg )
    | MsgReceived msg


{-| The functions that define a program.

  - `init` receives the [`Environment`](#Environment) and returns the initial model together
    with a command to run.
  - `update` and `subscriptions` work exactly as they do for `Platform.worker`.

Subscriptions are not active until `init` has run.

-}
type alias ProgramConfiguration model msg =
    { init : Environment -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }


{-| Define a program with access to long-lived state and the ability to respond to messages
and listen to subscriptions. If you want to define a simple and short-lived program, chances
are you're looking for [`defineSimpleProgram`](#defineSimpleProgram) instead.

The program keeps running for as long as it has pending work or active subscriptions, or
until it calls [`exit`](#exit) or [`exitWithCode`](#exitWithCode).

-}
defineProgram : ProgramConfiguration model msg -> Program model msg
defineProgram config =
    Platform.worker
        { init = initProgram config.init
        , update = update config.update
        , subscriptions = subscriptions config.subscriptions
        }


initProgram : (Environment -> ( model, Cmd msg )) -> () -> ( Model model, Cmd (Msg model msg) )
initProgram appInit _ =
    ( Uninitialized
    , initializeEnvironment
        |> Task.map appInit
        |> Task.perform InitDone
    )


update : (msg -> model -> ( model, Cmd msg )) -> Msg model msg -> Model model -> ( Model model, Cmd (Msg model msg) )
update appUpdate msg model =
    case model of
        Uninitialized ->
            case msg of
                InitDone ( initModel, initCmd ) ->
                    ( Initialized initModel, Cmd.map MsgReceived initCmd )

                MsgReceived _ ->
                    -- Ignore
                    ( model, Cmd.none )

        Initialized appModel ->
            case msg of
                InitDone _ ->
                    -- Ignore
                    ( model, Cmd.none )

                MsgReceived appMsg ->
                    let
                        ( newModel, cmd ) =
                            appUpdate appMsg appModel
                    in
                    ( Initialized newModel, Cmd.map MsgReceived cmd )


subscriptions : (model -> Sub msg) -> Model model -> Sub (Msg model msg)
subscriptions appSubs model =
    case model of
        Uninitialized ->
            Sub.none

        Initialized appModel ->
            Sub.map MsgReceived (appSubs appModel)


{-| A program that runs a single command and then finishes. It has no model of its own.

This is `Program () msg`: a [`Program`](#Program) whose model is `()`. In gren-node a simple
program had its own, unrelated program type.

-}
type alias SimpleProgram msg =
    Program () msg


{-| Define a simple program that doesn't require long-lived state or the ability to respond to
messages or subscriptions. Ideal for simple and short-lived programs.

The function receives the [`Environment`](#Environment) and returns the command to run, which
is usually built with [`endSimpleProgram`](#endSimpleProgram). Messages produced by that
command are ignored.

-}
defineSimpleProgram : (Environment -> Cmd msg) -> SimpleProgram msg
defineSimpleProgram appInit =
    defineProgram
        { init = \env -> ( (), appInit env )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| When defining a program with [`defineSimpleProgram`](#defineSimpleProgram), use this
function to define the final task to execute. The result of the task is ignored; the program
ends once the task, and any IO it started, has completed.
-}
endSimpleProgram : Task Never a -> Cmd msg
endSimpleProgram task =
    command (Execute (Task.map (\_ -> ()) task))



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
    endSimpleProgram (kExitWithCode code)


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


kEnvironment : Task Never ( ( String, String, String ), List String, ( Int, Int, Int ) )
kEnvironment =
    Eco.Kernel.System.environment


kGetPlatform : Task Never String
kGetPlatform =
    Eco.Kernel.System.getPlatform


kGetCpuArchitecture : Task Never String
kGetCpuArchitecture =
    Eco.Kernel.System.getCpuArchitecture


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
