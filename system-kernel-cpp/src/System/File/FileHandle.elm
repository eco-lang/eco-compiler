module System.File.FileHandle exposing
    ( FileHandle, ReadableFileHandle, WriteableFileHandle, ReadWriteableFileHandle, ReadAccess, WriteAccess, makeReadOnly, makeWriteOnly
    , openForRead, OpenForWriteBehaviour(..), openForWrite, openForReadAndWrite, close
    , metadata, changeAccess, changeOwner, changeTimes
    , read, readFromOffset
    , write, writeFromOffset, truncate, sync, syncData
    )

{-| This module provides access to files through file handles. A [FileHandle](#FileHandle)
represents an open file. If you know you're going to perform repeated operations on a file, it
will be more efficient through a [FileHandle](#FileHandle).

The error type is the [Error](System-File#Error) from [System.File](System-File), but
[errorPath](System-File#errorPath) will always return an empty path.

Compared with gren-node's file handle module, the phantom types are named
[ReadAccess](#ReadAccess) and [WriteAccess](#WriteAccess) (gren: `ReadPermission` and
`WritePermission`), and opening a file needs no permission value.

@docs FileHandle, ReadableFileHandle, WriteableFileHandle, ReadWriteableFileHandle, ReadAccess, WriteAccess, makeReadOnly, makeWriteOnly


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
import System.File as File
import System.File.Path exposing (Path)
import Task exposing (Task)
import Time


{-| A file handle is used to perform operations on a file, like reading and writing.

Having a file handle gives you access to perform certain operations, so make sure you
only pass a file handle to code you can trust.

The [FileHandle](#FileHandle) type also records whether the file may be read and written as
part of its type, using [ReadAccess](#ReadAccess) and [WriteAccess](#WriteAccess).

-}
type FileHandle readAccess writeAccess
    = FileHandle Int


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


{-| An alias for a [FileHandle](#FileHandle) that can be used in read operations.
-}
type alias ReadableFileHandle a =
    FileHandle ReadAccess a


{-| An alias for a [FileHandle](#FileHandle) that can be used in write operations.
-}
type alias WriteableFileHandle a =
    FileHandle a WriteAccess


{-| An alias for a [FileHandle](#FileHandle) that can be used for both read and write operations.
-}
type alias ReadWriteableFileHandle =
    FileHandle ReadAccess WriteAccess


{-| This lets you downgrade a [ReadWriteableFileHandle](#ReadWriteableFileHandle) to a
[FileHandle](#FileHandle) that only has read access.

Comes in handy when you want full access to a file in some parts of your code, but limited access
in other parts of your code.

-}
makeReadOnly : ReadWriteableFileHandle -> FileHandle ReadAccess Never
makeReadOnly handle =
    Debug.todo "Implement System API"


{-| This lets you downgrade a [ReadWriteableFileHandle](#ReadWriteableFileHandle) to a
[FileHandle](#FileHandle) that only has write access.

Comes in handy when you want full access to a file in some parts of your code, but limited access
in other parts of your code.

-}
makeWriteOnly : ReadWriteableFileHandle -> FileHandle Never WriteAccess
makeWriteOnly handle =
    Debug.todo "Implement System API"



-- OPEN


{-| Open the file at the provided path with read access. The task fails if the file doesn't exist.
-}
openForRead : Path -> Task File.Error (FileHandle ReadAccess Never)
openForRead path =
    Debug.todo "Implement System API"


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
openForWrite : OpenForWriteBehaviour -> Path -> Task File.Error (FileHandle Never WriteAccess)
openForWrite behaviour path =
    Debug.todo "Implement System API"


{-| Open a file at the provided path with both read and write access.
-}
openForReadAndWrite : OpenForWriteBehaviour -> Path -> Task File.Error ReadWriteableFileHandle
openForReadAndWrite behaviour path =
    Debug.todo "Implement System API"


{-| Close a file. All later operations performed against the given [FileHandle](#FileHandle)
will fail.
-}
close : FileHandle a b -> Task File.Error ()
close handle =
    Debug.todo "Implement System API"



-- METADATA


{-| Retrieve [Metadata](System-File#Metadata) about the file represented by the
[FileHandle](#FileHandle).

**Deviation from gren-node:** the task succeeds with the `Metadata` itself; gren-node's
annotation wrapped it in a file handle type by mistake.

-}
metadata : ReadableFileHandle a -> Task File.Error File.Metadata
metadata handle =
    Debug.todo "Implement System API"


{-| Change how different users can access a file. Each list becomes one octal digit of the
file mode, as in [System.File.changeAccess](System-File#changeAccess).
-}
changeAccess :
    { owner : List File.AccessPermission, group : List File.AccessPermission, others : List File.AccessPermission }
    -> WriteableFileHandle a
    -> Task File.Error (WriteableFileHandle a)
changeAccess permissions handle =
    Debug.todo "Implement System API"


{-| Change who owns the file. You'll need the ID of the new user and group who will own the file.
-}
changeOwner : { userID : Int, groupID : Int } -> WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
changeOwner ids handle =
    Debug.todo "Implement System API"


{-| This will let you set the timestamp for when the file was last accessed, and last modified.
The times will be rounded down to the closest second.
-}
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix } -> WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
changeTimes times handle =
    Debug.todo "Implement System API"



-- READING


{-| Read all bytes in a file.
-}
read : ReadableFileHandle a -> Task File.Error Bytes
read handle =
    Debug.todo "Implement System API"


{-| Read `length` number of bytes from a file, starting at `offset` bytes.

A negative `length` reads everything from `offset` to the end of the file. Fewer bytes than asked
for are returned if the end of the file is reached first.

-}
readFromOffset : ReadableFileHandle a -> { offset : Int, length : Int } -> Task File.Error Bytes
readFromOffset handle options =
    Debug.todo "Implement System API"



-- WRITING


{-| Write the provided bytes into the file, starting at the beginning of the file (offset 0).
If the file is not empty, existing bytes will be overwritten. Use
[writeFromOffset](#writeFromOffset) to write somewhere else.
-}
write : WriteableFileHandle a -> Bytes -> Task File.Error (WriteableFileHandle a)
write handle bytes =
    Debug.todo "Implement System API"


{-| Write bytes into a specific location of a file, given as a byte offset from the beginning
of the file.
-}
writeFromOffset : WriteableFileHandle a -> Int -> Bytes -> Task File.Error (WriteableFileHandle a)
writeFromOffset handle offset bytes =
    Debug.todo "Implement System API"


{-| Make sure that a file is of the given size. If the file is larger than the given size, excess
bytes are discarded. If the file is smaller than the given size, zeroes will be added until it is
of the given size.
-}
truncate : Int -> WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
truncate length handle =
    Debug.todo "Implement System API"


{-| Usually when you make changes to a file, the changes aren't actually written to disk right
away. The changes are likely placed in an OS-level buffer, and flushed to disk when the OS decides
it's time to do so.

This task, when executed, will force changes to be written to disk.

-}
sync : WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
sync handle =
    Debug.todo "Implement System API"


{-| Same as [sync](#sync), except it only forces the contents of the file to be written. Changes
to a file's metadata are not synced. This operation might be a little faster than a full sync, at
the risk of losing changes to metadata.
-}
syncData : WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
syncData handle =
    Debug.todo "Implement System API"
