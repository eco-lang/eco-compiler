module Eco.File exposing
    ( readString, writeString, readBytes, writeBytes
    , Handle(..), IOMode(..), open, close, size, hWriteString
    , lock, unlock
    , fileExists, dirExists, findExecutable, list, modificationTime, touch
    , getCwd, setCwd, canonicalize, appDataDir, createDir, removeFile, removeDir
    )

{-| File system operations via XHR: file I/O, handles, locks, and directories.

This is the XHR-based bootstrap implementation. The kernel variant
(in eco-kernel-cpp) has identical type signatures but delegates to
Eco.Kernel.File directly.


# File I/O by Path

@docs readString, writeString, readBytes, writeBytes


# File Handles

@docs Handle, IOMode, open, close, size, hWriteString


# File Locking

@docs lock, unlock


# File and Directory Queries

@docs fileExists, dirExists, findExecutable, list, modificationTime, touch


# Directory Operations

@docs getCwd, setCwd, canonicalize, appDataDir, createDir, removeFile, removeDir

-}

import Bytes exposing (Bytes)
import Eco.IO.Error as IOErr exposing (IOError)
import Eco.XHR
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)
import Time


{-| An opaque file handle for reading, writing, or querying file metadata.
-}
type Handle
    = Handle Int


{-| The mode in which a file is opened.
-}
type IOMode
    = ReadMode
    | WriteMode
    | AppendMode
    | ReadWriteMode



-- FILE I/O BY PATH


{-| Read a file as a UTF-8 string.
-}
readString : String -> Task IOError String
readString path =
    Eco.XHR.stringTask "File.readString"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Write a UTF-8 string to a file.
-}
writeString : String -> String -> Task IOError ()
writeString path content =
    Eco.XHR.unitTask "File.writeString"
        (Encode.object
            [ ( "path", Encode.string path )
            , ( "content", Encode.string content )
            ]
        )
        |> Task.mapError IOErr.ofKernelTuple


{-| Read a file as raw bytes.
-}
readBytes : String -> Task IOError Bytes
readBytes path =
    Eco.XHR.rawBytesRecvTask "File.readBytes"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Write raw bytes to a file.
-}
writeBytes : String -> Bytes -> Task IOError ()
writeBytes path bytes =
    Eco.XHR.sendBytesTask "File.writeBytes"
        [ Http.header "X-Eco-Path" path ]
        bytes
        |> Task.mapError IOErr.ofKernelTuple



-- FILE HANDLES


{-| Open a file handle with the given mode.
-}
open : String -> IOMode -> Task IOError Handle
open path mode =
    Eco.XHR.jsonTask "File.open"
        (Encode.object
            [ ( "path", Encode.string path )
            , ( "mode", Encode.int (ioModeToInt mode) )
            ]
        )
        Decode.int
        |> Task.mapError IOErr.ofKernelTuple
        |> Task.map Handle


{-| Close a file handle.
-}
close : Handle -> Task IOError ()
close (Handle h) =
    Eco.XHR.unitTask "File.close"
        (Encode.object [ ( "handle", Encode.int h ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Write a string to a file handle.
-}
hWriteString : Handle -> String -> Task IOError ()
hWriteString (Handle h) content =
    Eco.XHR.unitTask "File.hWriteString"
        (Encode.object
            [ ( "handle", Encode.int h )
            , ( "content", Encode.string content )
            ]
        )
        |> Task.mapError IOErr.ofKernelTuple


{-| Get the size of a file in bytes via its handle.
-}
size : Handle -> Task IOError Int
size (Handle h) =
    Eco.XHR.jsonTask "File.size"
        (Encode.object [ ( "handle", Encode.int h ) ])
        Decode.int
        |> Task.mapError IOErr.ofKernelTuple



-- FILE LOCKING


{-| Acquire a lock on a file. Blocks until the lock is acquired.
-}
lock : String -> Task IOError ()
lock path =
    Eco.XHR.unitTask "File.lock"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Release a lock on a file.
-}
unlock : String -> Task IOError ()
unlock path =
    Eco.XHR.unitTask "File.unlock"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple



-- FILE AND DIRECTORY QUERIES


{-| Check if a file exists at the given path.
-}
fileExists : String -> Task Never Bool
fileExists path =
    Eco.XHR.jsonTask "File.fileExists"
        (Encode.object [ ( "path", Encode.string path ) ])
        Decode.bool
        |> Eco.XHR.orCrash


{-| Check if a directory exists at the given path.
-}
dirExists : String -> Task Never Bool
dirExists path =
    Eco.XHR.jsonTask "File.dirExists"
        (Encode.object [ ( "path", Encode.string path ) ])
        Decode.bool
        |> Eco.XHR.orCrash


{-| Search for an executable on the system PATH.
-}
findExecutable : String -> Task Never (Maybe String)
findExecutable name =
    Eco.XHR.jsonTask "File.findExecutable"
        (Encode.object [ ( "name", Encode.string name ) ])
        (Decode.nullable Decode.string)
        |> Eco.XHR.orCrash


{-| List the contents of a directory.
-}
list : String -> Task IOError (List String)
list path =
    Eco.XHR.jsonTask "File.list"
        (Encode.object [ ( "path", Encode.string path ) ])
        (Decode.list Decode.string)
        |> Task.mapError IOErr.ofKernelTuple


{-| Get the modification time of a file.
-}
modificationTime : String -> Task IOError Time.Posix
modificationTime path =
    Eco.XHR.jsonTask "File.modificationTime"
        (Encode.object [ ( "path", Encode.string path ) ])
        Decode.int
        |> Task.mapError IOErr.ofKernelTuple
        |> Task.map Time.millisToPosix


{-| Update the modification time of a file to the current time.
Creates the file if it does not exist.
-}
touch : String -> Task IOError ()
touch path =
    Eco.XHR.unitTask "File.touch"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple



-- DIRECTORY OPERATIONS


{-| Get the current working directory.
-}
getCwd : Task Never String
getCwd =
    Eco.XHR.stringTask "File.getCwd" Encode.null
        |> Eco.XHR.orCrash


{-| Set the current working directory.
-}
setCwd : String -> Task IOError ()
setCwd path =
    Eco.XHR.unitTask "File.setCwd"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Resolve symlinks and normalize a path.
-}
canonicalize : String -> Task IOError String
canonicalize path =
    Eco.XHR.stringTask "File.canonicalize"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Get the application-specific user data directory.
-}
appDataDir : String -> Task Never String
appDataDir name =
    Eco.XHR.stringTask "File.appDataDir"
        (Encode.object [ ( "name", Encode.string name ) ])
        |> Eco.XHR.orCrash


{-| Create a directory. If the first argument is True, parent directories are
created as needed.
-}
createDir : Bool -> String -> Task IOError ()
createDir createParents path =
    Eco.XHR.unitTask "File.createDir"
        (Encode.object
            [ ( "createParents", Encode.bool createParents )
            , ( "path", Encode.string path )
            ]
        )
        |> Task.mapError IOErr.ofKernelTuple


{-| Remove a file.
-}
removeFile : String -> Task IOError ()
removeFile path =
    Eco.XHR.unitTask "File.removeFile"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Remove a directory and all its contents recursively.
-}
removeDir : String -> Task IOError ()
removeDir path =
    Eco.XHR.unitTask "File.removeDir"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


ioModeToInt : IOMode -> Int
ioModeToInt mode =
    case mode of
        ReadMode ->
            0

        WriteMode ->
            1

        AppendMode ->
            2

        ReadWriteMode ->
            3
