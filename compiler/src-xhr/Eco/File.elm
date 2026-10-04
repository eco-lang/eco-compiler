module Eco.File exposing
    ( readString, writeString, readBytes, writeBytes, writeBytesAtomic
    , Handle(..), IOMode(..), open, close, size, hWriteString
    , lock, unlock
    , fileExists, dirExists, findExecutable, list, modificationTime, touch
    , getCwd, setCwd, canonicalize, appDataDir, createDir, removeFile, removeDir
    )

{-| Gives a program running on stock Elm, which has no access to files of its
own, a way to read and write files and directories. Each operation here is a
request to eco-io, the HTTP server that `Eco.XHR` describes, and eco-io does
the work.

This module is one of two with the same name, exposed values and signatures.
The native build uses a kernel module in its place, and code elsewhere imports
`Eco.File` without knowing which of the two it gets.

Each operation sends the op `"File."` followed by its own name, with its
arguments as JSON. `writeBytes` and `writeBytesAtomic` are the exceptions: they
send the bytes as the request body and the path in an `X-Eco-Path` header. How
a reply becomes a result, a failure or a crash is set out in `Eco.XHR`.

Operations that can fail return a `Task IOError`, with the failure classified
as `Eco.IO.Error` describes. `fileExists`, `dirExists`, `findExecutable`,
`getCwd` and `appDataDir` have no failure type: any failure of theirs crashes
the program, through `Eco.XHR.orCrash`.

What an operation does to the file system is decided by eco-io, not here.
Where the eco-io server in this repository, `bin/eco-io-handler.js`, does
something its name does not suggest, the operation's docstring says so.


# File I/O by Path

@docs readString, writeString, readBytes, writeBytes, writeBytesAtomic


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


{-| An open file, as `open` returns it, for `hWriteString`, `size` and `close`
to act on.

`Handle` carries the number eco-io gave the file when it opened it. The
constructor is exposed, so a handle can be made from any `Int`, and every
operation sends that number to eco-io as it is.

-}
type Handle
    = Handle Int


{-| How `open` opens a file: for reading, writing, appending, or both reading
and writing.

The mode is sent to eco-io as 0, 1, 2 or 3, in that order. The server in this
repository opens the file with the Node flags `r`, `w`, `a` and `r+`
respectively, so `WriteMode` empties an existing file and `ReadMode` and
`ReadWriteMode` fail on a missing one.

-}
type IOMode
    = ReadMode
    | WriteMode
    | AppendMode
    | ReadWriteMode



-- FILE I/O BY PATH


{-| Reads the whole of the file at `path` as UTF-8 text.
-}
readString : String -> Task IOError String
readString path =
    Eco.XHR.stringTask "File.readString"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Writes `content` as UTF-8 text to the file at `path`, replacing what it
held, or creating it if it is missing.
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


{-| Reads the whole of the file at `path` as bytes.
-}
readBytes : String -> Task IOError Bytes
readBytes path =
    Eco.XHR.rawBytesRecvTask "File.readBytes"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Writes `bytes` to the file at `path`, replacing what it held, or creating it
if it is missing.
-}
writeBytes : String -> Bytes -> Task IOError ()
writeBytes path bytes =
    Eco.XHR.sendBytesTask "File.writeBytes"
        [ Http.header "X-Eco-Path" path ]
        bytes
        |> Task.mapError IOErr.ofKernelTuple


{-| Writes `bytes` to the file at `path` by writing them to a new file beside it
and then renaming that file over `path`, so that `path` itself is never partly
written.

The server in this repository names the new file `path` followed by `.tmp-`, its
process id and a counter, and removes it if either step fails.

-}
writeBytesAtomic : String -> Bytes -> Task IOError ()
writeBytesAtomic path bytes =
    Eco.XHR.sendBytesTask "File.writeBytesAtomic"
        [ Http.header "X-Eco-Path" path ]
        bytes
        |> Task.mapError IOErr.ofKernelTuple



-- FILE HANDLES


{-| Opens the file at `path` in `mode` and returns a handle to it.
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


{-| Closes the file the handle names.

The server in this repository also accepts the number of a stream it opened to
a child process's standard input, and ends that stream.

-}
close : Handle -> Task IOError ()
close (Handle h) =
    Eco.XHR.unitTask "File.close"
        (Encode.object [ ( "handle", Encode.int h ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Writes `content` as UTF-8 text to the open file.
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


{-| Returns the size in bytes of the open file.
-}
size : Handle -> Task IOError Int
size (Handle h) =
    Eco.XHR.jsonTask "File.size"
        (Encode.object [ ( "handle", Encode.int h ) ])
        Decode.int
        |> Task.mapError IOErr.ofKernelTuple



-- FILE LOCKING


{-| Asks eco-io to lock the file at `path`.

The server in this repository takes no lock and succeeds at once, as do the
native build's kernels. Nothing waits, and nothing keeps another process
out.

-}
lock : String -> Task IOError ()
lock path =
    Eco.XHR.unitTask "File.lock"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Asks eco-io to release the lock on the file at `path`. Like `lock`, it
succeeds at once and does nothing in the server in this repository and in the
native build's kernels.
-}
unlock : String -> Task IOError ()
unlock path =
    Eco.XHR.unitTask "File.unlock"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple



-- FILE AND DIRECTORY QUERIES


{-| Returns whether `path` names a file. The server in this repository answers
`False` for a directory, and for a path it cannot examine.
-}
fileExists : String -> Task Never Bool
fileExists path =
    Eco.XHR.jsonTask "File.fileExists"
        (Encode.object [ ( "path", Encode.string path ) ])
        Decode.bool
        |> Eco.XHR.orCrash


{-| Returns whether `path` names a directory. The server in this repository
answers `False` for a file, and for a path it cannot examine.
-}
dirExists : String -> Task Never Bool
dirExists path =
    Eco.XHR.jsonTask "File.dirExists"
        (Encode.object [ ( "path", Encode.string path ) ])
        Decode.bool
        |> Eco.XHR.orCrash


{-| Returns the path of the executable called `name` that the system's search
path finds, or `Nothing` if it finds none.
-}
findExecutable : String -> Task Never (Maybe String)
findExecutable name =
    Eco.XHR.jsonTask "File.findExecutable"
        (Encode.object [ ( "name", Encode.string name ) ])
        (Decode.nullable Decode.string)
        |> Eco.XHR.orCrash


{-| Returns the names of the entries in the directory at `path`, without the
directory in front of them.
-}
list : String -> Task IOError (List String)
list path =
    Eco.XHR.jsonTask "File.list"
        (Encode.object [ ( "path", Encode.string path ) ])
        (Decode.list Decode.string)
        |> Task.mapError IOErr.ofKernelTuple


{-| Returns when the file at `path` was last modified. eco-io reports it as a
whole number of milliseconds, and the server in this repository rounds it down.
-}
modificationTime : String -> Task IOError Time.Posix
modificationTime path =
    Eco.XHR.jsonTask "File.modificationTime"
        (Encode.object [ ( "path", Encode.string path ) ])
        Decode.int
        |> Task.mapError IOErr.ofKernelTuple
        |> Task.map Time.millisToPosix


{-| Sets the modification time of the file at `path` to now, creating an empty
file there if it is missing.
-}
touch : String -> Task IOError ()
touch path =
    Eco.XHR.unitTask "File.touch"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple



-- DIRECTORY OPERATIONS


{-| The task that reads eco-io's current working directory.
-}
getCwd : Task Never String
getCwd =
    Eco.XHR.stringTask "File.getCwd" Encode.null
        |> Eco.XHR.orCrash


{-| Changes eco-io's current working directory to `path`.
-}
setCwd : String -> Task IOError ()
setCwd path =
    Eco.XHR.unitTask "File.setCwd"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Returns `path` as an absolute path, with symbolic links resolved.

The server in this repository succeeds even when the links cannot be resolved,
for instance because `path` does not exist: it then returns `path` made
absolute and normalized, with no links resolved. The task can still fail when
the request to eco-io itself fails.

-}
canonicalize : String -> Task IOError String
canonicalize path =
    Eco.XHR.stringTask "File.canonicalize"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Returns the directory where an application called `name` keeps its data for
the current user. The server in this repository gives
`~/Library/Application Support/name` on macOS, `name` under `%APPDATA%` (or
under the home directory when that is unset) on Windows, and `~/.name`
elsewhere. The directory need not exist.
-}
appDataDir : String -> Task Never String
appDataDir name =
    Eco.XHR.stringTask "File.appDataDir"
        (Encode.object [ ( "name", Encode.string name ) ])
        |> Eco.XHR.orCrash


{-| Creates the directory at `path`. When `createParents` is `True`, missing
parent directories are created too, and the server in this repository then
does not fail when the directory already exists.
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


{-| Removes the file at `path`.
-}
removeFile : String -> Task IOError ()
removeFile path =
    Eco.XHR.unitTask "File.removeFile"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Removes the directory at `path` with everything in it. The server in this
repository also removes a file at `path`, and does not fail when nothing is
there.
-}
removeDir : String -> Task IOError ()
removeDir path =
    Eco.XHR.unitTask "File.removeDir"
        (Encode.object [ ( "path", Encode.string path ) ])
        |> Task.mapError IOErr.ofKernelTuple


{-| Returns the number that stands for `mode` in an eco-io `open` request.
-}
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
