module System.IO exposing
    ( Program, Model, Msg, run
    , FilePath, Handle(..)
    , stdout, stderr
    , writeString
    , LockSharedExclusive(..)
    , write
    , writeLn, print, printLn, readLine, flush, isTerminal
    , crashOnError
    , MVar(..)
    , Stream, ChItem(..)
    )

{-| The compiler is a headless Elm program whose every effect is a `Task`, and
this module turns such a task into a program that can be run. It also gives the
rest of the compiler a few console and file operations, built on the `Eco.*`
modules that do the IO, and defines some types that other modules share.

`run` builds the program. Its model holds nothing and each of its messages is a
task to perform. Once the task it was given completes, the program goes on
performing the empty task `Task.succeed ()` without end, so completing the task
does not end the program.

A _handle_ is a number naming a stream or an open file. Writing to a handle goes
through `Eco.Console.write`, and closing one through `Eco.File.close`, with the
number passed on as it is. `stdout` and `stderr` are the two handles defined
here.

Console output is best-effort. `write`, `writeLn`, `print` and `printLn` cannot
fail: an error from the write is discarded and the task succeeds. `readLine`
and `writeString` fail with an `IOError`, as `Eco.IO.Error` describes,
and `crashOnError` turns such a failure into a crash. `flush` and `isTerminal`
ask the host nothing: `flush` does nothing, and `isTerminal` answers `True`.

`LockSharedExclusive`, `MVar`, `ChItem` and `Stream` are defined here, but this
module has no operations on them. The operations on MVars, channels
and file locks are in `Utils.Main`. A _channel_ is a queue of values passed
between concurrent tasks, built from MVars by `Utils.Main`.


# Running a program

@docs Program, Model, Msg, run


# Handles and files

@docs FilePath, Handle
@docs stdout, stderr
@docs writeString
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

import Eco.Console
import Eco.File
import Eco.IO.Error as IOErr exposing (IOError)
import Task exposing (Task)
import Utils.Crash exposing (crash)



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



-- ====== FILES AND HANDLES ======


{-| A path in the file system, as text.

This is a name for `String`, not a new type. Any `String` is accepted where a
`FilePath` is expected, and nothing checks that it is a path.

-}
type alias FilePath =
    String


{-| A stream or open file, named by a number.

The constructor is exposed, so a handle can be made from any `Int`, and nothing
here checks that the number names anything. `write` passes the number to
`Eco.Console.write` and `close` passes it to `Eco.File.close`, so what a number
names is decided by the host behind those modules.

-}
type Handle
    = Handle Int


{-| The handle of standard output.
-}
stdout : Handle
stdout =
    Handle 1


{-| The handle of standard error.
-}
stderr : Handle
stderr =
    Handle 2



-- ====== FILE OPERATIONS ======


{-| Writes `content` as text to the file at `path`, as `Eco.File.writeString`
does.
-}
writeString : FilePath -> String -> Task IOError ()
writeString path content =
    Eco.File.writeString path content



-- ====== FILE LOCKING ======


{-| The kind of lock to take on a file.

`LockExclusive` is the only constructor, so there is no way to ask for a shared
lock.

-}
type LockSharedExclusive
    = LockExclusive



-- ====== CONSOLE I/O ======


{-| Writes `content` to the stream the handle names, with no newline added.

The write cannot fail. Any error from `Eco.Console.write`, a broken pipe
included, is discarded and the task succeeds, so a caller cannot learn that
the output was lost.

-}
write : Handle -> String -> Task Never ()
write (Handle fd) content =
    Eco.Console.write (Eco.Console.Handle fd) content
        |> Task.onError (\_ -> Task.succeed ())


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


{-| Reads the next line of standard input, as `Eco.Console.readLine` does.
There is no separate value for the end of input.
-}
readLine : Task IOError String
readLine =
    Eco.Console.readLine


{-| Does nothing and succeeds, whatever the handle. Nothing in this module
holds output back, so it has nothing of its own to flush.
-}
flush : Task Never ()
flush =
    Task.succeed ()


{-| Answers `True` for every handle, without asking the host whether the handle
is a terminal.
-}
isTerminal : Task Never Bool
isTerminal =
    Task.succeed True


{-| Turns a task that can fail with an `IOError` into one that cannot, by
crashing the program when it fails.

The crash message is `"IO error: "` followed by the error as
`Eco.IO.Error.toString` renders it, and the crash is `Utils.Crash.crash`.

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
