module API.Install exposing (run)

{-| Adds one package to the direct dependencies of the project in the current
directory, without asking for confirmation, for the API mode of the compiler.

The work has two steps. First a _plan_ is made from the project's `elm.json`:
the outline as it should be after the install, or the finding that the package
is already a direct dependency. Then the plan is applied: the new outline is
written and the dependencies are verified and built with
`Builder.Elm.Details.verifyInstall`; if that fails, the old outline is written
back.

A package that the outline already names somewhere else is _promoted_: moved
into the direct dependencies at the version or constraint it already has,
without running the solver. Only the verification afterwards checks the result.
A package the outline does not name at all is solved for. In an application
`Builder.Deps.Solver.addToApp` chooses its version and adjusts the others; in a
package, the solver checks that the existing constraints and the new package
can be satisfied together, and the new package is added with a constraint
reaching up to its next major version from the version chosen.

Errors do not come back to the caller: `run` reports them on standard error and
exits with failure, as `Builder.Reporting.attempt` describes. On success a line
of plain text is printed to standard output.

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
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| Installs `pkg` as a direct dependency of the project whose `elm.json` is
found in the current directory or the nearest parent that has one.

It prints "It is already installed!" when `pkg` is already a direct
dependency, and "Success!" once the new outline is written and verified. Any
failure, including finding no `elm.json`, an unknown package or no solution,
is reported on standard error and ends the process with failure.

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
                                (Task.eio Exit.InstallBadRegistry (Stuff.resolveBundledPackages [] |> Task.andThen (Solver.initEnv Registry.Normal))
                                    |> Task.andThen
                                        (\env ->
                                            Task.eio Exit.InstallBadOutline (Outline.read root)
                                                |> Task.andThen
                                                    (\oldOutline ->
                                                        case oldOutline of
                                                            Outline.App outline ->
                                                                makeAppPlan env pkg outline
                                                                    |> Task.andThen (\changes -> attemptChanges root env oldOutline changes)

                                                            Outline.Pkg outline ->
                                                                makePkgPlan env pkg outline
                                                                    |> Task.andThen (\changes -> attemptChanges root env oldOutline changes)
                                                    )
                                        )
                                )
                )
        )



-- ====== ATTEMPT CHANGES ======


{-| The plan for an install: what is to become of the project's outline.

`AlreadyInstalled` means the package is a direct dependency already and nothing
is written.

`PromoteTest` and `PromoteIndirect` carry an outline in which a package already
named as a test dependency, or as an indirect dependency of an application, has
been moved into the direct dependencies unchanged. `Changes` carries an outline
the solver produced for a package that was not named at all. All three are
applied the same way.

The type parameter is not used.

-}
type Changes vsn
    = AlreadyInstalled
    | PromoteTest Outline.Outline
    | PromoteIndirect Outline.Outline
    | Changes Outline.Outline


{-| Applies `changes` to the project at `root`, whose outline is now
`oldOutline`, printing "It is already installed!" when there is nothing to do.
-}
attemptChanges : String -> Solver.Env -> Outline.Outline -> Changes a -> Task Exit.Install ()
attemptChanges root env oldOutline changes =
    case changes of
        AlreadyInstalled ->
            Task.io (IO.printLn "It is already installed!")

        PromoteIndirect newOutline ->
            attemptChangesHelp root env oldOutline newOutline

        PromoteTest newOutline ->
            attemptChangesHelp root env oldOutline newOutline

        Changes newOutline ->
            attemptChangesHelp root env oldOutline newOutline


{-| Writes `newOutline` to the project at `root` and verifies its dependencies,
printing "Success!" if they verify. If verification fails, `oldOutline` is
written back and the failure is returned.
-}
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


{-| Returns the plan for installing `pkg` in an application.

The outline's sections are searched in order: direct dependencies, indirect
ones, direct test dependencies, then indirect test dependencies. A package
found in one of the last three is moved into the direct dependencies at the
version it has there. A package found in none is looked up in the registry,
which fails with nearby names as suggestions if it is unknown, and is otherwise
added with `Builder.Deps.Solver.addToApp`.

-}
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
    if Dict.member pkg direct then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg indirect of
            Just vsn ->
                Outline.AppOutline
                    { appData
                        | depsDirect = Dict.insert pkg vsn direct
                        , depsIndirect = Dict.remove pkg indirect
                    }
                    |> Outline.App
                    |> PromoteIndirect
                    |> Task.succeed

            Nothing ->
                case Dict.get pkg testDirect of
                    Just vsn ->
                        Outline.AppOutline
                            { appData
                                | depsDirect = Dict.insert pkg vsn direct
                                , testDirect = Dict.remove pkg testDirect
                            }
                            |> Outline.App
                            |> PromoteTest
                            |> Task.succeed

                    Nothing ->
                        case Dict.get pkg testIndirect of
                            Just vsn ->
                                Outline.AppOutline
                                    { appData
                                        | depsDirect = Dict.insert pkg vsn direct
                                        , testIndirect = Dict.remove pkg testIndirect
                                    }
                                    |> Outline.App
                                    |> PromoteTest
                                    |> Task.succeed

                            Nothing ->
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


{-| Returns the plan for installing `pkg` in a package project.

A package already in `deps` needs nothing; one in `testDeps` is moved to `deps`
with the same constraint. Otherwise, after checking that the registry knows
`pkg`, the solver is asked for versions satisfying every constraint in `deps`
and `testDeps` together with `pkg` at any version. `pkg` is then added to
`deps`, constrained from the version chosen up to its next major version, and
no other constraint is changed.

-}
makePkgPlan : Solver.Env -> Pkg.Name -> Outline.PkgOutline -> Task Exit.Install (Changes C.Constraint)
makePkgPlan (Solver.Env env) pkg (Outline.PkgOutline pkgData) =
    if Dict.member pkg pkgData.deps then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg pkgData.testDeps of
            Just con ->
                Outline.PkgOutline
                    { pkgData
                        | deps = Dict.insert pkg con pkgData.deps
                        , testDeps = Dict.remove pkg pkgData.testDeps
                    }
                    |> Outline.Pkg
                    |> PromoteTest
                    |> Task.succeed

            Nothing ->
                case Registry.getVersions_ pkg env.registry of
                    Err suggestions ->
                        case env.connection of
                            Solver.Online _ ->
                                Task.throw (Exit.InstallUnknownPackageOnline pkg suggestions)

                            Solver.Offline ->
                                Task.throw (Exit.InstallUnknownPackageOffline pkg suggestions)

                    Ok (Registry.KnownVersions _ _) ->
                        let
                            old : Dict Pkg.Name C.Constraint
                            old =
                                Dict.union pkgData.deps pkgData.testDeps

                            cons : Dict Pkg.Name C.Constraint
                            cons =
                                Dict.insert pkg C.anything old
                        in
                        Task.io (Solver.verify env.cache env.connection env.registry cons)
                            |> Task.andThen
                                (\result ->
                                    case result of
                                        Solver.SolverOk solution ->
                                            let
                                                (Solver.Details vsn _) =
                                                    Utils.dictFind pkg solution

                                                con : C.Constraint
                                                con =
                                                    C.untilNextMajor vsn

                                                new : Dict Pkg.Name C.Constraint
                                                new =
                                                    Dict.insert pkg con old

                                                changes : Dict Pkg.Name (Change C.Constraint)
                                                changes =
                                                    detectChanges old new

                                                news : Dict Pkg.Name C.Constraint
                                                news =
                                                    Utils.dictMapMaybe keepNew changes
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


{-| Returns `old` with each of its entries replaced by the one `new` has for the
same name, and with the entry `new` has for `pkg` added when `old` lacks it.

Other names that only `new` has are not added.

-}
addNews : Maybe Pkg.Name -> Dict Pkg.Name C.Constraint -> Dict Pkg.Name C.Constraint -> Dict Pkg.Name C.Constraint
addNews pkg new old =
    Dict.merge
        Dict.insert
        (\k _ n -> Dict.insert k n)
        (\k c acc ->
            if Just k == pkg then
                Dict.insert k c acc

            else
                acc
        )
        old
        new
        Dict.empty



-- ====== CHANGES ======


{-| What happened to one dependency's entry between two versions of a set of
dependencies. `Insert` is a name only the new set has, `Change` a name both
have with different values, and `Remove` a name only the old set has. `Insert`
and `Change` carry the entry's new value.
-}
type Change a
    = Insert a
    | Change a
    | Remove


{-| Returns, for each name whose entry differs between `old` and `new`, how it
changed. Names whose entry is the same in both are left out.
-}
detectChanges : Dict Pkg.Name a -> Dict Pkg.Name a -> Dict Pkg.Name (Change a)
detectChanges old new =
    Dict.merge
        (\k _ -> Dict.insert k Remove)
        (\k oldElem newElem acc ->
            case keepChange oldElem newElem of
                Just change ->
                    Dict.insert k change acc

                Nothing ->
                    acc
        )
        (\k v -> Dict.insert k (Insert v))
        old
        new
        Dict.empty


{-| Returns a `Change` to `new`, or `Nothing` when it equals `old`.
-}
keepChange : v -> v -> Maybe (Change v)
keepChange old new =
    if old == new then
        Nothing

    else
        Just (Change new)


{-| Returns the new value an entry has after `change`, or `Nothing` if it was
removed.
-}
keepNew : Change a -> Maybe a
keepNew change =
    case change of
        Insert a ->
            Just a

        Change a ->
            Just a

        Remove ->
            Nothing
