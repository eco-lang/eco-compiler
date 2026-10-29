module Terminal.Install exposing
    ( run
    , Args(..), Flags(..)
    )

{-| The `install` command: it adds one package to the project's `elm.json`,
as a dependency or, with `--test`, as a test dependency. Unless `--yes` was
given, it first shows the user what will change and asks for approval; with
`--yes` the change is applied without being shown.

An `elm.json` describes either an application or a package, and the two record
dependencies differently. An application lists exact versions, split into
direct and indirect dependencies, and the same again for tests. A package lists
version constraints on its direct dependencies and its test dependencies only.
So every step that builds a plan comes in an application form and a package
form, and the plan type `Changes` is parameterised by what an entry holds: a
version or a constraint.

A plan is one of three things. The package may already be installed, in which
case nothing happens. It may be recorded somewhere else in `elm.json`, as an
indirect dependency or a test dependency, and is then _promoted_: moved into
the field that was asked for, at the version or constraint already recorded,
without consulting the solver. Otherwise the solver
(`Builder.Deps.Solver`) chooses versions, and the plan lists every package
whose entry is added, changed or removed.

Once the user approves, or `--yes` was given, the new `elm.json` is written and
`Builder.Elm.Details.verifyInstall` checks that the project's dependencies can
be built. If they cannot, the old `elm.json` is written back and the error is
reported.


# Command Entry

@docs run


# Configuration Types

@docs Args, Flags

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
import Compiler.Elm.Licenses as Licenses
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Dict exposing (Dict)
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| The positional argument of the `install` command.

`NoArgs` is the command given no package. It installs nothing and is reported
as an error that shows example `install` commands.

`Install` names the package to add.

-}
type Args
    = NoArgs
    | Install Pkg.Name


{-| The flags of the `install` command, in order: `--test`, which installs
the package as a test dependency; `--yes`, which approves the plan without
asking; and `--refresh-registry`, which makes the registry be refreshed even
when the cached copy would otherwise be used as it is.
-}
type Flags
    = Flags Bool Bool Bool


{-| Performs the `install` command in the project that contains the current
directory: plans the change to its `elm.json`, asks for approval unless `--yes`
was given, writes the new `elm.json` and checks that its dependencies build.

Declining the plan changes nothing and is not an error. Any failure, including
running outside a project, is reported on standard error and the program exits
with failure, as `Builder.Reporting.attempt` does.

-}
run : Args -> Flags -> Task Never ()
run args (Flags forTest autoYes refreshRegistry) =
    let
        registryPolicy =
            if refreshRegistry then
                Registry.ForceRefresh

            else
                Registry.Normal
    in
    Reporting.attempt Exit.installToReport
        (Stuff.findRoot
            |> Task.andThen (handleRoot args forTest autoYes registryPolicy)
        )


{-| Returns the outcome of the command in the project at the root found, or
the error for having no `elm.json` when no root was found.
-}
handleRoot : Args -> Bool -> Bool -> Registry.RegistryPolicy -> Maybe FilePath -> Task Never (Result Exit.Install ())
handleRoot args forTest autoYes registryPolicy maybeRoot =
    case maybeRoot of
        Nothing ->
            Task.succeed (Err Exit.InstallNoOutline)

        Just root ->
            handleArgs root args forTest autoYes registryPolicy


{-| Returns the outcome of the command for `args` in the project at `root`.
With no package named, the result is the usage error, which carries the
Elm home directory (`Builder.Stuff.getElmHome`) for the message to show.
-}
handleArgs : FilePath -> Args -> Bool -> Bool -> Registry.RegistryPolicy -> Task Never (Result Exit.Install ())
handleArgs root args forTest autoYes registryPolicy =
    case args of
        NoArgs ->
            Stuff.getElmHome
                |> Task.map (\elmHome -> Err (Exit.InstallNoArgs elmHome))

        Install pkg ->
            Task.run (installPackage root pkg forTest autoYes registryPolicy)


{-| Builds the solver environment, with the bundled packages that are found
linked in as local packages, and installs `pkg` in the project at `root`.
-}
installPackage : FilePath -> Pkg.Name -> Bool -> Bool -> Registry.RegistryPolicy -> Task Exit.Install ()
installPackage root pkg forTest autoYes registryPolicy =
    Task.eio Exit.InstallBadRegistry (Stuff.resolveBundledPackages [] |> Task.andThen (Solver.initEnv registryPolicy))
        |> Task.andThen (installWithEnv root pkg forTest autoYes)


{-| Reads the `elm.json` at `root` and installs `pkg` in it.
-}
installWithEnv : FilePath -> Pkg.Name -> Bool -> Bool -> Solver.Env -> Task Exit.Install ()
installWithEnv root pkg forTest autoYes env =
    Task.eio Exit.InstallBadOutline (Outline.read root)
        |> Task.andThen (installWithOutline root pkg forTest autoYes env)


{-| Plans the installation of `pkg` into `oldOutline` and carries the plan
out, showing application entries as versions and package entries as
constraints.
-}
installWithOutline : FilePath -> Pkg.Name -> Bool -> Bool -> Solver.Env -> Outline.Outline -> Task Exit.Install ()
installWithOutline root pkg forTest autoYes env oldOutline =
    case oldOutline of
        Outline.App outline ->
            makeAppPlan env pkg outline forTest
                |> Task.andThen (\changes -> attemptChanges root env oldOutline V.toChars changes autoYes)

        Outline.Pkg outline ->
            makePkgPlan env pkg outline forTest
                |> Task.andThen (\changes -> attemptChanges root env oldOutline C.toChars changes autoYes)



-- ====== ATTEMPT CHANGES ======


{-| A plan for one installation, generic in what an `elm.json` entry holds: a
version for an application, a constraint for a package.

`AlreadyInstalled` is the package already present in the field asked for.

`PromoteTest` and `PromoteIndirect` carry the new outline in which a package
already present elsewhere has been moved, at its recorded version or
constraint. `PromoteIndirect` is a move from an application's indirect
dependencies to its direct ones. `PromoteTest` is any other move: from a test
field into the regular dependencies, or, for an application installed with
`--test`, from the indirect test dependencies to the direct ones.

`Changes` carries the solver's plan, every package whose entry is added,
changed or removed, together with the new outline.

-}
type Changes vsn
    = AlreadyInstalled
    | PromoteTest Outline.Outline
    | PromoteIndirect Outline.Outline
    | Changes (Dict Pkg.Name (Change vsn)) Outline.Outline


{-| Carries out `changes` in the project at `root`: reports that there is
nothing to do, or asks the question that fits the plan and applies it. For a
solver plan the question lists the packages to add, change and remove, each
entry printed by `toChars`; it is shown only when the question is asked.
-}
attemptChanges : String -> Solver.Env -> Outline.Outline -> (a -> String) -> Changes a -> Bool -> Task Exit.Install ()
attemptChanges root env oldOutline toChars changes autoYes =
    case changes of
        AlreadyInstalled ->
            Task.io (IO.printLn "It is already installed!")

        PromoteIndirect newOutline ->
            attemptChangesHelp root env oldOutline newOutline autoYes <|
                D.vcat
                    [ D.fillSep
                        [ D.fromChars "I"
                        , D.fromChars "found"
                        , D.fromChars "it"
                        , D.fromChars "in"
                        , D.fromChars "your"
                        , D.fromChars "elm.json"
                        , D.fromChars "file,"
                        , D.fromChars "but"
                        , D.fromChars "in"
                        , D.fromChars "the"
                        , D.dullyellow (D.fromChars "\"indirect\"")
                        , D.fromChars "dependencies."
                        ]
                    , D.fillSep
                        [ D.fromChars "Should"
                        , D.fromChars "I"
                        , D.fromChars "move"
                        , D.fromChars "it"
                        , D.fromChars "into"
                        , D.green (D.fromChars "\"direct\"")
                        , D.fromChars "dependencies"
                        , D.fromChars "for"
                        , D.fromChars "more"
                        , D.fromChars "general"
                        , D.fromChars "use?"
                        , D.fromChars "[Y/n]: "
                        ]
                    ]

        PromoteTest newOutline ->
            attemptChangesHelp root env oldOutline newOutline autoYes <|
                D.vcat
                    [ D.fillSep
                        [ D.fromChars "I"
                        , D.fromChars "found"
                        , D.fromChars "it"
                        , D.fromChars "in"
                        , D.fromChars "your"
                        , D.fromChars "elm.json"
                        , D.fromChars "file,"
                        , D.fromChars "but"
                        , D.fromChars "in"
                        , D.fromChars "the"
                        , D.dullyellow (D.fromChars "\"test-dependencies\"")
                        , D.fromChars "field."
                        ]
                    , D.fillSep
                        [ D.fromChars "Should"
                        , D.fromChars "I"
                        , D.fromChars "move"
                        , D.fromChars "it"
                        , D.fromChars "into"
                        , D.green (D.fromChars "\"dependencies\"")
                        , D.fromChars "for"
                        , D.fromChars "more"
                        , D.fromChars "general"
                        , D.fromChars "use?"
                        , D.fromChars "[Y/n]: "
                        ]
                    ]

        Changes changeDict newOutline ->
            let
                widths : Widths
                widths =
                    Dict.foldr (widen toChars) (Widths 0 0 0) changeDict

                changeDocs : ChangeDocs
                changeDocs =
                    Dict.foldr (addChange toChars widths) (Docs [] [] []) changeDict
            in
            attemptChangesHelp root env oldOutline newOutline autoYes <|
                D.vcat
                    [ D.fromChars "Here is my plan:"
                    , viewChangeDocs changeDocs
                    , D.fromChars ""
                    , D.fromChars "Would you like me to update your elm.json accordingly? [Y/n]: "
                    ]


{-| Asks `question` unless `autoYes`, and on approval writes `newOutline`,
verifies the project's dependencies and restores `oldOutline` if that fails.
-}
attemptChangesHelp : FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> D.Doc -> Task Exit.Install ()
attemptChangesHelp root env oldOutline newOutline autoYes question =
    Task.eio Exit.InstallBadDetails <|
        BW.withScope
            (\scope ->
                askInstallQuestion autoYes question
                    |> Task.andThen (applyInstallChanges scope root env oldOutline newOutline)
            )


{-| Returns whether the plan is approved: `True` straight away when `autoYes`,
otherwise the user's answer to `question`.
-}
askInstallQuestion : Bool -> D.Doc -> Task Never Bool
askInstallQuestion autoYes question =
    if autoYes then
        Task.succeed True

    else
        Reporting.ask question


{-| Writes `newOutline` and verifies the project's dependencies if `approved`,
restoring `oldOutline` when verification fails. When not approved, prints that
nothing was changed and succeeds.
-}
applyInstallChanges : BW.Scope -> FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> Task Never (Result Exit.Details ())
applyInstallChanges scope root env oldOutline newOutline approved =
    if approved then
        Outline.write root newOutline
            |> Task.andThen (\_ -> Details.verifyInstall scope root env newOutline)
            |> Task.andThen (handleInstallResult root oldOutline)

    else
        IO.printLn "Okay, I did not change anything!"
            |> Task.map (\_ -> Ok ())


{-| Finishes an installation given the result of verifying it: prints success,
or writes `oldOutline` back to `root` and returns the error.
-}
handleInstallResult : FilePath -> Outline.Outline -> Result Exit.Details () -> Task Never (Result Exit.Details ())
handleInstallResult root oldOutline result =
    case result of
        Err exit ->
            Outline.write root oldOutline
                |> Task.map (\_ -> Err exit)

        Ok () ->
            IO.printLn "Success!"
                |> Task.map (\_ -> Ok ())



-- ====== MAKE APP PLAN ======


{-| Plans the installation of `pkg` into an application, as a test dependency
when `forTest` is true.
-}
makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Bool -> Task Exit.Install (Changes V.Version)
makeAppPlan (Solver.Env env) pkg ((Outline.AppOutline appData) as outline) forTest =
    if forTest then
        makeAppPlanForTest env.cache env.connection env.registry pkg appData outline

    else
        makeAppPlanForDeps env.cache env.connection env.registry pkg appData outline


{-| Plans the installation of `pkg` as a direct test dependency of an
application. A package among the direct test dependencies is already
installed, and one among the indirect test dependencies is promoted.
Anything else, including a package that is a regular dependency, goes to the
solver.
-}
makeAppPlanForTest :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> Outline.AppOutlineData
    -> Outline.AppOutline
    -> Task Exit.Install (Changes V.Version)
makeAppPlanForTest cache connection registry pkg appData outline =
    if Dict.member pkg appData.testDirect then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg appData.testIndirect of
            Just vsn ->
                Outline.AppOutline
                    { appData
                        | testDirect = Dict.insert pkg vsn appData.testDirect
                        , testIndirect = Dict.remove pkg appData.testIndirect
                    }
                    |> Outline.App
                    |> PromoteTest
                    |> Task.succeed

            Nothing ->
                addAppPackageFromScratch cache connection registry pkg outline True


{-| Plans the installation of `pkg` as a direct dependency of an application.
A package among the direct dependencies is already installed. One found among
the indirect dependencies, the direct test dependencies or the indirect test
dependencies, checked in that order, is promoted. Anything else goes to the
solver.
-}
makeAppPlanForDeps :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> Outline.AppOutlineData
    -> Outline.AppOutline
    -> Task Exit.Install (Changes V.Version)
makeAppPlanForDeps cache connection registry pkg appData outline =
    if Dict.member pkg appData.depsDirect then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg appData.depsIndirect of
            Just vsn ->
                Outline.AppOutline
                    { appData
                        | depsDirect = Dict.insert pkg vsn appData.depsDirect
                        , depsIndirect = Dict.remove pkg appData.depsIndirect
                    }
                    |> Outline.App
                    |> PromoteIndirect
                    |> Task.succeed

            Nothing ->
                case Dict.get pkg appData.testDirect of
                    Just vsn ->
                        Outline.AppOutline
                            { appData
                                | depsDirect = Dict.insert pkg vsn appData.depsDirect
                                , testDirect = Dict.remove pkg appData.testDirect
                            }
                            |> Outline.App
                            |> PromoteTest
                            |> Task.succeed

                    Nothing ->
                        case Dict.get pkg appData.testIndirect of
                            Just vsn ->
                                Outline.AppOutline
                                    { appData
                                        | depsDirect = Dict.insert pkg vsn appData.depsDirect
                                        , testIndirect = Dict.remove pkg appData.testIndirect
                                    }
                                    |> Outline.App
                                    |> PromoteTest
                                    |> Task.succeed

                            Nothing ->
                                addAppPackageFromScratch cache connection registry pkg outline False


{-| Plans the installation of `pkg` into an application with the solver, as
`Builder.Deps.Solver.addToApp` chooses versions, after checking that the
package is known.
-}
addAppPackageFromScratch :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> Outline.AppOutline
    -> Bool
    -> Task Exit.Install (Changes V.Version)
addAppPackageFromScratch cache connection registry pkg outline forTest =
    checkPackageKnown cache connection registry pkg
        |> Task.andThen (\_ -> Task.io (Solver.addToApp cache connection registry pkg outline forTest))
        |> Task.andThen (handleAppSolverResult pkg)


{-| Turns the solver's answer for an application into a plan listing every
dependency whose version is added, changed or removed, or into the matching
installation error.
-}
handleAppSolverResult : Pkg.Name -> Solver.SolverResult Solver.AppSolution -> Task Exit.Install (Changes V.Version)
handleAppSolverResult pkg result =
    case result of
        Solver.SolverOk (Solver.AppSolution old new app) ->
            Task.succeed (Changes (detectChanges old new) (Outline.App app))

        Solver.NoSolution ->
            Task.throw (Exit.InstallNoOnlineAppSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.InstallNoOfflineAppSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.InstallHadSolverTrouble exit)


{-| Fails with an unknown-package error, carrying the registry's suggestions,
unless `pkg` is a locally linked package of `cache` or is in `registry`.

The bundled packages that `Builder.Stuff.resolveBundledPackages` finds are
linked in as local packages, which is how they pass this check without being in
the registry.

-}
checkPackageKnown : Stuff.PackageCache -> Solver.Connection -> Registry.Registry -> Pkg.Name -> Task Exit.Install ()
checkPackageKnown cache connection registry pkg =
    if Stuff.isLocalPackage cache pkg then
        Task.succeed ()

    else
        case Registry.getVersions_ pkg registry of
            Err suggestions ->
                throwUnknownPackageError connection pkg suggestions

            Ok _ ->
                Task.succeed ()


{-| Fails with the unknown-package error for `pkg` that matches the connection,
online or offline, carrying `suggestions` of similar names.
-}
throwUnknownPackageError : Solver.Connection -> Pkg.Name -> List Pkg.Name -> Task Exit.Install a
throwUnknownPackageError connection pkg suggestions =
    case connection of
        Solver.Online _ ->
            Task.throw (Exit.InstallUnknownPackageOnline pkg suggestions)

        Solver.Offline ->
            Task.throw (Exit.InstallUnknownPackageOffline pkg suggestions)



-- ====== MAKE PACKAGE PLAN ======


{-| The fields of a package's `elm.json`, under the names this module uses.
`deps` and `test` are the constraints on the regular and the test
dependencies, and `elmVersion` is the constraint on the compiler version.
-}
type alias PkgOutlineInfo =
    { name : Pkg.Name
    , summary : String
    , license : Licenses.License
    , version : V.Version
    , exposed : Outline.Exposed
    , deps : Dict Pkg.Name C.Constraint
    , test : Dict Pkg.Name C.Constraint
    , elmVersion : C.Constraint
    }


{-| Plans the installation of `pkg` into a package, as a test dependency when
`forTest` is true.
-}
makePkgPlan : Solver.Env -> Pkg.Name -> Outline.PkgOutline -> Bool -> Task Exit.Install (Changes C.Constraint)
makePkgPlan (Solver.Env env) pkg (Outline.PkgOutline pkgData) forTest =
    let
        info =
            PkgOutlineInfo pkgData.name pkgData.summary pkgData.license pkgData.version pkgData.exposed pkgData.deps pkgData.testDeps pkgData.elm
    in
    if forTest then
        makePkgPlanForTest env.cache env.connection env.registry pkg info

    else
        makePkgPlanForDeps env.cache env.connection env.registry pkg info


{-| Plans the installation of `pkg` as a test dependency of a package. A package
already among the test dependencies is already installed. Otherwise the solver
is asked to satisfy the current test dependency constraints with `pkg` added at
any version; the regular dependencies take no part in that solve.
-}
makePkgPlanForTest :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> PkgOutlineInfo
    -> Task Exit.Install (Changes C.Constraint)
makePkgPlanForTest cache connection registry pkg info =
    if Dict.member pkg info.test then
        Task.succeed AlreadyInstalled

    else
        let
            cons =
                Dict.insert pkg C.anything info.test
        in
        checkPackageKnown cache connection registry pkg
            |> Task.andThen (\_ -> Task.io (Solver.verify cache connection registry cons))
            |> Task.andThen (handlePkgTestSolverResult pkg info)


{-| Turns the solver's answer into a plan that adds `pkg` to the test
dependencies, constrained from its solved version up to the next major
version, or into the matching installation error.
-}
handlePkgTestSolverResult :
    Pkg.Name
    -> PkgOutlineInfo
    -> Solver.SolverResult (Dict Pkg.Name Solver.Details)
    -> Task Exit.Install (Changes C.Constraint)
handlePkgTestSolverResult pkg info result =
    case result of
        Solver.SolverOk solution ->
            let
                (Solver.Details vsn _) =
                    Utils.dictFind pkg solution

                con =
                    C.untilNextMajor vsn

                newTest =
                    Dict.insert pkg con info.test

                changes =
                    detectChanges info.test newTest

                news =
                    Utils.dictMapMaybe keepNew changes
            in
            Outline.PkgOutline
                { name = info.name
                , summary = info.summary
                , license = info.license
                , version = info.version
                , exposed = info.exposed
                , deps = info.deps
                , testDeps = addNews (Just pkg) news info.test
                , elm = info.elmVersion
                }
                |> Outline.Pkg
                |> Changes changes
                |> Task.succeed

        Solver.NoSolution ->
            Task.throw (Exit.InstallNoOnlinePkgSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.InstallNoOfflinePkgSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.InstallHadSolverTrouble exit)


{-| Plans the installation of `pkg` as a dependency of a package. A package
already among the dependencies is already installed, and one among the test
dependencies is promoted with its constraint. Anything else goes to the solver.
-}
makePkgPlanForDeps :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> PkgOutlineInfo
    -> Task Exit.Install (Changes C.Constraint)
makePkgPlanForDeps cache connection registry pkg info =
    if Dict.member pkg info.deps then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg info.test of
            Just con ->
                Outline.PkgOutline
                    { name = info.name
                    , summary = info.summary
                    , license = info.license
                    , version = info.version
                    , exposed = info.exposed
                    , deps = Dict.insert pkg con info.deps
                    , testDeps = Dict.remove pkg info.test
                    , elm = info.elmVersion
                    }
                    |> Outline.Pkg
                    |> PromoteTest
                    |> Task.succeed

            Nothing ->
                addPkgDependencyFromScratch cache connection registry pkg info


{-| Plans the installation of `pkg` as a dependency of a package by asking the
solver to satisfy every current constraint, regular and test, with `pkg` added
at any version. Where a package has both, the regular constraint is the one
used.
-}
addPkgDependencyFromScratch :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> PkgOutlineInfo
    -> Task Exit.Install (Changes C.Constraint)
addPkgDependencyFromScratch cache connection registry pkg info =
    let
        old =
            Dict.union info.deps info.test

        cons =
            Dict.insert pkg C.anything old
    in
    checkPackageKnown cache connection registry pkg
        |> Task.andThen (\_ -> Task.io (Solver.verify cache connection registry cons))
        |> Task.andThen (handlePkgDepsSolverResult pkg info old)


{-| Turns the solver's answer into a plan that adds `pkg` to the dependencies,
constrained from its solved version up to the next major version, or into the
matching installation error. `old` is the constraints the solve started from.
Only `pkg` is added to the dependencies; existing dependency and
test-dependency constraints are unchanged.
-}
handlePkgDepsSolverResult :
    Pkg.Name
    -> PkgOutlineInfo
    -> Dict Pkg.Name C.Constraint
    -> Solver.SolverResult (Dict Pkg.Name Solver.Details)
    -> Task Exit.Install (Changes C.Constraint)
handlePkgDepsSolverResult pkg info old result =
    case result of
        Solver.SolverOk solution ->
            let
                (Solver.Details vsn _) =
                    Utils.dictFind pkg solution

                con =
                    C.untilNextMajor vsn

                new =
                    Dict.insert pkg con old

                changes =
                    detectChanges old new

                news =
                    Utils.dictMapMaybe keepNew changes
            in
            Outline.PkgOutline
                { name = info.name
                , summary = info.summary
                , license = info.license
                , version = info.version
                , exposed = info.exposed
                , deps = addNews (Just pkg) news info.deps
                , testDeps = addNews Nothing news info.test
                , elm = info.elmVersion
                }
                |> Outline.Pkg
                |> Changes changes
                |> Task.succeed

        Solver.NoSolution ->
            Task.throw (Exit.InstallNoOnlinePkgSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.InstallNoOfflinePkgSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.InstallHadSolverTrouble exit)


{-| Returns `old` with the entries of `new` applied: an entry in both takes its
value from `new`, and an entry only in `new` is added only when its key is
`pkg`.
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


{-| What a plan does to one package's entry. `Change` carries the old value,
then the new one.
-}
type Change a
    = Insert a
    | Change a a
    | Remove a


{-| Returns, for each key whose entry differs between `old` and `new`, what
happened to it. Keys with equal entries are left out.
-}
detectChanges : Dict Pkg.Name a -> Dict Pkg.Name a -> Dict Pkg.Name (Change a)
detectChanges old new =
    Dict.merge
        (\k v -> Dict.insert k (Remove v))
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


{-| Returns the change from `old` to `new`, or `Nothing` when they are equal.
-}
keepChange : v -> v -> Maybe (Change v)
keepChange old new =
    if old == new then
        Nothing

    else
        Just (Change old new)


{-| Returns the value an entry has after `change`, or `Nothing` when it is
removed.
-}
keepNew : Change a -> Maybe a
keepNew change =
    case change of
        Insert a ->
            Just a

        Change _ a ->
            Just a

        Remove _ ->
            Nothing



-- ====== VIEW CHANGE DOCS ======


{-| The lines of a plan, grouped as the entries to add, to change and to remove,
in that order.
-}
type ChangeDocs
    = Docs (List D.Doc) (List D.Doc) (List D.Doc)


{-| Lays out a plan as its "Add:", "Change:" and "Remove:" sections, each
preceded by a blank line, leaving out a section with no entries.
-}
viewChangeDocs : ChangeDocs -> D.Doc
viewChangeDocs (Docs inserts changes removes) =
    [ viewNonZero "Add:" inserts
    , viewNonZero "Change:" changes
    , viewNonZero "Remove:" removes
    ]
        |> List.concat
        |> D.vcat
        |> D.indent 2


{-| Returns a section headed `title` with `entries` indented beneath it, or
nothing when there are no entries.
-}
viewNonZero : String -> List D.Doc -> List D.Doc
viewNonZero title entries =
    if List.isEmpty entries then
        []

    else
        [ D.fromChars ""
        , D.fromChars title
        , D.indent 2 (D.vcat entries)
        ]



-- ====== VIEW CHANGE ======


{-| Adds the line for one package's change to the matching group of a plan,
before the lines already there.
-}
addChange : (a -> String) -> Widths -> Pkg.Name -> Change a -> ChangeDocs -> ChangeDocs
addChange toChars widths name change (Docs inserts changes removes) =
    case change of
        Insert new ->
            Docs (viewInsert toChars widths name new :: inserts) changes removes

        Change old new ->
            Docs inserts (viewChange toChars widths name old new :: changes) removes

        Remove old ->
            Docs inserts changes (viewRemove toChars widths name old :: removes)


{-| Shows a package to be added, with its new entry.
-}
viewInsert : (a -> String) -> Widths -> Pkg.Name -> a -> D.Doc
viewInsert toChars (Widths nameWidth leftWidth _) name new =
    viewName nameWidth name
        |> D.plus (pad leftWidth (toChars new))


{-| Shows a package whose entry changes, as its old entry, `=>` and its new
entry.
-}
viewChange : (a -> String) -> Widths -> Pkg.Name -> a -> a -> D.Doc
viewChange toChars (Widths nameWidth leftWidth rightWidth) name old new =
    D.hsep
        [ viewName nameWidth name
        , pad leftWidth (toChars old)
        , D.fromChars "=>"
        , pad rightWidth (toChars new)
        ]


{-| Shows a package to be removed, with its old entry.
-}
viewRemove : (a -> String) -> Widths -> Pkg.Name -> a -> D.Doc
viewRemove toChars (Widths nameWidth leftWidth _) name old =
    viewName nameWidth name
        |> D.plus (pad leftWidth (toChars old))


{-| Shows a package name padded with spaces to `width` plus three columns, so the
versions after it line up.
-}
viewName : Int -> Pkg.Name -> D.Doc
viewName width name =
    D.fromChars (String.padRight (width + 3) ' ' (Pkg.toChars name))


{-| Shows `string` right-aligned in a field of `width` columns, by putting
spaces before it.
-}
pad : Int -> String -> D.Doc
pad width string =
    D.fromChars (String.repeat (width - String.length string) " ")
        |> D.a (D.fromChars string)



-- ====== WIDTHS ======


{-| The column widths of a plan, in characters: the longest package name, the
longest entry in the left column (an added entry or an old one), and the
longest new entry of a change.
-}
type Widths
    = Widths Int Int Int


{-| Returns `widths` grown to fit the columns of one package's change, with
entries measured as `toChars` prints them.
-}
widen : (a -> String) -> Pkg.Name -> Change a -> Widths -> Widths
widen toChars pkg change (Widths name left right) =
    let
        toLength : a -> Int
        toLength a =
            String.length (toChars a)

        newName : Int
        newName =
            max name (String.length (Pkg.toChars pkg))
    in
    case change of
        Insert new ->
            Widths newName (max left (toLength new)) right

        Change old new ->
            Widths newName (max left (toLength old)) (max right (toLength new))

        Remove old ->
            Widths newName (max left (toLength old)) right
