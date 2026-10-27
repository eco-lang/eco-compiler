module Terminal.Bump exposing (run)

{-| The `bump` command, which sets the version in a package's `elm.json` to the
one its API changes call for.

A package's version follows its API: how far the version must rise (MAJOR,
MINOR or PATCH) is decided by how the exposed API changed, by the rules of
`Builder.Deps.Diff`. The command therefore compares the API the package has
now with the documentation published for the version named in `elm.json`, and
asks before writing the version that the difference requires.

The command works only on a package, and the registry is always refreshed from
the package server first, so it needs network access. What happens next depends
on whether the registry knows the package.

A package the registry knows must name in `elm.json` a version that a new
release may be bumped from, as `Builder.Deps.Bump.getPossibilities` lists them.
Any other version fails with the list of those that are allowed. Otherwise the
published documentation of that version is fetched, the package's exposed
modules are built here to produce their documentation, and `Builder.Deps.Diff`
compares the two and gives the new version.

A package the registry does not know has never been published, and its version
is expected to be 1.0.0. When it is not, the command offers to set it to 1.0.0;
declining leaves the version unchanged and the command still succeeds.

In both cases the version is written only when the user answers yes, and an
empty answer counts as yes.


# Command Entry

@docs run

-}

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Bump as Bump
import Builder.Deps.Diff as Diff
import Builder.Deps.Registry as Registry
import Builder.Eco.FEStats as FEStats
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.Http as Http
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Builder.Stuff as Stuff
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Magnitude as M
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Prelude
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| Runs the command in the current directory's project, reporting any failure
with `Exit.bumpToReport`.
-}
run : () -> () -> Task Never ()
run () () =
    Task.run (Task.andThen bump getEnv) |> Reporting.attempt Exit.bumpToReport



-- ====== ENV ======


{-| Everything the command works with: the project root, the package cache, the
HTTP manager, the freshly refreshed registry, and the package's `elm.json`.
-}
type alias EnvData =
    { root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , registry : Registry.Registry
    , outline : Outline.PkgOutline
    }


{-| The command's environment, as `getEnv` assembles it. Holding one means the
project is a package.
-}
type Env
    = Env EnvData


{-| The part of the environment gathered before the registry is read.
-}
type alias EnvSetup =
    { root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    }


{-| Assembles the environment, failing when there is no project, the registry
cannot be refreshed, `elm.json` cannot be read, or the project is an
application.
-}
getEnv : Task Exit.Bump Env
getEnv =
    Task.io Stuff.findRoot
        |> Task.andThen requireRoot
        |> Task.andThen addPackageCache
        |> Task.andThen addHttpManager
        |> Task.andThen addRegistry
        |> Task.andThen readAndValidateOutline


{-| Returns the project root, failing with `BumpNoOutline` when no `elm.json`
was found.
-}
requireRoot : Maybe FilePath -> Task Exit.Bump FilePath
requireRoot maybeRoot =
    case maybeRoot of
        Nothing ->
            Task.throw Exit.BumpNoOutline

        Just root ->
            Task.succeed root


{-| Pairs `root` with the package cache, whose locally linked packages are the
bundled packages found next to the executable.
-}
addPackageCache : FilePath -> Task Exit.Bump ( FilePath, Stuff.PackageCache )
addPackageCache root =
    Task.io (Stuff.resolveBundledPackages [] |> Task.andThen Stuff.getPackageCache)
        |> Task.map (\cache -> ( root, cache ))


{-| Adds an HTTP manager to the root and package cache.
-}
addHttpManager : ( FilePath, Stuff.PackageCache ) -> Task Exit.Bump EnvSetup
addHttpManager ( root, cache ) =
    Task.io Http.getManager
        |> Task.map (\manager -> EnvSetup root cache manager)


{-| Pairs `setup` with the registry, refreshed from the package server whatever
the age of the cached copy. A failed refresh fails the command.
-}
addRegistry : EnvSetup -> Task Exit.Bump ( EnvSetup, Registry.Registry )
addRegistry setup =
    Task.eio Exit.BumpMustHaveLatestRegistry (Registry.latest setup.manager setup.cache Registry.ForceRefresh)
        |> Task.map (\registry -> ( setup, registry ))


{-| Reads the project's `elm.json` and builds the environment from it.
-}
readAndValidateOutline : ( EnvSetup, Registry.Registry ) -> Task Exit.Bump Env
readAndValidateOutline ( setup, registry ) =
    Task.eio Exit.BumpBadOutline (Outline.read setup.root)
        |> Task.andThen (validateOutline setup registry)


{-| Builds the environment from a package's `outline`, failing with
`BumpApplication` for an application.
-}
validateOutline : EnvSetup -> Registry.Registry -> Outline.Outline -> Task Exit.Bump Env
validateOutline setup registry outline =
    case outline of
        Outline.App _ ->
            Task.throw Exit.BumpApplication

        Outline.Pkg pkgOutline ->
            Task.succeed (Env { root = setup.root, cache = setup.cache, manager = setup.manager, registry = registry, outline = pkgOutline })



-- ====== BUMP ======


{-| Checks the package's version against the registry and continues with the
path for a published or an unpublished package.

A published package whose version is not one a release may be bumped from fails
with those versions, sorted and without repeats.

-}
bump : Env -> Task Exit.Bump ()
bump ((Env envData) as env) =
    let
        (Outline.PkgOutline pkgData) =
            envData.outline
    in
    case Registry.getVersions pkgData.name envData.registry of
        Just knownVersions ->
            let
                bumpableVersions : List V.Version
                bumpableVersions =
                    List.map (\( old, _, _ ) -> old) (Bump.getPossibilities knownVersions)
            in
            if List.member pkgData.version bumpableVersions then
                suggestVersion env

            else
                List.map Prelude.head (Utils.listGroupBy (==) (List.sortWith V.compare bumpableVersions)) |> Exit.BumpUnexpectedVersion pkgData.version |> Task.throw

        Nothing ->
            checkNewPackage envData.root envData.outline |> Task.io



-- ====== CHECK NEW PACKAGE ======


{-| Announces that the package is unpublished and checks that its version is
1.0.0.
-}
checkNewPackage : FilePath -> Outline.PkgOutline -> Task Never ()
checkNewPackage root ((Outline.PkgOutline pkgData) as outline) =
    IO.printLn "This package has not been published before. Let me verify the version number."
        |> Task.andThen (\_ -> validateNewPackageVersion root outline pkgData.version)


{-| Confirms `version` when it is 1.0.0, and otherwise asks whether to set the
version in `elm.json` to 1.0.0.
-}
validateNewPackageVersion : FilePath -> Outline.PkgOutline -> V.Version -> Task Never ()
validateNewPackageVersion root outline version =
    if version == V.one then
        IO.printLn "The version number in elm.json is correct so you are all set!"

    else
        let
            question =
                D.fromChars "It looks like the version in elm.json has been changed though!\nWould you like me to change it back to "
                    |> D.a (D.fromVersion V.one)
                    |> D.a (D.fromChars "? [Y/n] ")
        in
        changeVersion root outline V.one question



-- ====== SUGGEST VERSION ======


{-| What is known about the published version while the new documentation is
being built: `oldVersion` is the version in `elm.json`, and `oldDocs` is the
documentation published for it.
-}
type alias VersionSuggestion =
    { root : FilePath
    , outline : Outline.PkgOutline
    , oldVersion : V.Version
    , oldDocs : Docs.Documentation
    }


{-| Fetches the documentation published for the package's current version,
builds the documentation of the package as it is now, and offers the version
their difference calls for.
-}
suggestVersion : Env -> Task Exit.Bump ()
suggestVersion (Env envData) =
    let
        (Outline.PkgOutline pkgData) =
            envData.outline
    in
    Task.eio (Exit.BumpCannotFindDocs pkgData.version) (Diff.getDocs envData.cache envData.manager pkgData.name pkgData.version)
        |> Task.andThen (initVersionSuggestion envData.root envData.outline pkgData.version)
        |> Task.andThen addNewDocs
        |> Task.andThen promptVersionChange


{-| Collects its arguments into a `VersionSuggestion`.
-}
initVersionSuggestion : FilePath -> Outline.PkgOutline -> V.Version -> Docs.Documentation -> Task Exit.Bump VersionSuggestion
initVersionSuggestion root outline vsn oldDocs =
    Task.succeed (VersionSuggestion root outline vsn oldDocs)


{-| Pairs `suggestion` with the documentation of the package as it is now.
-}
addNewDocs : VersionSuggestion -> Task Exit.Bump ( VersionSuggestion, Docs.Documentation )
addNewDocs suggestion =
    generateDocs suggestion.root suggestion.outline
        |> Task.map (\newDocs -> ( suggestion, newDocs ))


{-| Shows the magnitude of the API change and the version it leads to, and
asks whether to write that version to `elm.json`.
-}
promptVersionChange : ( VersionSuggestion, Docs.Documentation ) -> Task Exit.Bump ()
promptVersionChange ( suggestion, newDocs ) =
    let
        changes : Diff.PackageChanges
        changes =
            Diff.diff suggestion.oldDocs newDocs

        newVersion : V.Version
        newVersion =
            Diff.bump changes suggestion.oldVersion

        old : D.Doc
        old =
            D.fromVersion suggestion.oldVersion

        new : D.Doc
        new =
            D.fromVersion newVersion

        mag : D.Doc
        mag =
            M.toChars (Diff.toMagnitude changes) |> D.fromChars

        question : D.Doc
        question =
            D.fromChars "Based on your new API, this should be a"
                |> D.plus (D.green mag)
                |> D.plus (D.fromChars "change (")
                |> D.a old
                |> D.a (D.fromChars " => ")
                |> D.a new
                |> D.a (D.fromChars ")\n")
                |> D.a (D.fromChars "Bail out of this command and run 'elm diff' for a full explanation.\n")
                |> D.a (D.fromChars "\n")
                |> D.a (D.fromChars "Should I perform the update (")
                |> D.a old
                |> D.a (D.fromChars " => ")
                |> D.a new
                |> D.a (D.fromChars ") in elm.json? [Y/n] ")
    in
    Task.io (changeVersion suggestion.root suggestion.outline newVersion question)


{-| Builds the documentation of the package's exposed modules.

The project details are loaded first, for a JavaScript rather than a typed
build and with no configuration hash, so this may solve and build the package's
dependencies.

-}
generateDocs : FilePath -> Outline.PkgOutline -> Task Exit.Bump Docs.Documentation
generateDocs root (Outline.PkgOutline pkgData) =
    Task.eio Exit.BumpBadDetails (BW.withScope (\scope -> Stuff.resolveBundledPackages [] |> Task.andThen (\locals -> Details.load Reporting.silent scope root Nothing Nothing False False locals Registry.Normal)))
        |> Task.andThen (buildDocsFromExposed root pkgData.exposed)


{-| Builds the modules named in `exposed` and returns their documentation,
failing with `BumpNoExposed` when no module is exposed.
-}
buildDocsFromExposed : FilePath -> Outline.Exposed -> Details.Details -> Task Exit.Bump Docs.Documentation
buildDocsFromExposed root exposed details =
    case Outline.flattenExposed exposed of
        [] ->
            Task.throw Exit.BumpNoExposed

        e :: es ->
            Build.fromExposed Reporting.silent root Nothing Nothing details Build.keepDocs FEStats.disabled (NE.Nonempty e es) |> Task.eio Exit.BumpBadBuild



-- ====== CHANGE VERSION ======


{-| Asks `question` and, on a yes, writes `targetVersion` into `elm.json` at
`root`.
-}
changeVersion : FilePath -> Outline.PkgOutline -> V.Version -> D.Doc -> Task Never ()
changeVersion root outline targetVersion question =
    Reporting.ask question
        |> Task.andThen (applyVersionChange root outline targetVersion)


{-| Writes `targetVersion` and reports it when `approved`, and otherwise says
that nothing changed.
-}
applyVersionChange : FilePath -> Outline.PkgOutline -> V.Version -> Bool -> Task Never ()
applyVersionChange root outline targetVersion approved =
    if not approved then
        IO.printLn "Okay, I did not change anything!"

    else
        writeNewOutline root outline targetVersion
            |> Task.andThen (\_ -> confirmVersionChange targetVersion)


{-| Writes `elm.json` at `root` as `outline` with its version replaced by
`targetVersion`.
-}
writeNewOutline : FilePath -> Outline.PkgOutline -> V.Version -> Task Never ()
writeNewOutline root (Outline.PkgOutline pkgData) targetVersion =
    Outline.write root
        (Outline.Pkg
            (Outline.PkgOutline { pkgData | version = targetVersion })
        )


{-| Prints the version that was written.
-}
confirmVersionChange : V.Version -> Task Never ()
confirmVersionChange targetVersion =
    Help.toStdout
        (D.fromChars "Version changed to "
            |> D.a (D.green (D.fromVersion targetVersion))
            |> D.a (D.fromChars "!\n")
        )
