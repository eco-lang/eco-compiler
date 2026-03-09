module Eco.File exposing
    ( readString, writeString, readBytes, writeBytes
    , Handle(..), IOMode(..), open, close, size, hWriteString
    , lock, unlock
    , fileExists, dirExists
    , findExecutable, list, modificationTime
    , getCwd, setCwd, canonicalize, appDataDir
    , createDir, removeFile, removeDir
    )

{-| File system operations: file I/O, handles, locks, and directories.

All operations are atomic IO primitives backed by kernel implementations.


# File I/O by Path

@docs readString, writeString, readBytes, writeBytes


# File Handles

@docs Handle, IOMode, open, close, size


# File Locking

@docs lock, unlock


# File and Directory Queries

@docs fileExists, dirExists, findExecutable, list, modificationTime


# Directory Operations

@docs getCwd, setCwd, canonicalize, appDataDir, createDir, removeFile, removeDir

-}

import Bytes exposing (Bytes)
import Eco.Kernel.File
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
readString : String -> Task Never String
readString path =
    Eco.Kernel.File.readString path


{-| Write a UTF-8 string to a file.
-}
writeString : String -> String -> Task Never ()
writeString path content =
    Eco.Kernel.File.writeString path content


{-| Read a file as raw bytes.
-}
readBytes : String -> Task Never Bytes
readBytes path =
    Eco.Kernel.File.readBytes path


{-| Write raw bytes to a file.
-}
writeBytes : String -> Bytes -> Task Never ()
writeBytes path bytes =
    Eco.Kernel.File.writeBytes path bytes



-- FILE HANDLES


{-| Open a file handle with the given mode.
-}
open : String -> IOMode -> Task Never Handle
open path mode =
    Eco.Kernel.File.open path mode
        |> Task.map Handle


{-| Close a file handle.
-}
close : Handle -> Task Never ()
close (Handle h) =
    Eco.Kernel.File.close h


{-| Write a string to a file handle.
-}
hWriteString : Handle -> String -> Task Never ()
hWriteString (Handle h) content =
    Eco.Kernel.File.hWriteString h content


{-| Get the size of a file in bytes via its handle.
-}
size : Handle -> Task Never Int
size (Handle h) =
    Eco.Kernel.File.size h



-- FILE LOCKING


{-| Acquire a lock on a file. Blocks until the lock is acquired.
-}
lock : String -> Task Never ()
lock path =
    Eco.Kernel.File.lock path


{-| Release a lock on a file.
-}
unlock : String -> Task Never ()
unlock path =
    Eco.Kernel.File.unlock path



-- FILE AND DIRECTORY QUERIES


{-| Check if a file exists at the given path.
-}
fileExists : String -> Task Never Bool
fileExists path =
    Eco.Kernel.File.fileExists path


{-| Check if a directory exists at the given path.
-}
dirExists : String -> Task Never Bool
dirExists path =
    Eco.Kernel.File.dirExists path


{-| Search for an executable on the system PATH.
-}
findExecutable : String -> Task Never (Maybe String)
findExecutable name =
    Eco.Kernel.File.findExecutable name


{-| List the contents of a directory.
-}
list : String -> Task Never (List String)
list path =
    Eco.Kernel.File.list path


{-| Get the modification time of a file.
-}
modificationTime : String -> Task Never Time.Posix
modificationTime path =
    Eco.Kernel.File.modificationTime path
        |> Task.map Time.millisToPosix



-- DIRECTORY OPERATIONS


{-| Get the current working directory.
-}
getCwd : Task Never String
getCwd =
    Eco.Kernel.File.getCwd


{-| Set the current working directory.
-}
setCwd : String -> Task Never ()
setCwd path =
    Eco.Kernel.File.setCwd path


{-| Resolve symlinks and normalize a path.
-}
canonicalize : String -> Task Never String
canonicalize path =
    Eco.Kernel.File.canonicalize path


{-| Get the application-specific user data directory.
-}
appDataDir : String -> Task Never String
appDataDir name =
    Eco.Kernel.File.appDataDir name


{-| Create a directory. If the first argument is True, parent directories are
created as needed.
-}
createDir : Bool -> String -> Task Never ()
createDir createParents path =
    Eco.Kernel.File.createDir createParents path


{-| Remove a file.
-}
removeFile : String -> Task Never ()
removeFile path =
    Eco.Kernel.File.removeFile path


{-| Remove a directory and all its contents recursively.
-}
removeDir : String -> Task Never ()
removeDir path =
    Eco.Kernel.File.removeDir path
