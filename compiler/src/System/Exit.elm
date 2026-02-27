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

import Eco.Process
import Task exposing (Task)
import Utils.Crash exposing (crash)


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
        ecoExitCode : Eco.Process.ExitCode
        ecoExitCode =
            case exitCode of
                ExitSuccess ->
                    Eco.Process.ExitSuccess

                ExitFailure int ->
                    Eco.Process.ExitFailure int
    in
    Eco.Process.exit ecoExitCode
        |> Task.map (\_ -> crash "exitWith: process should have exited")


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
