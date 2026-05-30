module Eco.File exposing
    ( readString, writeString, readBytes, writeBytes
    , Handle(..), IOMode(..), open, close, size
    , lock, unlock
    , fileExists, dirExists, findExecutable, list, modificationTime, touch
    , getCwd, setCwd, canonicalize, appDataDir, createDir, removeFile, removeDir
    , hWriteString
    )

{-| File system operations: file I/O, handles, locks, and directories.

All operations are atomic IO primitives backed by kernel implementations.
Fallible operations fail with a typed `IOError`; the kernel reports failures as
the neutral `( classificationTag, path, message )` tuple (see IO_ERR_002) which
`Eco.IO.Error.ofKernelTuple` decodes.


# File I/O by Path

@docs readString, writeString, readBytes, writeBytes


# File Handles

@docs Handle, IOMode, open, close, size


# File Locking

@docs lock, unlock


# File and Directory Queries

@docs fileExists, dirExists, findExecutable, list, modificationTime, touch


# Directory Operations

@docs getCwd, setCwd, canonicalize, appDataDir, createDir, removeFile, removeDir

-}

import Bytes exposing (Bytes)
import Eco.IO.Error as IOErr exposing (IOError)
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
readString : String -> Task IOError String
readString path =
    Eco.Kernel.File.readString path
        |> Task.mapError IOErr.ofKernelTuple


{-| Write a UTF-8 string to a file.
-}
writeString : String -> String -> Task IOError ()
writeString path content =
    Eco.Kernel.File.writeString path content
        |> Task.mapError IOErr.ofKernelTuple


{-| Read a file as raw bytes.
-}
readBytes : String -> Task IOError Bytes
readBytes path =
    Eco.Kernel.File.readBytes path
        |> Task.mapError IOErr.ofKernelTuple


{-| Write raw bytes to a file.
-}
writeBytes : String -> Bytes -> Task IOError ()
writeBytes path bytes =
    Eco.Kernel.File.writeBytes path bytes
        |> Task.mapError IOErr.ofKernelTuple



-- FILE HANDLES


{-| Open a file handle with the given mode.
-}
open : String -> IOMode -> Task IOError Handle
open path mode =
    Eco.Kernel.File.open path mode
        |> Task.mapError IOErr.ofKernelTuple
        |> Task.map Handle


{-| Close a file handle.
-}
close : Handle -> Task IOError ()
close (Handle h) =
    Eco.Kernel.File.close h
        |> Task.mapError IOErr.ofKernelTuple


{-| Write a string to a file handle.
-}
hWriteString : Handle -> String -> Task IOError ()
hWriteString (Handle h) content =
    Eco.Kernel.File.hWriteString h content
        |> Task.mapError IOErr.ofKernelTuple


{-| Get the size of a file in bytes via its handle.
-}
size : Handle -> Task IOError Int
size (Handle h) =
    Eco.Kernel.File.size h
        |> Task.mapError IOErr.ofKernelTuple



-- FILE LOCKING


{-| Acquire a lock on a file. Blocks until the lock is acquired.
-}
lock : String -> Task IOError ()
lock path =
    Eco.Kernel.File.lock path
        |> Task.mapError IOErr.ofKernelTuple


{-| Release a lock on a file.
-}
unlock : String -> Task IOError ()
unlock path =
    Eco.Kernel.File.unlock path
        |> Task.mapError IOErr.ofKernelTuple



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
list : String -> Task IOError (List String)
list path =
    Eco.Kernel.File.list path
        |> Task.mapError IOErr.ofKernelTuple


{-| Get the modification time of a file.
-}
modificationTime : String -> Task IOError Time.Posix
modificationTime path =
    Eco.Kernel.File.modificationTime path
        |> Task.mapError IOErr.ofKernelTuple
        |> Task.map Time.millisToPosix


{-| Update the modification time of a file to the current time.
Creates the file if it does not exist.
-}
touch : String -> Task IOError ()
touch path =
    Eco.Kernel.File.touch path
        |> Task.mapError IOErr.ofKernelTuple



-- DIRECTORY OPERATIONS


{-| Get the current working directory.
-}
getCwd : Task Never String
getCwd =
    Eco.Kernel.File.getCwd


{-| Set the current working directory.
-}
setCwd : String -> Task IOError ()
setCwd path =
    Eco.Kernel.File.setCwd path
        |> Task.mapError IOErr.ofKernelTuple


{-| Resolve symlinks and normalize a path.
-}
canonicalize : String -> Task IOError String
canonicalize path =
    Eco.Kernel.File.canonicalize path
        |> Task.mapError IOErr.ofKernelTuple


{-| Get the application-specific user data directory.
-}
appDataDir : String -> Task Never String
appDataDir name =
    Eco.Kernel.File.appDataDir name


{-| Create a directory. If the first argument is True, parent directories are
created as needed.
-}
createDir : Bool -> String -> Task IOError ()
createDir createParents path =
    Eco.Kernel.File.createDir createParents path
        |> Task.mapError IOErr.ofKernelTuple


{-| Remove a file.
-}
removeFile : String -> Task IOError ()
removeFile path =
    Eco.Kernel.File.removeFile path
        |> Task.mapError IOErr.ofKernelTuple


{-| Remove a directory and all its contents recursively.
-}
removeDir : String -> Task IOError ()
removeDir path =
    Eco.Kernel.File.removeDir path
        |> Task.mapError IOErr.ofKernelTuple
