module System.Exit exposing
    ( ExitCode(..)
    , exitWith, exitSuccess, exitFailure
    )

{-| Process exit code management for the Elm compiler.

This module provides functions to terminate the compiler process with appropriate
exit codes, following standard Unix conventions where 0 indicates success and
non-zero values indicate various failure conditions.

Ref.: <https://hackage.haskell.org/package/base-4.20.0.1/docs/System-Exit.html>


# Exit Codes

@docs ExitCode


# Exiting the Process

@docs exitWith, exitSuccess, exitFailure

-}

import Task exposing (Task)
import Utils.Impure as Impure


{-| Exit code representing success (0) or failure (non-zero integer).
-}
type ExitCode
    = ExitSuccess
    | ExitFailure Int


{-| Exit the program with the specified exit code.
-}
exitWith : ExitCode -> Task Never a
exitWith exitCode =
    let
        code : Int
        code =
            case exitCode of
                ExitSuccess ->
                    0

                ExitFailure int ->
                    int
    in
    Impure.task "exitWith"
        []
        (Impure.StringBody (String.fromInt code))
        Impure.Crash


{-| Exit the program with exit code 1, indicating failure.
-}
exitFailure : Task Never a
exitFailure =
    exitWith (ExitFailure 1)


{-| Exit the program with exit code 0, indicating success.
-}
exitSuccess : Task Never a
exitSuccess =
    exitWith ExitSuccess
