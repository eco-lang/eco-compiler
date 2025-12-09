module Builder.Elm.Details exposing
    ( BuildID
    , Details(..)
    , Extras
    , Foreign(..)
    , Interfaces
    , Local(..)
    , Status
    , ValidOutline(..)
    , detailsEncoder
    , load
    , loadInterfaces
    , loadObjects
    , loadTypedObjects
    , localDecoder
    , localEncoder
    , verifyInstall
    )

import Builder.BackgroundWriter as BW
import Builder.Deps.Registry as Registry
import Builder.Deps.Solver as Solver
import Builder.Deps.Website as Website
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.Http as Http
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Source as Src
import Compiler.Compile as Compile
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Constraint as Con
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Interface as I
import Compiler.Elm.Kernel as Kernel
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Module as Parse
import Compiler.Parse.SyntaxVersion as SV exposing (SyntaxVersion)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Bytes.Decode
import Utils.Bytes.Encode as BE
import Bytes.Encode
import Utils.Crash exposing (crash)
import Utils.Main as Utils exposing (FilePath, MVar)
import Utils.Task.Extra as Task



-- DETAILS


type Details
    = Details File.Time ValidOutline BuildID (Dict String ModuleName.Raw Local) (Dict String ModuleName.Raw Foreign) Extras


type alias BuildID =
    Int


type ValidOutline
    = ValidApp (NE.Nonempty Outline.SrcDir)
    | ValidPkg Pkg.Name (List ModuleName.Raw) (Dict ( String, String ) Pkg.Name V.Version {- for docs in reactor -})



-- NOTE: we need two ways to detect if a file must be recompiled:
--
-- (1) _time is the modification time from the last time we compiled the file.
-- By checking EQUALITY with the current modification time, we can detect file
-- saves and `git checkout` of previous versions. Both need a recompile.
--
-- (2) _lastChange is the BuildID from the last time a new interface file was
-- generated, and _lastCompile is the BuildID from the last time the file was
-- compiled. These may be different if a file is recompiled but the interface
-- stayed the same. When the _lastCompile is LESS THAN the _lastChange of any
-- imports, we need to recompile. This can happen when a project has multiple
-- entrypoints and some modules are compiled less often than their imports.
--


type Local
    = Local FilePath File.Time (List ModuleName.Raw) Bool BuildID BuildID


type Foreign
    = Foreign Pkg.Name (List Pkg.Name)


type Extras
    = ArtifactsCached
    | ArtifactsFresh Interfaces Opt.GlobalGraph


type alias Interfaces =
    Dict (List String) TypeCheck.Canonical I.DependencyInterface



-- LOAD ARTIFACTS


loadObjects : FilePath -> Details -> Task Never (MVar (Maybe Opt.GlobalGraph))
loadObjects root (Details _ _ _ _ _ extras) =
    case extras of
        ArtifactsFresh _ o ->
            Utils.newMVar (Utils.maybeEncoder Opt.globalGraphEncoder) (Just o)

        ArtifactsCached ->
            fork (Utils.maybeEncoder Opt.globalGraphEncoder) (File.readBinary Opt.globalGraphDecoder (Stuff.objects root))


{-| Load typed global objects for MLIR backend.
For now, typed objects are always loaded from cache since we don't store them in Extras.
-}
loadTypedObjects : FilePath -> Details -> Task Never (MVar (Maybe TOpt.GlobalGraph))
loadTypedObjects root _ =
    -- Typed objects are not cached in memory, always load from disk
    -- The file may not exist if typed optimization hasn't been run
    fork (Utils.maybeEncoder TOpt.globalGraphEncoder)
        (File.readBinary TOpt.globalGraphDecoder (Stuff.typedObjects root)
            |> Task.map
                (\maybeGraph ->
                    -- If the file doesn't exist, return an empty graph
                    case maybeGraph of
                        Just g ->
                            Just g

                        Nothing ->
                            Just TOpt.emptyGlobalGraph
                )
        )


loadInterfaces : FilePath -> Details -> Task Never (MVar (Maybe Interfaces))
loadInterfaces root (Details _ _ _ _ _ extras) =
    case extras of
        ArtifactsFresh i _ ->
            Utils.newMVar (Utils.maybeEncoder interfacesEncoder) (Just i)

        ArtifactsCached ->
            fork (Utils.maybeEncoder interfacesEncoder) (File.readBinary interfacesDecoder (Stuff.interfaces root))



-- VERIFY INSTALL -- used by Install


verifyInstall : BW.Scope -> FilePath -> Solver.Env -> Outline.Outline -> Task Never (Result Exit.Details ())
verifyInstall scope root (Solver.Env cache manager connection registry) outline =
    File.getTime (root ++ "/elm.json")
        |> Task.andThen (runVerifyInstall scope root cache manager connection registry outline)


runVerifyInstall : BW.Scope -> FilePath -> Stuff.PackageCache -> Http.Manager -> Solver.Connection -> Registry.Registry -> Outline.Outline -> File.Time -> Task Never (Result Exit.Details ())
runVerifyInstall scope root cache manager connection registry outline time =
    let
        key : Reporting.Key msg
        key =
            Reporting.ignorer

        env : Env
        env =
            Env key scope root cache manager connection registry
    in
    case outline of
        Outline.Pkg pkg ->
            Task.run (Task.map (\_ -> ()) (verifyPkg env time pkg))

        Outline.App app ->
            Task.run (Task.map (\_ -> ()) (verifyApp env time app))



-- LOAD -- used by Make, Repl, Reactor, Test


load : Reporting.Style -> BW.Scope -> FilePath -> Task Never (Result Exit.Details Details)
load style scope root =
    File.getTime (root ++ "/elm.json")
        |> Task.andThen (loadWithTime style scope root)


loadWithTime : Reporting.Style -> BW.Scope -> FilePath -> File.Time -> Task Never (Result Exit.Details Details)
loadWithTime style scope root newTime =
    File.readBinary detailsDecoder (Stuff.details root)
        |> Task.andThen (handleCachedDetails style scope root newTime)


handleCachedDetails : Reporting.Style -> BW.Scope -> FilePath -> File.Time -> Maybe Details -> Task Never (Result Exit.Details Details)
handleCachedDetails style scope root newTime maybeDetails =
    case maybeDetails of
        Nothing ->
            generate style scope root newTime

        Just (Details oldTime outline buildID locals foreigns extras) ->
            if oldTime == newTime then
                Task.succeed (Ok (Details oldTime outline (buildID + 1) locals foreigns extras))

            else
                generate style scope root newTime



-- GENERATE


generate : Reporting.Style -> BW.Scope -> FilePath -> File.Time -> Task Never (Result Exit.Details Details)
generate style scope root time =
    Reporting.trackDetails style
        (\key ->
            initEnv key scope root
                |> Task.andThen (verifyOutline time)
        )


verifyOutline : File.Time -> Result Exit.Details ( Env, Outline.Outline ) -> Task Never (Result Exit.Details Details)
verifyOutline time result =
    case result of
        Err exit ->
            Task.succeed (Err exit)

        Ok ( env, outline ) ->
            case outline of
                Outline.Pkg pkg ->
                    Task.run (verifyPkg env time pkg)

                Outline.App app ->
                    Task.run (verifyApp env time app)



-- ENV


type Env
    = Env Reporting.DKey BW.Scope FilePath Stuff.PackageCache Http.Manager Solver.Connection Registry.Registry


initEnv : Reporting.DKey -> BW.Scope -> FilePath -> Task Never (Result Exit.Details ( Env, Outline.Outline ))
initEnv key scope root =
    fork resultRegistryProblemEnvEncoder Solver.initEnv
        |> Task.andThen (initEnvWithMVar key scope root)


initEnvWithMVar : Reporting.DKey -> BW.Scope -> FilePath -> MVar (Result Exit.RegistryProblem Solver.Env) -> Task Never (Result Exit.Details ( Env, Outline.Outline ))
initEnvWithMVar key scope root mvar =
    Outline.read root
        |> Task.andThen (handleOutlineForEnv key scope root mvar)


handleOutlineForEnv : Reporting.DKey -> BW.Scope -> FilePath -> MVar (Result Exit.RegistryProblem Solver.Env) -> Result Exit.Outline Outline.Outline -> Task Never (Result Exit.Details ( Env, Outline.Outline ))
handleOutlineForEnv key scope root mvar eitherOutline =
    case eitherOutline of
        Err problem ->
            Task.succeed (Err (Exit.DetailsBadOutline problem))

        Ok outline ->
            Utils.readMVar resultRegistryProblemEnvDecoder mvar
                |> Task.map (combineEnvAndOutline key scope root outline)


combineEnvAndOutline : Reporting.DKey -> BW.Scope -> FilePath -> Outline.Outline -> Result Exit.RegistryProblem Solver.Env -> Result Exit.Details ( Env, Outline.Outline )
combineEnvAndOutline key scope root outline maybeEnv =
    case maybeEnv of
        Err problem ->
            Err (Exit.DetailsCannotGetRegistry problem)

        Ok (Solver.Env cache manager connection registry) ->
            Ok ( Env key scope root cache manager connection registry, outline )



-- VERIFY PROJECT


verifyPkg : Env -> File.Time -> Outline.PkgOutline -> Task Exit.Details Details
verifyPkg env time (Outline.PkgOutline pkg _ _ _ exposed direct testDirect elm) =
    if Con.goodElm elm then
        union identity Pkg.compareName noDups direct testDirect
            |> Task.andThen (verifyConstraints env)
            |> Task.andThen
                (\solution ->
                    let
                        exposedList : List ModuleName.Raw
                        exposedList =
                            Outline.flattenExposed exposed

                        exactDeps : Dict ( String, String ) Pkg.Name V.Version
                        exactDeps =
                            Dict.map (\_ (Solver.Details v _) -> v) solution

                        -- for pkg docs in reactor
                    in
                    verifyDependencies env time (ValidPkg pkg exposedList exactDeps) solution direct
                )

    else
        Task.throw (Exit.DetailsBadElmInPkg elm)


verifyApp : Env -> File.Time -> Outline.AppOutline -> Task Exit.Details Details
verifyApp env time ((Outline.AppOutline elmVersion srcDirs direct _ _ _) as outline) =
    if elmVersion == V.elmCompiler then
        checkAppDeps outline
            |> Task.andThen
                (\stated ->
                    verifyConstraints env (Dict.map (\_ -> Con.exactly) stated)
                        |> Task.andThen
                            (\actual ->
                                if Dict.size stated == Dict.size actual then
                                    verifyDependencies env time (ValidApp srcDirs) actual direct

                                else
                                    Task.throw Exit.DetailsHandEditedDependencies
                            )
                )

    else
        Task.throw (Exit.DetailsBadElmInAppOutline elmVersion)


checkAppDeps : Outline.AppOutline -> Task Exit.Details (Dict ( String, String ) Pkg.Name V.Version)
checkAppDeps (Outline.AppOutline _ _ direct indirect testDirect testIndirect) =
    union identity Pkg.compareName allowEqualDups indirect testDirect
        |> Task.andThen
            (\x ->
                union identity Pkg.compareName noDups direct testIndirect
                    |> Task.andThen (\y -> union identity Pkg.compareName noDups x y)
            )



-- VERIFY CONSTRAINTS


verifyConstraints : Env -> Dict ( String, String ) Pkg.Name Con.Constraint -> Task Exit.Details (Dict ( String, String ) Pkg.Name Solver.Details)
verifyConstraints (Env _ _ _ cache _ connection registry) constraints =
    Task.io (Solver.verify cache connection registry constraints)
        |> Task.andThen
            (\result ->
                case result of
                    Solver.SolverOk details ->
                        Task.succeed details

                    Solver.NoSolution ->
                        Task.throw Exit.DetailsNoSolution

                    Solver.NoOfflineSolution ->
                        Task.throw Exit.DetailsNoOfflineSolution

                    Solver.SolverErr exit ->
                        Task.throw (Exit.DetailsSolverProblem exit)
            )



-- UNION


union : (k -> comparable) -> (k -> k -> Order) -> (k -> v -> v -> Task Exit.Details v) -> Dict comparable k v -> Dict comparable k v -> Task Exit.Details (Dict comparable k v)
union toComparable keyComparison tieBreaker deps1 deps2 =
    Dict.merge keyComparison
        (\k dep -> Task.map (Dict.insert toComparable k dep))
        (\k dep1 dep2 acc ->
            tieBreaker k dep1 dep2
                |> Task.andThen (\v -> Task.map (Dict.insert toComparable k v) acc)
        )
        (\k dep -> Task.map (Dict.insert toComparable k dep))
        deps1
        deps2
        (Task.succeed Dict.empty)


noDups : k -> v -> v -> Task Exit.Details v
noDups _ _ _ =
    Task.throw Exit.DetailsHandEditedDependencies


allowEqualDups : k -> v -> v -> Task Exit.Details v
allowEqualDups _ v1 v2 =
    if v1 == v2 then
        Task.succeed v1

    else
        Task.throw Exit.DetailsHandEditedDependencies



-- FORK


fork : (a -> Bytes.Encode.Encoder) -> Task Never a -> Task Never (MVar a)
fork encoder work =
    Utils.newEmptyMVar
        |> Task.andThen
            (\mvar ->
                Utils.forkIO (Task.andThen (Utils.putMVar encoder mvar) work)
                    |> Task.map (\_ -> mvar)
            )



-- VERIFY DEPENDENCIES


verifyDependencies : Env -> File.Time -> ValidOutline -> Dict ( String, String ) Pkg.Name Solver.Details -> Dict ( String, String ) Pkg.Name a -> Task Exit.Details Details
verifyDependencies ((Env key scope root cache _ _ _) as env) time outline solution directDeps =
    Task.eio identity
        (Reporting.report key (Reporting.DStart (Dict.size solution))
            |> Task.andThen (\_ -> Utils.newEmptyMVar)
            |> Task.andThen (verifyAllDeps env solution)
            |> Task.andThen (finalizeDependencies scope root time outline directDeps)
        )


{-| Fork verification of all dependencies.
-}
verifyAllDeps : Env -> Dict ( String, String ) Pkg.Name Solver.Details -> MVar (Dict ( String, String ) Pkg.Name (MVar Dep)) -> Task Never (Dict ( String, String ) Pkg.Name Dep)
verifyAllDeps ((Env _ _ _ cache _ _ _) as env) solution mvar =
    Stuff.withRegistryLock cache
        (Utils.mapTraverseWithKey identity Pkg.compareName (\k v -> fork depEncoder (verifyDep env mvar solution k v)) solution)
        |> Task.andThen
            (\mvars ->
                Utils.putMVar dictNameMVarDepEncoder mvar mvars
                    |> Task.andThen (\_ -> Utils.mapTraverse identity Pkg.compareName (Utils.readMVar depDecoder) mvars)
            )


{-| Finalize dependency verification: build artifacts or report errors.
-}
finalizeDependencies : BW.Scope -> FilePath -> File.Time -> ValidOutline -> Dict ( String, String ) Pkg.Name a -> Dict ( String, String ) Pkg.Name Dep -> Task Never (Result Exit.Details Details)
finalizeDependencies scope root time outline directDeps deps =
    case Utils.sequenceDictResult identity Pkg.compareName deps of
        Err _ ->
            Stuff.getElmHome
                |> Task.map
                    (\home ->
                        Err
                            (Exit.DetailsBadDeps home
                                (List.filterMap identity (Utils.eitherLefts (Dict.values compare deps)))
                            )
                    )

        Ok artifacts ->
            writeVerifiedArtifacts scope root time outline directDeps artifacts


{-| Write verified artifacts to disk.
-}
writeVerifiedArtifacts :
    BW.Scope
    -> FilePath
    -> File.Time
    -> ValidOutline
    -> Dict ( String, String ) Pkg.Name a
    -> Dict ( String, String ) Pkg.Name Artifacts
    -> Task Never (Result Exit.Details Details)
writeVerifiedArtifacts scope root time outline directDeps artifacts =
    let
        objs : Opt.GlobalGraph
        objs =
            Dict.foldr compare (\_ -> addObjects) Opt.empty artifacts

        ifaces : Interfaces
        ifaces =
            Dict.foldr compare (addInterfaces directDeps) Dict.empty artifacts

        foreigns : Dict String ModuleName.Raw Foreign
        foreigns =
            Dict.map (\_ -> OneOrMore.destruct Foreign) (Dict.foldr compare gatherForeigns Dict.empty (Dict.intersection compare artifacts directDeps))

        details : Details
        details =
            Details time outline 0 Dict.empty foreigns (ArtifactsFresh ifaces objs)
    in
    BW.writeBinary Opt.globalGraphEncoder scope (Stuff.objects root) objs
        |> Task.andThen (\_ -> BW.writeBinary interfacesEncoder scope (Stuff.interfaces root) ifaces)
        |> Task.andThen (\_ -> BW.writeBinary detailsEncoder scope (Stuff.details root) details)
        |> Task.map (\_ -> Ok details)


addObjects : Artifacts -> Opt.GlobalGraph -> Opt.GlobalGraph
addObjects (Artifacts _ objs) graph =
    Opt.addGlobalGraph objs graph


addInterfaces : Dict ( String, String ) Pkg.Name a -> Pkg.Name -> Artifacts -> Interfaces -> Interfaces
addInterfaces directDeps pkg (Artifacts ifaces _) dependencyInterfaces =
    Dict.union
        dependencyInterfaces
        (Dict.fromList ModuleName.toComparableCanonical
            (List.map (Tuple.mapFirst (TypeCheck.Canonical pkg))
                (Dict.toList compare
                    (if Dict.member identity pkg directDeps then
                        ifaces

                     else
                        Dict.map (\_ -> I.privatize) ifaces
                    )
                )
            )
        )


gatherForeigns : Pkg.Name -> Artifacts -> Dict String ModuleName.Raw (OneOrMore.OneOrMore Pkg.Name) -> Dict String ModuleName.Raw (OneOrMore.OneOrMore Pkg.Name)
gatherForeigns pkg (Artifacts ifaces _) foreigns =
    let
        isPublic : I.DependencyInterface -> Maybe (OneOrMore.OneOrMore Pkg.Name)
        isPublic di =
            case di of
                I.Public _ ->
                    Just (OneOrMore.one pkg)

                I.Private _ _ _ ->
                    Nothing
    in
    Utils.mapUnionWith identity compare OneOrMore.more foreigns (Utils.mapMapMaybe identity compare isPublic ifaces)



-- VERIFY DEPENDENCY


type Artifacts
    = Artifacts (Dict String ModuleName.Raw I.DependencyInterface) Opt.GlobalGraph


type alias Dep =
    Result (Maybe Exit.DetailsBadDep) Artifacts


{-| Context for verifying a dependency.
-}
type alias VerifyDepContext =
    { key : Reporting.DKey
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , depsMVar : MVar (Dict ( String, String ) Pkg.Name (MVar Dep))
    , pkg : Pkg.Name
    , vsn : V.Version
    , details : Solver.Details
    , fingerprint : Dict ( String, String ) Pkg.Name V.Version
    }


verifyDep : Env -> MVar (Dict ( String, String ) Pkg.Name (MVar Dep)) -> Dict ( String, String ) Pkg.Name Solver.Details -> Pkg.Name -> Solver.Details -> Task Never Dep
verifyDep (Env key _ _ cache manager _ _) depsMVar solution pkg ((Solver.Details vsn directDeps) as details) =
    let
        fingerprint : Dict ( String, String ) Pkg.Name V.Version
        fingerprint =
            Utils.mapIntersectionWith identity Pkg.compareName (\(Solver.Details v _) _ -> v) solution directDeps

        ctx : VerifyDepContext
        ctx =
            { key = key, cache = cache, manager = manager, depsMVar = depsMVar, pkg = pkg, vsn = vsn, details = details, fingerprint = fingerprint }
    in
    Utils.dirDoesDirectoryExist (Stuff.package cache pkg vsn ++ "/src")
        |> Task.andThen (handleDepExistence ctx)


handleDepExistence : VerifyDepContext -> Bool -> Task Never Dep
handleDepExistence ctx exists =
    if exists then
        handleCachedDep ctx

    else
        downloadAndBuildDep ctx


handleCachedDep : VerifyDepContext -> Task Never Dep
handleCachedDep ctx =
    Reporting.report ctx.key Reporting.DCached
        |> Task.andThen (\_ -> checkArtifactCache ctx)


checkArtifactCache : VerifyDepContext -> Task Never Dep
checkArtifactCache ctx =
    File.readBinary artifactCacheDecoder (Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/artifacts.dat")
        |> Task.andThen (handleArtifactCache ctx)


handleArtifactCache : VerifyDepContext -> Maybe ArtifactCache -> Task Never Dep
handleArtifactCache ctx maybeCache =
    case maybeCache of
        Nothing ->
            build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint EverySet.empty

        Just (ArtifactCache fingerprints artifacts) ->
            if EverySet.member toComparableFingerprint ctx.fingerprint fingerprints then
                Task.map (\_ -> Ok artifacts) (Reporting.report ctx.key Reporting.DBuilt)

            else
                build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint fingerprints


downloadAndBuildDep : VerifyDepContext -> Task Never Dep
downloadAndBuildDep ctx =
    Reporting.report ctx.key Reporting.DRequested
        |> Task.andThen (\_ -> downloadAndHandleResult ctx)


downloadAndHandleResult : VerifyDepContext -> Task Never Dep
downloadAndHandleResult ctx =
    downloadPackage ctx.cache ctx.manager ctx.pkg ctx.vsn
        |> Task.andThen (handleDownloadResult ctx)


handleDownloadResult : VerifyDepContext -> Result Exit.PackageProblem () -> Task Never Dep
handleDownloadResult ctx result =
    case result of
        Err problem ->
            Reporting.report ctx.key (Reporting.DFailed ctx.pkg ctx.vsn)
                |> Task.map (\_ -> Err (Just (Exit.BD_BadDownload ctx.pkg ctx.vsn problem)))

        Ok () ->
            Reporting.report ctx.key (Reporting.DReceived ctx.pkg ctx.vsn)
                |> Task.andThen (\_ -> build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint EverySet.empty)



-- ARTIFACT CACHE


type ArtifactCache
    = ArtifactCache (EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint) Artifacts


type alias Fingerprint =
    Dict ( String, String ) Pkg.Name V.Version


toComparableFingerprint : Fingerprint -> List ( ( String, String ), ( Int, Int, Int ) )
toComparableFingerprint fingerprint =
    Dict.toList compare fingerprint
        |> List.map (Tuple.mapSecond V.toComparable)



-- BUILD


{-| Context for building a package.
-}
type alias BuildContext =
    { key : Reporting.DKey
    , cache : Stuff.PackageCache
    , pkg : Pkg.Name
    , vsn : V.Version
    , fingerprint : Fingerprint
    , fingerprints : EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint
    }


build :
    Reporting.DKey
    -> Stuff.PackageCache
    -> MVar (Dict ( String, String ) Pkg.Name (MVar Dep))
    -> Pkg.Name
    -> Solver.Details
    -> Fingerprint
    -> EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint
    -> Task Never Dep
build key cache depsMVar pkg (Solver.Details vsn _) f fs =
    let
        ctx : BuildContext
        ctx =
            { key = key, cache = cache, pkg = pkg, vsn = vsn, fingerprint = f, fingerprints = fs }
    in
    Outline.read (Stuff.package cache pkg vsn)
        |> Task.andThen
            (\eitherOutline ->
                case eitherOutline of
                    Err _ ->
                        reportBuildBroken ctx

                    Ok (Outline.App _) ->
                        reportBuildBroken ctx

                    Ok (Outline.Pkg (Outline.PkgOutline _ _ _ _ exposed deps _ _)) ->
                        buildPackage ctx depsMVar exposed deps
            )


{-| Report a broken build.
-}
reportBuildBroken : BuildContext -> Task Never Dep
reportBuildBroken { key, pkg, vsn, fingerprint } =
    Reporting.report key Reporting.DBroken
        |> Task.map (\_ -> Err (Just (Exit.BD_BadBuild pkg vsn fingerprint)))


{-| Build a package after successfully reading its outline.
-}
buildPackage : BuildContext -> MVar (Dict ( String, String ) Pkg.Name (MVar Dep)) -> Outline.Exposed -> Dict ( String, String ) Pkg.Name Con.Constraint -> Task Never Dep
buildPackage ctx depsMVar exposed deps =
    Utils.readMVar dictPkgNameMVarDepDecoder depsMVar
        |> Task.andThen
            (\allDeps ->
                Utils.mapTraverse identity Pkg.compareName (Utils.readMVar depDecoder) (Dict.intersection compare allDeps deps)
                    |> Task.andThen (buildWithDirectDeps ctx exposed)
            )


{-| Build with direct dependencies resolved.
-}
buildWithDirectDeps : BuildContext -> Outline.Exposed -> Dict ( String, String ) Pkg.Name Dep -> Task Never Dep
buildWithDirectDeps ctx exposed directDeps =
    case Utils.sequenceDictResult identity Pkg.compareName directDeps of
        Err _ ->
            Reporting.report ctx.key Reporting.DBroken
                |> Task.map (\_ -> Err Nothing)

        Ok directArtifacts ->
            let
                src : String
                src =
                    Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src"

                foreignDeps : Dict String ModuleName.Raw ForeignInterface
                foreignDeps =
                    gatherForeignInterfaces directArtifacts

                exposedDict : Dict String ModuleName.Raw ()
                exposedDict =
                    Utils.mapFromKeys identity (\_ -> ()) (Outline.flattenExposed exposed)
            in
            getDocsStatus ctx.cache ctx.pkg ctx.vsn
                |> Task.andThen (crawlPackageModules ctx foreignDeps src exposedDict)
                |> Task.andThen (compilePackageModules ctx exposedDict)


{-| Crawl package modules to discover their statuses.
-}
crawlPackageModules :
    BuildContext
    -> Dict String ModuleName.Raw ForeignInterface
    -> String
    -> Dict String ModuleName.Raw ()
    -> DocsStatus
    -> Task Never (Result Dep ( DocsStatus, Dict String ModuleName.Raw Status ))
crawlPackageModules ctx foreignDeps src exposedDict docsStatus =
    Utils.newEmptyMVar
        |> Task.andThen (forkCrawlModules ctx foreignDeps src exposedDict docsStatus)


forkCrawlModules :
    BuildContext
    -> Dict String ModuleName.Raw ForeignInterface
    -> String
    -> Dict String ModuleName.Raw ()
    -> DocsStatus
    -> MVar (Dict String ModuleName.Raw (MVar (Maybe Status)))
    -> Task Never (Result Dep ( DocsStatus, Dict String ModuleName.Raw Status ))
forkCrawlModules ctx foreignDeps src exposedDict docsStatus mvar =
    Utils.mapTraverseWithKey identity compare (always << fork (BE.maybe statusEncoder) << crawlModule foreignDeps mvar ctx.pkg src docsStatus) exposedDict
        |> Task.andThen (waitAndCollectCrawlResults ctx docsStatus mvar)


waitAndCollectCrawlResults :
    BuildContext
    -> DocsStatus
    -> MVar (Dict String ModuleName.Raw (MVar (Maybe Status)))
    -> Dict String ModuleName.Raw (MVar (Maybe Status))
    -> Task Never (Result Dep ( DocsStatus, Dict String ModuleName.Raw Status ))
waitAndCollectCrawlResults ctx docsStatus mvar mvars =
    Utils.putMVar statusDictEncoder mvar mvars
        |> Task.andThen (\_ -> Utils.dictMapM_ compare (Utils.readMVar (BD.maybe statusDecoder)) mvars)
        |> Task.andThen (\_ -> Utils.readMVar statusDictDecoder mvar)
        |> Task.andThen (Utils.mapTraverse identity compare (Utils.readMVar (BD.maybe statusDecoder)))
        |> Task.andThen (finalizeCrawlResults ctx docsStatus)


finalizeCrawlResults :
    BuildContext
    -> DocsStatus
    -> Dict String ModuleName.Raw (Maybe Status)
    -> Task Never (Result Dep ( DocsStatus, Dict String ModuleName.Raw Status ))
finalizeCrawlResults ctx docsStatus maybeStatuses =
    case Utils.sequenceDictMaybe identity compare maybeStatuses of
        Nothing ->
            reportBuildBroken ctx
                |> Task.map Err

        Just statuses ->
            Task.succeed (Ok ( docsStatus, statuses ))


{-| Compile package modules and write artifacts.
-}
compilePackageModules : BuildContext -> Dict String ModuleName.Raw () -> Result Dep ( DocsStatus, Dict String ModuleName.Raw Status ) -> Task Never Dep
compilePackageModules ctx exposedDict crawlResult =
    case crawlResult of
        Err dep ->
            Task.succeed dep

        Ok ( docsStatus, statuses ) ->
            Utils.newEmptyMVar
                |> Task.andThen (forkCompileModules ctx exposedDict docsStatus statuses)


forkCompileModules :
    BuildContext
    -> Dict String ModuleName.Raw ()
    -> DocsStatus
    -> Dict String ModuleName.Raw Status
    -> MVar (Dict String ModuleName.Raw (MVar (Maybe DResult)))
    -> Task Never Dep
forkCompileModules ctx exposedDict docsStatus statuses rmvar =
    Utils.mapTraverse identity compare (fork (BE.maybe dResultEncoder) << compile ctx.pkg rmvar) statuses
        |> Task.andThen (waitAndCollectCompileResults ctx exposedDict docsStatus rmvar)


waitAndCollectCompileResults :
    BuildContext
    -> Dict String ModuleName.Raw ()
    -> DocsStatus
    -> MVar (Dict String ModuleName.Raw (MVar (Maybe DResult)))
    -> Dict String ModuleName.Raw (MVar (Maybe DResult))
    -> Task Never Dep
waitAndCollectCompileResults ctx exposedDict docsStatus rmvar rmvars =
    Utils.putMVar dictRawMVarMaybeDResultEncoder rmvar rmvars
        |> Task.andThen (\_ -> Utils.mapTraverse identity compare (Utils.readMVar (BD.maybe dResultDecoder)) rmvars)
        |> Task.andThen (writePackageArtifacts ctx exposedDict docsStatus)


{-| Write package artifacts to disk.
-}
writePackageArtifacts : BuildContext -> Dict String ModuleName.Raw () -> DocsStatus -> Dict String ModuleName.Raw (Maybe DResult) -> Task Never Dep
writePackageArtifacts ctx exposedDict docsStatus maybeResults =
    case Utils.sequenceDictMaybe identity compare maybeResults of
        Nothing ->
            reportBuildBroken ctx

        Just results ->
            let
                path : String
                path =
                    Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/artifacts.dat"

                ifaces : Dict String ModuleName.Raw I.DependencyInterface
                ifaces =
                    gatherInterfaces exposedDict results

                objects : Opt.GlobalGraph
                objects =
                    gatherObjects results

                artifacts : Artifacts
                artifacts =
                    Artifacts ifaces objects

                fingerprints : EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint
                fingerprints =
                    EverySet.insert toComparableFingerprint ctx.fingerprint ctx.fingerprints
            in
            writeDocs ctx.cache ctx.pkg ctx.vsn docsStatus results
                |> Task.andThen (\_ -> File.writeBinary artifactCacheEncoder path (ArtifactCache fingerprints artifacts))
                |> Task.andThen (\_ -> Reporting.report ctx.key Reporting.DBuilt)
                |> Task.map (\_ -> Ok artifacts)



-- GATHER


gatherObjects : Dict String ModuleName.Raw DResult -> Opt.GlobalGraph
gatherObjects results =
    Dict.foldr compare addLocalGraph Opt.empty results


addLocalGraph : ModuleName.Raw -> DResult -> Opt.GlobalGraph -> Opt.GlobalGraph
addLocalGraph name status graph =
    case status of
        RLocal _ objs _ ->
            Opt.addLocalGraph objs graph

        RForeign _ ->
            graph

        RKernelLocal cs ->
            Opt.addKernel (Name.getKernel name) cs graph

        RKernelForeign ->
            graph


gatherInterfaces : Dict String ModuleName.Raw () -> Dict String ModuleName.Raw DResult -> Dict String ModuleName.Raw I.DependencyInterface
gatherInterfaces exposed artifacts =
    let
        onLeft : a -> b -> c -> d
        onLeft _ _ _ =
            crash "compiler bug manifesting in Elm.Details.gatherInterfaces"

        onBoth : comparable -> () -> DResult -> Dict comparable comparable I.DependencyInterface -> Dict comparable comparable I.DependencyInterface
        onBoth k () iface =
            toLocalInterface I.public iface
                |> Maybe.map (Dict.insert identity k)
                |> Maybe.withDefault identity

        onRight : comparable -> DResult -> Dict comparable comparable I.DependencyInterface -> Dict comparable comparable I.DependencyInterface
        onRight k iface =
            toLocalInterface I.private iface
                |> Maybe.map (Dict.insert identity k)
                |> Maybe.withDefault identity
    in
    Dict.merge compare onLeft onBoth onRight exposed artifacts Dict.empty


toLocalInterface : (I.Interface -> a) -> DResult -> Maybe a
toLocalInterface func result =
    case result of
        RLocal iface _ _ ->
            Just (func iface)

        RForeign _ ->
            Nothing

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- GATHER FOREIGN INTERFACES


type ForeignInterface
    = ForeignAmbiguous
    | ForeignSpecific I.Interface


gatherForeignInterfaces : Dict ( String, String ) Pkg.Name Artifacts -> Dict String ModuleName.Raw ForeignInterface
gatherForeignInterfaces directArtifacts =
    let
        finalize : I.Interface -> List I.Interface -> ForeignInterface
        finalize i is =
            case is of
                [] ->
                    ForeignSpecific i

                _ :: _ ->
                    ForeignAmbiguous

        gather : Pkg.Name -> Artifacts -> Dict String ModuleName.Raw (OneOrMore.OneOrMore I.Interface) -> Dict String ModuleName.Raw (OneOrMore.OneOrMore I.Interface)
        gather _ (Artifacts ifaces _) buckets =
            Utils.mapUnionWith identity compare OneOrMore.more buckets (Utils.mapMapMaybe identity compare isPublic ifaces)

        isPublic : I.DependencyInterface -> Maybe (OneOrMore.OneOrMore I.Interface)
        isPublic di =
            case di of
                I.Public iface ->
                    Just (OneOrMore.one iface)

                I.Private _ _ _ ->
                    Nothing
    in
    Dict.map (\_ -> OneOrMore.destruct finalize) <|
        Dict.foldr compare gather Dict.empty directArtifacts



-- CRAWL


type alias StatusDict =
    Dict String ModuleName.Raw (MVar (Maybe Status))


type Status
    = SLocal DocsStatus (Dict String ModuleName.Raw ()) Src.Module
    | SForeign I.Interface
    | SKernelLocal (List Kernel.Chunk)
    | SKernelForeign


crawlModule : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> Task Never (Maybe Status)
crawlModule foreignDeps mvar pkg src docsStatus name =
    let
        path : String -> FilePath
        path extension =
            Utils.fpCombine src (Utils.fpAddExtension (ModuleName.toFilePath name) extension)

        guidaPath : FilePath
        guidaPath =
            path "guida"

        elmPath : FilePath
        elmPath =
            path "elm"
    in
    File.exists guidaPath
        |> Task.andThen (checkElmPathAndCrawl foreignDeps mvar pkg src docsStatus name guidaPath elmPath)


checkElmPathAndCrawl : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> FilePath -> FilePath -> Bool -> Task Never (Maybe Status)
checkElmPathAndCrawl foreignDeps mvar pkg src docsStatus name guidaPath elmPath guidaExists =
    File.exists elmPath
        |> Task.andThen (resolveCrawlAction foreignDeps mvar pkg src docsStatus name guidaPath elmPath guidaExists)


resolveCrawlAction : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> FilePath -> FilePath -> Bool -> Bool -> Task Never (Maybe Status)
resolveCrawlAction foreignDeps mvar pkg src docsStatus name guidaPath elmPath guidaExists elmExists =
    case Dict.get identity name foreignDeps of
        Just ForeignAmbiguous ->
            Task.succeed Nothing

        Just (ForeignSpecific iface) ->
            if guidaExists || elmExists then
                Task.succeed Nothing

            else
                Task.succeed (Just (SForeign iface))

        Nothing ->
            if guidaExists then
                crawlFile SV.Guida foreignDeps mvar pkg src docsStatus name guidaPath

            else if elmExists then
                crawlFile SV.Elm foreignDeps mvar pkg src docsStatus name elmPath

            else if Pkg.isKernel pkg && Name.isKernel name then
                crawlKernel foreignDeps mvar pkg src name

            else
                Task.succeed Nothing


crawlFile : SyntaxVersion -> Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> FilePath -> Task Never (Maybe Status)
crawlFile syntaxVersion foreignDeps mvar pkg src docsStatus expectedName path =
    File.readUtf8 path
        |> Task.andThen (parseAndCrawlFile syntaxVersion foreignDeps mvar pkg src docsStatus expectedName)


parseAndCrawlFile : SyntaxVersion -> Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> String -> Task Never (Maybe Status)
parseAndCrawlFile syntaxVersion foreignDeps mvar pkg src docsStatus expectedName bytes =
    case Parse.fromByteString syntaxVersion (Parse.Package pkg) bytes of
        Ok ((Src.Module _ (Just (A.At _ actualName)) _ _ imports _ _ _ _ _) as modul) ->
            if expectedName == actualName then
                crawlImports foreignDeps mvar pkg src imports
                    |> Task.map (\deps -> Just (SLocal docsStatus deps modul))

            else
                Task.succeed Nothing

        _ ->
            Task.succeed Nothing


crawlImports : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> List Src.Import -> Task Never (Dict String ModuleName.Raw ())
crawlImports foreignDeps mvar pkg src imports =
    Utils.takeMVar statusDictDecoder mvar
        |> Task.andThen (forkCrawlNewImports foreignDeps mvar pkg src imports)


forkCrawlNewImports : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> List Src.Import -> StatusDict -> Task Never (Dict String ModuleName.Raw ())
forkCrawlNewImports foreignDeps mvar pkg src imports statusDict =
    let
        deps : Dict String Name.Name ()
        deps =
            Dict.fromList identity (List.map (\i -> ( Src.getImportName i, () )) imports)

        news : Dict String Name.Name ()
        news =
            Dict.diff deps statusDict
    in
    Utils.mapTraverseWithKey identity compare (always << fork (BE.maybe statusEncoder) << crawlModule foreignDeps mvar pkg src DocsNotNeeded) news
        |> Task.andThen (waitForCrawledImports mvar statusDict deps)


waitForCrawledImports : MVar StatusDict -> StatusDict -> Dict String Name.Name () -> Dict String ModuleName.Raw (MVar (Maybe Status)) -> Task Never (Dict String ModuleName.Raw ())
waitForCrawledImports mvar statusDict deps mvars =
    Utils.putMVar statusDictEncoder mvar (Dict.union mvars statusDict)
        |> Task.andThen (\_ -> Utils.dictMapM_ compare (Utils.readMVar (BD.maybe statusDecoder)) mvars)
        |> Task.map (\_ -> deps)


crawlKernel : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> ModuleName.Raw -> Task Never (Maybe Status)
crawlKernel foreignDeps mvar pkg src name =
    let
        path : FilePath
        path =
            Utils.fpCombine src (Utils.fpAddExtension (ModuleName.toFilePath name) "js")
    in
    File.exists path
        |> Task.andThen (handleKernelExistence foreignDeps mvar pkg src path)


handleKernelExistence : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> FilePath -> Bool -> Task Never (Maybe Status)
handleKernelExistence foreignDeps mvar pkg src path exists =
    if exists then
        File.readUtf8 path
            |> Task.andThen (parseAndCrawlKernel foreignDeps mvar pkg src)

    else
        Task.succeed (Just SKernelForeign)


parseAndCrawlKernel : Dict String ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> String -> Task Never (Maybe Status)
parseAndCrawlKernel foreignDeps mvar pkg src bytes =
    case Kernel.fromByteString pkg (Utils.mapMapMaybe identity compare getDepHome foreignDeps) bytes of
        Nothing ->
            Task.succeed Nothing

        Just (Kernel.Content imports chunks) ->
            crawlImports foreignDeps mvar pkg src (List.map Src.c1Value imports)
                |> Task.map (\_ -> Just (SKernelLocal chunks))


getDepHome : ForeignInterface -> Maybe Pkg.Name
getDepHome fi =
    case fi of
        ForeignSpecific (I.Interface pkg _ _ _ _) ->
            Just pkg

        ForeignAmbiguous ->
            Nothing



-- COMPILE


type DResult
    = RLocal I.Interface Opt.LocalGraph (Maybe Docs.Module)
    | RForeign I.Interface
    | RKernelLocal (List Kernel.Chunk)
    | RKernelForeign


compile : Pkg.Name -> MVar (Dict String ModuleName.Raw (MVar (Maybe DResult))) -> Status -> Task Never (Maybe DResult)
compile pkg mvar status =
    case status of
        SLocal docsStatus deps modul ->
            Utils.readMVar moduleNameRawMVarMaybeDResultDecoder mvar
                |> Task.andThen
                    (\resultsDict ->
                        Utils.mapTraverse identity compare (Utils.readMVar (BD.maybe dResultDecoder)) (Dict.intersection compare resultsDict deps)
                            |> Task.andThen
                                (\maybeResults ->
                                    case Utils.sequenceDictMaybe identity compare maybeResults of
                                        Just results ->
                                            Compile.compile pkg (Utils.mapMapMaybe identity compare getInterface results) modul
                                                |> Task.map
                                                    (\result ->
                                                        case result of
                                                            Err _ ->
                                                                Nothing

                                                            Ok (Compile.Artifacts canonical annotations objects) ->
                                                                let
                                                                    ifaces : I.Interface
                                                                    ifaces =
                                                                        I.fromModule pkg canonical annotations

                                                                    docs : Maybe Docs.Module
                                                                    docs =
                                                                        makeDocs docsStatus canonical
                                                                in
                                                                Just (RLocal ifaces objects docs)
                                                    )

                                        Nothing ->
                                            Task.succeed Nothing
                                )
                    )

        SForeign iface ->
            Task.succeed (Just (RForeign iface))

        SKernelLocal chunks ->
            Task.succeed (Just (RKernelLocal chunks))

        SKernelForeign ->
            Task.succeed (Just RKernelForeign)


getInterface : DResult -> Maybe I.Interface
getInterface result =
    case result of
        RLocal iface _ _ ->
            Just iface

        RForeign iface ->
            Just iface

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- MAKE DOCS


type DocsStatus
    = DocsNeeded
    | DocsNotNeeded


getDocsStatus : Stuff.PackageCache -> Pkg.Name -> V.Version -> Task Never DocsStatus
getDocsStatus cache pkg vsn =
    File.exists (Stuff.package cache pkg vsn ++ "/docs.json")
        |> Task.map
            (\exists ->
                if exists then
                    DocsNotNeeded

                else
                    DocsNeeded
            )


makeDocs : DocsStatus -> Can.Module -> Maybe Docs.Module
makeDocs status modul =
    case status of
        DocsNeeded ->
            case Docs.fromModule modul of
                Ok docs ->
                    Just docs

                Err _ ->
                    Nothing

        DocsNotNeeded ->
            Nothing


writeDocs : Stuff.PackageCache -> Pkg.Name -> V.Version -> DocsStatus -> Dict String ModuleName.Raw DResult -> Task Never ()
writeDocs cache pkg vsn status results =
    case status of
        DocsNeeded ->
            E.writeUgly (Stuff.package cache pkg vsn ++ "/docs.json")
                (Docs.encode (Utils.mapMapMaybe identity compare toDocs results))

        DocsNotNeeded ->
            Task.succeed ()


toDocs : DResult -> Maybe Docs.Module
toDocs result =
    case result of
        RLocal _ _ docs ->
            docs

        RForeign _ ->
            Nothing

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- DOWNLOAD PACKAGE


downloadPackage : Stuff.PackageCache -> Http.Manager -> Pkg.Name -> V.Version -> Task Never (Result Exit.PackageProblem ())
downloadPackage cache manager pkg vsn =
    Website.metadata pkg vsn "endpoint.json"
        |> Task.andThen
            (\url ->
                Http.get manager url [] identity (Task.succeed << Ok)
                    |> Task.andThen
                        (\eitherByteString ->
                            case eitherByteString of
                                Err err ->
                                    Task.succeed (Err (Exit.PP_BadEndpointRequest err))

                                Ok byteString ->
                                    case D.fromByteString endpointDecoder byteString of
                                        Err _ ->
                                            Task.succeed (Err (Exit.PP_BadEndpointContent url))

                                        Ok ( endpoint, expectedHash ) ->
                                            Http.getArchive manager endpoint Exit.PP_BadArchiveRequest (Exit.PP_BadArchiveContent endpoint) <|
                                                \( sha, archive ) ->
                                                    if expectedHash == Http.shaToChars sha then
                                                        Task.map Ok (File.writePackage (Stuff.package cache pkg vsn) archive)

                                                    else
                                                        Task.succeed (Err (Exit.PP_BadArchiveHash endpoint expectedHash (Http.shaToChars sha)))
                        )
            )


endpointDecoder : D.Decoder e ( String, String )
endpointDecoder =
    D.field "url" D.string
        |> D.andThen
            (\url ->
                D.field "hash" D.string
                    |> D.map (\hash -> ( url, hash ))
            )



-- ENCODERS and DECODERS


detailsEncoder : Details -> Bytes.Encode.Encoder
detailsEncoder (Details oldTime outline buildID locals foreigns extras) =
    Bytes.Encode.sequence
        [ File.timeEncoder oldTime
        , validOutlineEncoder outline
        , BE.int buildID
        , BE.assocListDict compare ModuleName.rawEncoder localEncoder locals
        , BE.assocListDict compare ModuleName.rawEncoder foreignEncoder foreigns
        , extrasEncoder extras
        ]


detailsDecoder : Bytes.Decode.Decoder Details
detailsDecoder =
    BD.map6 Details
        File.timeDecoder
        validOutlineDecoder
        BD.int
        (BD.assocListDict identity ModuleName.rawDecoder localDecoder)
        (BD.assocListDict identity ModuleName.rawDecoder foreignDecoder)
        extrasDecoder


interfacesEncoder : Interfaces -> Bytes.Encode.Encoder
interfacesEncoder =
    BE.assocListDict ModuleName.compareCanonical ModuleName.canonicalEncoder I.dependencyInterfaceEncoder


interfacesDecoder : Bytes.Decode.Decoder Interfaces
interfacesDecoder =
    BD.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder I.dependencyInterfaceDecoder


resultRegistryProblemEnvEncoder : Result Exit.RegistryProblem Solver.Env -> Bytes.Encode.Encoder
resultRegistryProblemEnvEncoder =
    BE.result Exit.registryProblemEncoder Solver.envEncoder


resultRegistryProblemEnvDecoder : Bytes.Decode.Decoder (Result Exit.RegistryProblem Solver.Env)
resultRegistryProblemEnvDecoder =
    BD.result Exit.registryProblemDecoder Solver.envDecoder


depEncoder : Dep -> Bytes.Encode.Encoder
depEncoder dep =
    BE.result (BE.maybe Exit.detailsBadDepEncoder) artifactsEncoder dep


depDecoder : Bytes.Decode.Decoder Dep
depDecoder =
    BD.result (BD.maybe Exit.detailsBadDepDecoder) artifactsDecoder


artifactsEncoder : Artifacts -> Bytes.Encode.Encoder
artifactsEncoder (Artifacts ifaces objects) =
    Bytes.Encode.sequence
        [ BE.assocListDict compare ModuleName.rawEncoder I.dependencyInterfaceEncoder ifaces
        , Opt.globalGraphEncoder objects
        ]


artifactsDecoder : Bytes.Decode.Decoder Artifacts
artifactsDecoder =
    Bytes.Decode.map2 Artifacts
        (BD.assocListDict identity ModuleName.rawDecoder I.dependencyInterfaceDecoder)
        Opt.globalGraphDecoder


dictNameMVarDepEncoder : Dict ( String, String ) Pkg.Name (MVar Dep) -> Bytes.Encode.Encoder
dictNameMVarDepEncoder =
    BE.assocListDict compare Pkg.nameEncoder Utils.mVarEncoder


artifactCacheEncoder : ArtifactCache -> Bytes.Encode.Encoder
artifactCacheEncoder (ArtifactCache fingerprints artifacts) =
    Bytes.Encode.sequence
        [ BE.everySet (\_ _ -> EQ) fingerprintEncoder fingerprints
        , artifactsEncoder artifacts
        ]


artifactCacheDecoder : Bytes.Decode.Decoder ArtifactCache
artifactCacheDecoder =
    Bytes.Decode.map2 ArtifactCache
        (BD.everySet toComparableFingerprint fingerprintDecoder)
        artifactsDecoder


dictPkgNameMVarDepDecoder : Bytes.Decode.Decoder (Dict ( String, String ) Pkg.Name (MVar Dep))
dictPkgNameMVarDepDecoder =
    BD.assocListDict identity Pkg.nameDecoder Utils.mVarDecoder


statusEncoder : Status -> Bytes.Encode.Encoder
statusEncoder status =
    case status of
        SLocal docsStatus deps modul ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , docsStatusEncoder docsStatus
                , BE.list ModuleName.rawEncoder (Dict.keys compare deps)
                , Src.moduleEncoder modul
                ]

        SForeign iface ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , I.interfaceEncoder iface
                ]

        SKernelLocal chunks ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.list Kernel.chunkEncoder chunks
                ]

        SKernelForeign ->
            Bytes.Encode.unsignedInt8 3


statusDecoder : Bytes.Decode.Decoder Status
statusDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 SLocal
                            docsStatusDecoder
                            (BD.list ModuleName.rawDecoder
                                |> Bytes.Decode.map (Dict.fromList identity << List.map (\dep -> ( dep, () )))
                            )
                            Src.moduleDecoder

                    1 ->
                        Bytes.Decode.map SForeign I.interfaceDecoder

                    2 ->
                        Bytes.Decode.map SKernelLocal (BD.list Kernel.chunkDecoder)

                    3 ->
                        Bytes.Decode.succeed SKernelForeign

                    _ ->
                        Bytes.Decode.fail
            )


dictRawMVarMaybeDResultEncoder : Dict String ModuleName.Raw (MVar (Maybe DResult)) -> Bytes.Encode.Encoder
dictRawMVarMaybeDResultEncoder =
    BE.assocListDict compare ModuleName.rawEncoder Utils.mVarEncoder


moduleNameRawMVarMaybeDResultDecoder : Bytes.Decode.Decoder (Dict String ModuleName.Raw (MVar (Maybe DResult)))
moduleNameRawMVarMaybeDResultDecoder =
    BD.assocListDict identity ModuleName.rawDecoder Utils.mVarDecoder


dResultEncoder : DResult -> Bytes.Encode.Encoder
dResultEncoder dResult =
    case dResult of
        RLocal ifaces objects docs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , I.interfaceEncoder ifaces
                , Opt.localGraphEncoder objects
                , BE.maybe Docs.bytesModuleEncoder docs
                ]

        RForeign iface ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , I.interfaceEncoder iface
                ]

        RKernelLocal chunks ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.list Kernel.chunkEncoder chunks
                ]

        RKernelForeign ->
            Bytes.Encode.unsignedInt8 3


dResultDecoder : Bytes.Decode.Decoder DResult
dResultDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 RLocal
                            I.interfaceDecoder
                            Opt.localGraphDecoder
                            (BD.maybe Docs.bytesModuleDecoder)

                    1 ->
                        Bytes.Decode.map RForeign I.interfaceDecoder

                    2 ->
                        Bytes.Decode.map RKernelLocal (BD.list Kernel.chunkDecoder)

                    3 ->
                        Bytes.Decode.succeed RKernelForeign

                    _ ->
                        Bytes.Decode.fail
            )


statusDictEncoder : StatusDict -> Bytes.Encode.Encoder
statusDictEncoder statusDict =
    BE.assocListDict compare ModuleName.rawEncoder Utils.mVarEncoder statusDict


statusDictDecoder : Bytes.Decode.Decoder StatusDict
statusDictDecoder =
    BD.assocListDict identity ModuleName.rawDecoder Utils.mVarDecoder


localEncoder : Local -> Bytes.Encode.Encoder
localEncoder (Local path time deps hasMain lastChange lastCompile) =
    Bytes.Encode.sequence
        [ BE.string path
        , File.timeEncoder time
        , BE.list ModuleName.rawEncoder deps
        , BE.bool hasMain
        , BE.int lastChange
        , BE.int lastCompile
        ]


localDecoder : Bytes.Decode.Decoder Local
localDecoder =
    BD.map6 Local
        BD.string
        File.timeDecoder
        (BD.list ModuleName.rawDecoder)
        BD.bool
        BD.int
        BD.int


validOutlineEncoder : ValidOutline -> Bytes.Encode.Encoder
validOutlineEncoder validOutline =
    case validOutline of
        ValidApp srcDirs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.nonempty Outline.srcDirEncoder srcDirs
                ]

        ValidPkg pkg exposedList exactDeps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Pkg.nameEncoder pkg
                , BE.list ModuleName.rawEncoder exposedList
                , BE.assocListDict compare Pkg.nameEncoder V.versionEncoder exactDeps
                ]


validOutlineDecoder : Bytes.Decode.Decoder ValidOutline
validOutlineDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map ValidApp (BD.nonempty Outline.srcDirDecoder)

                    1 ->
                        Bytes.Decode.map3 ValidPkg
                            Pkg.nameDecoder
                            (BD.list ModuleName.rawDecoder)
                            (BD.assocListDict identity Pkg.nameDecoder V.versionDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


foreignEncoder : Foreign -> Bytes.Encode.Encoder
foreignEncoder (Foreign dep deps) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoder dep
        , BE.list Pkg.nameEncoder deps
        ]


foreignDecoder : Bytes.Decode.Decoder Foreign
foreignDecoder =
    Bytes.Decode.map2 Foreign
        Pkg.nameDecoder
        (BD.list Pkg.nameDecoder)


extrasEncoder : Extras -> Bytes.Encode.Encoder
extrasEncoder extras =
    case extras of
        ArtifactsCached ->
            Bytes.Encode.unsignedInt8 0

        ArtifactsFresh ifaces objs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , interfacesEncoder ifaces
                , Opt.globalGraphEncoder objs
                ]


extrasDecoder : Bytes.Decode.Decoder Extras
extrasDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed ArtifactsCached

                    1 ->
                        Bytes.Decode.map2 ArtifactsFresh
                            interfacesDecoder
                            Opt.globalGraphDecoder

                    _ ->
                        Bytes.Decode.fail
            )


fingerprintEncoder : Fingerprint -> Bytes.Encode.Encoder
fingerprintEncoder =
    BE.assocListDict compare Pkg.nameEncoder V.versionEncoder


fingerprintDecoder : Bytes.Decode.Decoder Fingerprint
fingerprintDecoder =
    BD.assocListDict identity Pkg.nameDecoder V.versionDecoder


docsStatusEncoder : DocsStatus -> Bytes.Encode.Encoder
docsStatusEncoder docsStatus =
    Bytes.Encode.unsignedInt8
        (case docsStatus of
            DocsNeeded ->
                0

            DocsNotNeeded ->
                1
        )


docsStatusDecoder : Bytes.Decode.Decoder DocsStatus
docsStatusDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed DocsNeeded

                    1 ->
                        Bytes.Decode.succeed DocsNotNeeded

                    _ ->
                        Bytes.Decode.fail
            )
