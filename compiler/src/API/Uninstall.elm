module API.Uninstall exposing (run)

{-| Remove Elm packages from an application or package project. This module handles
removing packages from elm.json and recalculating the dependency graph to ensure
all remaining dependencies are satisfied.

For applications, the solver recomputes the dependency solution after removal. For
packages, direct removal is performed since package dependencies use version ranges
rather than exact versions.


# Uninstallation

@docs run

-}

import Builder.BackgroundWriter as BW
import Builder.Deps.Solver as Solver
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.Elm.Constraint as C
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Data.Map as Dict exposing (Dict)
import System.IO as IO
import Task exposing (Task)
import Utils.Main exposing (FilePath)
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| Remove a package from the project's dependencies and update elm.json.
Recalculates the dependency graph to ensure all remaining dependencies are satisfied.
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
                                (Task.eio Exit.UninstallBadRegistry Solver.initEnv
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


type Changes vsn
    = AlreadyNotPresent
    | Changes Outline.Outline


attemptChanges : String -> Solver.Env -> Outline.Outline -> Changes a -> Task Exit.Uninstall ()
attemptChanges root env oldOutline changes =
    case changes of
        AlreadyNotPresent ->
            Task.io (IO.putStrLn "It is not currently installed!")

        Changes newOutline ->
            attemptChangesHelp root env oldOutline newOutline


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
                                    IO.putStrLn "Success!"
                                        |> Task.map (\_ -> Ok ())
                        )
            )



-- ====== MAKE APP PLAN ======


makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Task Exit.Uninstall (Changes V.Version)
makeAppPlan (Solver.Env env) pkg ((Outline.AppOutline appData) as outline) =
    let
        direct =
            appData.depsDirect

        testDirect =
            appData.testDirect
    in
    case Dict.get identity pkg (Dict.union direct testDirect) of
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


makePkgPlan : Pkg.Name -> Outline.PkgOutline -> Task Exit.Uninstall (Changes C.Constraint)
makePkgPlan pkg (Outline.PkgOutline pkgData) =
    let
        old : Dict ( String, String ) Pkg.Name C.Constraint
        old =
            Dict.union pkgData.deps pkgData.testDeps
    in
    if Dict.member identity pkg old then
        Outline.PkgOutline
            { pkgData
                | deps = Dict.remove identity pkg pkgData.deps
                , testDeps = Dict.remove identity pkg pkgData.testDeps
            }
            |> Outline.Pkg
            |> Changes
            |> Task.succeed

    else
        Task.succeed AlreadyNotPresent
