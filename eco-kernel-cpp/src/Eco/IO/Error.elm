module Eco.IO.Error exposing
    ( IOError(..)
    , RawIOError
    , fromKernel, decodeIOError, ofKernelTuple
    , tagFromCode
    , toString
    )

{-| Structured IO error types shared by Eco.File, Eco.Console, parts of
Eco.Process, Eco.Runtime, and Eco.MVar.

Kernel IO primitives fail with a neutral fixed-layout tuple
`( classificationTag, path, message )` (see IO_ERR_002). The `Raw*` record is
the Elm-facing neutral representation assembled from that tuple; `decodeIOError`
maps it into the typed `IOError` ADT. The classification tag is computed at each
kernel (native C++ maps `errno`; JS/XHR map `err.code`) so this single decode
covers all backends.

@docs IOError, RawIOError
@docs fromKernel, decodeIOError, ofKernelTuple
@docs toString

-}


{-| A structured IO error. Each constructor corresponds to a stable
classification tag emitted by the kernels.
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


{-| The neutral record assembled from the kernel failure tuple.
-}
type alias RawIOError =
    { tag : Int
    , path : String
    , message : String
    }


{-| Assemble the neutral record from a kernel failure tuple
`( classificationTag, path, message )`.
-}
fromKernel : ( Int, String, String ) -> RawIOError
fromKernel ( tag, path, message ) =
    { tag = tag, path = path, message = message }


{-| Map the neutral record into the typed `IOError`. The tag values are the
stable contract shared with the kernels (see IO_ERR_002).
-}
decodeIOError : RawIOError -> IOError
decodeIOError raw =
    case raw.tag of
        1 ->
            FileNotFound raw.path

        2 ->
            PermissionDenied raw.path

        3 ->
            NotADirectory raw.path

        4 ->
            IsADirectory raw.path

        5 ->
            AlreadyExists raw.path

        6 ->
            NoSpaceLeft (nonEmpty raw.path)

        7 ->
            TooManyOpenFiles

        8 ->
            BrokenPipe (nonEmpty raw.path)

        9 ->
            BadFileDescriptor

        _ ->
            OtherIOError
                { tag = raw.tag
                , path = nonEmpty raw.path
                , message = raw.message
                }


{-| Convenience: decode straight from the kernel failure tuple.
-}
ofKernelTuple : ( Int, String, String ) -> IOError
ofKernelTuple =
    fromKernel >> decodeIOError


{-| Map a Node/libuv-style errno code string (e.g. "ENOENT") to the stable
classification tag. Used by the XHR path, where the eco-io server forwards the
error `code` string rather than a numeric errno. Keep in sync with the C++ and
JS kernel errno classification (see IO_ERR_002).
-}
tagFromCode : String -> Int
tagFromCode code =
    case code of
        "ENOENT" ->
            1

        "EACCES" ->
            2

        "EPERM" ->
            2

        "ENOTDIR" ->
            3

        "EISDIR" ->
            4

        "EEXIST" ->
            5

        "ENOSPC" ->
            6

        "EMFILE" ->
            7

        "ENFILE" ->
            7

        "EPIPE" ->
            8

        "EBADF" ->
            9

        _ ->
            0


nonEmpty : String -> Maybe String
nonEmpty s =
    if s == "" then
        Nothing

    else
        Just s


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


pathSuffix : Maybe String -> String
pathSuffix maybePath =
    case maybePath of
        Just path ->
            " (" ++ path ++ ")"

        Nothing ->
            ""
