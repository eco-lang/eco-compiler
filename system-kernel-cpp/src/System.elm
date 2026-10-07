module System exposing
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
import Platform
import Stream
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
    Debug.todo "Implement System API"


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
    Debug.todo "Implement System API"


{-| Get a `Dict` of the environment variables of the running process, mapping each variable
name to its value.
-}
getEnvironmentVariables : Task x (Dict String String)
getEnvironmentVariables =
    Debug.todo "Implement System API"



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
    Debug.todo "Implement System API"


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
defineSimpleProgram init =
    Debug.todo "Implement System API"


{-| When defining a program with [`defineSimpleProgram`](#defineSimpleProgram), use this
function to define the final task to execute. The result of the task is ignored; the program
ends once the task, and any IO it started, has completed.
-}
endSimpleProgram : Task Never a -> Cmd msg
endSimpleProgram task =
    Debug.todo "Implement System API"



-- EXIT


{-| Terminate the program immediately. Buffered standard output is flushed, but the program
will not wait for tasks like HTTP requests or file system writes to complete.

This function is equivalent to:

    exitWithCode 0

-}
exit : Cmd msg
exit =
    Debug.todo "Implement System API"


{-| Terminate the program immediately with the given exit code. Buffered standard output is
flushed, but the program will not wait for tasks like HTTP requests or file system writes, so
only use this if you've reached a state where it makes no sense to continue.

The exit code can be read by other processes on your system. Any value other than 0 is
considered an error, but there are no other formal requirements for what makes an exit code.
If all you want is to signal that your application exited due to an error, 1 is a good option.

-}
exitWithCode : Int -> Cmd msg
exitWithCode code =
    Debug.todo "Implement System API"


{-| Set the exit code that the program will return once it finishes.

This will not terminate your program, so things like HTTP requests or writes to the file
system are allowed to complete. The program only exits once there is no ongoing work left.

-}
setExitCode : Int -> Task x ()
setExitCode code =
    Debug.todo "Implement System API"



-- SUBSCRIPTIONS


{-| Receive the given message when the program has run out of work: there are no queued
messages and no pending IO. This is the equivalent of Node's `beforeExit` event.

If handling the message starts new IO, the program keeps running and the message will be
delivered again the next time the program runs out of work. If it does not, the program exits.
This subscription never fires when the program is embedded in a host application.

-}
onEmptyEventLoop : msg -> Sub msg
onEmptyEventLoop msg =
    Debug.todo "Implement System API"


{-| Receive the given message when the process receives an interrupt signal (`SIGINT`), which
usually happens when the user presses Ctrl+C in the terminal. While subscribed, the signal no
longer terminates the program, so you are expected to exit yourself.
-}
onSignalInterrupt : msg -> Sub msg
onSignalInterrupt msg =
    Debug.todo "Implement System API"


{-| Receive the given message when the process receives a terminate signal (`SIGTERM`), the
polite request to shut down sent by service managers and the `kill` command. While subscribed,
the signal no longer terminates the program, so you are expected to exit yourself.
-}
onSignalTerminate : msg -> Sub msg
onSignalTerminate msg =
    Debug.todo "Implement System API"
