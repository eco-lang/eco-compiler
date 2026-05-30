module System.IO exposing
    ( Program, Model, Msg, run
    , FilePath, Handle(..)
    , stdout, stderr
    , writeString
    , LockSharedExclusive(..)
    , write
    , writeLn, print, printLn, readLine, close, flush, isTerminal
    , crashOnError
    , MVar(..)
    , Stream, ChItem(..)
    , ReplState(..), initialReplState
    , ReplSettings(..)
    )

{-| Centralized IO operations for the Elm compiler.

This is the single IO routing layer for the compiler. All IO operations go
through this module — callers import `System.IO as IO` and call `IO.<name>`.

The implementation delegates to the `Eco.*` modules (Eco.File, Eco.Console,
Eco.Env, Eco.MVar, Eco.Process, Eco.Runtime) which are backed by either XHR
(bootstrap build) or kernel calls (native build).

Function names follow the `guida-io-ops.csv` naming conventions.


# Program

@docs Program, Model, Msg, run


# Files and handles

@docs FilePath, Handle


# Standard handles

@docs stdout, stderr


# File operations

@docs writeString


# File and directory queries


# File locking

@docs LockSharedExclusive


# Console I/O

@docs write
@docs writeLn, print, printLn, readLine, close, flush, isTerminal


# Environment and process


# MVars (concurrency primitives)

@docs MVar


# Channels (built on MVars)

@docs Stream, ChItem


# Concurrency


# Runtime


# REPL support

@docs ReplState, initialReplState
@docs ReplSettings

-}

import Dict exposing (Dict)
import Eco.Console
import Eco.File
import Eco.IO.Error as IOErr exposing (IOError)
import Task exposing (Task)
import Utils.Crash exposing (crash)



-- ====== PROGRAM ======


{-| Type alias for an IO program that runs impure tasks.
-}
type alias Program =
    Platform.Program () Model Msg


{-| Create and run an IO program from a task.
-}
run : Task Never () -> Program
run app =
    Platform.worker
        { init = update app
        , update = update
        , subscriptions = \_ -> Sub.none
        }


{-| The program's model state (unit type as we use tasks for state management).
-}
type alias Model =
    ()


{-| Messages are tasks to be executed.
-}
type alias Msg =
    Task Never ()


update : Msg -> Model -> ( Model, Cmd Msg )
update msg () =
    ( (), Task.perform Task.succeed msg )



-- ====== FILES AND HANDLES ======


{-| Type alias for file paths represented as strings.
-}
type alias FilePath =
    String


{-| Opaque handle to an open file or stream, wrapping a file descriptor integer.
-}
type Handle
    = Handle Int


{-| Handle to the standard output stream.
-}
stdout : Handle
stdout =
    Handle 1


{-| Handle to the standard error stream.
-}
stderr : Handle
stderr =
    Handle 2



-- ====== FILE OPERATIONS ======


{-| Close an open file handle.
-}
close : Handle -> Task IOError ()
close (Handle handle) =
    Eco.File.close (Eco.File.Handle handle)


{-| Write a UTF-8 string to a file.
-}
writeString : FilePath -> String -> Task IOError ()
writeString path content =
    Eco.File.writeString path content



-- ====== FILE AND DIRECTORY QUERIES ======
-- ====== FILE LOCKING ======


{-| Lock mode. Currently only exclusive is supported.
-}
type LockSharedExclusive
    = LockExclusive



-- ====== CONSOLE I/O ======


{-| Write a string to the specified handle without adding a newline.

Console output is best-effort: a write error (e.g. EPIPE when the downstream
reader closed the pipe, as in `eco ... | head`) is swallowed here rather than
surfaced, matching the kernel's historical behaviour of ignoring the write
return value. This is the IO_ERR_001 clause (a) "handle locally" case.
-}
write : Handle -> String -> Task Never ()
write (Handle fd) content =
    Eco.Console.write (Eco.Console.Handle fd) content
        |> Task.onError (\_ -> Task.succeed ())


{-| Write a string to the specified handle followed by a newline.
-}
writeLn : Handle -> String -> Task Never ()
writeLn handle content =
    write handle (content ++ "\n")


{-| Write a string to stdout without adding a newline.
-}
print : String -> Task Never ()
print =
    write stdout


{-| Write a string to stdout followed by a newline.
-}
printLn : String -> Task Never ()
printLn s =
    print (s ++ "\n")


{-| Read a line of input from stdin.
-}
readLine : Task IOError String
readLine =
    Eco.Console.readLine


{-| Flush any buffered output on the handle (currently a no-op).
-}
flush : Handle -> Task Never ()
flush _ =
    Task.succeed ()


{-| Check if the handle is connected to a terminal (currently always True).
-}
isTerminal : Handle -> Task Never Bool
isTerminal _ =
    Task.succeed True


{-| Handle a fallible IO task locally by crashing with a diagnostic when it
fails (IO_ERR_001 clause (a)). Used for build-internal artifact/cache IO where
the surrounding code is `Task Never` and threading an `IOError` through the
MVar-concurrent build pipeline would be unbounded; a failure here indicates a
corrupt or unwritable build cache and is reported clearly rather than dropped.
-}
crashOnError : Task IOError a -> Task Never a
crashOnError =
    Task.onError (\err -> crash ("IO error: " ++ IOErr.toString err))



-- ====== ENVIRONMENT AND PROCESS ======
-- ====== MVARS ======


{-| A mutable variable for communication between threads, identified by an integer reference.
-}
type MVar a
    = MVar Int



-- ====== CHANNELS ======


{-| An item in a channel stream.
-}
type ChItem a
    = ChItem a (Stream a)


{-| A stream of values backed by an MVar chain.
-}
type alias Stream a =
    MVar (ChItem a)



-- ====== CONCURRENCY ======
-- ====== RUNTIME ======
-- ====== REPL STATE ======


{-| State maintained by the REPL.
-}
type ReplState
    = ReplState (Dict String String) (Dict String String) (Dict String String)


{-| Initial empty REPL state.
-}
initialReplState : ReplState
initialReplState =
    ReplState Dict.empty Dict.empty Dict.empty


{-| REPL settings type (no-op placeholder).
-}
type ReplSettings
    = ReplSettings
