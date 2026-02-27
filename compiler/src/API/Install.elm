module API.Install exposing (run)

{-| Install Elm packages into an application or package project. This module
handles dependency resolution, constraint solving, and updating the elm.json file.

The installer can promote packages from indirect to direct dependencies, from test
to production dependencies, or add entirely new packages while maintaining version
compatibility across the dependency graph.


# Installation

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
import Data.Map as Dict exposing (Dict)
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| Install a package into the project's dependencies and update elm.json.
Resolves version constraints and updates the dependency graph while maintaining compatibility.
-}
run : Pkg.Name -> Task Never ()
run pkg =
    Reporting.attempt Exit.installToReport
        (Stuff.findRoot
            |> Task.andThen
                (\maybeRoot ->
                    case maybeRoot of
                        Nothing ->
                            Task.succeed (Err Exit.InstallNoOutline)

                        Just root ->
                            Task.run
                                (Task.eio Exit.InstallBadRegistry Solver.initEnv
                                    |> Task.andThen
                                        (\env ->
                                            Task.eio Exit.InstallBadOutline (Outline.read root)
                                                |> Task.andThen
                                                    (\oldOutline ->
                                                        case oldOutline of
                                                            Outline.App outline ->
                                                                makeAppPlan env pkg outline
                                                                    |> Task.andThen (\changes -> attemptChanges root env oldOutline V.toChars changes)

                                                            Outline.Pkg outline ->
                                                                makePkgPlan env pkg outline
                                                                    |> Task.andThen (\changes -> attemptChanges root env oldOutline C.toChars changes)
                                                    )
                                        )
                                )
                )
        )



-- ====== ATTEMPT CHANGES ======


type Changes vsn
    = AlreadyInstalled
    | PromoteTest Outline.Outline
    | PromoteIndirect Outline.Outline
    | Changes Outline.Outline


attemptChanges : String -> Solver.Env -> Outline.Outline -> (a -> String) -> Changes a -> Task Exit.Install ()
attemptChanges root env oldOutline _ changes =
    case changes of
        AlreadyInstalled ->
            Task.io (IO.printLn "It is already installed!")

        PromoteIndirect newOutline ->
            attemptChangesHelp root env oldOutline newOutline

        PromoteTest newOutline ->
            attemptChangesHelp root env oldOutline newOutline

        Changes newOutline ->
            attemptChangesHelp root env oldOutline newOutline


attemptChangesHelp : FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Task Exit.Install ()
attemptChangesHelp root env oldOutline newOutline =
    Task.eio Exit.InstallBadDetails <|
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


makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Task Exit.Install (Changes V.Version)
makeAppPlan (Solver.Env env) pkg ((Outline.AppOutline appData) as outline) =
    let
        direct =
            appData.depsDirect

        indirect =
            appData.depsIndirect

        testDirect =
            appData.testDirect

        testIndirect =
            appData.testIndirect
    in
    if Dict.member identity pkg direct then
        Task.succeed AlreadyInstalled

    else
        -- is it already indirect?
        case Dict.get identity pkg indirect of
            Just vsn ->
                Outline.AppOutline
                    { appData
                        | depsDirect = Dict.insert identity pkg vsn direct
                        , depsIndirect = Dict.remove identity pkg indirect
                    }
                    |> Outline.App
                    |> PromoteIndirect
                    |> Task.succeed

            Nothing ->
                -- is it already a test dependency?
                case Dict.get identity pkg testDirect of
                    Just vsn ->
                        Outline.AppOutline
                            { appData
                                | depsDirect = Dict.insert identity pkg vsn direct
                                , testDirect = Dict.remove identity pkg testDirect
                            }
                            |> Outline.App
                            |> PromoteTest
                            |> Task.succeed

                    Nothing ->
                        -- is it already an indirect test dependency?
                        case Dict.get identity pkg testIndirect of
                            Just vsn ->
                                Outline.AppOutline
                                    { appData
                                        | depsDirect = Dict.insert identity pkg vsn direct
                                        , testIndirect = Dict.remove identity pkg testIndirect
                                    }
                                    |> Outline.App
                                    |> PromoteTest
                                    |> Task.succeed

                            Nothing ->
                                -- finally try to add it from scratch
                                case Registry.getVersions_ pkg env.registry of
                                    Err suggestions ->
                                        case env.connection of
                                            Solver.Online _ ->
                                                Task.throw (Exit.InstallUnknownPackageOnline pkg suggestions)

                                            Solver.Offline ->
                                                Task.throw (Exit.InstallUnknownPackageOffline pkg suggestions)

                                    Ok _ ->
                                        Task.io (Solver.addToApp env.cache env.connection env.registry pkg outline False)
                                            |> Task.andThen
                                                (\result ->
                                                    case result of
                                                        Solver.SolverOk (Solver.AppSolution _ _ app) ->
                                                            Task.succeed (Changes (Outline.App app))

                                                        Solver.NoSolution ->
                                                            Task.throw (Exit.InstallNoOnlineAppSolution pkg)

                                                        Solver.NoOfflineSolution ->
                                                            Task.throw (Exit.InstallNoOfflineAppSolution pkg)

                                                        Solver.SolverErr exit ->
                                                            Task.throw (Exit.InstallHadSolverTrouble exit)
                                                )



-- ====== MAKE PACKAGE PLAN ======


makePkgPlan : Solver.Env -> Pkg.Name -> Outline.PkgOutline -> Task Exit.Install (Changes C.Constraint)
makePkgPlan (Solver.Env env) pkg (Outline.PkgOutline pkgData) =
    if Dict.member identity pkg pkgData.deps then
        Task.succeed AlreadyInstalled

    else
        -- is already in test dependencies?
        case Dict.get identity pkg pkgData.testDeps of
            Just con ->
                Outline.PkgOutline
                    { pkgData
                        | deps = Dict.insert identity pkg con pkgData.deps
                        , testDeps = Dict.remove identity pkg pkgData.testDeps
                    }
                    |> Outline.Pkg
                    |> PromoteTest
                    |> Task.succeed

            Nothing ->
                -- try to add a new dependency
                case Registry.getVersions_ pkg env.registry of
                    Err suggestions ->
                        case env.connection of
                            Solver.Online _ ->
                                Task.throw (Exit.InstallUnknownPackageOnline pkg suggestions)

                            Solver.Offline ->
                                Task.throw (Exit.InstallUnknownPackageOffline pkg suggestions)

                    Ok (Registry.KnownVersions _ _) ->
                        let
                            old : Dict ( String, String ) Pkg.Name C.Constraint
                            old =
                                Dict.union pkgData.deps pkgData.testDeps

                            cons : Dict ( String, String ) Pkg.Name C.Constraint
                            cons =
                                Dict.insert identity pkg C.anything old
                        in
                        Task.io (Solver.verify env.cache env.connection env.registry cons)
                            |> Task.andThen
                                (\result ->
                                    case result of
                                        Solver.SolverOk solution ->
                                            let
                                                (Solver.Details vsn _) =
                                                    Utils.find identity pkg solution

                                                con : C.Constraint
                                                con =
                                                    C.untilNextMajor vsn

                                                new : Dict ( String, String ) Pkg.Name C.Constraint
                                                new =
                                                    Dict.insert identity pkg con old

                                                changes : Dict ( String, String ) Pkg.Name (Change C.Constraint)
                                                changes =
                                                    detectChanges old new

                                                news : Dict ( String, String ) Pkg.Name C.Constraint
                                                news =
                                                    Utils.mapMapMaybe identity Pkg.compareName keepNew changes
                                            in
                                            Outline.PkgOutline
                                                { pkgData
                                                    | deps = addNews (Just pkg) news pkgData.deps
                                                    , testDeps = addNews Nothing news pkgData.testDeps
                                                }
                                                |> Outline.Pkg
                                                |> Changes
                                                |> Task.succeed

                                        Solver.NoSolution ->
                                            Task.throw (Exit.InstallNoOnlinePkgSolution pkg)

                                        Solver.NoOfflineSolution ->
                                            Task.throw (Exit.InstallNoOfflinePkgSolution pkg)

                                        Solver.SolverErr exit ->
                                            Task.throw (Exit.InstallHadSolverTrouble exit)
                                )


addNews : Maybe Pkg.Name -> Dict ( String, String ) Pkg.Name C.Constraint -> Dict ( String, String ) Pkg.Name C.Constraint -> Dict ( String, String ) Pkg.Name C.Constraint
addNews pkg new old =
    Dict.merge compare
        (Dict.insert identity)
        (\k _ n -> Dict.insert identity k n)
        (\k c acc ->
            if Just k == pkg then
                Dict.insert identity k c acc

            else
                acc
        )
        old
        new
        Dict.empty



-- ====== CHANGES ======


type Change a
    = Insert a
    | Change a
    | Remove


detectChanges : Dict ( String, String ) Pkg.Name a -> Dict ( String, String ) Pkg.Name a -> Dict ( String, String ) Pkg.Name (Change a)
detectChanges old new =
    Dict.merge compare
        (\k _ -> Dict.insert identity k Remove)
        (\k oldElem newElem acc ->
            case keepChange k oldElem newElem of
                Just change ->
                    Dict.insert identity k change acc

                Nothing ->
                    acc
        )
        (\k v -> Dict.insert identity k (Insert v))
        old
        new
        Dict.empty


keepChange : k -> v -> v -> Maybe (Change v)
keepChange _ old new =
    if old == new then
        Nothing

    else
        Just (Change new)


keepNew : Change a -> Maybe a
keepNew change =
    case change of
        Insert a ->
            Just a

        Change a ->
            Just a

        Remove ->
            Nothing
