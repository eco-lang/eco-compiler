module Terminal.Publish exposing (run)

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Bump as Bump
import Builder.Deps.Diff as Diff
import Builder.Deps.Registry as Registry
import Builder.Deps.Website as Website
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.Http as Http
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Builder.Stuff as Stuff
import Codec.Archive.Zip as Zip
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Magnitude as M
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Compiler.Json.String as Json
import Compiler.Reporting.Doc as D
import List.Extra as List
import System.Exit as Exit
import System.IO as IO
import System.Process as Process
import Task exposing (Task)
import Utils.Main as Utils exposing (FilePath)
import Utils.Task.Extra as Task



-- RUN


{-| TODO mandate no "exposing (..)" in packages to make
optimization to skip builds in Elm.Details always valid
-}
run : () -> () -> Task Never ()
run () () =
    Reporting.attempt Exit.publishToReport <|
        Task.run (Task.andThen publish getEnv)



-- ENV


type alias EnvData =
    { root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , registry : Registry.Registry
    , outline : Outline.Outline
    }


type Env
    = Env EnvData


type alias EnvSetup =
    { root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    }


getEnv : Task Exit.Publish Env
getEnv =
    Task.mio Exit.PublishNoOutline Stuff.findRoot
        |> Task.andThen addPackageCache
        |> Task.andThen addHttpManager
        |> Task.andThen addRegistry
        |> Task.andThen readOutline


addPackageCache : FilePath -> Task Exit.Publish ( FilePath, Stuff.PackageCache )
addPackageCache root =
    Task.io Stuff.getPackageCache
        |> Task.map (\cache -> ( root, cache ))


addHttpManager : ( FilePath, Stuff.PackageCache ) -> Task Exit.Publish EnvSetup
addHttpManager ( root, cache ) =
    Task.io Http.getManager
        |> Task.map (\manager -> EnvSetup root cache manager)


addRegistry : EnvSetup -> Task Exit.Publish ( EnvSetup, Registry.Registry )
addRegistry setup =
    Task.eio Exit.PublishMustHaveLatestRegistry (Registry.latest setup.manager setup.cache)
        |> Task.map (\registry -> ( setup, registry ))


readOutline : ( EnvSetup, Registry.Registry ) -> Task Exit.Publish Env
readOutline ( setup, registry ) =
    Task.eio Exit.PublishBadOutline (Outline.read setup.root)
        |> Task.map (\outline -> Env { root = setup.root, cache = setup.cache, manager = setup.manager, registry = registry, outline = outline })



-- PUBLISH


type alias PublishInfo =
    { env : Env
    , pkg : Pkg.Name
    , vsn : V.Version
    , maybeKnownVersions : Maybe Registry.KnownVersions
    }


type alias DocsAndGit =
    { docs : Docs.Documentation
    , git : Git
    }


type alias PublishData =
    { info : PublishInfo
    , docs : Docs.Documentation
    , git : Git
    , commitHash : String
    }


publish : Env -> Task Exit.Publish ()
publish ((Env envData) as env) =
    case envData.outline of
        Outline.App _ ->
            Task.throw Exit.PublishApplication

        Outline.Pkg (Outline.PkgOutline pkgData) ->
            let
                info =
                    PublishInfo env pkgData.name pkgData.version (Registry.getVersions pkgData.name envData.registry)
            in
            reportPublishStart pkgData.name pkgData.version info.maybeKnownVersions
                |> Task.andThen (\_ -> checkExposed pkgData.exposed)
                |> Task.andThen (\_ -> checkSummary pkgData.summary)
                |> Task.andThen (\_ -> verifyReadme envData.root)
                |> Task.andThen (\_ -> verifyLicense envData.root)
                |> Task.andThen (\_ -> verifyBuild envData.root)
                |> Task.andThen (verifyAndGetGit info)
                |> Task.andThen (verifyTagAndChanges info envData.manager)
                |> Task.andThen (finalizePublish info envData.manager)


checkExposed : Outline.Exposed -> Task Exit.Publish ()
checkExposed exposed =
    if noExposed exposed then
        Task.throw Exit.PublishNoExposed

    else
        Task.succeed ()


checkSummary : String -> Task Exit.Publish ()
checkSummary summary =
    if badSummary summary then
        Task.throw Exit.PublishNoSummary

    else
        Task.succeed ()


verifyAndGetGit : PublishInfo -> Docs.Documentation -> Task Exit.Publish DocsAndGit
verifyAndGetGit info docs =
    verifyVersion info.env info.pkg info.vsn docs info.maybeKnownVersions
        |> Task.andThen (\_ -> getGit)
        |> Task.map (\git -> DocsAndGit docs git)


verifyTagAndChanges : PublishInfo -> Http.Manager -> DocsAndGit -> Task Exit.Publish PublishData
verifyTagAndChanges info manager docsAndGit =
    verifyTag docsAndGit.git manager info.pkg info.vsn
        |> Task.andThen (verifyNoLocalChangesAndBuildData info docsAndGit)


verifyNoLocalChangesAndBuildData : PublishInfo -> DocsAndGit -> String -> Task Exit.Publish PublishData
verifyNoLocalChangesAndBuildData info docsAndGit commitHash =
    verifyNoChanges docsAndGit.git commitHash info.vsn
        |> Task.map (\_ -> PublishData info docsAndGit.docs docsAndGit.git commitHash)


finalizePublish : PublishInfo -> Http.Manager -> PublishData -> Task Exit.Publish ()
finalizePublish info manager publishData =
    verifyZip info.env info.pkg info.vsn
        |> Task.andThen (doRegister manager publishData)


doRegister : Http.Manager -> PublishData -> Http.Sha -> Task Exit.Publish ()
doRegister manager publishData zipHash =
    Task.io (IO.putStrLn "")
        |> Task.andThen (\_ -> register manager publishData.info.pkg publishData.info.vsn publishData.docs publishData.commitHash zipHash)
        |> Task.andThen (\_ -> Task.io (IO.putStrLn "Success!"))



-- VERIFY SUMMARY


badSummary : String -> Bool
badSummary summary =
    String.isEmpty summary || Outline.defaultSummary == summary


noExposed : Outline.Exposed -> Bool
noExposed exposed =
    case exposed of
        Outline.ExposedList modules ->
            List.isEmpty modules

        Outline.ExposedDict chunks ->
            List.all (List.isEmpty << Tuple.second) chunks



-- VERIFY README


verifyReadme : String -> Task Exit.Publish ()
verifyReadme root =
    let
        readmePath : String
        readmePath =
            root ++ "/README.md"
    in
    reportReadmeCheck <|
        (File.exists readmePath
            |> Task.andThen (checkReadmeExists readmePath)
        )


checkReadmeExists : String -> Bool -> Task Never (Result Exit.Publish ())
checkReadmeExists readmePath exists =
    if exists then
        IO.withFile readmePath IO.ReadMode IO.hFileSize
            |> Task.map validateReadmeSize

    else
        Task.succeed (Err Exit.PublishNoReadme)


validateReadmeSize : Int -> Result Exit.Publish ()
validateReadmeSize size =
    if size < 300 then
        Err Exit.PublishShortReadme

    else
        Ok ()



-- VERIFY LICENSE


verifyLicense : String -> Task Exit.Publish ()
verifyLicense root =
    let
        licensePath : String
        licensePath =
            root ++ "/LICENSE"
    in
    reportLicenseCheck <|
        (File.exists licensePath
            |> Task.map
                (\exists ->
                    if exists then
                        Ok ()

                    else
                        Err Exit.PublishNoLicense
                )
        )



-- VERIFY BUILD


verifyBuild : String -> Task Exit.Publish Docs.Documentation
verifyBuild root =
    reportBuildCheck <|
        BW.withScope (loadDetailsAndBuildDocs root)


loadDetailsAndBuildDocs : String -> BW.Scope -> Task Never (Result Exit.Publish Docs.Documentation)
loadDetailsAndBuildDocs root scope =
    Task.run
        (Task.eio Exit.PublishBadDetails (Details.load Reporting.silent scope root)
            |> Task.andThen (extractExposedAndBuildDocs root)
        )


extractExposedAndBuildDocs : String -> Details.Details -> Task Exit.Publish Docs.Documentation
extractExposedAndBuildDocs root ((Details.Details detailsData) as details) =
    getExposedModules detailsData.outline
        |> Task.andThen (buildDocsFromExposed root details)


getExposedModules : Details.ValidOutline -> Task Exit.Publish (NE.Nonempty ModuleName.Raw)
getExposedModules outline =
    case outline of
        Details.ValidApp _ ->
            Task.throw Exit.PublishApplication

        Details.ValidPkg _ [] _ ->
            Task.throw Exit.PublishNoExposed

        Details.ValidPkg _ (e :: es) _ ->
            Task.succeed (NE.Nonempty e es)


buildDocsFromExposed : String -> Details.Details -> NE.Nonempty ModuleName.Raw -> Task Exit.Publish Docs.Documentation
buildDocsFromExposed root details exposed =
    Task.eio Exit.PublishBuildProblem <|
        Build.fromExposed Docs.bytesDecoder Docs.bytesEncoder Reporting.silent root details Build.keepDocs exposed



-- GET GIT


type Git
    = Git (List String -> Task Never Exit.ExitCode)


getGit : Task Exit.Publish Git
getGit =
    Task.io (Utils.dirFindExecutable "git")
        |> Task.andThen requireGit


requireGit : Maybe String -> Task Exit.Publish Git
requireGit maybeGit =
    case maybeGit of
        Nothing ->
            Task.throw Exit.PublishNoGit

        Just git ->
            Task.succeed (makeGitRunner git)


makeGitRunner : String -> Git
makeGitRunner git =
    Git (runGitCommand git)


runGitCommand : String -> List String -> Task Never Exit.ExitCode
runGitCommand git args =
    let
        process : { cmdspec : Process.CmdSpec, std_in : Process.StdStream, std_out : Process.StdStream, std_err : Process.StdStream }
        process =
            Process.proc git args
                |> (\cp ->
                        { cp
                            | std_in = Process.CreatePipe
                            , std_out = Process.CreatePipe
                            , std_err = Process.CreatePipe
                        }
                   )
    in
    Process.withCreateProcess process
        (\_ _ _ handle ->
            Process.waitForProcess handle
        )



-- VERIFY GITHUB TAG


verifyTag : Git -> Http.Manager -> Pkg.Name -> V.Version -> Task Exit.Publish String
verifyTag (Git run_) manager pkg vsn =
    reportTagCheck vsn <|
        -- https://stackoverflow.com/questions/1064499/how-to-list-all-git-tags
        (run_ [ "show", "--name-only", V.toChars vsn, "--" ]
            |> Task.andThen (handleTagCheckResult manager pkg vsn)
        )


handleTagCheckResult : Http.Manager -> Pkg.Name -> V.Version -> Exit.ExitCode -> Task Never (Result Exit.Publish String)
handleTagCheckResult manager pkg vsn exitCode =
    case exitCode of
        Exit.ExitFailure _ ->
            Task.succeed (Err (Exit.PublishMissingTag vsn))

        Exit.ExitSuccess ->
            fetchCommitHash manager pkg vsn


fetchCommitHash : Http.Manager -> Pkg.Name -> V.Version -> Task Never (Result Exit.Publish String)
fetchCommitHash manager pkg vsn =
    let
        url : String
        url =
            toTagUrl pkg vsn
    in
    Http.get manager url [ Http.accept "application/json" ] (Exit.PublishCannotGetTag vsn) (decodeCommitHash vsn url)


decodeCommitHash : V.Version -> String -> String -> Task Never (Result Exit.Publish String)
decodeCommitHash vsn url body =
    case D.fromByteString commitHashDecoder body of
        Ok hash ->
            Task.succeed (Ok hash)

        Err _ ->
            Task.succeed (Err (Exit.PublishCannotGetTagData vsn url body))


toTagUrl : Pkg.Name -> V.Version -> String
toTagUrl pkg vsn =
    "https://api.github.com/repos/" ++ Pkg.toUrl pkg ++ "/git/refs/tags/" ++ V.toChars vsn


commitHashDecoder : D.Decoder e String
commitHashDecoder =
    D.field "object" (D.field "sha" D.string)



-- VERIFY NO LOCAL CHANGES SINCE TAG


verifyNoChanges : Git -> String -> V.Version -> Task Exit.Publish ()
verifyNoChanges (Git run_) commitHash vsn =
    reportLocalChangesCheck <|
        -- https://stackoverflow.com/questions/3878624/how-do-i-programmatically-determine-if-there-are-uncommited-changes
        (run_ [ "diff-index", "--quiet", commitHash, "--" ]
            |> Task.map (checkNoLocalChanges vsn)
        )


checkNoLocalChanges : V.Version -> Exit.ExitCode -> Result Exit.Publish ()
checkNoLocalChanges vsn exitCode =
    case exitCode of
        Exit.ExitSuccess ->
            Ok ()

        Exit.ExitFailure _ ->
            Err (Exit.PublishLocalChanges vsn)



-- VERIFY THAT ZIP BUILDS / COMPUTE HASH


verifyZip : Env -> Pkg.Name -> V.Version -> Task Exit.Publish Http.Sha
verifyZip (Env envData) pkg vsn =
    withPrepublishDir envData.root (downloadAndVerifyZip envData.manager pkg vsn)


downloadAndVerifyZip : Http.Manager -> Pkg.Name -> V.Version -> String -> Task Exit.Publish Http.Sha
downloadAndVerifyZip manager pkg vsn prepublishDir =
    let
        url : String
        url =
            toZipUrl pkg vsn
    in
    reportDownloadCheck
        (Http.getArchive manager
            url
            Exit.PublishCannotGetZip
            (Exit.PublishCannotDecodeZip url)
            (Task.succeed << Ok)
        )
        |> Task.andThen (writeAndVerifyArchive prepublishDir)


writeAndVerifyArchive : String -> ( Http.Sha, Zip.Archive ) -> Task Exit.Publish Http.Sha
writeAndVerifyArchive prepublishDir ( sha, archive ) =
    Task.io (File.writePackage prepublishDir archive)
        |> Task.andThen (\_ -> verifyDownloadedCode prepublishDir)
        |> Task.map (\_ -> sha)


verifyDownloadedCode : String -> Task Exit.Publish ()
verifyDownloadedCode prepublishDir =
    reportZipBuildCheck <|
        Utils.dirWithCurrentDirectory prepublishDir <|
            verifyZipBuild prepublishDir


toZipUrl : Pkg.Name -> V.Version -> String
toZipUrl pkg vsn =
    "https://github.com/" ++ Pkg.toUrl pkg ++ "/zipball/" ++ V.toChars vsn ++ "/"


withPrepublishDir : String -> (String -> Task x a) -> Task x a
withPrepublishDir root callback =
    let
        dir : String
        dir =
            Stuff.prepublishDir root
    in
    Task.eio identity <|
        Utils.bracket_
            (Utils.dirCreateDirectoryIfMissing True dir)
            (Utils.dirRemoveDirectoryRecursive dir)
            (Task.run (callback dir))


verifyZipBuild : FilePath -> Task Never (Result Exit.Publish ())
verifyZipBuild root =
    BW.withScope (loadDetailsAndVerifyZip root)


loadDetailsAndVerifyZip : FilePath -> BW.Scope -> Task Never (Result Exit.Publish ())
loadDetailsAndVerifyZip root scope =
    Task.run
        (Task.eio Exit.PublishZipBadDetails (Details.load Reporting.silent scope root)
            |> Task.andThen (extractExposedAndBuildZip root)
        )


extractExposedAndBuildZip : FilePath -> Details.Details -> Task Exit.Publish ()
extractExposedAndBuildZip root ((Details.Details detailsData) as details) =
    getZipExposedModules detailsData.outline
        |> Task.andThen (buildZipFromExposed root details)


getZipExposedModules : Details.ValidOutline -> Task Exit.Publish (NE.Nonempty ModuleName.Raw)
getZipExposedModules outline =
    case outline of
        Details.ValidApp _ ->
            Task.throw Exit.PublishZipApplication

        Details.ValidPkg _ [] _ ->
            Task.throw Exit.PublishZipNoExposed

        Details.ValidPkg _ (e :: es) _ ->
            Task.succeed (NE.Nonempty e es)


buildZipFromExposed : FilePath -> Details.Details -> NE.Nonempty ModuleName.Raw -> Task Exit.Publish ()
buildZipFromExposed root details exposed =
    Task.eio Exit.PublishZipBuildProblem
        (Build.fromExposed Docs.bytesDecoder Docs.bytesEncoder Reporting.silent root details Build.keepDocs exposed)
        |> Task.map (\_ -> ())



-- VERIFY VERSION


type GoodVersion
    = GoodStart
    | GoodBump V.Version M.Magnitude


verifyVersion : Env -> Pkg.Name -> V.Version -> Docs.Documentation -> Maybe Registry.KnownVersions -> Task Exit.Publish ()
verifyVersion env pkg vsn newDocs publishedVersions =
    reportSemverCheck vsn <|
        case publishedVersions of
            Nothing ->
                if vsn == V.one then
                    Task.succeed <| Ok GoodStart

                else
                    Task.succeed <| Err <| Exit.PublishNotInitialVersion vsn

            Just ((Registry.KnownVersions latest previous) as knownVersions) ->
                if vsn == latest || List.member vsn previous then
                    Task.succeed <| Err <| Exit.PublishAlreadyPublished vsn

                else
                    verifyBump env pkg vsn newDocs knownVersions


verifyBump : Env -> Pkg.Name -> V.Version -> Docs.Documentation -> Registry.KnownVersions -> Task Never (Result Exit.Publish GoodVersion)
verifyBump (Env envData) pkg vsn newDocs ((Registry.KnownVersions latest _) as knownVersions) =
    case List.find (\( _, new, _ ) -> vsn == new) (Bump.getPossibilities knownVersions) of
        Nothing ->
            Task.succeed <|
                Err <|
                    Exit.PublishInvalidBump vsn latest

        Just ( old, new, magnitude ) ->
            Diff.getDocs envData.cache envData.manager pkg old
                |> Task.map
                    (\result ->
                        case result of
                            Err dp ->
                                Err <| Exit.PublishCannotGetDocs old new dp

                            Ok oldDocs ->
                                let
                                    changes : Diff.PackageChanges
                                    changes =
                                        Diff.diff oldDocs newDocs

                                    realNew : V.Version
                                    realNew =
                                        Diff.bump changes old
                                in
                                if new == realNew then
                                    Ok <| GoodBump old magnitude

                                else
                                    Err <|
                                        Exit.PublishBadBump old new magnitude realNew (Diff.toMagnitude changes)
                    )



-- REGISTER PACKAGES


register : Http.Manager -> Pkg.Name -> V.Version -> Docs.Documentation -> String -> Http.Sha -> Task Exit.Publish ()
register manager pkg vsn docs commitHash sha =
    Website.route "/register"
        [ ( "name", Pkg.toChars pkg )
        , ( "version", V.toChars vsn )
        , ( "commit-hash", commitHash )
        ]
        |> Task.andThen (uploadPackageFiles manager docs sha)
        |> Task.eio Exit.PublishCannotRegister


uploadPackageFiles : Http.Manager -> Docs.Documentation -> Http.Sha -> String -> Task Never (Result Http.Error ())
uploadPackageFiles manager docs sha url =
    Http.upload manager
        url
        [ Http.filePart "elm.json" "elm.json"
        , Http.jsonPart "docs.json" "docs.json" (Docs.jsonEncoder docs)
        , Http.filePart "README.md" "README.md"
        , Http.stringPart "github-hash" (Http.shaToChars sha)
        ]



-- REPORTING


reportPublishStart : Pkg.Name -> V.Version -> Maybe Registry.KnownVersions -> Task x ()
reportPublishStart pkg vsn maybeKnownVersions =
    Task.io <|
        case maybeKnownVersions of
            Nothing ->
                IO.putStrLn <| Exit.newPackageOverview ++ "\nI will now verify that everything is in order...\n"

            Just _ ->
                IO.putStrLn <| "Verifying " ++ Pkg.toChars pkg ++ " " ++ V.toChars vsn ++ " ...\n"



-- REPORTING PHASES


reportReadmeCheck : Task Never (Result x a) -> Task x a
reportReadmeCheck =
    reportCheck
        "Looking for README.md"
        "Found README.md"
        "Problem with your README.md"


reportLicenseCheck : Task Never (Result x a) -> Task x a
reportLicenseCheck =
    reportCheck
        "Looking for LICENSE"
        "Found LICENSE"
        "Problem with your LICENSE"


reportBuildCheck : Task Never (Result x a) -> Task x a
reportBuildCheck =
    reportCheck
        "Verifying documentation..."
        "Verified documentation"
        "Problem with documentation"


reportSemverCheck : V.Version -> Task Never (Result x GoodVersion) -> Task x ()
reportSemverCheck version work =
    let
        vsn : String
        vsn =
            V.toChars version

        waiting : String
        waiting =
            "Checking semantic versioning rules. Is " ++ vsn ++ " correct?"

        failure : String
        failure =
            "Version " ++ vsn ++ " is not correct!"

        success : GoodVersion -> String
        success result =
            case result of
                GoodStart ->
                    "All packages start at version " ++ V.toChars V.one

                GoodBump oldVersion magnitude ->
                    "Version number "
                        ++ vsn
                        ++ " verified ("
                        ++ M.toChars magnitude
                        ++ " change, "
                        ++ V.toChars oldVersion
                        ++ " => "
                        ++ vsn
                        ++ ")"
    in
    Task.void <| reportCustomCheck waiting success failure work


reportTagCheck : V.Version -> Task Never (Result x a) -> Task x a
reportTagCheck vsn =
    reportCheck
        ("Is version " ++ V.toChars vsn ++ " tagged on GitHub?")
        ("Version " ++ V.toChars vsn ++ " is tagged on GitHub")
        ("Version " ++ V.toChars vsn ++ " is not tagged on GitHub!")


reportDownloadCheck : Task Never (Result x a) -> Task x a
reportDownloadCheck =
    reportCheck
        "Downloading code from GitHub..."
        "Code downloaded successfully from GitHub"
        "Could not download code from GitHub!"


reportLocalChangesCheck : Task Never (Result x a) -> Task x a
reportLocalChangesCheck =
    reportCheck
        "Checking for uncommitted changes..."
        "No uncommitted changes in local code"
        "Your local code is different than the code tagged on GitHub"


reportZipBuildCheck : Task Never (Result x a) -> Task x a
reportZipBuildCheck =
    reportCheck
        "Verifying downloaded code..."
        "Downloaded code compiles successfully"
        "Cannot compile downloaded code!"


reportCheck : String -> String -> String -> Task Never (Result x a) -> Task x a
reportCheck waiting success failure work =
    reportCustomCheck waiting (\_ -> success) failure work


reportCustomCheck : String -> (a -> String) -> String -> Task Never (Result x a) -> Task x a
reportCustomCheck waiting success failure work =
    Task.eio identity <|
        (putFlush (makeWaitingDoc waiting)
            |> Task.andThen (\_ -> work)
            |> Task.andThen (showResultAndReturn waiting success failure)
        )


putFlush : D.Doc -> Task Never ()
putFlush doc =
    Help.toStdout doc
        |> Task.andThen flushStdout


flushStdout : () -> Task Never ()
flushStdout _ =
    IO.hFlush IO.stdout


makeWaitingDoc : String -> D.Doc
makeWaitingDoc waiting =
    D.append (D.fromChars "  ") waitingMark
        |> D.plus (D.fromChars waiting)


showResultAndReturn : String -> (a -> String) -> String -> Result x a -> Task Never (Result x a)
showResultAndReturn waiting success failure result =
    putFlush (makeResultDoc waiting success failure result)
        |> Task.map (\_ -> result)


makeResultDoc : String -> (a -> String) -> String -> Result x a -> D.Doc
makeResultDoc waiting success failure result =
    let
        padded : String -> String
        padded message =
            message ++ String.repeat (String.length waiting - String.length message) " "
    in
    case result of
        Ok a ->
            D.append (D.fromChars "\u{000D}  ") goodMark
                |> D.plus (D.fromChars (padded (success a) ++ "\n"))

        Err _ ->
            D.append (D.fromChars "\u{000D}  ") badMark
                |> D.plus (D.fromChars (padded failure ++ "\n\n"))



-- MARKS


goodMark : D.Doc
goodMark =
    D.green <|
        if isWindows then
            D.fromChars "+"

        else
            D.fromChars "●"


badMark : D.Doc
badMark =
    D.red <|
        if isWindows then
            D.fromChars "X"

        else
            D.fromChars "✗"


waitingMark : D.Doc
waitingMark =
    D.dullyellow <|
        if isWindows then
            D.fromChars "-"

        else
            D.fromChars "→"


isWindows : Bool
isWindows =
    -- Info.os == "mingw32"
    False
