module System.Exit exposing
    ( ExitCode(..)
    , exitWith, exitSuccess, exitFailure
    )

{-| Ends the compiler's own process with an exit code, the number a process
hands back when it ends to say whether it succeeded.

By convention 0 means success and any other number means failure. `ExitCode`
names the two cases, and the names follow Haskell's `System.Exit`.

`exitWith` ends the process at once through eco/system's
`System.exitWithCodeTask`. Output whose write has completed is not lost, and the
compiler awaits every write before it moves on. The tasks here are typed to
succeed with any value, which they can only honour by never succeeding: if
`System.exitWithCodeTask` ever completes instead of ending the process (it does
when the program is embedded in a host), `exitWith` crashes the program.


# Exit Codes

@docs ExitCode


# Exiting the Process

@docs exitWith, exitSuccess, exitFailure

-}

import System
import System.Crash exposing (crash)
import Task exposing (Task)


{-| How a process ended, or is to end, as its exit code.

`ExitSuccess` is code 0. `ExitFailure` carries the code. Nothing stops a value
of `ExitFailure 0`, and `exitWith` asks for the process to end with code 0 for
it, which reports success.

-}
type ExitCode
    = ExitSuccess
    | ExitFailure Int


{-| Ends the process with `exitCode`, through `System.exitWithCodeTask`.

The task never succeeds: if `System.exitWithCodeTask` completes instead of
ending the process, this crashes the program.

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
    System.exitWithCodeTask code
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
