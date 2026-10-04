module System.Exit exposing
    ( ExitCode(..)
    , exitWith, exitSuccess, exitFailure
    )

{-| Ends the compiler's own process with an exit code, the number a process
hands back when it ends to say whether it succeeded.

By convention 0 means success and any other number means failure. `ExitCode`
names the two cases, and the names follow Haskell's `System.Exit`.

Ending the process is not something an Elm program can do itself, so `exitWith`
asks `Eco.Process.exit` to do it, and that module describes how the request is
carried out. The tasks here are typed to succeed with any value, which they can
only honour by never succeeding: if `Eco.Process.exit` ever completes instead
of ending the process, `exitWith` crashes the program.


# Exit Codes

@docs ExitCode


# Exiting the Process

@docs exitWith, exitSuccess, exitFailure

-}

import Eco.Process
import Task exposing (Task)
import Utils.Crash exposing (crash)


{-| How a process ended, or is to end, as its exit code.

`ExitSuccess` is code 0. `ExitFailure` carries the code. Nothing stops a value
of `ExitFailure 0`, and `exitWith` asks for the process to end with code 0 for
it, which reports success.

-}
type ExitCode
    = ExitSuccess
    | ExitFailure Int


{-| Ends the process with `exitCode`, through `Eco.Process.exit`.

The task never succeeds: if `Eco.Process.exit` completes instead of ending the
process, this crashes the program.

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


{-| Ends the process with exit code 1, which reports failure.
-}
exitFailure : Task Never a
exitFailure =
    exitWith (ExitFailure 1)


{-| Ends the process with exit code 0, which reports success.
-}
exitSuccess : Task Never a
exitSuccess =
    exitWith ExitSuccess
