module System.File.Internal exposing (Error(..), MetadataOf, decodeError, decodeMetadata)

{-| Internal; not exposed.

`Error` is defined here so that both `System.File` and `System.File.FileHandle` can build it,
while users only see the alias exposed by `System.File`. The same goes for the metadata record
and its decoder: `System.File` and `System.File.FileHandle` both decode the kernel's metadata
list, but only `System.File` can name `EntityType`'s constructors, so the decoder takes the
entity constructor as an argument (plans/eco-system-library.md §3.1).

-}

import System.File.Path exposing (Path)
import Time


{-| A file system error: the path involved, the error code (an errno name such as `"ENOENT"`)
and a human readable message.
-}
type Error
    = Error
        { path : Path
        , code : String
        , message : String
        }


{-| Build an `Error` from the kernel's `( code, message )` failure tuple (B2 `FErr`).
-}
decodeError : Path -> ( String, String ) -> Error
decodeError path ( code, message ) =
    Error
        { path = path
        , code = code
        , message = message
        }


{-| The metadata record, generic in its entity type.
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


{-| Decode the kernel's metadata list (Appendix B.3 `stat`):
`[ entityType, dev, uid, gid, size, blksize, blocks, atimeMs, mtimeMs, ctimeMs, birthtimeMs ]`.
Missing entries read as 0.
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
