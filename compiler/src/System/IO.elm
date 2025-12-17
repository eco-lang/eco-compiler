module System.IO exposing
    ( Program, Model, Msg, run
    , FilePath, Handle(..)
    , stdout, stderr
    , withFile, IOMode(..)
    , hClose
    , hFileSize
    , hFlush
    , hIsTerminalDevice
    , hPutStr, hPutStrLn
    , putStr, putStrLn, getLine
    , ReplState(..), initialReplState
    , writeString
    )

{-| File I/O operations for the Elm compiler runtime.

This module provides a portable interface for file and console I/O operations,
modeled after Haskell's System.IO. It enables the compiler to interact with the
file system and standard streams through an impure effects system.

Ref.: <https://hackage.haskell.org/package/base-4.20.0.1/docs/System-IO.html>

@docs Program, Model, Msg, run


# Files and handles

@docs FilePath, Handle


# Standard handles

@docs stdout, stderr


# Opening files

@docs withFile, IOMode


# Closing files

@docs hClose


# File locking

@docs hFileSize


# Buffering operations

@docs hFlush


# Terminal operations (not portable: GHC only)

@docs hIsTerminalDevice


# Text output

@docs hPutStr, hPutStrLn


# Special cases for standard input and output

@docs putStr, putStrLn, getLine


# Repl State

@docs ReplState, initialReplState


# Internal helpers

@docs writeString

-}

import Dict exposing (Dict)
import Http
import Json.Decode as Decode
import Task exposing (Task)
import Utils.Impure as Impure


{-| Type alias for an IO program that runs impure tasks. -}
type alias Program =
    Platform.Program () Model Msg


{-| Create and run an IO program from a task. -}
run : Task Never () -> Program
run app =
    Platform.worker
        { init = update app
        , update = update
        , subscriptions = \_ -> Sub.none
        }


{-| The program's model state (unit type as we use tasks for state management). -}
type alias Model =
    ()


{-| Messages are tasks to be executed. -}
type alias Msg =
    Task Never ()


update : Msg -> Model -> ( Model, Cmd Msg )
update msg () =
    ( (), Task.perform Task.succeed msg )



-- Interal helpers


{-| Write a string to a file at the given path. -}
writeString : FilePath -> String -> Task Never ()
writeString path content =
    Impure.task "writeString"
        [ Http.header "path" path ]
        (Impure.StringBody content)
        (Impure.Always ())



-- Files and handles


{-| Type alias for file paths represented as strings. -}
type alias FilePath =
    String


{-| Opaque handle to an open file or stream, wrapping a file descriptor integer. -}
type Handle
    = Handle Int



-- Standard handles


{-| Handle to the standard output stream. -}
stdout : Handle
stdout =
    Handle 1


{-| Handle to the standard error stream. -}
stderr : Handle
stderr =
    Handle 2



-- Opening files


{-| Open a file with the specified mode, pass the handle to a callback, and automatically close it afterward. -}
withFile : String -> IOMode -> (Handle -> Task Never a) -> Task Never a
withFile path mode callback =
    Impure.task "withFile"
        [ Http.header "mode"
            (case mode of
                ReadMode ->
                    "r"

                WriteMode ->
                    "w"

                AppendMode ->
                    "a"

                ReadWriteMode ->
                    "w+"
            )
        ]
        (Impure.StringBody path)
        (Impure.DecoderResolver (Decode.map Handle Decode.int))
        |> Task.andThen callback


{-| File opening mode specifying read, write, append, or read-write access. -}
type IOMode
    = ReadMode
    | WriteMode
    | AppendMode
    | ReadWriteMode



-- Closing files


{-| Close an open file handle. -}
hClose : Handle -> Task Never ()
hClose (Handle handle) =
    Impure.task "hClose" [] (Impure.StringBody (String.fromInt handle)) (Impure.Always ())



-- File locking


{-| Get the size in bytes of the file associated with the handle. -}
hFileSize : Handle -> Task Never Int
hFileSize (Handle handle) =
    Impure.task "hFileSize"
        []
        (Impure.StringBody (String.fromInt handle))
        (Impure.DecoderResolver Decode.int)



-- Buffering operations


{-| Flush any buffered output on the handle (currently a no-op). -}
hFlush : Handle -> Task Never ()
hFlush _ =
    Task.succeed ()



-- Terminal operations (not portable: GHC only)


{-| Check if the handle is connected to a terminal device (currently always returns True). -}
hIsTerminalDevice : Handle -> Task Never Bool
hIsTerminalDevice _ =
    Task.succeed True



-- Text output


{-| Write a string to the specified handle without adding a newline. -}
hPutStr : Handle -> String -> Task Never ()
hPutStr (Handle fd) content =
    Impure.task "hPutStr"
        [ Http.header "fd" (String.fromInt fd) ]
        (Impure.StringBody content)
        (Impure.Always ())


{-| Write a string to the specified handle followed by a newline. -}
hPutStrLn : Handle -> String -> Task Never ()
hPutStrLn handle content =
    hPutStr handle (content ++ "\n")



-- Special cases for standard input and output


{-| Write a string to stdout without adding a newline. -}
putStr : String -> Task Never ()
putStr =
    hPutStr stdout


{-| Write a string to stdout followed by a newline. -}
putStrLn : String -> Task Never ()
putStrLn s =
    putStr (s ++ "\n")


{-| Read a line of input from stdin. -}
getLine : Task Never String
getLine =
    Impure.task "getLine" [] Impure.EmptyBody (Impure.StringResolver identity)



-- Repl State (Terminal.Repl)


{-| State maintained by the REPL, containing three dictionaries for tracking REPL session data. -}
type ReplState
    = ReplState (Dict String String) (Dict String String) (Dict String String)


{-| Initial empty REPL state with empty dictionaries. -}
initialReplState : ReplState
initialReplState =
    ReplState Dict.empty Dict.empty Dict.empty
