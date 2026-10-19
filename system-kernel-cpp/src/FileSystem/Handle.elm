module FileSystem.Handle exposing
    ( Handle, ReadableHandle, WriteableHandle, ReadWriteableHandle, ReadAccess, WriteAccess, makeReadOnly, makeWriteOnly
    , openForRead, OpenForWriteBehaviour(..), openForWrite, openForReadAndWrite, close
    , metadata, changeAccess, changeOwner, changeTimes
    , read, readFromOffset
    , write, writeFromOffset, truncate, sync, syncData
    )

{-| This module provides access to files through file handles. A [Handle](#Handle)
represents an open file. If you know you're going to perform repeated operations on a file, it
will be more efficient through a [Handle](#Handle).

The error type is the [Error](FileSystem#Error) from [FileSystem](FileSystem). For operations
on an open [Handle](#Handle), [errorPath](FileSystem#errorPath) returns the empty path;
only a failure to open a file reports the path that was being opened.

Handles have no file position. [read](#read) reads the whole file and [write](#write) writes
at offset 0, so two `write` calls overwrite each other rather than appending; every other read
and write names its offset. For sequential IO, use
[FileSystem.readFileStream](FileSystem#readFileStream) and
[FileSystem.writeFileStream](FileSystem#writeFileStream) instead.

Most programs don't need handles: [FileSystem.writeFileWith](FileSystem#writeFileWith) covers
durable writes and exclusive create. Handles are for random access on one open file, and for
operations that must apply to the file you opened even if its path is renamed or replaced.

Compared with gren-node's file handle module, the type is called [Handle](#Handle) (gren:
`FileHandle`), the phantom types are named
[ReadAccess](#ReadAccess) and [WriteAccess](#WriteAccess) (gren: `ReadPermission` and
`WritePermission`), and opening a file needs no permission value.

@docs Handle, ReadableHandle, WriteableHandle, ReadWriteableHandle, ReadAccess, WriteAccess, makeReadOnly, makeWriteOnly


## File open/close

@docs openForRead, OpenForWriteBehaviour, openForWrite, openForReadAndWrite, close


## File metadata

@docs metadata, changeAccess, changeOwner, changeTimes


## Read from file

@docs read, readFromOffset


## Write to file

@docs write, writeFromOffset, truncate, sync, syncData

-}

import Bytes exposing (Bytes)
import Eco.Kernel.FileSystem
import FileSystem
import FileSystem.Internal
import Path exposing (Path)
import Task exposing (Task)
import Time


{-| A file handle is used to perform operations on a file, like reading and writing.

Having a file handle gives you access to perform certain operations, so make sure you
only pass a file handle to code you can trust.

The [Handle](#Handle) type also records whether the file may be read and written as
part of its type, using [ReadAccess](#ReadAccess) and [WriteAccess](#WriteAccess).

-}
type Handle readAccess writeAccess
    = Handle Int


{-| A type that represents the right to read from a file.

Named `ReadPermission` in gren-node.

-}
type ReadAccess
    = ReadAccess


{-| A type that represents the right to write to a file.

Named `WritePermission` in gren-node.

-}
type WriteAccess
    = WriteAccess


{-| An alias for a [Handle](#Handle) that can be used in read operations.
-}
type alias ReadableHandle a =
    Handle ReadAccess a


{-| An alias for a [Handle](#Handle) that can be used in write operations.
-}
type alias WriteableHandle a =
    Handle a WriteAccess


{-| An alias for a [Handle](#Handle) that can be used for both read and write operations.
-}
type alias ReadWriteableHandle =
    Handle ReadAccess WriteAccess


{-| This lets you downgrade a [ReadWriteableHandle](#ReadWriteableHandle) to a
[Handle](#Handle) that only has read access.

Comes in handy when you want full access to a file in some parts of your code, but limited access
in other parts of your code.

-}
makeReadOnly : ReadWriteableHandle -> Handle ReadAccess Never
makeReadOnly handle =
    let
        (Handle fd) =
            handle
    in
    Handle fd


{-| This lets you downgrade a [ReadWriteableHandle](#ReadWriteableHandle) to a
[Handle](#Handle) that only has write access.

Comes in handy when you want full access to a file in some parts of your code, but limited access
in other parts of your code.

-}
makeWriteOnly : ReadWriteableHandle -> Handle Never WriteAccess
makeWriteOnly handle =
    let
        (Handle fd) =
            handle
    in
    Handle fd



-- OPEN


{-| Open the file at the provided path with read access. The task fails if the file doesn't exist.
-}
openForRead : Path -> Task FileSystem.Error (Handle ReadAccess Never)
openForRead path =
    openImpl "r" path


{-| There are several ways to open a file for writing.

  - `EnsureEmpty` will create an empty file if it doesn't exist, or remove all contents of a file
    if it does exist.
  - `ExpectExisting` will fail the task if the file doesn't exist.
  - `ExpectNotExisting` will fail the task if the file does exist.

-}
type OpenForWriteBehaviour
    = EnsureEmpty
    | ExpectExisting
    | ExpectNotExisting


{-| Open a file at the provided path with write access.
-}
openForWrite : OpenForWriteBehaviour -> Path -> Task FileSystem.Error (Handle Never WriteAccess)
openForWrite behaviour path =
    let
        access =
            case behaviour of
                EnsureEmpty ->
                    "w"

                ExpectExisting ->
                    "r+"

                ExpectNotExisting ->
                    "wx"
    in
    openImpl access path


{-| Open a file at the provided path with both read and write access.
-}
openForReadAndWrite : OpenForWriteBehaviour -> Path -> Task FileSystem.Error ReadWriteableHandle
openForReadAndWrite behaviour path =
    let
        access =
            case behaviour of
                EnsureEmpty ->
                    "w+"

                ExpectExisting ->
                    "r+"

                ExpectNotExisting ->
                    "wx+"
    in
    openImpl access path


{-| Close a file. All later operations performed against the given [Handle](#Handle)
will fail.
-}
close : Handle a b -> Task FileSystem.Error ()
close handle =
    kClose (fdOf handle)
        |> handleError



-- METADATA


{-| Retrieve [Metadata](FileSystem#Metadata) about the file represented by the
[Handle](#Handle).

**Deviation from gren-node:** the task succeeds with the `Metadata` itself; gren-node's
annotation wrapped it in a file handle type by mistake.

-}
metadata : ReadableHandle a -> Task FileSystem.Error FileSystem.Metadata
metadata handle =
    kFstat (fdOf handle)
        |> Task.map (FileSystem.Internal.decodeMetadata entityFromInt)
        |> handleError


{-| Change how different users can access a file. Each list becomes one octal digit of the
file mode, as in [FileSystem.changeAccess](FileSystem#changeAccess).
-}
changeAccess :
    { owner : List FileSystem.AccessPermission, group : List FileSystem.AccessPermission, others : List FileSystem.AccessPermission }
    -> WriteableHandle a
    -> Task FileSystem.Error (WriteableHandle a)
changeAccess permissions handle =
    kFchmod (fdOf handle)
        (FileSystem.accessPermissionsToInt permissions.owner
            * 64
            + FileSystem.accessPermissionsToInt permissions.group
            * 8
            + FileSystem.accessPermissionsToInt permissions.others
        )
        |> handleError
        |> Task.map (\_ -> handle)


{-| Change who owns the file. You'll need the ID of the new user and group who will own the file.
-}
changeOwner : { userID : Int, groupID : Int } -> WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
changeOwner ids handle =
    kFchown (fdOf handle) ids.userID ids.groupID
        |> handleError
        |> Task.map (\_ -> handle)


{-| This will let you set the timestamp for when the file was last accessed, and last modified.
The times will be rounded down to the closest second.
-}
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix } -> WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
changeTimes times handle =
    kFutimes (fdOf handle)
        (Time.posixToMillis times.lastAccessed // 1000)
        (Time.posixToMillis times.lastModified // 1000)
        |> handleError
        |> Task.map (\_ -> handle)



-- READING


{-| Read all bytes in a file.
-}
read : ReadableHandle a -> Task FileSystem.Error Bytes
read handle =
    readFromOffset handle { offset = 0, length = -1 }


{-| Read `length` number of bytes from a file, starting at `offset` bytes.

A negative `length` reads everything from `offset` to the end of the file. Fewer bytes than asked
for are returned if the end of the file is reached first.

-}
readFromOffset : ReadableHandle a -> { offset : Int, length : Int } -> Task FileSystem.Error Bytes
readFromOffset handle options =
    kReadFromOffset (fdOf handle) options.offset options.length
        |> handleError



-- WRITING


{-| Write the provided bytes into the file, starting at the beginning of the file (offset 0).
If the file is not empty, existing bytes will be overwritten. Use
[writeFromOffset](#writeFromOffset) to write somewhere else.
-}
write : WriteableHandle a -> Bytes -> Task FileSystem.Error (WriteableHandle a)
write handle bytes =
    writeFromOffset handle 0 bytes


{-| Write bytes into a specific location of a file, given as a byte offset from the beginning
of the file.
-}
writeFromOffset : WriteableHandle a -> Int -> Bytes -> Task FileSystem.Error (WriteableHandle a)
writeFromOffset handle offset bytes =
    kWriteFromOffset (fdOf handle) offset bytes
        |> handleError
        |> Task.map (\_ -> handle)


{-| Make sure that a file is of the given size. If the file is larger than the given size, excess
bytes are discarded. If the file is smaller than the given size, zeroes will be added until it is
of the given size.
-}
truncate : Int -> WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
truncate length handle =
    kFtruncate (fdOf handle) length
        |> handleError
        |> Task.map (\_ -> handle)


{-| Usually when you make changes to a file, the changes aren't actually written to disk right
away. The changes are likely placed in an OS-level buffer, and flushed to disk when the OS decides
it's time to do so.

This task, when executed, will force changes to be written to disk.

-}
sync : WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
sync handle =
    kFsync (fdOf handle)
        |> handleError
        |> Task.map (\_ -> handle)


{-| Same as [sync](#sync), except it only forces the contents of the file to be written. Changes
to a file's metadata are not synced. This operation might be a little faster than a full sync, at
the risk of losing changes to metadata.
-}
syncData : WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
syncData handle =
    kFdatasync (fdOf handle)
        |> handleError
        |> Task.map (\_ -> handle)



-- HELPERS


openImpl : String -> Path -> Task FileSystem.Error (Handle a b)
openImpl access path =
    kOpen access (Path.toPosixString path)
        |> Task.mapError (FileSystem.Internal.decodeError path)
        |> Task.map Handle


fdOf : Handle a b -> Int
fdOf (Handle fd) =
    fd


{-| Errors of operations on an open handle carry the empty path (see the module docs).
-}
handleError : Task ( String, String ) a -> Task FileSystem.Error a
handleError task =
    Task.mapError (FileSystem.Internal.decodeError Path.empty) task


{-| Private duplicate of the one in `FileSystem` (plans/eco-system-library.md Phase 4 step 4.2).
-}
entityFromInt : Int -> FileSystem.EntityType
entityFromInt n =
    case n of
        0 ->
            FileSystem.File

        1 ->
            FileSystem.Directory

        2 ->
            FileSystem.Socket

        3 ->
            FileSystem.Symlink

        4 ->
            FileSystem.Device

        _ ->
            FileSystem.Pipe



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.3).


kOpen : String -> String -> Task ( String, String ) Int
kOpen =
    Eco.Kernel.FileSystem.open


kClose : Int -> Task ( String, String ) ()
kClose =
    Eco.Kernel.FileSystem.close


kFstat : Int -> Task ( String, String ) (List Int)
kFstat =
    Eco.Kernel.FileSystem.fstat


kFchmod : Int -> Int -> Task ( String, String ) ()
kFchmod =
    Eco.Kernel.FileSystem.fchmod


kFchown : Int -> Int -> Int -> Task ( String, String ) ()
kFchown =
    Eco.Kernel.FileSystem.fchown


kFutimes : Int -> Int -> Int -> Task ( String, String ) ()
kFutimes =
    Eco.Kernel.FileSystem.futimes


kReadFromOffset : Int -> Int -> Int -> Task ( String, String ) Bytes
kReadFromOffset =
    Eco.Kernel.FileSystem.readFromOffset


kWriteFromOffset : Int -> Int -> Bytes -> Task ( String, String ) ()
kWriteFromOffset =
    Eco.Kernel.FileSystem.writeFromOffset


kFtruncate : Int -> Int -> Task ( String, String ) ()
kFtruncate =
    Eco.Kernel.FileSystem.ftruncate


kFsync : Int -> Task ( String, String ) ()
kFsync =
    Eco.Kernel.FileSystem.fsync


kFdatasync : Int -> Task ( String, String ) ()
kFdatasync =
    Eco.Kernel.FileSystem.fdatasync
