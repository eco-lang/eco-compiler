module Terminal.Bump exposing (run)

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Bump as Bump
import Builder.Deps.Diff as Diff
import Builder.Deps.Registry as Registry
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
import System.IO as IO
import Task exposing (Task)
import Utils.Main as Utils exposing (FilePath)
import Utils.Task.Extra as Task



-- RUN


run : () -> () -> Task Never ()
run () () =
    Reporting.attempt Exit.bumpToReport <|
        Task.run (Task.andThen bump getEnv)



-- ENV


type alias EnvData =
    { root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , registry : Registry.Registry
    , outline : Outline.PkgOutline
    }


type Env
    = Env EnvData


type alias EnvSetup =
    { root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    }


getEnv : Task Exit.Bump Env
getEnv =
    Task.io Stuff.findRoot
        |> Task.andThen requireRoot
        |> Task.andThen addPackageCache
        |> Task.andThen addHttpManager
        |> Task.andThen addRegistry
        |> Task.andThen readAndValidateOutline


requireRoot : Maybe FilePath -> Task Exit.Bump FilePath
requireRoot maybeRoot =
    case maybeRoot of
        Nothing ->
            Task.throw Exit.BumpNoOutline

        Just root ->
            Task.succeed root


addPackageCache : FilePath -> Task Exit.Bump ( FilePath, Stuff.PackageCache )
addPackageCache root =
    Task.io Stuff.getPackageCache
        |> Task.map (\cache -> ( root, cache ))


addHttpManager : ( FilePath, Stuff.PackageCache ) -> Task Exit.Bump EnvSetup
addHttpManager ( root, cache ) =
    Task.io Http.getManager
        |> Task.map (\manager -> EnvSetup root cache manager)


addRegistry : EnvSetup -> Task Exit.Bump ( EnvSetup, Registry.Registry )
addRegistry setup =
    Task.eio Exit.BumpMustHaveLatestRegistry (Registry.latest setup.manager setup.cache)
        |> Task.map (\registry -> ( setup, registry ))


readAndValidateOutline : ( EnvSetup, Registry.Registry ) -> Task Exit.Bump Env
readAndValidateOutline ( setup, registry ) =
    Task.eio Exit.BumpBadOutline (Outline.read setup.root)
        |> Task.andThen (validateOutline setup registry)


validateOutline : EnvSetup -> Registry.Registry -> Outline.Outline -> Task Exit.Bump Env
validateOutline setup registry outline =
    case outline of
        Outline.App _ ->
            Task.throw Exit.BumpApplication

        Outline.Pkg pkgOutline ->
            Task.succeed (Env { root = setup.root, cache = setup.cache, manager = setup.manager, registry = registry, outline = pkgOutline })



-- BUMP


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
                Task.throw <|
                    Exit.BumpUnexpectedVersion pkgData.version <|
                        List.map Prelude.head (Utils.listGroupBy (==) (List.sortWith V.compare bumpableVersions))

        Nothing ->
            Task.io <| checkNewPackage envData.root envData.outline



-- CHECK NEW PACKAGE


checkNewPackage : FilePath -> Outline.PkgOutline -> Task Never ()
checkNewPackage root ((Outline.PkgOutline pkgData) as outline) =
    IO.putStrLn Exit.newPackageOverview
        |> Task.andThen (\_ -> validateNewPackageVersion root outline pkgData.version)


validateNewPackageVersion : FilePath -> Outline.PkgOutline -> V.Version -> Task Never ()
validateNewPackageVersion root outline version =
    if version == V.one then
        IO.putStrLn "The version number in elm.json is correct so you are all set!"

    else
        let
            question =
                D.fromChars "It looks like the version in elm.json has been changed though!\nWould you like me to change it back to "
                    |> D.a (D.fromVersion V.one)
                    |> D.a (D.fromChars "? [Y/n] ")
        in
        changeVersion root outline V.one question



-- SUGGEST VERSION


type alias VersionSuggestion =
    { root : FilePath
    , outline : Outline.PkgOutline
    , oldVersion : V.Version
    , oldDocs : Docs.Documentation
    }


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


initVersionSuggestion : FilePath -> Outline.PkgOutline -> V.Version -> Docs.Documentation -> Task Exit.Bump VersionSuggestion
initVersionSuggestion root outline vsn oldDocs =
    Task.succeed (VersionSuggestion root outline vsn oldDocs)


addNewDocs : VersionSuggestion -> Task Exit.Bump ( VersionSuggestion, Docs.Documentation )
addNewDocs suggestion =
    generateDocs suggestion.root suggestion.outline
        |> Task.map (\newDocs -> ( suggestion, newDocs ))


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
            D.fromChars <| M.toChars (Diff.toMagnitude changes)

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


generateDocs : FilePath -> Outline.PkgOutline -> Task Exit.Bump Docs.Documentation
generateDocs root (Outline.PkgOutline pkgData) =
    Task.eio Exit.BumpBadDetails (BW.withScope (\scope -> Details.load Reporting.silent scope root))
        |> Task.andThen (buildDocsFromExposed root pkgData.exposed)


buildDocsFromExposed : FilePath -> Outline.Exposed -> Details.Details -> Task Exit.Bump Docs.Documentation
buildDocsFromExposed root exposed details =
    case Outline.flattenExposed exposed of
        [] ->
            Task.throw Exit.BumpNoExposed

        e :: es ->
            Task.eio Exit.BumpBadBuild <|
                Build.fromExposed Docs.bytesDecoder Docs.bytesEncoder Reporting.silent root details Build.keepDocs (NE.Nonempty e es)



-- CHANGE VERSION


changeVersion : FilePath -> Outline.PkgOutline -> V.Version -> D.Doc -> Task Never ()
changeVersion root outline targetVersion question =
    Reporting.ask question
        |> Task.andThen (applyVersionChange root outline targetVersion)


applyVersionChange : FilePath -> Outline.PkgOutline -> V.Version -> Bool -> Task Never ()
applyVersionChange root outline targetVersion approved =
    if not approved then
        IO.putStrLn "Okay, I did not change anything!"

    else
        writeNewOutline root outline targetVersion
            |> Task.andThen (\_ -> confirmVersionChange targetVersion)


writeNewOutline : FilePath -> Outline.PkgOutline -> V.Version -> Task Never ()
writeNewOutline root (Outline.PkgOutline pkgData) targetVersion =
    Outline.write root
        (Outline.Pkg
            (Outline.PkgOutline { pkgData | version = targetVersion })
        )


confirmVersionChange : V.Version -> Task Never ()
confirmVersionChange targetVersion =
    Help.toStdout
        (D.fromChars "Version changed to "
            |> D.a (D.green (D.fromVersion targetVersion))
            |> D.a (D.fromChars "!\n")
        )
