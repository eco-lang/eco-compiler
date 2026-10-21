module FileSystem.Internal exposing (Error(..), MetadataOf, decodeError, decodeMetadata)

{-| `FileSystem` and `FileSystem.Handle` both build file system errors and decode file
metadata, and this module lets them share one error type and one metadata decoder without
making the error's constructor public.

The package does not expose this module. `FileSystem` exposes `Error` only as an alias of the
type defined here, so outside the package the constructor cannot be reached, and an error can be
taken apart only through `FileSystem`'s accessors (`errorPath`, `errorKind` and
`errorToString`).

The kernel, `Eco.Kernel.FileSystem`, is the part of the runtime, not written in Elm, that
carries out file system calls; it names an entity's type by an integer code. `FileSystem`
imports this module, so this module cannot import `FileSystem` and cannot name
`FileSystem.EntityType`. That is why the metadata record, `MetadataOf`, is generic in its
entity type, and why `decodeMetadata` is given the function that turns the kernel's entity
code into one.

A kernel failure reaches Elm as a `( code, message )` pair, and `decodeError` adds a path to make
an `Error`. `Error` is a type of its own, not interchangeable with `Socket.Error` or
`Stream.Error`.

-}

import Path exposing (Path)
import Time


{-| A failed file system operation: the path it concerned, a code naming the kind of failure,
and a message describing it.

The code is usually an errno name such as `"ENOENT"`; the kernels also report codes of their
own, such as `"ERR_FS_EISDIR"` for a non-recursive remove of a directory. The message usually
begins with the code, as in `"ENOENT: no such file or directory, open '/x'"`, but not always.
The path is whichever path `decodeError` was given, which may be `Path.empty`.

-}
type Error
    = Error
        { path : Path
        , code : String
        , message : String
        }


{-| Builds an `Error` for `path` from a kernel's `( code, message )` failure, keeping the code
and message as they are.
-}
decodeError : Path -> ( String, String ) -> Error
decodeError path ( code, message ) =
    Error
        { path = path
        , code = code
        , message = message
        }


{-| What the kernel reports about one file system entity, with the entity type left as a
parameter.

`deviceID` identifies the device the entity is stored on, not the device a `Device` entity
stands for. `byteSize` and `blockSize` are in bytes; `blockSize` is the block size the operating
system prefers for IO. `blocks` is the operating system's allocated block count (`st_blocks`),
which Linux and macOS count in 512-byte units, not in units of `blockSize`.

`created` is the birth time when the kernel obtains one; otherwise both kernels report the
status change time, so `created` equals `lastChanged`. `lastChanged` is the status change time
(`ctime`), not a creation time; it moves when the entity's metadata changes as well as when its
contents do.

`FileSystem.Metadata` spells out these same fields with `FileSystem.EntityType` instead of
being defined as `MetadataOf EntityType`. Record aliases are structural, so the two are
interchangeable, but only for as long as their fields are kept identical.

-}
type alias MetadataOf e =
    { entityType : e
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


{-| Builds the metadata record from the kernel's list of integers, using `toEntity` to turn the
entity code into an entity type.

The list is
`[ entityType, dev, uid, gid, size, blksize, blocks, atimeMs, mtimeMs, ctimeMs, birthtimeMs ]`,
the four times in whole milliseconds since the Unix epoch. A missing entry reads as 0, so a
short list gives `toEntity 0`, zeros or the epoch rather than a failure; entries past the
eleventh are ignored.

-}
decodeMetadata : (Int -> e) -> List Int -> MetadataOf e
decodeMetadata toEntity values =
    let
        at i =
            List.drop i values |> List.head |> Maybe.withDefault 0
    in
    { entityType = toEntity (at 0)
    , deviceID = at 1
    , userID = at 2
    , groupID = at 3
    , byteSize = at 4
    , blockSize = at 5
    , blocks = at 6
    , lastAccessed = Time.millisToPosix (at 7)
    , lastModified = Time.millisToPosix (at 8)
    , lastChanged = Time.millisToPosix (at 9)
    , created = Time.millisToPosix (at 10)
    }
