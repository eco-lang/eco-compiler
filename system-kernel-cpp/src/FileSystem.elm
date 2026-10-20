effect module FileSystem where { subscription = MySub } exposing
    ( Metadata, EntityType(..), metadata, AccessPermission(..), checkAccess, changeAccess, accessPermissionsToInt, changeOwner, changeTimes, move, realPath
    , copyFile, appendToFile, readFile, ReadFileStreamMode(..), readFileStream, writeFile, WriteFileStreamMode(..), writeFileStream, truncateFile, remove
    , WriteOptions, defaultWriteOptions, writeFileWith, writeFileStreamWith
    , listDirectory, makeDirectory, makeTempDirectory
    , hardLink, softLink, readLink, unlink
    , WatchEvent(..), watch, watchRecursive
    , homeDirectory, currentWorkingDirectory, tempDirectory, devNull
    , Error, errorPath, errorCode, errorToString
    , errorIsPermissionDenied, errorIsFileExists, errorIsDirectoryFound, errorIsTooManyOpenFiles, errorIsNoSuchFileOrDirectory, errorIsNotADirectory, errorIsDirectoryNotEmpty, errorIsNotPermitted, errorIsLinkLoop, errorIsPathTooLong, errorIsInvalidInput, errorIsIO
    )

{-| A program needs to read, write and manage the files, directories and links it names, and this
module does that by [Path](Path#Path). Apart from the file streams, each task here opens and
closes whatever it needs. To keep a file open, read and write it at offsets, or act on the file
that was opened even after its path has been renamed or replaced, use
[FileSystem.Handle](FileSystem-Handle).

An _entity_ is anything a path can name: a file, a directory, a symbolic link, a socket, a device
or a pipe (see [EntityType](#EntityType)).

A path reaches the operating system as the text [Path.toPosixString](Path#toPosixString) prints,
and every path that comes back, from [realPath](#realPath), [readLink](#readLink),
[listDirectory](#listDirectory), [makeTempDirectory](#makeTempDirectory), the special paths and
watch events, is parsed with [Path.fromPosixString](Path#fromPosixString). Both are lexical and
lossy, as the [Path](Path) module describes.

Most functions that change the file system succeed with a `Path`, so that calls on one entity can
be chained. It is the path the function was given, with two exceptions. The two-path functions
[move](#move), [copyFile](#copyFile), [hardLink](#hardLink) and [softLink](#softLink) take the
destination, or the new link, first and the source, or the target, second, and succeed with the
first. [makeTempDirectory](#makeTempDirectory) succeeds with the directory it created.
[writeFileStream](#writeFileStream) and [writeFileStreamWith](#writeFileStreamWith) succeed with
a stream instead.

A task here that fails, fails with an [Error](#Error), which carries the path it concerns, a
code and a message. For the two-path functions that path is the first one as well;
[errorPath](#errorPath) gives the full rule.

[readFileStream](#readFileStream) and [writeFileStream](#writeFileStream) hand the file over as
a stream. They open the file before the task succeeds, so a file that cannot be opened fails the
task with an `Error`. After that, failures arrive on the stream as a `Stream.Error`, as the
[Stream](Stream) module describes.

Two kinds of write ask more than [writeFile](#writeFile) gives, and [WriteOptions](#WriteOptions)
selects them. A _durable_ write flushes the file's data to the storage device before it
succeeds. An _exclusive_ write creates the file, and fails if anything already exists at the
path.

[watch](#watch) and [watchRecursive](#watchRecursive) are subscriptions to changes at a path.
While a subscription to a path that could be watched exists, it keeps the program running.

On the native backend under Windows the file system is not supported: every task here that can
fail fails with the code `"ENOTSUP"`, and a watch subscription stops the program with a fatal
error.


## Metadata

@docs Metadata, EntityType, metadata, AccessPermission, checkAccess, changeAccess, accessPermissionsToInt, changeOwner, changeTimes, move, realPath


## Files

@docs copyFile, appendToFile, readFile, ReadFileStreamMode, readFileStream, writeFile, WriteFileStreamMode, writeFileStream, truncateFile, remove


## Durable and exclusive writes

@docs WriteOptions, defaultWriteOptions, writeFileWith, writeFileStreamWith


## Directories

@docs listDirectory, makeDirectory, makeTempDirectory


## Links

@docs hardLink, softLink, readLink, unlink


## Watch for changes

@docs WatchEvent, watch, watchRecursive


## Special paths

@docs homeDirectory, currentWorkingDirectory, tempDirectory, devNull


## Errors

@docs Error, errorPath, errorCode, errorToString
@docs errorIsPermissionDenied, errorIsFileExists, errorIsDirectoryFound, errorIsTooManyOpenFiles, errorIsNoSuchFileOrDirectory, errorIsNotADirectory, errorIsDirectoryNotEmpty, errorIsNotPermitted, errorIsLinkLoop, errorIsPathTooLong, errorIsInvalidInput, errorIsIO

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Eco.Kernel.FileSystem
import FileSystem.Internal
import Path exposing (Path)
import Platform
import Process
import Stream
import Stream.Internal
import Task exposing (Task)
import Time



-- ERRORS


{-| A failed file system operation: the path it concerned, a code naming the kind of failure,
and a message describing it.

The three parts are read with [errorPath](#errorPath), [errorCode](#errorCode) and
[errorToString](#errorToString), and the `errorIs*` functions test the code. Which code a
failure gets can depend on the operating system. An `Error` is not interchangeable with
`Socket.Error` or `Stream.Error`. Only the tasks of this module and of
[FileSystem.Handle](FileSystem-Handle) make one.

-}
type alias Error =
    FileSystem.Internal.Error


{-| Returns the path an error concerns.

For a function of this module it is the path the function was given, with two exceptions. For
[move](#move), [copyFile](#copyFile), [hardLink](#hardLink) and [softLink](#softLink) it is the
first path, the destination or new link, even when the failure was about the source. For
[makeTempDirectory](#makeTempDirectory) it is [tempDirectory](#tempDirectory) with the prefix
appended, without the random characters, which is not the path of any directory it created.

For an operation on an open [FileSystem.Handle](FileSystem-Handle) it is
[Path.empty](Path#empty).

-}
errorPath : Error -> Path
errorPath error =
    let
        (FileSystem.Internal.Error { path }) =
            error
    in
    path


{-| Returns the code naming the kind of failure.

It is usually the operating system's errno name, such as `"ENOENT"`. A non-recursive
[remove](#remove) of a directory reports `"ERR_FS_EISDIR"`, so
[errorIsDirectoryFound](#errorIsDirectoryFound) is `False` in that case.

-}
errorCode : Error -> String
errorCode error =
    let
        (FileSystem.Internal.Error { code }) =
            error
    in
    code


{-| Returns the error's message as the kernel gave it, with no code or path added.

The message usually begins with the code, as in `"ENOENT: no such file or directory, open '/x'"`.
The message for `"ERR_FS_EISDIR"` does not: it is
`"Path is a directory: rm returned EISDIR (is a directory) /x"`.

-}
errorToString : Error -> String
errorToString error =
    let
        (FileSystem.Internal.Error { message }) =
            error
    in
    message


{-| Checks whether the code is `"EACCES"`: access permissions, of the entity or of a directory on
its path, refused the operation.
-}
errorIsPermissionDenied : Error -> Bool
errorIsPermissionDenied error =
    errorCode error == "EACCES"


{-| Checks whether the code is `"EEXIST"`: something already exists at a path that had to be new,
as for an exclusive write (see [WriteOptions](#WriteOptions)) or a link path that is taken.
-}
errorIsFileExists : Error -> Bool
errorIsFileExists error =
    errorCode error == "EEXIST"


{-| Checks whether the code is `"EISDIR"`: a directory was found where a file was needed, as when
[readFile](#readFile), [readFileStream](#readFileStream) or [copyFile](#copyFile) is given a
directory. A non-recursive [remove](#remove) of a directory reports `"ERR_FS_EISDIR"` instead, for
which this is `False`.
-}
errorIsDirectoryFound : Error -> Bool
errorIsDirectoryFound error =
    errorCode error == "EISDIR"


{-| Checks whether the code is `"EMFILE"`: the program has as many files open as it is allowed.
-}
errorIsTooManyOpenFiles : Error -> Bool
errorIsTooManyOpenFiles error =
    errorCode error == "EMFILE"


{-| Checks whether the code is `"ENOENT"`: the entity, or a directory on its path, does not exist.
-}
errorIsNoSuchFileOrDirectory : Error -> Bool
errorIsNoSuchFileOrDirectory error =
    errorCode error == "ENOENT"


{-| Checks whether the code is `"ENOTDIR"`: an entry that had to be a directory, either the path
itself or an entry on it, is something else.
-}
errorIsNotADirectory : Error -> Bool
errorIsNotADirectory error =
    errorCode error == "ENOTDIR"


{-| Checks whether the code is `"ENOTEMPTY"`: a directory that had to be empty is not.
-}
errorIsDirectoryNotEmpty : Error -> Bool
errorIsDirectoryNotEmpty error =
    errorCode error == "ENOTEMPTY"


{-| Checks whether the code is `"EPERM"`: the operation needs a privilege the program does not have,
such as changing the owner of a file it does not own.
-}
errorIsNotPermitted : Error -> Bool
errorIsNotPermitted error =
    errorCode error == "EPERM"


{-| Checks whether the code is `"ELOOP"`: resolving the path followed too many symbolic links, as
happens when links form a loop.
-}
errorIsLinkLoop : Error -> Bool
errorIsLinkLoop error =
    errorCode error == "ELOOP"


{-| Checks whether the code is `"ENAMETOOLONG"`: the path, or an entry on it, is too long.
-}
errorIsPathTooLong : Error -> Bool
errorIsPathTooLong error =
    errorCode error == "ENAMETOOLONG"


{-| Checks whether the code is `"EINVAL"`: an argument was not valid for the operation, as when
[readLink](#readLink) is given a path that is not a symbolic link.
-}
errorIsInvalidInput : Error -> Bool
errorIsInvalidInput error =
    errorCode error == "EINVAL"


{-| Checks whether the code is `"EIO"`: a low-level input or output error, such as a failing
storage device.
-}
errorIsIO : Error -> Bool
errorIsIO error =
    errorCode error == "EIO"



-- METADATA
--
-- Metadata spells out the fields of FileSystem.Internal.MetadataOf, which decodeMetadata
-- builds, instead of being defined from it. Record aliases are structural, so `metadata` can
-- return one as the other, but only while the two field lists are kept identical.


{-| What the operating system reports about one entity, as [metadata](#metadata) returns it.

`deviceID` identifies the device that holds the entity; for a `Device` entity it is not the
number of the device the entity stands for. `userID` and `groupID` are the owner's numeric ids.
`blockSize` is the size in bytes the operating system prefers for IO, and `blocks` is the number
of blocks allocated to the entity, which Linux and macOS count in 512-byte units, not in units of
`blockSize`.

The four times are whole milliseconds. `lastChanged` is the status change time, when the entity's
metadata or contents last changed, not a creation time. `created` is the time the entity was
created when that can be read (natively, on macOS, and on Linux when `statx` reports one; on the
JS backend, when Node.js reports one); otherwise it is the status change time, equal to
`lastChanged`.

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


{-| The kind of an entity in the file system.

`File` is a regular file. `Socket` is a Unix domain socket. `Symlink` is a symbolic link, which is
reported only where a link is not followed: by [metadata](#metadata) with `resolveLink = False`,
and by [listDirectory](#listDirectory). `Device` is a character or block device, or any other
kind of entity not named here. `Pipe` is a named pipe (FIFO).

-}
type EntityType
    = File
    | Directory
    | Socket
    | Symlink
    | Device
    | Pipe


{-| Returns the metadata of the entity at the path.

With `resolveLink = True` a symbolic link is followed and the entity it points to is described.
With `resolveLink = False` a link is described itself, with the `entityType` `Symlink`.

-}
metadata : { resolveLink : Bool } -> Path -> Task Error Metadata
metadata options path =
    kStat options.resolveLink (Path.toPosixString path)
        |> Task.map (FileSystem.Internal.decodeMetadata entityFromInt)
        |> withPath path


{-| One way of accessing an entity: reading it, writing it, or executing it.

[checkAccess](#checkAccess) tests a list of them, and [changeAccess](#changeAccess) grants a
list of them to each of an entity's owner, group and everyone else.

-}
type AccessPermission
    = Read
    | Write
    | Execute


{-| Checks that the program may access the entity at the path in each of the given ways, and
succeeds with the path if it may.

An empty list checks only that the entity exists.

-}
checkAccess : List AccessPermission -> Path -> Task Error Path
checkAccess permissions path =
    kAccess (accessPermissionsToInt permissions) (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Sets the access permissions of the entity at the path, for its owner, its group and everyone
else.

Each list becomes one octal digit of the file mode, as
[accessPermissionsToInt](#accessPermissionsToInt) computes it, so
`{ owner = [ Read, Write ], group = [ Read ], others = [ Read ] }` sets the mode `644`. The mode
has no other bits, so the set-user-ID, set-group-ID and sticky bits are cleared.

-}
changeAccess : { owner : List AccessPermission, group : List AccessPermission, others : List AccessPermission } -> Path -> Task Error Path
changeAccess permissions path =
    kChmod (modeFromPermissions permissions) (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Returns the POSIX permission digit for a list of permissions: 4 for `Read`, plus 2 for
`Write`, plus 1 for `Execute`. A permission listed twice counts once.

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


{-| Sets the user and group that own the entity at the path, given as numeric ids.

With `resolveLink = False` the owner of a symbolic link itself is changed, not that of the
entity it points to.

-}
changeOwner : { userID : Int, groupID : Int, resolveLink : Bool } -> Path -> Task Error Path
changeOwner options path =
    kChown options.resolveLink options.userID options.groupID (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Sets the last access and last modification times of the entity at the path.

The times are set in whole seconds: each is sent as its milliseconds divided by 1000 with `//`,
which rounds down for times after 1970 and toward zero for times before. On the JS backend `//`
gives a 32-bit result, so a time from 2038-01-19T03:14:08Z on, or at or before
1901-12-13T20:45:51Z, is not set as given.

With `resolveLink = False` the times of a symbolic link itself are changed, not those of the
entity it points to.

-}
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix, resolveLink : Bool } -> Path -> Task Error Path
changeTimes options path =
    kUtimes options.resolveLink
        (Time.posixToMillis options.lastAccessed // 1000)
        (Time.posixToMillis options.lastModified // 1000)
        (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Moves, or renames, the entity at the second path to the first.

    move newPath oldPath

The task succeeds with the new path. If it fails, [errorPath](#errorPath) is the new path. This
is the operating system's rename and nothing more, so a move to another file system fails
(`"EXDEV"`) rather than copying.

-}
move : Path -> Path -> Task Error Path
move newPath oldPath =
    kRename (Path.toPosixString oldPath) (Path.toPosixString newPath)
        |> withPath newPath
        |> Task.map (\_ -> newPath)


{-| Returns the path the operating system gives for the entity at the path, with every symbolic
link resolved. The entity must exist.
-}
realPath : Path -> Task Error Path
realPath path =
    kRealpath (Path.toPosixString path)
        |> withPath path
        |> Task.map Path.fromPosixString



-- FILES


{-| Copies the file at the second path to the first.

    copyFile destinationPath sourcePath

An existing file at the destination is overwritten, and the copy gets the source's mode. A
directory as the source fails with `"EISDIR"` before the destination is touched. The task
succeeds with the destination path, and if it fails, [errorPath](#errorPath) is the destination
path.

-}
copyFile : Path -> Path -> Task Error Path
copyFile destinationPath sourcePath =
    kCopyFile (Path.toPosixString sourcePath) (Path.toPosixString destinationPath)
        |> withPath destinationPath
        |> Task.map (\_ -> destinationPath)


{-| Adds the bytes to the end of the file at the path, creating the file if it does not exist.
-}
appendToFile : Bytes -> Path -> Task Error Path
appendToFile bytes path =
    kAppendFile bytes (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Reads the whole of the file at the path.

The contents are read into memory at once. For a very large file,
[readFileStream](#readFileStream) reads it in pieces instead.

-}
readFile : Path -> Task Error Bytes
readFile path =
    kReadFile (Path.toPosixString path)
        |> withPath path


{-| Which bytes of a file [readFileStream](#readFileStream) delivers. Offsets count bytes from the
beginning of the file.

`Beginning` delivers the whole file.

`From n` skips the first `n` bytes and delivers the rest. A negative `n` is 0, and an `n` past the
end gives a stream with nothing in it.

`Between` delivers the bytes from `start` to `end`, and `end` is **inclusive**:
`Between { start = 0, end = 9 }` delivers ten bytes, or fewer if the file is shorter. A negative
`start` is 0. A negative `end` delivers everything from `start` to the end of the file; otherwise
an `end` before `start` delivers nothing.

-}
type ReadFileStreamMode
    = Beginning
    | From Int
    | Between { start : Int, end : Int }


{-| Opens the file at the path and returns a stream of its bytes, the ones `mode` selects.

The file is opened before the task succeeds, so a file that cannot be opened, such as a missing
file or a directory (`"EISDIR"`), fails this task with an [Error](#Error). Failures while reading
arrive on the stream as a `Stream.Error`.

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


{-| Writes the bytes into the file at the path, creating the file if it does not exist and
replacing its contents if it does.

This is [writeFileWith](#writeFileWith) with [defaultWriteOptions](#defaultWriteOptions).

-}
writeFile : Bytes -> Path -> Task Error Path
writeFile bytes path =
    kWriteFile bytes (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Where the bytes written to a [writeFileStream](#writeFileStream) go in the file.

`Replace` empties the file, or creates it, and writes from the beginning.

`ReplaceFrom n` keeps the first `n` bytes and writes from there. A file shorter than `n` is
extended with zero bytes up to `n` once anything is written or the stream is closed. When the stream is closed, the file is cut off
where the writing ended, so whatever followed is gone; a cancelled stream is not cut off. For
`n > 0` the file must already exist, unless `createNew` (see [WriteOptions](#WriteOptions)) is set, which
requires that it does not and creates it.
`ReplaceFrom n` with `n <= 0` is `Replace`, and creates the file.

`Append` writes at the end of the file, creating it if it does not exist.

-}
type WriteFileStreamMode
    = Replace
    | ReplaceFrom Int
    | Append


{-| Opens the file at the path and returns a stream whose bytes are written into it, where `mode`
says. Close the stream when you are done writing to it.

The file is opened before the task succeeds, so a file that cannot be opened fails this task with
an [Error](#Error). Failures while writing arrive on the stream as a `Stream.Error`.

This is [writeFileStreamWith](#writeFileStreamWith) with
[defaultWriteOptions](#defaultWriteOptions).

-}
writeFileStream : WriteFileStreamMode -> Path -> Task Error (Stream.Writable Bytes)
writeFileStream =
    writeFileStreamWith defaultWriteOptions


{-| What [writeFileWith](#writeFileWith) and [writeFileStreamWith](#writeFileStreamWith) ask of a
write beyond what [writeFile](#writeFile) does.

`createNew` makes the write exclusive. The file is created, and the task fails with `"EEXIST"`
([errorIsFileExists](#errorIsFileExists)) if anything already exists at the path. The operating
system checks and creates in one step (`O_EXCL`), so of two programs creating the same file at
most one succeeds.

`sync` makes the write durable. The file's data is flushed to the storage device (`fsync`) before
the write succeeds; for [writeFileStreamWith](#writeFileStreamWith), before closing the stream
succeeds.

Neither replaces a file in one step. Without `createNew`, [writeFileWith](#writeFileWith) empties
an existing file before writing, so a failure part way leaves it empty or partly written. To
replace a file in one step, write a new file with `sync` and [move](#move) it over the old one.

-}
type alias WriteOptions =
    { createNew : Bool
    , sync : Bool
    }


{-| Write options with both `createNew` and `sync` off, which give the behaviour of
[writeFile](#writeFile) and [writeFileStream](#writeFileStream).
-}
defaultWriteOptions : WriteOptions
defaultWriteOptions =
    { createNew = False
    , sync = False
    }


{-| Writes the bytes into the file at the path, as [writeFile](#writeFile) does, with the
[WriteOptions](#WriteOptions) given.

    FileSystem.writeFileWith { defaultWriteOptions | createNew = True, sync = True } bytes path

With either option on, the file is opened (emptying an existing one, or failing with `"EEXIST"`
for `createNew`), written from the beginning, flushed for `sync`, and closed. If a step after the
open fails, closing the file is still attempted, and the first failure is the one reported.

-}
writeFileWith : WriteOptions -> Bytes -> Path -> Task Error Path
writeFileWith options bytes path =
    if not options.createNew && not options.sync then
        writeFile bytes path

    else
        kOpen
            (if options.createNew then
                "wx"

             else
                "w"
            )
            (Path.toPosixString path)
            |> Task.andThen
                (\fd ->
                    kWriteFromOffset fd 0 bytes
                        |> Task.andThen
                            (\_ ->
                                if options.sync then
                                    kFsync fd

                                else
                                    Task.succeed ()
                            )
                        |> Task.andThen (\_ -> kClose fd)
                        |> Task.onError (\err -> kClose fd |> Task.onError (\_ -> Task.succeed ()) |> Task.andThen (\_ -> Task.fail err))
                )
            |> withPath path
            |> Task.map (\_ -> path)


{-| Opens a stream into the file at the path, as [writeFileStream](#writeFileStream) does, with the
[WriteOptions](#WriteOptions) given.

With `sync`, closing the stream succeeds only once the data has been flushed to the storage
device, and a failed flush fails the close. A cancelled stream is not flushed.

-}
writeFileStreamWith : WriteOptions -> WriteFileStreamMode -> Path -> Task Error (Stream.Writable Bytes)
writeFileStreamWith options mode path =
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

        flags =
            kind
                + (if options.createNew then
                    4

                   else
                    0
                  )
                + (if options.sync then
                    8

                   else
                    0
                  )
    in
    kWriteFileStream flags position (Path.toPosixString path)
        |> withPath path
        |> Task.map Stream.Internal.Writable


{-| Sets the length of the file at the path, in bytes: a longer file loses the bytes past
`length`, and a shorter one is extended with zero bytes. The file must already exist.
-}
truncateFile : Int -> Path -> Task Error Path
truncateFile length path =
    kTruncate length (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Removes the entity at the path.

A symbolic link is removed itself, not the entity it points to. A directory is removed only with
`recursive = True`, and then together with everything in it. With `recursive = False` it fails
with the code `"ERR_FS_EISDIR"`, for which [errorIsDirectoryFound](#errorIsDirectoryFound) is
`False`.

-}
remove : { recursive : Bool } -> Path -> Task Error Path
remove options path =
    kRemove options.recursive (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)



-- DIRECTORIES


{-| Returns the entries of the directory at the path, without `.` and `..`, sorted by name byte by
byte (as UTF-8).

Each `path` is the entry's name alone, relative to the listed directory, parsed with
[Path.fromPosixString](Path#fromPosixString). A name that parsing changes, such as `a.`, which
comes back as `a`, therefore does not name its entry once appended to the directory's path.

Each `entityType` is that of the entry itself: a symbolic link is `Symlink`, not followed.

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


{-| Creates a directory at the path.

With `recursive = False` the parent directory must exist, and the task fails with `"EEXIST"` if
something is already at the path. With `recursive = True` every missing directory on the path is
created too, and a directory already at the path is not an error.

-}
makeDirectory : { recursive : Bool } -> Path -> Task Error Path
makeDirectory options path =
    kMakeDirectory options.recursive (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)


{-| Creates a new directory in [tempDirectory](#tempDirectory), named `prefix` followed by six
random characters, and succeeds with its path. Each call creates a different directory.

If it fails, [errorPath](#errorPath) is [tempDirectory](#tempDirectory) with `prefix` appended,
without the random characters.

-}
makeTempDirectory : String -> Task Error Path
makeTempDirectory prefix =
    tempDirectory
        |> Task.andThen
            (\tmp ->
                kMakeTempDirectory prefix
                    |> withPath (Path.appendPosixString prefix tmp)
                    |> Task.map Path.fromPosixString
            )



-- LINKS


{-| Creates a hard link at the first path to the file at the second.

    hardLink linkPath targetPath

A hard link is a second name for the same file, and neither name is the original. The task
succeeds with the link path, and if it fails, [errorPath](#errorPath) is the link path.

-}
hardLink : Path -> Path -> Task Error Path
hardLink linkPath targetPath =
    kLink (Path.toPosixString targetPath) (Path.toPosixString linkPath)
        |> withPath linkPath
        |> Task.map (\_ -> linkPath)


{-| Creates a soft link at the first path that points to the second.

    softLink linkPath targetPath

A soft link, also called a symbolic link, is a special file holding the path of another
location, which is followed when the link is resolved. The target is stored as the text
[Path.toPosixString](Path#toPosixString) prints and is not checked, so it need not exist. The
task succeeds with the link path, and if it fails, [errorPath](#errorPath) is the link path.

-}
softLink : Path -> Path -> Task Error Path
softLink linkPath targetPath =
    kSymlink (Path.toPosixString targetPath) (Path.toPosixString linkPath)
        |> withPath linkPath
        |> Task.map (\_ -> linkPath)


{-| Returns the path stored in the soft link at the path.

The stored text is parsed with [Path.fromPosixString](Path#fromPosixString), so the result may
not print back as the stored text. It is not resolved against the link's directory.

-}
readLink : Path -> Task Error Path
readLink path =
    kReadLink (Path.toPosixString path)
        |> withPath path
        |> Task.map Path.fromPosixString


{-| Removes the name at the path, which may name anything but a directory. A soft link is removed
itself, not the entity it points to; [remove](#remove) removes a directory.
-}
unlink : Path -> Task Error Path
unlink path =
    kUnlink (Path.toPosixString path)
        |> withPath path
        |> Task.map (\_ -> path)



-- WATCH


{-| A change seen by [watch](#watch) or [watchRecursive](#watchRecursive).

`Changed` means an entity's contents or attributes changed, such as a write to a file or a change
of its permissions.

`Moved` means an entity was created, deleted or renamed. A rename is usually two `Moved` events,
one for the old name and one for the new. On the JS backend under Linux, a change to a
directory's attributes is also reported as `Moved`.

An event about another entity carries that entity's path, relative to the watched path (on the JS
backend, when Node.js reports one). An event about the watched path itself carries `Nothing` on
the native backend; on the JS backend it can carry the watched entry's own name instead, so a
change to a watched file `f.txt` carries the path `f.txt`.

-}
type WatchEvent
    = Changed (Maybe Path)
    | Moved (Maybe Path)


{-| Creates a subscription to the changes at the path: to the entity itself and, for a
directory, to its entries, but not to anything inside its subdirectories.

A path that cannot be watched, such as one that does not exist, gives no events and no error.
Subscriptions to the same path with the same recursiveness share one watcher, and each event
goes to all of them.

-}
watch : (WatchEvent -> msg) -> Path -> Sub msg
watch toMsg path =
    subscription (Watch (Path.toPosixString path) False (watchTagger toMsg))


{-| Creates a subscription like [watch](#watch), which also reports changes anywhere inside the
directory's subdirectories.
-}
watchRecursive : (WatchEvent -> msg) -> Path -> Sub msg
watchRecursive toMsg path =
    subscription (Watch (Path.toPosixString path) True (watchTagger toMsg))



-- SPECIAL PATHS


{-| The home directory of the current user.

It is `$HOME` when that is set and not empty, otherwise the home directory recorded for the user
in the system's user database (natively on Windows, `%USERPROFILE%`), and
[Path.empty](Path#empty) when there is none.

-}
homeDirectory : Task x Path
homeDirectory =
    kHomeDirectory
        |> Task.map Path.fromPosixString
        |> Task.mapError never


{-| The program's current working directory, which the operating system resolves relative paths
against. It is [Path.empty](Path#empty) if the directory cannot be read.
-}
currentWorkingDirectory : Task x Path
currentWorkingDirectory =
    kCurrentWorkingDirectory
        |> Task.map Path.fromPosixString
        |> Task.mapError never


{-| The directory meant for temporary files.

It is the first of the `TMPDIR`, `TMP` and `TEMP` environment variables that is set and not
empty, and otherwise `/tmp` (`C:/Windows/Temp` on Windows).

-}
tempDirectory : Task x Path
tempDirectory =
    kTmpDirectory
        |> Task.map Path.fromPosixString
        |> Task.mapError never


{-| The path of the null device, `/dev/null`, which reads as empty and discards whatever is
written to it.

On Windows the kernels report `//./nul`, which [Path.fromPosixString](Path#fromPosixString)
parses into `/nul`, a path that does not name the null device.

-}
devNull : Task x Path
devNull =
    kDevNull
        |> Task.map Path.fromPosixString
        |> Task.mapError never



-- HELPERS


{-| Turns a kernel's `( code, message )` failure into an [Error](#Error) about `path`.
-}
withPath : Path -> Task ( String, String ) a -> Task Error a
withPath path task =
    Task.mapError (FileSystem.Internal.decodeError path) task


{-| Returns the entity type for a kernel's entity code: 0 to 4 are `File`, `Directory`, `Socket`,
`Symlink` and `Device`, and every other code, including the kernels' 5 for a pipe, is `Pipe`.
`FileSystem.Handle` has its own copy, because this one is not exposed.
-}
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


{-| Returns the numeric mode `chmod` is given for the three permission lists: one octal digit
each, owner, then group, then everyone else, so the mode written `644` is 420.
-}
modeFromPermissions : { owner : List AccessPermission, group : List AccessPermission, others : List AccessPermission } -> Int
modeFromPermissions permissions =
    accessPermissionsToInt permissions.owner
        * 64
        + accessPermissionsToInt permissions.group
        * 8
        + accessPermissionsToInt permissions.others


{-| Builds the tagger for a kernel watch event `( kind, relativePath )`: kind 1 is `Moved` and any
other kind `Changed`, and the relative path is parsed with `Path.fromPosixString`.
-}
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
-- The native backend runs the C++ manager registered as "FileSystem"
-- (src/eco-system/FileSystem/FileSystemManager.{hpp,cpp}) and ignores the manager functions
-- below; the JS backend runs them. One watcher exists per (path, recursive) key: a
-- never-completing kernel listener spawned when the key first appears and killed when its
-- last subscription goes away. It notifies the manager through `Platform.sendToSelf`, which
-- hands the event to every tagger of that key. The constructor layout of MySub is mirrored
-- by FileSystemManager.hpp: keep them in sync.


{-| The manager's one subscription: `Watch` carries the watched path as POSIX text, whether the
watch is recursive, and the tagger for the kernel's `( kind, relativePath )` events. The native
manager reads these three fields by position.
-}
type MySub msg
    = Watch String Bool (( Int, Maybe String ) -> msg)


{-| Applies `f` to every message the subscription produces.
-}
subMap : (a -> b) -> MySub a -> MySub b
subMap f (Watch path recursive tagger) =
    Watch path recursive (\event -> f (tagger event))


{-| The JS manager's state: the running watchers, by the key `watchKey` builds.
-}
type alias State msg =
    Dict String (Watcher msg)


{-| One running watch: the taggers of its key's subscriptions, in subscription order, and the
process running its kernel listener.
-}
type alias Watcher msg =
    { taggers : List (( Int, Maybe String ) -> msg)
    , listener : Process.Id
    }


{-| One key's wanted watch, gathered from the current subscriptions: the path, whether it is
recursive, and the taggers in subscription order.
-}
type alias WatchSpec msg =
    { path : String
    , recursive : Bool
    , taggers : List (( Int, Maybe String ) -> msg)
    }


{-| A message from a listener to the manager: `Notify` carries the key of the watch that saw an
event and the kernel's `( kind, relativePath )` for it.
-}
type Event
    = Notify String ( Int, Maybe String )


{-| Returns the comparable key for a watch of `path`: the path text after `"R"` for a recursive
watch or `"N"` otherwise, so the two kinds of watch of one path have different keys.
-}
watchKey : String -> Bool -> String
watchKey path recursive =
    if recursive then
        "R" ++ path

    else
        "N" ++ path


{-| The manager's starting state, with no watchers.
-}
init : Task Never (State msg)
init =
    Task.succeed Dict.empty


{-| Brings the watchers in line with the current subscriptions and returns the new state.

The listener of every key no longer subscribed is killed, which closes its watch. A key that
already has a watcher keeps it and takes the current taggers. A new key gets a listener process
spawned for it.

-}
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

        -- The subscriptions arrive in reverse order; reversing keeps taggers in subscription order.
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


{-| Sends one message to the program for each tagger of the event's key, in subscription order.
An event for a key that no longer has a watcher is dropped.
-}
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
-- The annotations fix the kernel ABI: the C++ and JS kernels take and return exactly these
-- shapes. Paths sent to a kernel are POSIX text, and a failure is a ( code, message ) pair.


{-| Asks for the 11-integer status list of the entity at the POSIX path, following a symbolic link
when the `Bool` is `True`; `FileSystem.Internal.decodeMetadata` reads it.
-}
kStat : Bool -> String -> Task ( String, String ) (List Int)
kStat =
    Eco.Kernel.FileSystem.stat


{-| Checks access to the entity at the path, for the permission bits in the `Int` (4 read, 2
write, 1 execute; 0 only checks that it exists).
-}
kAccess : Int -> String -> Task ( String, String ) ()
kAccess =
    Eco.Kernel.FileSystem.access


{-| Sets the mode of the entity at the path to the `Int`.
-}
kChmod : Int -> String -> Task ( String, String ) ()
kChmod =
    Eco.Kernel.FileSystem.chmod


{-| Sets the owner of the entity at the path to the user id and group id, following a symbolic
link when the `Bool` is `True`.
-}
kChown : Bool -> Int -> Int -> String -> Task ( String, String ) ()
kChown =
    Eco.Kernel.FileSystem.chown


{-| Sets the access and modification times, in whole seconds, of the entity at the path, following
a symbolic link when the `Bool` is `True`.
-}
kUtimes : Bool -> Int -> Int -> String -> Task ( String, String ) ()
kUtimes =
    Eco.Kernel.FileSystem.utimes


{-| Renames the entity at the first path to the second; a failure names the second.
-}
kRename : String -> String -> Task ( String, String ) ()
kRename =
    Eco.Kernel.FileSystem.rename


{-| Asks for the resolved path of the entity at the path.
-}
kRealpath : String -> Task ( String, String ) String
kRealpath =
    Eco.Kernel.FileSystem.realpath


{-| Copies the file at the first path to the second; a failure names the second.
-}
kCopyFile : String -> String -> Task ( String, String ) ()
kCopyFile =
    Eco.Kernel.FileSystem.copyFile


{-| Appends the bytes to the file at the path, creating it if needed.
-}
kAppendFile : Bytes -> String -> Task ( String, String ) ()
kAppendFile =
    Eco.Kernel.FileSystem.appendFile


{-| Reads the whole file at the path.
-}
kReadFile : String -> Task ( String, String ) Bytes
kReadFile =
    Eco.Kernel.FileSystem.readFile


{-| Writes the bytes as the whole contents of the file at the path, creating it if needed.
-}
kWriteFile : Bytes -> String -> Task ( String, String ) ()
kWriteFile =
    Eco.Kernel.FileSystem.writeFile


{-| Sets the length in bytes of the file at the path.
-}
kTruncate : Int -> String -> Task ( String, String ) ()
kTruncate =
    Eco.Kernel.FileSystem.truncate


{-| Removes the entity at the path, a directory and its contents only when the `Bool` is `True`.
-}
kRemove : Bool -> String -> Task ( String, String ) ()
kRemove =
    Eco.Kernel.FileSystem.remove


{-| Asks for the entries of the directory at the path, as `( name, entity code )` pairs sorted by
name.
-}
kListDirectory : String -> Task ( String, String ) (List ( String, Int ))
kListDirectory =
    Eco.Kernel.FileSystem.listDirectory


{-| Creates a directory at the path, and any missing directories above it when the `Bool` is
`True`.
-}
kMakeDirectory : Bool -> String -> Task ( String, String ) ()
kMakeDirectory =
    Eco.Kernel.FileSystem.makeDirectory


{-| Creates a directory in the temporary directory, named the prefix followed by random
characters, and returns its path.
-}
kMakeTempDirectory : String -> Task ( String, String ) String
kMakeTempDirectory =
    Eco.Kernel.FileSystem.makeTempDirectory


{-| Creates a hard link at the second path to the file at the first; a failure names the second.
-}
kLink : String -> String -> Task ( String, String ) ()
kLink =
    Eco.Kernel.FileSystem.link


{-| Creates a soft link at the second path holding the first; a failure names the second.
-}
kSymlink : String -> String -> Task ( String, String ) ()
kSymlink =
    Eco.Kernel.FileSystem.symlink


{-| Asks for the text stored in the soft link at the path.
-}
kReadLink : String -> Task ( String, String ) String
kReadLink =
    Eco.Kernel.FileSystem.readLink


{-| Removes the name at the path.
-}
kUnlink : String -> Task ( String, String ) ()
kUnlink =
    Eco.Kernel.FileSystem.unlink


{-| Opens the file at the path and returns the id of a readable stream over it, from the first
`Int` (a byte offset) to the second (an inclusive end offset, or a negative number for the end of
the file).
-}
kReadFileStream : Int -> Int -> String -> Task ( String, String ) Int
kReadFileStream =
    Eco.Kernel.FileSystem.readFileStream


{-| Opens the file at the path with the open mode given first (`"w"` or `"wx"` here) and returns
its file descriptor, registered as an open handle.
-}
kOpen : String -> String -> Task ( String, String ) Int
kOpen =
    Eco.Kernel.FileSystem.open


{-| Closes an open file descriptor.
-}
kClose : Int -> Task ( String, String ) ()
kClose =
    Eco.Kernel.FileSystem.close


{-| Writes the bytes to an open file descriptor at the byte offset.
-}
kWriteFromOffset : Int -> Int -> Bytes -> Task ( String, String ) ()
kWriteFromOffset =
    Eco.Kernel.FileSystem.writeFromOffset


{-| Flushes an open file descriptor's data to the storage device.
-}
kFsync : Int -> Task ( String, String ) ()
kFsync =
    Eco.Kernel.FileSystem.fsync


{-| Opens the file at the path and returns the id of a writable stream into it. The first `Int`
holds the mode in bits 0 and 1 (0 `Replace`, 1 `ReplaceFrom`, 2 `Append`), `createNew` in bit 2
and `sync` in bit 3; the second is the `ReplaceFrom` offset.
-}
kWriteFileStream : Int -> Int -> String -> Task ( String, String ) Int
kWriteFileStream =
    Eco.Kernel.FileSystem.writeFileStream


{-| The home directory, as the text the kernel finds for it.
-}
kHomeDirectory : Task Never String
kHomeDirectory =
    Eco.Kernel.FileSystem.homeDirectory


{-| The current working directory, as the operating system reports it.
-}
kCurrentWorkingDirectory : Task Never String
kCurrentWorkingDirectory =
    Eco.Kernel.FileSystem.currentWorkingDirectory


{-| The temporary directory, as the text the kernel chooses.
-}
kTmpDirectory : Task Never String
kTmpDirectory =
    Eco.Kernel.FileSystem.tmpDirectory


{-| The null device's path as POSIX text.
-}
kDevNull : Task Never String
kDevNull =
    Eco.Kernel.FileSystem.devNull


{-| Watches the path, recursively when the `Bool` is `True`, and runs the callback's task for
every event; the task never completes, and killing its process ends the watch. Only the JS manager
above uses it; the native backend has no such kernel.
-}
kAttachWatchListener : String -> Bool -> (( Int, Maybe String ) -> Task Never ()) -> Task Never ()
kAttachWatchListener =
    Eco.Kernel.FileSystem.attachWatchListener
