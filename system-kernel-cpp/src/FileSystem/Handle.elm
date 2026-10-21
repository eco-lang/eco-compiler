module FileSystem.Handle exposing
    ( Handle, ReadableHandle, WriteableHandle, ReadWriteableHandle, ReadAccess, WriteAccess, makeReadOnly, makeWriteOnly
    , openForRead, OpenForWriteBehaviour(..), openForWrite, openForReadAndWrite, close
    , metadata, changeAccess, changeOwner, changeTimes
    , read, readFromOffset
    , write, writeFromOffset, truncate, sync, syncData
    )

{-| A program sometimes needs to keep a file open: to read and write it at chosen offsets, or to
go on acting on the file it opened after that file's path has been renamed or replaced. This
module does that with a [Handle](#Handle), which stands for one open file. Most programs need only
[FileSystem](FileSystem), whose tasks, apart from the file streams, each open and close whatever
they need; [FileSystem.writeFileWith](FileSystem#writeFileWith) also covers durable and exclusive
writes.

A handle's type records what it may be used for. In `Handle readAccess writeAccess`, the reading
functions accept a handle only if the first parameter is [ReadAccess](#ReadAccess), and the
functions that change the file only if the second is [WriteAccess](#WriteAccess). The function
that opened the file decides both, [makeReadOnly](#makeReadOnly) and
[makeWriteOnly](#makeWriteOnly) give one of them up, and [close](#close) takes any handle. Each
task that changes the file succeeds with the handle it was given, so that calls on one file can be
chained.

Reads and writes say where in the file they act, as a byte offset from its start. Apart from
[writeFromOffset](#writeFromOffset) with a negative offset, nothing here reads or moves a current
position in the file. [read](#read) reads the whole file and [write](#write) writes at offset 0,
so two `write`s overwrite each other rather than appending. To read or write a file from start to
end in pieces, use [FileSystem.readFileStream](FileSystem#readFileStream) and
[FileSystem.writeFileStream](FileSystem#writeFileStream).

A handle stays open until [close](#close). An operation on it started after that fails with
[HandleClosed](FileSystem#ErrorKind), unless its file descriptor, the operating system's number for an open file, has
since been reused for a file opened by this module or by
[FileSystem.writeFileWith](FileSystem#writeFileWith) with an option on, and that file is still
open. The closed handle then acts on that file.

A task that fails, fails with a [FileSystem.Error](FileSystem#Error). When opening fails,
[errorPath](FileSystem#errorPath) is the path that was being opened; for every operation on a
handle it is [Path.empty](Path#empty). The path to open reaches the operating system as
[Path.toPosixString](Path#toPosixString) prints it.

On the native backend under Windows, opening a file fails with
[NotSupported](FileSystem#ErrorKind), so no handle can be obtained there.

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


{-| An open file, together with what its holder may do with it.

A handle comes from [openForRead](#openForRead), [openForWrite](#openForWrite) or
[openForReadAndWrite](#openForReadAndWrite), or is a copy of one. Its first type parameter can be
[ReadAccess](#ReadAccess) only if the file was opened for reading, and its second
[WriteAccess](#WriteAccess) only if it was opened for writing; the open functions put `Never` where
an access is absent. The converse does not hold: `openForWrite ExpectExisting` opens the file for
reading too, and its handle still has no read access.

Holding a handle is all it takes to use it within its access, so pass one only to code that should
have that access.

Copies of a handle, including those [makeReadOnly](#makeReadOnly) and
[makeWriteOnly](#makeWriteOnly) return, are the same open file, and closing one closes them all.

-}
type Handle readAccess writeAccess
    = Handle Int


{-| The marker, in a [Handle](#Handle)'s first type parameter, that the handle may be read.

It is used only as a type parameter; a program cannot make a value of it.

-}
type ReadAccess
    = ReadAccess


{-| The marker, in a [Handle](#Handle)'s second type parameter, that the handle may be used to
change the file.

It is used only as a type parameter; a program cannot make a value of it.

-}
type WriteAccess
    = WriteAccess


{-| A [Handle](#Handle) that may be read, whatever its write access.
-}
type alias ReadableHandle a =
    Handle ReadAccess a


{-| A [Handle](#Handle) that may be used to change the file, whatever its read access.
-}
type alias WriteableHandle a =
    Handle a WriteAccess


{-| A [Handle](#Handle) that may be both read and used to change the file, as
[openForReadAndWrite](#openForReadAndWrite) returns.
-}
type alias ReadWriteableHandle =
    Handle ReadAccess WriteAccess


{-| Returns the same open file as a handle that may only be read, for passing to code that should
not change the file. Closing either handle closes the file.
-}
makeReadOnly : ReadWriteableHandle -> Handle ReadAccess Never
makeReadOnly handle =
    let
        (Handle fd) =
            handle
    in
    Handle fd


{-| Returns the same open file as a handle that may only be used to change the file, for passing
to code that should not read it. Closing either handle closes the file.
-}
makeWriteOnly : ReadWriteableHandle -> Handle Never WriteAccess
makeWriteOnly handle =
    let
        (Handle fd) =
            handle
    in
    Handle fd



-- OPEN


{-| Opens the file at the path for reading. The task fails if the file cannot be opened, as when
nothing exists at the path.
-}
openForRead : Path -> Task FileSystem.Error (Handle ReadAccess Never)
openForRead path =
    openImpl "r" path


{-| What opening a file for writing does with whatever is at the path already.

`EnsureEmpty` creates the file if nothing exists at the path, and empties the file if it exists.

`ExpectExisting` opens the file with its contents as they are, and fails if nothing exists at the
path. It opens the file for reading as well as writing, whichever function opens it, so the
program must be allowed to read the file too.

`ExpectNotExisting` creates the file, and fails with [FileExists](FileSystem#ErrorKind) if
anything already exists at the path. The operating system checks and creates in one step (`O_EXCL`), so of two programs creating
the same file at most one succeeds.

A file that opening creates gets the mode `666`, less the bits the process's umask removes.

-}
type OpenForWriteBehaviour
    = EnsureEmpty
    | ExpectExisting
    | ExpectNotExisting


{-| Opens the file at the path for writing, treating what is already there as the
[OpenForWriteBehaviour](#OpenForWriteBehaviour) says.
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


{-| Opens the file at the path for both reading and writing, treating what is already there as the
[OpenForWriteBehaviour](#OpenForWriteBehaviour) says.
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


{-| Closes the file.

The handle, and every copy of it, counts as closed from then on, even if closing fails. An
operation on it started afterwards, a second `close` included, fails with
[HandleClosed](FileSystem#ErrorKind), except after the reuse of its file descriptor that the
module documentation describes.

-}
close : Handle a b -> Task FileSystem.Error ()
close handle =
    kClose (fdOf handle)
        |> handleError



-- METADATA


{-| Returns the metadata of the open file, with the fields
[FileSystem.Metadata](FileSystem#Metadata) describes.

Its `entityType` is never `Symlink`: opening a path that names a symbolic link opens the entity
the link points to.

-}
metadata : ReadableHandle a -> Task FileSystem.Error FileSystem.Metadata
metadata handle =
    kFstat (fdOf handle)
        |> Task.map (FileSystem.Internal.decodeMetadata entityFromInt)
        |> handleError


{-| Sets the access permissions of the open file, for its owner, its group and everyone else.

Each list becomes one octal digit of the file mode, as in
[FileSystem.changeAccess](FileSystem#changeAccess), so
`{ owner = [ Read, Write ], group = [ Read ], others = [ Read ] }` sets the mode `644`. The mode
has no other bits, so the set-user-ID, set-group-ID and sticky bits are cleared.

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


{-| Sets the user and group that own the open file, given as numeric ids.
-}
changeOwner : { userID : Int, groupID : Int } -> WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
changeOwner ids handle =
    kFchown (fdOf handle) ids.userID ids.groupID
        |> handleError
        |> Task.map (\_ -> handle)


{-| Sets the last access and last modification times of the open file.

The times are set in whole seconds, as for [FileSystem.changeTimes](FileSystem#changeTimes): each
is sent as its milliseconds divided by 1000 with `//`, which rounds down for times after 1970 and
toward zero for times before. On the JS backend `//` gives a 32-bit result, so a time from
2038-01-19T03:14:08Z on, or at or before 1901-12-13T20:45:51Z, is sent wrapped round into that
range, and a different time is set.

-}
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix } -> WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
changeTimes times handle =
    kFutimes (fdOf handle)
        (Time.posixToMillis times.lastAccessed // 1000)
        (Time.posixToMillis times.lastModified // 1000)
        |> handleError
        |> Task.map (\_ -> handle)



-- READING


{-| Reads the whole file, from its first byte to its end.
-}
read : ReadableHandle a -> Task FileSystem.Error Bytes
read handle =
    readFromOffset handle { offset = 0, length = -1 }


{-| Reads up to `length` bytes, starting `offset` bytes into the file.

Fewer bytes come back if the end of the file comes first, and none if `offset` is at or past it.
A negative `length` reads to the end of the file, and a negative `offset` reads from the start.

-}
readFromOffset : ReadableHandle a -> { offset : Int, length : Int } -> Task FileSystem.Error Bytes
readFromOffset handle options =
    kReadFromOffset (fdOf handle) options.offset options.length
        |> handleError



-- WRITING


{-| Writes the bytes at the start of the file.

The bytes already in the file are overwritten where the new ones fall, and any past them are
kept: the file is not shortened. [writeFromOffset](#writeFromOffset) writes elsewhere, and
[truncate](#truncate) shortens the file.

-}
write : WriteableHandle a -> Bytes -> Task FileSystem.Error (WriteableHandle a)
write handle bytes =
    writeFromOffset handle 0 bytes


{-| Writes the bytes into the file starting `offset` bytes from its start, overwriting what is
there.

A negative `offset` writes at the open file's current position instead. That position is the
start of the file when it is opened, and only a write with a negative offset moves it, to just
past the bytes written. So a sequence of such writes, each started after the one before has
succeeded, through any copies of the handle, puts its bytes one after another.

-}
writeFromOffset : WriteableHandle a -> Int -> Bytes -> Task FileSystem.Error (WriteableHandle a)
writeFromOffset handle offset bytes =
    kWriteFromOffset (fdOf handle) offset bytes
        |> handleError
        |> Task.map (\_ -> handle)


{-| Sets the size of the file to `length` bytes. A longer file loses the bytes past `length`, and a
shorter one is extended with zero bytes.

A negative `length` fails with [InvalidInput](FileSystem#ErrorKind) on the native backend, and empties the file on the JS
backend.

-}
truncate : Int -> WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
truncate length handle =
    kFtruncate (fdOf handle) length
        |> handleError
        |> Task.map (\_ -> handle)


{-| Flushes the file's changes, its data and its metadata, from the operating system's buffers to
the storage device (`fsync`), and succeeds once the operating system reports them written.
-}
sync : WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
sync handle =
    kFsync (fdOf handle)
        |> handleError
        |> Task.map (\_ -> handle)


{-| Flushes the file's data to the storage device, as [sync](#sync) does, but with `fdatasync`,
which may leave metadata that reading the data back does not need, such as the times, unwritten.

On the native backend under macOS it asks instead for `F_FULLFSYNC`, which also flushes the
storage device's own cache, and uses `fsync` if that fails; [sync](#sync) there uses `fsync`
alone.

-}
syncData : WriteableHandle a -> Task FileSystem.Error (WriteableHandle a)
syncData handle =
    kFdatasync (fdOf handle)
        |> handleError
        |> Task.map (\_ -> handle)



-- HELPERS


{-| Opens the file at `path` with the kernel open mode given first (`"r"`, `"w"`, `"r+"`, `"wx"`,
`"w+"` or `"wx+"`) and makes a handle of it. An open failure carries `path`.
-}
openImpl : String -> Path -> Task FileSystem.Error (Handle a b)
openImpl access path =
    kOpen access (Path.toPosixString path)
        |> Task.mapError (FileSystem.Internal.decodeError path)
        |> Task.map Handle


{-| Returns the file descriptor a handle stands for, which is what the kernels take.
-}
fdOf : Handle a b -> Int
fdOf (Handle fd) =
    fd


{-| Turns a kernel's `( code, message )` failure on an open handle into a `FileSystem.Error` whose
path is `Path.empty`.
-}
handleError : Task ( String, String ) a -> Task FileSystem.Error a
handleError task =
    Task.mapError (FileSystem.Internal.decodeError Path.empty) task


{-| Returns the entity type for a kernel's entity code: 0 to 4 are `File`, `Directory`, `Socket`,
`Symlink` and `Device`, and every other code, including the kernels' 5 for a pipe, is `Pipe`.
It repeats the one in `FileSystem`, which that module does not expose.
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
-- The annotations fix the kernel ABI: the C++ and JS kernels take and return exactly these
-- shapes. A failure is a ( code, message ) pair. Every binding that takes a file descriptor
-- fails with "EBADF", without reaching the operating system, unless `open` returned it and
-- `close` has not yet been asked to close it.


{-| Opens the file at the POSIX path given second with the open mode given first, and returns
its file descriptor, registered as an open handle.
-}
kOpen : String -> String -> Task ( String, String ) Int
kOpen =
    Eco.Kernel.FileSystem.open


{-| Removes an open file descriptor from the open handles and closes it.
-}
kClose : Int -> Task ( String, String ) ()
kClose =
    Eco.Kernel.FileSystem.close


{-| Asks for the 11-integer status list of an open file descriptor;
`FileSystem.Internal.decodeMetadata` reads it.
-}
kFstat : Int -> Task ( String, String ) (List Int)
kFstat =
    Eco.Kernel.FileSystem.fstat


{-| Sets the numeric mode, given second, of an open file descriptor.
-}
kFchmod : Int -> Int -> Task ( String, String ) ()
kFchmod =
    Eco.Kernel.FileSystem.fchmod


{-| Sets the owner of an open file descriptor to the user id and group id given second and third.
-}
kFchown : Int -> Int -> Int -> Task ( String, String ) ()
kFchown =
    Eco.Kernel.FileSystem.fchown


{-| Sets the access and modification times of an open file descriptor, given second and third in
whole seconds since the Unix epoch.
-}
kFutimes : Int -> Int -> Int -> Task ( String, String ) ()
kFutimes =
    Eco.Kernel.FileSystem.futimes


{-| Reads from an open file descriptor at the offset given second (0 when it is negative) as many
bytes as the third argument says, stopping at the end of the file, or to the end of the file when
the third argument is negative.
-}
kReadFromOffset : Int -> Int -> Int -> Task ( String, String ) Bytes
kReadFromOffset =
    Eco.Kernel.FileSystem.readFromOffset


{-| Writes all the bytes to an open file descriptor at the offset given second, or at the
descriptor's current position, moving it, when the offset is negative.
-}
kWriteFromOffset : Int -> Int -> Bytes -> Task ( String, String ) ()
kWriteFromOffset =
    Eco.Kernel.FileSystem.writeFromOffset


{-| Sets the size, given second in bytes, of the file behind an open file descriptor.
-}
kFtruncate : Int -> Int -> Task ( String, String ) ()
kFtruncate =
    Eco.Kernel.FileSystem.ftruncate


{-| Flushes an open file descriptor's data and metadata to the storage device (`fsync`).
-}
kFsync : Int -> Task ( String, String ) ()
kFsync =
    Eco.Kernel.FileSystem.fsync


{-| Flushes an open file descriptor's data to the storage device (`fdatasync`; natively on macOS,
`F_FULLFSYNC`, falling back to `fsync`).
-}
kFdatasync : Int -> Task ( String, String ) ()
kFdatasync =
    Eco.Kernel.FileSystem.fdatasync
