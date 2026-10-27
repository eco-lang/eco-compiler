module API.Uninstall exposing (run)

{-| Removes one package from the `elm.json` of the project the command is run
in, for the API-mode `uninstall` command. Nothing is asked of the user.

The work is split into a plan and its application. The plan is either the new
outline or the finding that the package is not there to remove. An application
lists exact versions, so removing a direct dependency means solving again, as
`Builder.Deps.Solver.removeFromApp` describes. Only the direct and test-direct
dependencies are searched: a package that is only an indirect dependency is
reported as not installed. A package project lists version ranges, so its plan
just deletes the package from its dependencies and test dependencies, and
solves nothing.

Applying a plan writes the new `elm.json` and then checks that the project's
dependencies can be installed, through `Builder.Elm.Details.verifyInstall`. If
that check fails, the old `elm.json` is written back.

Errors are not returned: `Builder.Reporting.attempt` reports them on standard
error and exits with failure. On success, plain text is printed to standard
output.


# Uninstallation

@docs run

-}

import Builder.BackgroundWriter as BW
import Builder.Deps.Registry as Registry
import Builder.Deps.Solver as Solver
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.Elm.Constraint as C
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Dict exposing (Dict)
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| Removes `pkg` from the dependencies of the project whose root
`Builder.Stuff.findRoot` finds, and prints "Success!", or "It is not currently
installed!" when there was nothing to remove.

Having no project root, an unreadable registry or `elm.json`, no solution
without `pkg`, a solver failure, or a failed install check is reported and ends
the process with failure.

-}
run : Pkg.Name -> Task Never ()
run pkg =
    Reporting.attempt Exit.uninstallToReport
        (Stuff.findRoot
            |> Task.andThen
                (\maybeRoot ->
                    case maybeRoot of
                        Nothing ->
                            Task.succeed (Err Exit.UninstallNoOutline)

                        Just root ->
                            Task.run
                                (Task.eio Exit.UninstallBadRegistry (Stuff.resolveBundledPackages [] |> Task.andThen (Solver.initEnv Registry.Normal))
                                    |> Task.andThen
                                        (\env ->
                                            Task.eio Exit.UninstallBadOutline (Outline.read root)
                                                |> Task.andThen
                                                    (\oldOutline ->
                                                        case oldOutline of
                                                            Outline.App outline ->
                                                                makeAppPlan env pkg outline
                                                                    |> Task.andThen (\changes -> attemptChanges root env oldOutline changes)

                                                            Outline.Pkg outline ->
                                                                makePkgPlan pkg outline
                                                                    |> Task.andThen (\changes -> attemptChanges root env oldOutline changes)
                                                    )
                                        )
                                )
                )
        )



-- ====== ATTEMPT CHANGES ======


{-| A plan for the uninstall: `Changes` carries the whole new outline, and
`AlreadyNotPresent` means the package was not found where the plan looked.

The type parameter is not used by either constructor.

-}
type Changes vsn
    = AlreadyNotPresent
    | Changes Outline.Outline


{-| Applies `changes` to the project at `root`, or prints that the package is
not installed when there is nothing to change.
-}
attemptChanges : String -> Solver.Env -> Outline.Outline -> Changes a -> Task Exit.Uninstall ()
attemptChanges root env oldOutline changes =
    case changes of
        AlreadyNotPresent ->
            Task.io (IO.printLn "It is not currently installed!")

        Changes newOutline ->
            attemptChangesHelp root env oldOutline newOutline


{-| Writes `newOutline` to the project at `root` and verifies that its
dependencies install, printing "Success!" if they do. If they do not,
`oldOutline` is written back and the verification error is returned.

The task waits for every background write the verification starts before it
finishes.

-}
attemptChangesHelp : FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Task Exit.Uninstall ()
attemptChangesHelp root env oldOutline newOutline =
    Task.eio Exit.UninstallBadDetails <|
        BW.withScope
            (\scope ->
                Outline.write root newOutline
                    |> Task.andThen (\_ -> Details.verifyInstall scope root env newOutline)
                    |> Task.andThen
                        (\result ->
                            case result of
                                Err exit ->
                                    Outline.write root oldOutline
                                        |> Task.map (\_ -> Err exit)

                                Ok () ->
                                    IO.printLn "Success!"
                                        |> Task.map (\_ -> Ok ())
                        )
            )



-- ====== MAKE APP PLAN ======


{-| Plans the removal of `pkg` from an application: re-solves without it when
it is a direct or test-direct dependency, and otherwise gives
`AlreadyNotPresent`. Fails with an uninstall error when there is no solution or
the solver has trouble.
-}
makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Task Exit.Uninstall (Changes V.Version)
makeAppPlan (Solver.Env env) pkg ((Outline.AppOutline appData) as outline) =
    let
        direct =
            appData.depsDirect

        testDirect =
            appData.testDirect
    in
    case Dict.get pkg (Dict.union direct testDirect) of
        Just _ ->
            Task.io (Solver.removeFromApp env.cache env.connection env.registry pkg outline)
                |> Task.andThen
                    (\result ->
                        case result of
                            Solver.SolverOk (Solver.AppSolution _ _ app) ->
                                Task.succeed (Changes (Outline.App app))

                            Solver.NoSolution ->
                                Task.throw (Exit.UninstallNoOnlineAppSolution pkg)

                            Solver.NoOfflineSolution ->
                                Task.throw (Exit.UninstallNoOfflineAppSolution pkg)

                            Solver.SolverErr exit ->
                                Task.throw (Exit.UninstallHadSolverTrouble exit)
                    )

        Nothing ->
            Task.succeed AlreadyNotPresent



-- ====== MAKE PACKAGE PLAN ======


{-| Plans the removal of `pkg` from a package project by deleting it from both
the dependencies and the test dependencies, or gives `AlreadyNotPresent` when
it is in neither.
-}
makePkgPlan : Pkg.Name -> Outline.PkgOutline -> Task Exit.Uninstall (Changes C.Constraint)
makePkgPlan pkg (Outline.PkgOutline pkgData) =
    let
        old : Dict Pkg.Name C.Constraint
        old =
            Dict.union pkgData.deps pkgData.testDeps
    in
    if Dict.member pkg old then
        Outline.PkgOutline
            { pkgData
                | deps = Dict.remove pkg pkgData.deps
                , testDeps = Dict.remove pkg pkgData.testDeps
            }
            |> Outline.Pkg
            |> Changes
            |> Task.succeed

    else
        Task.succeed AlreadyNotPresent
