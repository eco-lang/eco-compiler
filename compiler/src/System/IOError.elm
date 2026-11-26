module System.IOError exposing
    ( IOError(..)
    , fromFileSystem, fromStream, fromKernel
    , toString
    )

{-| The compiler's own type for a failed IO operation, and the one place that
says how a failure of eco/system or of eco/kernel becomes one.

The constructors and their rendering are those of `Eco.IO.Error`, which the
compiler used before its file and console IO moved to eco/system
(plans/compiler-io-on-eco-system.md D8), so every report and crash message
built from an `IOError` reads as it did. A failure always names the path the
compiler gave the operation, never a path eco/system parsed from it.

@docs IOError
@docs fromFileSystem, fromStream, fromKernel
@docs toString

-}

import Eco.IO.Error
import FileSystem
import Stream


{-| A failed IO operation, classified by what went wrong. The `String` or
`Maybe String` a constructor carries is the path concerned, when there is one.
`OtherIOError` is every other failure: `tag` is the classification number the
eco/kernel kernels gave it (0 for one that came from eco/system), and `message`
describes it.
-}
type IOError
    = FileNotFound String
    | PermissionDenied String
    | NotADirectory String
    | IsADirectory String
    | AlreadyExists String
    | NoSpaceLeft (Maybe String)
    | TooManyOpenFiles
    | BrokenPipe (Maybe String)
    | BadFileDescriptor
    | OtherIOError { tag : Int, path : Maybe String, message : String }


{-| Classifies a failure of eco/system's `FileSystem` or `FileSystem.Handle`
about `path`, as the eco/kernel kernels classified the same errno: a missing
entity is `FileNotFound`, a refused permission or privilege `PermissionDenied`,
a directory where a file was needed (including a non-recursive remove of a
directory) `IsADirectory`, and so on. A kind with no counterpart is an
`OtherIOError` with the message eco/system gave.
-}
fromFileSystem : String -> FileSystem.Error -> IOError
fromFileSystem path err =
    case FileSystem.errorKind err of
        FileSystem.NoSuchFileOrDirectory ->
            FileNotFound path

        FileSystem.PermissionDenied ->
            PermissionDenied path

        FileSystem.NotPermitted ->
            PermissionDenied path

        FileSystem.NotADirectory ->
            NotADirectory path

        FileSystem.DirectoryFound ->
            IsADirectory path

        FileSystem.DirectoryRemoveNotRecursive ->
            IsADirectory path

        FileSystem.FileExists ->
            AlreadyExists path

        FileSystem.NoSpace ->
            NoSpaceLeft (nonEmpty path)

        FileSystem.TooManyOpenFiles ->
            TooManyOpenFiles

        FileSystem.HandleClosed ->
            BadFileDescriptor

        _ ->
            OtherIOError { tag = 0, path = nonEmpty path, message = FileSystem.errorToString err }


{-| Classifies a failure of a standard stream, as `Stream.errorToString`
describes it.
-}
fromStream : Stream.Error -> IOError
fromStream err =
    OtherIOError { tag = 0, path = Nothing, message = Stream.errorToString err }


{-| Gives the same failure for an `Eco.IO.Error.IOError`, which the kernels the
compiler still uses from eco/kernel fail with (`Eco.MVar`, `Eco.FileLock`).
-}
fromKernel : Eco.IO.Error.IOError -> IOError
fromKernel err =
    case err of
        Eco.IO.Error.FileNotFound path ->
            FileNotFound path

        Eco.IO.Error.PermissionDenied path ->
            PermissionDenied path

        Eco.IO.Error.NotADirectory path ->
            NotADirectory path

        Eco.IO.Error.IsADirectory path ->
            IsADirectory path

        Eco.IO.Error.AlreadyExists path ->
            AlreadyExists path

        Eco.IO.Error.NoSpaceLeft path ->
            NoSpaceLeft path

        Eco.IO.Error.TooManyOpenFiles ->
            TooManyOpenFiles

        Eco.IO.Error.BrokenPipe path ->
            BrokenPipe path

        Eco.IO.Error.BadFileDescriptor ->
            BadFileDescriptor

        Eco.IO.Error.OtherIOError r ->
            OtherIOError r


{-| A short human-readable description, for embedding in larger messages.
-}
toString : IOError -> String
toString err =
    case err of
        FileNotFound path ->
            "file not found: " ++ path

        PermissionDenied path ->
            "permission denied: " ++ path

        NotADirectory path ->
            "not a directory: " ++ path

        IsADirectory path ->
            "is a directory: " ++ path

        AlreadyExists path ->
            "already exists: " ++ path

        NoSpaceLeft maybePath ->
            "no space left on device" ++ pathSuffix maybePath

        TooManyOpenFiles ->
            "too many open files"

        BrokenPipe maybePath ->
            "broken pipe" ++ pathSuffix maybePath

        BadFileDescriptor ->
            "bad file descriptor"

        OtherIOError r ->
            r.message ++ pathSuffix r.path


{-| ` (path)` for a path, and nothing for none.
-}
pathSuffix : Maybe String -> String
pathSuffix maybePath =
    case maybePath of
        Just path ->
            " (" ++ path ++ ")"

        Nothing ->
            ""


{-| The path, or `Nothing` for the empty one.
-}
nonEmpty : String -> Maybe String
nonEmpty s =
    if s == "" then
        Nothing

    else
        Just s
