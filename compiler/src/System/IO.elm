module System.IO exposing
    ( Program, Model, Msg, run
    , environment
    , FilePath, Handle(..)
    , stdout, stderr
    , writeString, writeBytes
    , LockSharedExclusive(..)
    , write
    , writeLn, print, printLn, readLine, flush, isTerminal
    , crashOnError
    , MVar(..)
    , Stream, ChItem(..)
    )

{-| The compiler is a headless Elm program whose every effect is a `Task`, and
this module turns such a task into a program that can be run. It also gives the
rest of the compiler a few console and file operations, built on eco/system's
`System`, `Stream`, `Terminal` and `FileSystem` modules, and defines some types
that other modules share.

`run` builds the program. Its model holds nothing and each of its messages is a
task to perform. Once the task it was given completes, the program goes on
performing the empty task `Task.succeed ()` without end, so completing the task
does not end the program.

The program reaches its standard streams through `environment`, eco/system's
`System.environment`: the program is a `Platform.worker` whose flags are `()`
(stock Elm, which builds the first stage of the compiler, accepts no other), so
it is not handed the `System.Environment` as flags. A _handle_ names standard
output or standard error, and `stdout` and `stderr` are the two there are.

Console output is best-effort. `write`, `writeLn`, `print` and `printLn` cannot
fail: an error from the write is discarded and the task succeeds. Each write
has reached the stream when its task completes, so output written before the
program exits is not lost. `readLine` and `writeString` fail with an `IOError`,
as `System.IOError` describes, and `crashOnError` turns such a failure into a
crash. `flush` does nothing, since nothing here holds output back. `isTerminal`
asks `Terminal.isTerminal` whether a handle is a terminal; it cannot fail.

`LockSharedExclusive`, `MVar`, `ChItem` and `Stream` are defined here, but this
module has no operations on them. The operations on MVars, channels
and file locks are in `Utils.Main`. A _channel_ is a queue of values passed
between concurrent tasks, built from MVars by `Utils.Main`.


# Running a program

@docs Program, Model, Msg, run
@docs environment


# Handles and files

@docs FilePath, Handle
@docs stdout, stderr
@docs writeString, writeBytes
@docs LockSharedExclusive


# Console

@docs write
@docs writeLn, print, printLn, readLine, flush, isTerminal


# Failures

@docs crashOnError


# Shared types

@docs MVar
@docs Stream, ChItem

-}

import Bytes exposing (Bytes)
import Codec.Utf8 as Utf8
import FileSystem
import Stream
import System
import System.Crash exposing (crash)
import System.IOError as IOErr exposing (IOError)
import System.OsPath as OsPath
import Task exposing (Task)
import Terminal



-- ====== PROGRAM ======


{-| A headless program built by `run`, which takes no flags.
-}
type alias Program =
    Platform.Program () Model Msg


{-| Creates a headless program that performs `app`.

Completing `app` does not end the program. It then performs
`Task.succeed ()`, and again each time that completes, without end.

-}
run : Task Never () -> Program
run app =
    Platform.worker
        { init = update app
        , update = update
        , subscriptions = \_ -> Sub.none
        }


{-| The state of a program built by `run`, which holds nothing: all of the
program's work is in the tasks it performs.
-}
type alias Model =
    ()


{-| A message of a program built by `run`: a task for the program to perform.
-}
type alias Msg =
    Task Never ()


{-| Performs `msg`, and answers its completion with the message
`Task.succeed ()`, which is performed in turn. `run` also uses this as the
program's `init`, which is how the task it is given comes to be performed.
-}
update : Msg -> Model -> ( Model, Cmd Msg )
update msg () =
    ( (), Task.perform Task.succeed msg )


{-| A task that gives the program's environment: its platform, arguments,
application path and standard streams, as `System.environment` gives them.
-}
environment : Task x System.Environment
environment =
    System.environment



-- ====== FILES AND HANDLES ======


{-| A path in the file system, as text.

This is a name for `String`, not a new type. Any `String` is accepted where a
`FilePath` is expected, and nothing checks that it is a path.

-}
type alias FilePath =
    String


{-| One of the program's two standard output streams.
-}
type Handle
    = Stdout
    | Stderr


{-| The handle of standard output.
-}
stdout : Handle
stdout =
    Stdout


{-| The handle of standard error.
-}
stderr : Handle
stderr =
    Stderr


{-| The eco/system stream a handle names, in the program's environment.
-}
streamOf : Handle -> System.Environment -> Stream.Writable Bytes
streamOf handle env =
    case handle of
        Stdout ->
            env.stdout

        Stderr ->
            env.stderr



-- ====== FILE OPERATIONS ======


{-| Writes `content` as UTF-8 text to the file at `path`, creating the file or
replacing what it held. An empty `path` fails with `FileNotFound ""`.
-}
writeString : FilePath -> String -> Task IOError ()
writeString path content =
    if String.isEmpty path then
        Task.fail (IOErr.FileNotFound path)

    else
        FileSystem.writeFile (Utf8.encode content) (OsPath.toPath path)
            |> Task.map (\_ -> ())
            |> Task.mapError (IOErr.fromFileSystem path)


{-| Writes `bytes` to the file at `path`, creating the file or replacing what it
held. An empty `path` fails with `FileNotFound ""`.
-}
writeBytes : FilePath -> Bytes -> Task IOError ()
writeBytes path bytes =
    if String.isEmpty path then
        Task.fail (IOErr.FileNotFound path)

    else
        FileSystem.writeFile bytes (OsPath.toPath path)
            |> Task.map (\_ -> ())
            |> Task.mapError (IOErr.fromFileSystem path)



-- ====== FILE LOCKING ======


{-| The kind of lock to take on a file.

`LockExclusive` is the only constructor, so there is no way to ask for a shared
lock.

-}
type LockSharedExclusive
    = LockExclusive



-- ====== CONSOLE I/O ======


{-| Writes `content` to the stream the handle names, with no newline added, and
completes once the stream has taken it.

The write cannot fail. Any error from the stream, a broken pipe included, is
discarded and the task succeeds, so a caller cannot learn that the output was
lost.

-}
write : Handle -> String -> Task Never ()
write handle content =
    environment
        |> Task.andThen (\env -> Stream.logString content (streamOf handle env))


{-| Writes `content` followed by a newline to the stream the handle names. Like
`write`, it cannot fail, and any error is discarded.
-}
writeLn : Handle -> String -> Task Never ()
writeLn handle content =
    write handle (content ++ "\n")


{-| Writes the text to standard output with no newline added. Like `write`, it
cannot fail, and any error is discarded.
-}
print : String -> Task Never ()
print =
    write stdout


{-| Writes `s` followed by a newline to standard output. Like `write`, it
cannot fail, and any error is discarded.
-}
printLn : String -> Task Never ()
printLn s =
    print (s ++ "\n")


{-| Reads the next line of standard input, without its line ending. At the end
of input it gives `""`: there is no separate value for the end of input.
-}
readLine : Task IOError String
readLine =
    environment
        |> Task.andThen (\env -> Stream.readLine env.stdin)
        |> Task.onError
            (\err ->
                case err of
                    Stream.Closed ->
                        Task.succeed ""

                    _ ->
                        Task.fail (IOErr.fromStream err)
            )


{-| Does nothing and succeeds, whatever the handle. Nothing in this module
holds output back, so it has nothing of its own to flush.
-}
flush : Task Never ()
flush =
    Task.succeed ()


{-| Asks whether the stream `handle` names is a terminal. Answers `False` when
that cannot be told.
-}
isTerminal : Handle -> Task Never Bool
isTerminal handle =
    case handle of
        Stdout ->
            Terminal.isTerminal Terminal.Stdout

        Stderr ->
            Terminal.isTerminal Terminal.Stderr


{-| Turns a task that can fail with an `IOError` into one that cannot, by
crashing the program when it fails.

The crash message is `"IO error: "` followed by the error as
`System.IOError.toString` renders it, and the crash is `System.Crash.crash`.

-}
crashOnError : Task IOError a -> Task Never a
crashOnError =
    Task.onError (\err -> crash ("IO error: " ++ IOErr.toString err))



-- ====== MVARS ======


{-| A reference to an MVar, a cell held by the host through which concurrent
tasks hand values to one another, as `Eco.MVar` describes.

The `Int` is the number the host gave the MVar. The type parameter says what
the MVar holds, but nothing checks it: the constructor is exposed, so an `MVar`
can be made from any `Int`, for any `a`.

-}
type MVar a
    = MVar Int



-- ====== CHANNELS ======


{-| One link of a channel: a value, and the stream from which the value after
it will be read.
-}
type ChItem a
    = ChItem a (Stream a)


{-| A channel's chain of items from some point on: an MVar that, once filled,
holds the next `ChItem`. While it is empty it is the hole that the next value
written to the channel fills.

This is a name for `MVar (ChItem a)`, not a new type.

-}
type alias Stream a =
    MVar (ChItem a)
