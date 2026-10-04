module Eco.Process.Error exposing
    ( ProcessError(..)
    , decodeProcessError, ofKernelTuple
    , toString
    )

{-| A failed process spawn is reported as the failure tuple that `Eco.IO.Error`
decodes, and this module reads that tuple in terms of the command being
spawned.

The failure tuple, its tags and the `IOError` each tag decodes to are set out in
`Eco.IO.Error`. For a spawn, two of those tags say something about the command
rather than about a file. Tag 1, which `Eco.IO.Error` decodes as
`FileNotFound`, becomes `CommandNotFound`, and tag 2, which it decodes as
`PermissionDenied`, becomes `CommandNotExecutable`. For these two, the command
in the result is the one passed in, not anything read from the tuple. Any other
tag gives `SpawnIOError` holding the `IOError` that `Eco.IO.Error` decodes it
to.

@docs ProcessError
@docs decodeProcessError, ofKernelTuple
@docs toString

-}

import Eco.IO.Error as IOErr exposing (IOError)


{-| A failed attempt to spawn a process, classified by what it says about the
command.

`CommandNotFound` and `CommandNotExecutable` carry the command string given to
`decodeProcessError` or `ofKernelTuple`, not the path the failure reported.

`SpawnIOError` is a failure with any other tag, held as the `IOError` that
`Eco.IO.Error.decodeIOError` gives for it.

`OtherProcessError` carries a message, which `toString` returns unchanged.
Nothing in this module produces it.

-}
type ProcessError
    = CommandNotFound String
    | CommandNotExecutable String
    | SpawnIOError IOError
    | OtherProcessError String


{-| Classifies `raw`, a failure reported while spawning `cmd`.

Tag 1 gives `CommandNotFound cmd` and tag 2 gives `CommandNotExecutable cmd`;
for these the path and message in `raw` are dropped. Any other tag gives
`SpawnIOError` holding `Eco.IO.Error.decodeIOError raw`.

-}
decodeProcessError : String -> IOErr.RawIOError -> ProcessError
decodeProcessError cmd raw =
    case raw.tag of
        1 ->
            CommandNotFound cmd

        2 ->
            CommandNotExecutable cmd

        _ ->
            SpawnIOError (IOErr.decodeIOError raw)


{-| Classifies a failure tuple `( tag, path, message )` reported while spawning
`cmd`, as `decodeProcessError` does.
-}
ofKernelTuple : String -> ( Int, String, String ) -> ProcessError
ofKernelTuple cmd tuple =
    decodeProcessError cmd (IOErr.fromKernel tuple)


{-| Returns a short description of `err`.

`CommandNotFound` and `CommandNotExecutable` give `"command not found: "` and
`"command not executable: "` followed by the command. `SpawnIOError` gives what
`Eco.IO.Error.toString` gives for its `IOError`, and `OtherProcessError` gives
its message unchanged.

-}
toString : ProcessError -> String
toString err =
    case err of
        CommandNotFound cmd ->
            "command not found: " ++ cmd

        CommandNotExecutable cmd ->
            "command not executable: " ++ cmd

        SpawnIOError ioErr ->
            IOErr.toString ioErr

        OtherProcessError message ->
            message
