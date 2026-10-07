effect module System.File where { subscription = MySub } exposing
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
import Dict exposing (Dict)
import Eco.Kernel.FileSystem
import Platform
import Process
import Stream
import Stream.Internal
import System.File.Internal
import System.File.Path as Path exposing (Path)
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
    let
        (System.File.Internal.Error { path }) =
            error
    in
    path


{-| A string that identifies a specific kind of error. There can be several error codes for the
same kind of error, depending on the operating system that is in use.

This is usually an errno name such as `"ENOENT"`. A non-recursive [remove](#remove) of a directory
reports `"ERR_FS_EISDIR"`, so [errorIsDirectoryFound](#errorIsDirectoryFound) is `False` in that case.

-}
errorCode : Error -> String
errorCode error =
    let
        (System.File.Internal.Error { code }) =
            error
    in
    code


{-| Returns a human readable description of the error.
-}
errorToString : Error -> String
errorToString error =
    let
        (System.File.Internal.Error { message }) =
            error
    in
    message


{-| If `True`, the error occurred because you don't have the correct access permission to perform
the operation.
-}
errorIsPermissionDenied : Error -> Bool
errorIsPermissionDenied error =
    errorCode error == "EACCES"


{-| If `True`, a file exists when it was expected not to.
-}
errorIsFileExists : Error -> Bool
errorIsFileExists error =
    errorCode error == "EEXIST"


{-| If `True`, a file operation was attempted on a directory.
-}
errorIsDirectoryFound : Error -> Bool
errorIsDirectoryFound error =
    errorCode error == "EISDIR"


{-| If `True`, the application has too many open files.
-}
errorIsTooManyOpenFiles : Error -> Bool
errorIsTooManyOpenFiles error =
    errorCode error == "EMFILE"


{-| If `True`, the code was passed a [Path](System-File-Path#Path) which points to a file or
directory that doesn't exist.
-}
errorIsNoSuchFileOrDirectory : Error -> Bool
errorIsNoSuchFileOrDirectory error =
    errorCode error == "ENOENT"


{-| If `True`, a directory was expected but it found a file or some other entity.
-}
errorIsNotADirectory : Error -> Bool
errorIsNotADirectory error =
    errorCode error == "ENOTDIR"


{-| If `True`, the operation expected an empty directory, but the directory is not empty.
-}
errorIsDirectoryNotEmpty : Error -> Bool
errorIsDirectoryNotEmpty error =
    errorCode error == "ENOTEMPTY"


{-| If `True`, the operation was rejected because of missing privileges.
-}
errorIsNotPermitted : Error -> Bool
errorIsNotPermitted error =
    errorCode error == "EPERM"


{-| If `True`, we seem to be stuck in a loop following link after link after...
-}
errorIsLinkLoop : Error -> Bool
errorIsLinkLoop error =
    errorCode error == "ELOOP"


{-| If `True`, the [Path](System-File-Path#Path) is too long.
-}
errorIsPathTooLong : Error -> Bool
errorIsPathTooLong error =
    errorCode error == "ENAMETOOLONG"


{-| If `True`, the arguments passed to the function are invalid somehow.
-}
errorIsInvalidInput : Error -> Bool
errorIsInvalidInput error =
    errorCode error == "EINVAL"


{-| If `True`, the operation failed due to an IO error. This could be that the disk is
busy, or even corrupt.
-}
errorIsIO : Error -> Bool
errorIsIO error =
    errorCode error == "EIO"



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
    kStat options.resolveLink (Path.toPosixString path)
        |> Task.map (System.File.Internal.decodeMetadata entityFromInt)
        |> withPath path


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
    kAccess (accessPermissionsToInt permissions) (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Change the access permissions for the entity's owner, group and everyone else.

Each list is turned into one octal digit of the file mode with
[accessPermissionsToInt](#accessPermissionsToInt), so
`{ owner = [ Read, Write ], group = [ Read ], others = [ Read ] }` sets mode `644`.

-}
changeAccess : { owner : List AccessPermission, group : List AccessPermission, others : List AccessPermission } -> Path -> Task Error Path
changeAccess permissions path =
    kChmod (modeFromPermissions permissions) (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| The integer representation of a set of access permissions in a posix system.

    accessPermissionsToInt [ Read, Write ] == 6

-}
accessPermissionsToInt : List AccessPermission -> Int
accessPermissionsToInt permissions =
    let
        numberFor num a =
            if List.member a permissions then
                num

            else
                0
    in
    numberFor 4 Read + numberFor 2 Write + numberFor 1 Execute


{-| Change the user and group that owns a file.

You'll need the ID of the owner and group to perform this operation.

If `resolveLink` is `False`, you're changing the owner of the link itself,
not the entity it points to.

-}
changeOwner : { userID : Int, groupID : Int, resolveLink : Bool } -> Path -> Task Error Path
changeOwner options path =
    kChown options.resolveLink options.userID options.groupID (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Change the registered time (down to the second) an entity was accessed and modified.
Times are rounded down to the whole second.

If `resolveLink` is `False`, you're changing the last access and modification time of the link
itself, not the entity it points to.

-}
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix, resolveLink : Bool } -> Path -> Task Error Path
changeTimes options path =
    kUtimes options.resolveLink
        (Time.posixToMillis options.lastAccessed // 1000)
        (Time.posixToMillis options.lastModified // 1000)
        (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Move the entity represented by the second [Path](System-File-Path#Path), to the location
represented by the first [Path](System-File-Path#Path). This can also be used to rename an
entity.

    move newPath oldPath

The task succeeds with the new path. If it fails, [errorPath](#errorPath) is the new path.

-}
move : Path -> Path -> Task Error Path
move newPath oldPath =
    kRename (Path.toPosixString oldPath) (Path.toPosixString newPath)
        |> withPath newPath
        |> Task.map (\_ -> newPath)


{-| If you have a [Path](System-File-Path#Path) that is relative to the current directory,
or points at a link, you can use this to find the true [Path](System-File-Path#Path) of the
entity.
-}
realPath : Path -> Task Error Path
realPath path =
    kRealpath (Path.toPosixString path)
        |> withPath path
        |> Task.map Path.fromPosixString



-- FILES


{-| Copy the file represented by the second [Path](System-File-Path#Path), to the location
represented by the first [Path](System-File-Path#Path).

    copyFile destinationPath sourcePath

An existing file at the destination is overwritten. The task succeeds with the destination path,
and if it fails, [errorPath](#errorPath) is the destination path.

-}
copyFile : Path -> Path -> Task Error Path
copyFile destinationPath sourcePath =
    kCopyFile (Path.toPosixString sourcePath) (Path.toPosixString destinationPath)
        |> withPath destinationPath
        |> Task.map (\_ -> destinationPath)


{-| Add `Bytes` to the end of a file. The file is created if it doesn't exist.
-}
appendToFile : Bytes -> Path -> Task Error Path
appendToFile bytes path =
    kAppendFile bytes (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Read the entire contents of a file.

Note: This will return the entire contents of a file at once. For very large
files this might cause you to run out of memory. In those cases you might want
to use [readFileStream](#readFileStream) instead.

-}
readFile : Path -> Task Error Bytes
readFile path =
    kReadFile (Path.toPosixString path)
        |> withPath path


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
    let
        ( start, end ) =
            case mode of
                Beginning ->
                    ( 0, -1 )

                From n ->
                    ( max 0 n, -1 )

                Between range ->
                    ( max 0 range.start, range.end )
    in
    kReadFileStream start end (Path.toPosixString path)
        |> withPath path
        |> Task.map Stream.Internal.Readable


{-| Write the given `Bytes` into a file. The file will be created if it doesn't exist,
and overwritten if it does.
-}
writeFile : Bytes -> Path -> Task Error Path
writeFile bytes path =
    kWriteFile bytes (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


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
    let
        ( kind, position ) =
            case mode of
                Replace ->
                    ( 0, 0 )

                ReplaceFrom n ->
                    if n <= 0 then
                        ( 0, 0 )

                    else
                        ( 1, n )

                Append ->
                    ( 2, 0 )
    in
    kWriteFileStream kind position (Path.toPosixString path)
        |> withPath path
        |> Task.map Stream.Internal.Writable


{-| Make sure the given file is of a specific length. If the file is smaller than
the given length, zeroes are added to the file until it is the correct length. If the file
is larger than the given length, the excess bytes are removed.
-}
truncateFile : Int -> Path -> Task Error Path
truncateFile length path =
    kTruncate length (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Remove the file or directory at the given path.

  - `recursive` will delete a directory and everything in it.

Removing a directory with `recursive = False` fails with the error code `"ERR_FS_EISDIR"`.

-}
remove : { recursive : Bool } -> Path -> Task Error Path
remove options path =
    kRemove options.recursive (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)



-- DIRECTORIES


{-| List the contents of a directory. The returned [Paths](System-File-Path#Path) are relative to
the directory being listed. Entries are sorted by name, byte by byte.
-}
listDirectory : Path -> Task Error (List { path : Path, entityType : EntityType })
listDirectory path =
    kListDirectory (Path.toPosixString path)
        |> withPath path
        |> Task.map
            (List.map
                (\( name, entity ) ->
                    { path = Path.fromPosixString name
                    , entityType = entityFromInt entity
                    }
                )
            )


{-| Create a new directory at the given [Path](System-File-Path#Path).

If `recursive` is `True`, then a directory will be created for every section of the
given [Path](System-File-Path#Path).

-}
makeDirectory : { recursive : Bool } -> Path -> Task Error Path
makeDirectory options path =
    kMakeDirectory options.recursive (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Create a directory, prefixed by a given name, that ends up in a section of the
file system reserved for temporary files (see [tmpDirectory](#tmpDirectory)). You're given the
[Path](System-File-Path#Path) to this new directory.

A few random characters are added after the prefix, so every call creates a new directory.

-}
makeTempDirectory : String -> Task Error Path
makeTempDirectory prefix =
    tmpDirectory
        |> Task.andThen
            (\tmp ->
                kMakeTempDirectory prefix
                    |> withPath (Path.appendPosixString prefix tmp)
                    |> Task.map Path.fromPosixString
            )



-- LINKS


{-| Creates a hard link from the second [Path](System-File-Path#Path) to the first.

    hardLink linkPath targetPath

A hard link is an alias for a specific location. The link has the same
ownership and access permissions, and it's impossible to tell which is
the "real" entity and which is the link.

-}
hardLink : Path -> Path -> Task Error Path
hardLink linkPath targetPath =
    kLink (Path.toPosixString targetPath) (Path.toPosixString linkPath)
        |> withPath linkPath
        |> Task.map (\_ -> linkPath)


{-| Creates a soft link from the second [Path](System-File-Path#Path) to the first.

    softLink linkPath targetPath

A soft link, also known as a symbolic link or symlink, is a special file
that contains the path to some other location. Resolving a soft link will
redirect to this other location.

-}
softLink : Path -> Path -> Task Error Path
softLink linkPath targetPath =
    kSymlink (Path.toPosixString targetPath) (Path.toPosixString linkPath)
        |> withPath linkPath
        |> Task.map (\_ -> linkPath)


{-| Returns the [Path](System-File-Path#Path) pointed to by a soft link.
-}
readLink : Path -> Task Error Path
readLink path =
    kReadLink (Path.toPosixString path)
        |> withPath path
        |> Task.map Path.fromPosixString


{-| Removes a link, hard or soft, from the file system. If the
[Path](System-File-Path#Path) refers to a file, the file is removed.
-}
unlink : Path -> Task Error Path
unlink path =
    kUnlink (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)



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
    subscription (Watch (Path.toPosixString path) False (watchTagger toMsg))


{-| Same as [watch](#watch), but this will also watch for changes in sub-directories.
-}
watchRecursive : (WatchEvent -> msg) -> Path -> Sub msg
watchRecursive toMsg path =
    subscription (Watch (Path.toPosixString path) True (watchTagger toMsg))



-- SPECIAL PATHS


{-| Find the [Path](System-File-Path#Path) that represents the home directory of the current user.

This is `$HOME` when it is set, and otherwise the home directory recorded for the user in the
system's user database.

-}
homeDirectory : Task x Path
homeDirectory =
    kHomeDirectory
        |> Task.map Path.fromPosixString
        |> Task.mapError never


{-| Returns the current working directory of the program.

This is the directory that all relative paths are relative to, and is usually the
directory that the program was executed from.

-}
currentWorkingDirectory : Task x Path
currentWorkingDirectory =
    kCurrentWorkingDirectory
        |> Task.map Path.fromPosixString
        |> Task.mapError never


{-| Find a [Path](System-File-Path#Path) that represents a directory meant to hold temporary files.

This is the first of the `TMPDIR`, `TMP` and `TEMP` environment variables that is set, and
`/tmp` otherwise.

-}
tmpDirectory : Task x Path
tmpDirectory =
    kTmpDirectory
        |> Task.map Path.fromPosixString
        |> Task.mapError never


{-| [Path](System-File-Path#Path) to a file which is always empty. Anything written to this file
will be discarded.
-}
devNull : Task x Path
devNull =
    kDevNull
        |> Task.map Path.fromPosixString
        |> Task.mapError never



-- HELPERS


withPath : Path -> Task ( String, String ) a -> Task Error a
withPath path task =
    Task.mapError (System.File.Internal.decodeError path) task


entityFromInt : Int -> EntityType
entityFromInt n =
    case n of
        0 ->
            File

        1 ->
            Directory

        2 ->
            Socket

        3 ->
            Symlink

        4 ->
            Device

        _ ->
            Pipe


{-| The numeric file mode for `chmod`: one octal digit per class, as gren builds the string
`"644"` (plans/eco-system-library.md Appendix E.3).
-}
modeFromPermissions : { owner : List AccessPermission, group : List AccessPermission, others : List AccessPermission } -> Int
modeFromPermissions permissions =
    accessPermissionsToInt permissions.owner
        * 64
        + accessPermissionsToInt permissions.group
        * 8
        + accessPermissionsToInt permissions.others


watchTagger : (WatchEvent -> msg) -> ( Int, Maybe String ) -> msg
watchTagger toMsg ( kind, relativePath ) =
    let
        path =
            Maybe.map Path.fromPosixString relativePath
    in
    if kind == 1 then
        toMsg (Moved path)

    else
        toMsg (Changed path)



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "System.File"
-- (src/eco-system/FileSystem/FileSystemManager.{hpp,cpp}, plans/eco-system-library.md
-- Appendix C.2) and ignores the Elm functions below. The JS backend runs them
-- (plans/eco-system-library.md Phase 10, D15): one watcher exists per (path, recursive) key,
-- a never-completing kernel binding spawned when the key first appears and killed when its
-- last subscription goes away; it notifies the manager through `Platform.sendToSelf`, which
-- hands the event to every tagger of that key. The constructor layout of MySub is mirrored
-- by FileSystemManager.hpp: keep them in sync.


type MySub msg
    = Watch String Bool (( Int, Maybe String ) -> msg)


subMap : (a -> b) -> MySub a -> MySub b
subMap f (Watch path recursive tagger) =
    Watch path recursive (\event -> f (tagger event))


{-| The watchers by key (see `watchKey`).
-}
type alias State msg =
    Dict String (Watcher msg)


{-| The taggers of one key, in subscription order, and the process running its watcher.
-}
type alias Watcher msg =
    { taggers : List (( Int, Maybe String ) -> msg)
    , listener : Process.Id
    }


type alias WatchSpec msg =
    { path : String
    , recursive : Bool
    , taggers : List (( Int, Maybe String ) -> msg)
    }


type Event
    = Notify String ( Int, Maybe String )


{-| The registry key (path, recursive) as a comparable String.
-}
watchKey : String -> Bool -> String
watchKey path recursive =
    if recursive then
        "R" ++ path

    else
        "N" ++ path


init : Task Never (State msg)
init =
    Task.succeed Dict.empty


onEffects : Platform.Router msg Event -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router subs state =
    let
        addSub (Watch path recursive tagger) acc =
            Dict.update (watchKey path recursive)
                (\existing ->
                    case existing of
                        Just spec ->
                            Just { spec | taggers = spec.taggers ++ [ tagger ] }

                        Nothing ->
                            Just { path = path, recursive = recursive, taggers = [ tagger ] }
                )
                acc

        -- Effects arrive in reverse order of declaration.
        wanted =
            List.foldl addSub Dict.empty (List.reverse subs)

        stopped =
            Dict.diff state wanted
                |> Dict.values
                |> List.map (\watcher -> Process.kill watcher.listener)

        startOrKeep key spec acc =
            acc
                |> Task.andThen
                    (\watchers ->
                        case Dict.get key state of
                            Just watcher ->
                                Task.succeed (Dict.insert key { watcher | taggers = spec.taggers } watchers)

                            Nothing ->
                                Process.spawn
                                    (kAttachWatchListener spec.path
                                        spec.recursive
                                        (\event -> Platform.sendToSelf router (Notify key event))
                                    )
                                    |> Task.map (\pid -> Dict.insert key { taggers = spec.taggers, listener = pid } watchers)
                    )
    in
    Task.sequence stopped
        |> Task.andThen (\_ -> Dict.foldl startOrKeep (Task.succeed Dict.empty) wanted)


onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router (Notify key event) state =
    case Dict.get key state of
        Just watcher ->
            watcher.taggers
                |> List.map (\tagger -> Platform.sendToApp router (tagger event))
                |> Task.sequence
                |> Task.map (\_ -> state)

        Nothing ->
            Task.succeed state



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.3).


kStat : Bool -> String -> Task ( String, String ) (List Int)
kStat =
    Eco.Kernel.FileSystem.stat


kAccess : Int -> String -> Task ( String, String ) ()
kAccess =
    Eco.Kernel.FileSystem.access


kChmod : Int -> String -> Task ( String, String ) ()
kChmod =
    Eco.Kernel.FileSystem.chmod


kChown : Bool -> Int -> Int -> String -> Task ( String, String ) ()
kChown =
    Eco.Kernel.FileSystem.chown


kUtimes : Bool -> Int -> Int -> String -> Task ( String, String ) ()
kUtimes =
    Eco.Kernel.FileSystem.utimes


kRename : String -> String -> Task ( String, String ) ()
kRename =
    Eco.Kernel.FileSystem.rename


kRealpath : String -> Task ( String, String ) String
kRealpath =
    Eco.Kernel.FileSystem.realpath


kCopyFile : String -> String -> Task ( String, String ) ()
kCopyFile =
    Eco.Kernel.FileSystem.copyFile


kAppendFile : Bytes -> String -> Task ( String, String ) ()
kAppendFile =
    Eco.Kernel.FileSystem.appendFile


kReadFile : String -> Task ( String, String ) Bytes
kReadFile =
    Eco.Kernel.FileSystem.readFile


kWriteFile : Bytes -> String -> Task ( String, String ) ()
kWriteFile =
    Eco.Kernel.FileSystem.writeFile


kTruncate : Int -> String -> Task ( String, String ) ()
kTruncate =
    Eco.Kernel.FileSystem.truncate


kRemove : Bool -> String -> Task ( String, String ) ()
kRemove =
    Eco.Kernel.FileSystem.remove


kListDirectory : String -> Task ( String, String ) (List ( String, Int ))
kListDirectory =
    Eco.Kernel.FileSystem.listDirectory


kMakeDirectory : Bool -> String -> Task ( String, String ) ()
kMakeDirectory =
    Eco.Kernel.FileSystem.makeDirectory


kMakeTempDirectory : String -> Task ( String, String ) String
kMakeTempDirectory =
    Eco.Kernel.FileSystem.makeTempDirectory


kLink : String -> String -> Task ( String, String ) ()
kLink =
    Eco.Kernel.FileSystem.link


kSymlink : String -> String -> Task ( String, String ) ()
kSymlink =
    Eco.Kernel.FileSystem.symlink


kReadLink : String -> Task ( String, String ) String
kReadLink =
    Eco.Kernel.FileSystem.readLink


kUnlink : String -> Task ( String, String ) ()
kUnlink =
    Eco.Kernel.FileSystem.unlink


kReadFileStream : Int -> Int -> String -> Task ( String, String ) Int
kReadFileStream =
    Eco.Kernel.FileSystem.readFileStream


kWriteFileStream : Int -> Int -> String -> Task ( String, String ) Int
kWriteFileStream =
    Eco.Kernel.FileSystem.writeFileStream


kHomeDirectory : Task Never String
kHomeDirectory =
    Eco.Kernel.FileSystem.homeDirectory


kCurrentWorkingDirectory : Task Never String
kCurrentWorkingDirectory =
    Eco.Kernel.FileSystem.currentWorkingDirectory


kTmpDirectory : Task Never String
kTmpDirectory =
    Eco.Kernel.FileSystem.tmpDirectory


kDevNull : Task Never String
kDevNull =
    Eco.Kernel.FileSystem.devNull


{-| JS only (D15): used by the manager body above, which the native backend drops.
-}
kAttachWatchListener : String -> Bool -> (( Int, Maybe String ) -> Task Never ()) -> Task Never ()
kAttachWatchListener =
    Eco.Kernel.FileSystem.attachWatchListener
