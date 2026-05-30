module Eco.Process.Error exposing
    ( ProcessError(..)
    , decodeProcessError, ofKernelTuple
    , toString
    )

{-| Structured process-spawn error type for Eco.Process.spawn / spawnProcess.

`wait` continues to represent a non-zero exit as an `ExitFailure` value (not an
error), and `exit` never returns; only the spawn family can fail. Spawn failures
arrive as the same neutral IO failure tuple used elsewhere; the errno
classification is reinterpreted in process terms (ENOENT -> CommandNotFound,
EACCES -> CommandNotExecutable), falling back to a wrapped `IOError`.

@docs ProcessError
@docs decodeProcessError, ofKernelTuple
@docs toString

-}

import Eco.IO.Error as IOErr exposing (IOError)


{-| A structured process-spawn error.
-}
type ProcessError
    = CommandNotFound String
    | CommandNotExecutable String
    | SpawnIOError IOError
    | OtherProcessError String


{-| Map the neutral IO error record into a `ProcessError`, given the command.
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


{-| Convenience: decode straight from the kernel failure tuple, given the
command being spawned.
-}
ofKernelTuple : String -> ( Int, String, String ) -> ProcessError
ofKernelTuple cmd tuple =
    decodeProcessError cmd (IOErr.fromKernel tuple)


{-| A short human-readable description, for embedding in larger messages.
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
