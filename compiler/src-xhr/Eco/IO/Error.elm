module Eco.IO.Error exposing
    ( IOError(..), RawIOError
    , fromKernel, decodeIOError, ofKernelTuple
    , tagFromCode
    , toString
    )

{-| Code that reports a failed IO operation needs to tell the common kinds of
failure apart, and this module turns what an IO backend reports into an
`IOError` that can be matched on.

An IO operation that fails reports a _failure tuple_, `( tag, path, message )`.
The _tag_ is a small integer classifying the failure, the path is the file the
failure concerns, and the message is text describing it. The tag numbering is
set out under `IOError`. A backend that computes tags itself must number them
the same way, and nothing here can check that it does: a tag numbered
differently is decoded as the wrong kind of error.

`fromKernel` holds the tuple as a `RawIOError` record, `decodeIOError`
classifies the record, and `ofKernelTuple` does both. `tagFromCode` computes the
tag from an error code string such as `"ENOENT"`, for a backend that reports a
failure by its code rather than by tag. `toString` renders an `IOError` as a
short message.

@docs IOError, RawIOError
@docs fromKernel, decodeIOError, ofKernelTuple
@docs tagFromCode
@docs toString

-}


{-| A failed IO operation, classified by the kind of failure.

Tags 1 to 9 decode, in order, to `FileNotFound`, `PermissionDenied`,
`NotADirectory`, `IsADirectory`, `AlreadyExists`, `NoSpaceLeft`,
`TooManyOpenFiles`, `BrokenPipe` and `BadFileDescriptor`. Any other tag, 0
included, decodes to `OtherIOError`, which keeps the tag.

`FileNotFound`, `PermissionDenied`, `NotADirectory`, `IsADirectory` and
`AlreadyExists` carry the path exactly as reported, so a failure reported with
no path carries `""`.

`NoSpaceLeft` and `BrokenPipe` carry the path as a `Maybe`, which is `Nothing`
when the reported path is `""`.

`TooManyOpenFiles` and `BadFileDescriptor` carry no path.

`OtherIOError` carries its path as a `Maybe` in the same way, and is the only
constructor that keeps the backend's message. The others drop it.

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


{-| A failure tuple held as a record, before its tag is classified.

Any `Int` is accepted as `tag`; one outside 1 to 9 decodes to `OtherIOError`.

-}
type alias RawIOError =
    { tag : Int
    , path : String
    , message : String
    }


{-| Returns the failure tuple `( tag, path, message )` as a `RawIOError`, field
for field.
-}
fromKernel : ( Int, String, String ) -> RawIOError
fromKernel ( tag, path, message ) =
    { tag = tag, path = path, message = message }


{-| Classifies `raw` by its tag, using the tag numbering and the treatment of
paths and messages that `IOError` describes.
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


{-| Classifies a failure tuple `( tag, path, message )` as `decodeIOError` does.
-}
ofKernelTuple : ( Int, String, String ) -> IOError
ofKernelTuple =
    fromKernel >> decodeIOError


{-| Returns the tag for an error code string of the kind Node reports, such as
`"ENOENT"`.

`"ENOENT"` gives 1; `"EACCES"` and `"EPERM"` give 2; `"ENOTDIR"` gives 3;
`"EISDIR"` gives 4; `"EEXIST"` gives 5; `"ENOSPC"` gives 6; `"EMFILE"` and
`"ENFILE"` give 7; `"EPIPE"` gives 8; and `"EBADF"` gives 9. Any other string,
`""` included, gives 0, which decodes to `OtherIOError`.

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


{-| Returns `Nothing` for the empty string and `Just s` for any other, including
one of only whitespace.
-}
nonEmpty : String -> Maybe String
nonEmpty s =
    if s == "" then
        Nothing

    else
        Just s


{-| Returns a short description of `err`.

The named kinds give fixed English text. The five that carry a plain path add
it after a colon, so an empty path leaves the text ending in `": "`.
`NoSpaceLeft` and `BrokenPipe` add their path in parentheses when they have one.
`OtherIOError` gives the backend's message, with its path in parentheses when it
has one; its tag is not shown.

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


{-| Returns the path after a space and in parentheses, or `""` for `Nothing`.
-}
pathSuffix : Maybe String -> String
pathSuffix maybePath =
    case maybePath of
        Just path ->
            " (" ++ path ++ ")"

        Nothing ->
            ""
