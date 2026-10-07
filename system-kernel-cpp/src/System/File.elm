module System.File exposing
    ( Metadata, EntityType(..), metadata, AccessPermission(..), checkAccess, changeAccess, accessPermissionsToInt, changeOwner, changeTimes, move, realPath
    , copyFile, appendToFile, readFile, ReadFileStreamMode(..), readFileStream, writeFile, WriteFileStreamMode(..), writeFileStream, truncateFile, remove
    , listDirectory, makeDirectory, makeTempDirectory
    , hardLink, softLink, readLink, unlink
    , WatchEvent(..), watch, watchRecursive
    , homeDirectory, currentWorkingDirectory, tmpDirectory, devNull
    , Error, errorPath, errorCode, errorToString
    , errorIsPermissionDenied, errorIsFileExists, errorIsDirectoryFound, errorIsTooManyOpenFiles, errorIsNoSuchFileOrDirectory, errorIsNotADirectory, errorIsDirectoryNotEmpty, errorIsNotPermitted, errorIsLinkLoop, errorIsPathTooLong, errorIsInvalidInput, errorIsIO
    )

{-| This module provides access to the file system. It allows you to read and write files, create
directories and links, and so on. Locations are given as a [Path](System-File-Path#Path).

Every function that changes the file system succeeds with the [Path](System-File-Path#Path) it was
given, which makes it easy to chain operations on the same entity. If you know you are going to
perform many operations on the same file, [System.File.FileHandle](System-File-FileHandle) can be
more efficient.

Unlike gren-node's `FileSystem` module, no permission value is needed to use these functions.


## Metadata

@docs Metadata, EntityType, metadata, AccessPermission, checkAccess, changeAccess, accessPermissionsToInt, changeOwner, changeTimes, move, realPath


## Files

@docs copyFile, appendToFile, readFile, ReadFileStreamMode, readFileStream, writeFile, WriteFileStreamMode, writeFileStream, truncateFile, remove


## Directories

@docs listDirectory, makeDirectory, makeTempDirectory


## Links

@docs hardLink, softLink, readLink, unlink


## Watch for changes

@docs WatchEvent, watch, watchRecursive


## Special paths

@docs homeDirectory, currentWorkingDirectory, tmpDirectory, devNull


## Errors

@docs Error, errorPath, errorCode, errorToString
@docs errorIsPermissionDenied, errorIsFileExists, errorIsDirectoryFound, errorIsTooManyOpenFiles, errorIsNoSuchFileOrDirectory, errorIsNotADirectory, errorIsDirectoryNotEmpty, errorIsNotPermitted, errorIsLinkLoop, errorIsPathTooLong, errorIsInvalidInput, errorIsIO

-}

import Bytes exposing (Bytes)
import Stream
import System.File.Internal
import System.File.Path exposing (Path)
import Task exposing (Task)
import Time



-- ERRORS


{-| Represents an error that occurred when working with the file system.

There are many different kinds of error depending on which operation you're performing and which
operating system you're performing it on. To figure out which error it is, you'll need
to use one of the helper functions below, or check the specific error code.

-}
type alias Error =
    System.File.Internal.Error


{-| The path where the error occurred.

For [copyFile](#copyFile), [move](#move), [hardLink](#hardLink) and [softLink](#softLink) this
is the **destination** path.

-}
errorPath : Error -> Path
errorPath error =
    Debug.todo "Implement System API"


{-| A string that identifies a specific kind of error. There can be several error codes for the
same kind of error, depending on the operating system that is in use.

This is usually an errno name such as `"ENOENT"`. A non-recursive [remove](#remove) of a directory
reports `"ERR_FS_EISDIR"`, so [errorIsDirectoryFound](#errorIsDirectoryFound) is `False` in that case.

-}
errorCode : Error -> String
errorCode error =
    Debug.todo "Implement System API"


{-| Returns a human readable description of the error.
-}
errorToString : Error -> String
errorToString error =
    Debug.todo "Implement System API"


{-| If `True`, the error occurred because you don't have the correct access permission to perform
the operation.
-}
errorIsPermissionDenied : Error -> Bool
errorIsPermissionDenied error =
    Debug.todo "Implement System API"


{-| If `True`, a file exists when it was expected not to.
-}
errorIsFileExists : Error -> Bool
errorIsFileExists error =
    Debug.todo "Implement System API"


{-| If `True`, a file operation was attempted on a directory.
-}
errorIsDirectoryFound : Error -> Bool
errorIsDirectoryFound error =
    Debug.todo "Implement System API"


{-| If `True`, the application has too many open files.
-}
errorIsTooManyOpenFiles : Error -> Bool
errorIsTooManyOpenFiles error =
    Debug.todo "Implement System API"


{-| If `True`, the code was passed a [Path](System-File-Path#Path) which points to a file or
directory that doesn't exist.
-}
errorIsNoSuchFileOrDirectory : Error -> Bool
errorIsNoSuchFileOrDirectory error =
    Debug.todo "Implement System API"


{-| If `True`, a directory was expected but it found a file or some other entity.
-}
errorIsNotADirectory : Error -> Bool
errorIsNotADirectory error =
    Debug.todo "Implement System API"


{-| If `True`, the operation expected an empty directory, but the directory is not empty.
-}
errorIsDirectoryNotEmpty : Error -> Bool
errorIsDirectoryNotEmpty error =
    Debug.todo "Implement System API"


{-| If `True`, the operation was rejected because of missing privileges.
-}
errorIsNotPermitted : Error -> Bool
errorIsNotPermitted error =
    Debug.todo "Implement System API"


{-| If `True`, we seem to be stuck in a loop following link after link after...
-}
errorIsLinkLoop : Error -> Bool
errorIsLinkLoop error =
    Debug.todo "Implement System API"


{-| If `True`, the [Path](System-File-Path#Path) is too long.
-}
errorIsPathTooLong : Error -> Bool
errorIsPathTooLong error =
    Debug.todo "Implement System API"


{-| If `True`, the arguments passed to the function are invalid somehow.
-}
errorIsInvalidInput : Error -> Bool
errorIsInvalidInput error =
    Debug.todo "Implement System API"


{-| If `True`, the operation failed due to an IO error. This could be that the disk is
busy, or even corrupt.
-}
errorIsIO : Error -> Bool
errorIsIO error =
    Debug.todo "Implement System API"



-- METADATA


{-| Represents extra information about an entity in the file system.

Sizes are in bytes, and the four times have millisecond resolution where the operating system
provides it.

-}
type alias Metadata =
    { entityType : EntityType
    , deviceID : Int
    , userID : Int
    , groupID : Int
    , byteSize : Int
    , blockSize : Int
    , blocks : Int
    , lastAccessed : Time.Posix
    , lastModified : Time.Posix
    , lastChanged : Time.Posix
    , created : Time.Posix
    }


{-| The type of an entity in the file system.
-}
type EntityType
    = File
    | Directory
    | Socket
    | Symlink
    | Device
    | Pipe


{-| Return metadata for the entity represented by [Path](System-File-Path#Path).

If `resolveLink` is `False`, you will receive metadata for the link itself, not the entity
pointed at by the link.

-}
metadata : { resolveLink : Bool } -> Path -> Task Error Metadata
metadata options path =
    Debug.todo "Implement System API"


{-| Represents the permission to access an entity for a specific operation.

For example: if you, or your group, doesn't have the `Read` permission for a file,
you're not allowed to read from it.

-}
type AccessPermission
    = Read
    | Write
    | Execute


{-| Check if the user running this application has the given access permissions for the
entity represented by [Path](System-File-Path#Path).

Passing an empty `List` will check that the entity exists.

-}
checkAccess : List AccessPermission -> Path -> Task Error Path
checkAccess permissions path =
    Debug.todo "Implement System API"


{-| Change the access permissions for the entity's owner, group and everyone else.

Each list is turned into one octal digit of the file mode with
[accessPermissionsToInt](#accessPermissionsToInt), so
`{ owner = [ Read, Write ], group = [ Read ], others = [ Read ] }` sets mode `644`.

-}
changeAccess : { owner : List AccessPermission, group : List AccessPermission, others : List AccessPermission } -> Path -> Task Error Path
changeAccess permissions path =
    Debug.todo "Implement System API"


{-| The integer representation of a set of access permissions in a posix system.

    accessPermissionsToInt [ Read, Write ] == 6

-}
accessPermissionsToInt : List AccessPermission -> Int
accessPermissionsToInt permissions =
    Debug.todo "Implement System API"


{-| Change the user and group that owns a file.

You'll need the ID of the owner and group to perform this operation.

If `resolveLink` is `False`, you're changing the owner of the link itself,
not the entity it points to.

-}
changeOwner : { userID : Int, groupID : Int, resolveLink : Bool } -> Path -> Task Error Path
changeOwner options path =
    Debug.todo "Implement System API"


{-| Change the registered time (down to the second) an entity was accessed and modified.
Times are rounded down to the whole second.

If `resolveLink` is `False`, you're changing the last access and modification time of the link
itself, not the entity it points to.

-}
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix, resolveLink : Bool } -> Path -> Task Error Path
changeTimes options path =
    Debug.todo "Implement System API"


{-| Move the entity represented by the second [Path](System-File-Path#Path), to the location
represented by the first [Path](System-File-Path#Path). This can also be used to rename an
entity.

    move newPath oldPath

The task succeeds with the new path. If it fails, [errorPath](#errorPath) is the new path.

-}
move : Path -> Path -> Task Error Path
move newPath oldPath =
    Debug.todo "Implement System API"


{-| If you have a [Path](System-File-Path#Path) that is relative to the current directory,
or points at a link, you can use this to find the true [Path](System-File-Path#Path) of the
entity.
-}
realPath : Path -> Task Error Path
realPath path =
    Debug.todo "Implement System API"



-- FILES


{-| Copy the file represented by the second [Path](System-File-Path#Path), to the location
represented by the first [Path](System-File-Path#Path).

    copyFile destinationPath sourcePath

An existing file at the destination is overwritten. The task succeeds with the destination path,
and if it fails, [errorPath](#errorPath) is the destination path.

-}
copyFile : Path -> Path -> Task Error Path
copyFile destinationPath sourcePath =
    Debug.todo "Implement System API"


{-| Add `Bytes` to the end of a file. The file is created if it doesn't exist.
-}
appendToFile : Bytes -> Path -> Task Error Path
appendToFile bytes path =
    Debug.todo "Implement System API"


{-| Read the entire contents of a file.

Note: This will return the entire contents of a file at once. For very large
files this might cause you to run out of memory. In those cases you might want
to use [readFileStream](#readFileStream) instead.

-}
readFile : Path -> Task Error Bytes
readFile path =
    Debug.todo "Implement System API"


{-| Specify where in a file you'll start streaming data from.

  - `Beginning` reads the entire file.
  - `From` skips the associated number of bytes, then streams the rest of the file.
  - `Between` reads just the bytes between `start` and `end`, both of which are offsets from the
    beginning of the file. The `end` offset is **inclusive**: `Between { start = 0, end = 9 }`
    reads ten bytes.

-}
type ReadFileStreamMode
    = Beginning
    | From Int
    | Between { start : Int, end : Int }


{-| Read the contents of a file as a stream.

**Deviation from gren-node:** errors opening the file (for example a missing file) fail this task
itself, rather than being reported by the first read from the stream.

-}
readFileStream : ReadFileStreamMode -> Path -> Task Error (Stream.Readable Bytes)
readFileStream mode path =
    Debug.todo "Implement System API"


{-| Write the given `Bytes` into a file. The file will be created if it doesn't exist,
and overwritten if it does.
-}
writeFile : Bytes -> Path -> Task Error Path
writeFile bytes path =
    Debug.todo "Implement System API"


{-| Specify how the streamed bytes will be entered into the file.

  - `Replace` will delete all existing bytes in the file and add new bytes from the beginning.
    The file is created if it doesn't exist.
  - `ReplaceFrom` will keep the associated number of bytes already in the file, but replace
    everything after with the streamed data. The file must already exist. When the stream is
    closed, the file is cut off at the end of the streamed data.
  - `Append` will keep the contents of the file untouched, and add new data at the end.
    The file is created if it doesn't exist.

-}
type WriteFileStreamMode
    = Replace
    | ReplaceFrom Int
    | Append


{-| Create a writable stream backed by a file. Close the stream when you are done writing to it.
-}
writeFileStream : WriteFileStreamMode -> Path -> Task Error (Stream.Writable Bytes)
writeFileStream mode path =
    Debug.todo "Implement System API"


{-| Make sure the given file is of a specific length. If the file is smaller than
the given length, zeroes are added to the file until it is the correct length. If the file
is larger than the given length, the excess bytes are removed.
-}
truncateFile : Int -> Path -> Task Error Path
truncateFile length path =
    Debug.todo "Implement System API"


{-| Remove the file or directory at the given path.

  - `recursive` will delete a directory and everything in it.

Removing a directory with `recursive = False` fails with the error code `"ERR_FS_EISDIR"`.

-}
remove : { recursive : Bool } -> Path -> Task Error Path
remove options path =
    Debug.todo "Implement System API"



-- DIRECTORIES


{-| List the contents of a directory. The returned [Paths](System-File-Path#Path) are relative to
the directory being listed. Entries are sorted by name, byte by byte.
-}
listDirectory : Path -> Task Error (List { path : Path, entityType : EntityType })
listDirectory path =
    Debug.todo "Implement System API"


{-| Create a new directory at the given [Path](System-File-Path#Path).

If `recursive` is `True`, then a directory will be created for every section of the
given [Path](System-File-Path#Path).

-}
makeDirectory : { recursive : Bool } -> Path -> Task Error Path
makeDirectory options path =
    Debug.todo "Implement System API"


{-| Create a directory, prefixed by a given name, that ends up in a section of the
file system reserved for temporary files (see [tmpDirectory](#tmpDirectory)). You're given the
[Path](System-File-Path#Path) to this new directory.

A few random characters are added after the prefix, so every call creates a new directory.

-}
makeTempDirectory : String -> Task Error Path
makeTempDirectory prefix =
    Debug.todo "Implement System API"



-- LINKS


{-| Creates a hard link from the second [Path](System-File-Path#Path) to the first.

    hardLink linkPath targetPath

A hard link is an alias for a specific location. The link has the same
ownership and access permissions, and it's impossible to tell which is
the "real" entity and which is the link.

-}
hardLink : Path -> Path -> Task Error Path
hardLink linkPath targetPath =
    Debug.todo "Implement System API"


{-| Creates a soft link from the second [Path](System-File-Path#Path) to the first.

    softLink linkPath targetPath

A soft link, also known as a symbolic link or symlink, is a special file
that contains the path to some other location. Resolving a soft link will
redirect to this other location.

-}
softLink : Path -> Path -> Task Error Path
softLink linkPath targetPath =
    Debug.todo "Implement System API"


{-| Returns the [Path](System-File-Path#Path) pointed to by a soft link.
-}
readLink : Path -> Task Error Path
readLink path =
    Debug.todo "Implement System API"


{-| Removes a link, hard or soft, from the file system. If the
[Path](System-File-Path#Path) refers to a file, the file is removed.
-}
unlink : Path -> Task Error Path
unlink path =
    Debug.todo "Implement System API"



-- WATCH


{-| Represents a change within a watched directory.

  - `Changed` means that the contents of a file has changed in some way.
  - `Moved` means that an entity has been added or removed. A rename is usually two `Moved` events.

On most operating systems, each event will be associated with a [Path](System-File-Path#Path)
relative to the watched directory, but some operating systems will not provide that information.

-}
type WatchEvent
    = Changed (Maybe Path)
    | Moved (Maybe Path)


{-| This notifies your application every time there is a change within the directory
represented by the given [Path](System-File-Path#Path).
-}
watch : (WatchEvent -> msg) -> Path -> Sub msg
watch toMsg path =
    Debug.todo "Implement System API"


{-| Same as [watch](#watch), but this will also watch for changes in sub-directories.
-}
watchRecursive : (WatchEvent -> msg) -> Path -> Sub msg
watchRecursive toMsg path =
    Debug.todo "Implement System API"



-- SPECIAL PATHS


{-| Find the [Path](System-File-Path#Path) that represents the home directory of the current user.

This is `$HOME` when it is set, and otherwise the home directory recorded for the user in the
system's user database.

-}
homeDirectory : Task x Path
homeDirectory =
    Debug.todo "Implement System API"


{-| Returns the current working directory of the program.

This is the directory that all relative paths are relative to, and is usually the
directory that the program was executed from.

-}
currentWorkingDirectory : Task x Path
currentWorkingDirectory =
    Debug.todo "Implement System API"


{-| Find a [Path](System-File-Path#Path) that represents a directory meant to hold temporary files.

This is the first of the `TMPDIR`, `TMP` and `TEMP` environment variables that is set, and
`/tmp` otherwise.

-}
tmpDirectory : Task x Path
tmpDirectory =
    Debug.todo "Implement System API"


{-| [Path](System-File-Path#Path) to a file which is always empty. Anything written to this file
will be discarded.
-}
devNull : Task x Path
devNull =
    Debug.todo "Implement System API"
