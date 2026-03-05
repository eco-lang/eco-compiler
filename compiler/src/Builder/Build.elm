module Builder.Build exposing
    ( Artifacts(..), ArtifactsData, BResult, Module(..), Root(..)
    , ReplArtifacts(..), ReplArtifactsData
    , CachedInterface(..), Dependencies
    , DocsGoal(..), keepDocs, ignoreDocs, writeDocs
    , fromExposed, fromPaths, fromRepl
    , getRootNames, cachedInterfaceDecoder
    )

{-| Parallel compilation and incremental build orchestration for Elm projects.

This module implements the core build system that compiles Elm modules in parallel,
tracks dependencies between modules, performs incremental compilation based on
modification times and interface changes, and manages build artifacts. It handles
both application and package builds, including REPL sessions.


# Build Results

@docs Artifacts, ArtifactsData, BResult, Module, Root


# REPL Artifacts

@docs ReplArtifacts, ReplArtifactsData


# Module Status

@docs CachedInterface, Dependencies


# Documentation Generation

@docs DocsGoal, keepDocs, ignoreDocs, writeDocs


# Build Entry Points

@docs fromExposed, fromPaths, fromRepl


# Utilities

@docs getRootNames, cachedInterfaceDecoder

-}

import Basics.Extra exposing (flip)
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedModuleArtifact as TMod
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Compile as Compile
import Compiler.Data.Map.Utils as Map
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Interface as I
import Compiler.Elm.Kernel as Kernel
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Json.Encode as E
import Compiler.Parse.Module as Parse
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error as Error
import Compiler.Reporting.Error.Docs as EDocs
import Compiler.Reporting.Error.Import as Import
import Compiler.Reporting.Error.Syntax as Syntax
import Compiler.Reporting.Render.Type.Localizer as L
import Compiler.Graph as Graph
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import System.IO exposing (FilePath, MVar(..))
import Utils.Main as Utils



-- ====== ENVIRONMENT ======


type alias EnvData =
    { key : Reporting.BKey
    , root : String
    , maybeBuildDir : Maybe String
    , projectType : Parse.ProjectType
    , srcDirs : List AbsoluteSrcDir
    , buildID : Details.BuildID
    , locals : Dict String ModuleName.Raw Details.Local
    , foreigns : Dict String ModuleName.Raw Details.Foreign
    , needsTypedOpt : Bool
    }


type Env
    = Env EnvData


makeEnv : Reporting.BKey -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Bool -> Task Never Env
makeEnv key root maybeBuildDir maybeKernelPackage (Details.Details detailsData) needsTypedOpt =
    case detailsData.outline of
        Details.ValidApp givenSrcDirs ->
            Utils.listTraverse (toAbsoluteSrcDir root) (NE.toList givenSrcDirs)
                |> Task.map
                    (\srcDirs ->
                        Env
                            { key = key
                            , root = root
                            , maybeBuildDir = maybeBuildDir
                            , projectType =
                                case maybeKernelPackage of
                                    Nothing ->
                                        Parse.Application

                                    Just pkg ->
                                        Parse.KernelApplication pkg
                            , srcDirs = srcDirs
                            , buildID = detailsData.buildID
                            , locals = detailsData.locals
                            , foreigns = detailsData.foreigns
                            , needsTypedOpt = needsTypedOpt
                            }
                    )

        Details.ValidPkg pkg _ _ ->
            toAbsoluteSrcDir root (Outline.RelativeSrcDir "src")
                |> Task.map
                    (\srcDir ->
                        Env
                            { key = key
                            , root = root
                            , maybeBuildDir = maybeBuildDir
                            , projectType = Parse.Package pkg
                            , srcDirs = [ srcDir ]
                            , buildID = detailsData.buildID
                            , locals = detailsData.locals
                            , foreigns = detailsData.foreigns
                            , needsTypedOpt = needsTypedOpt
                            }
                    )



-- ====== SOURCE DIRECTORY ======


type AbsoluteSrcDir
    = AbsoluteSrcDir FilePath


toAbsoluteSrcDir : FilePath -> Outline.SrcDir -> Task Never AbsoluteSrcDir
toAbsoluteSrcDir root srcDir =
    Task.map AbsoluteSrcDir
        (Utils.dirCanonicalizePath
            (case srcDir of
                Outline.AbsoluteSrcDir dir ->
                    dir

                Outline.RelativeSrcDir dir ->
                    Utils.fpCombine root dir
            )
        )


addRelative : AbsoluteSrcDir -> FilePath -> FilePath
addRelative (AbsoluteSrcDir srcDir) path =
    Utils.fpCombine srcDir path



-- ====== FORK ======


{-| PERF try using IORef semephore on file crawl phase?
described in Chapter 13 of Parallel and Concurrent Programming in Haskell by Simon Marlow
<https://www.oreilly.com/library/view/parallel-and-concurrent/9781449335939/ch13.html#sec_conc-par-overhead>
-}
fork : (a -> Bytes.Encode.Encoder) -> Task Never a -> Task Never (MVar a)
fork encoder work =
    Utils.newEmptyMVar
        |> Task.andThen
            (\mvar ->
                Utils.forkIO (Task.andThen (Utils.putMVar encoder mvar) work)
                    |> Task.map (\_ -> mvar)
            )


forkWithKey : (k -> comparable) -> (k -> k -> Order) -> (b -> Bytes.Encode.Encoder) -> (k -> a -> Task Never b) -> Dict comparable k a -> Task Never (Dict comparable k (MVar b))
forkWithKey toComparable keyComparison encoder func dict =
    Utils.mapTraverseWithKey toComparable keyComparison (\k v -> fork encoder (func k v)) dict



-- ====== FROM EXPOSED ======


{-| Build a project by compiling a specific list of exposed modules (e.g., for package builds).

This entry point compiles the given modules and their dependencies, respecting the
documentation goal (keep, write, or ignore). It performs parallel compilation with
incremental rebuilding based on modification times and interface changes.

-}
fromExposed : Bytes.Decode.Decoder docs -> (docs -> Bytes.Encode.Encoder) -> Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> DocsGoal docs -> NE.Nonempty ModuleName.Raw -> Task Never (Result Exit.BuildProblem docs)
fromExposed docsDecoder docsEncoder style root maybeBuildDir maybeKernelPackage details docsGoal ((NE.Nonempty e es) as exposed) =
    Reporting.trackBuild docsDecoder docsEncoder style <|
        \key ->
            makeEnv key root maybeBuildDir maybeKernelPackage details False
                |> Task.andThen (crawlExposed root maybeBuildDir details docsGoal (e :: es))
                |> Task.andThen (compileExposed root maybeBuildDir details docsGoal exposed)


{-| Crawl phase for exposed modules: discover all dependencies and their statuses.
-}
crawlExposed : FilePath -> Maybe String -> Details.Details -> DocsGoal docs -> List ModuleName.Raw -> Env -> Task Never { dmvar : MVar (Maybe Dependencies), statuses : Dict String ModuleName.Raw Status, env : Env }
crawlExposed root maybeBuildDir details docsGoal modules env =
    let
        docsNeed : DocsNeed
        docsNeed =
            toDocsNeed docsGoal
    in
    Details.loadInterfaces root maybeBuildDir details
        |> Task.andThen (crawlExposedModules env docsNeed modules)
        |> Task.map (buildCrawlResult env)


crawlExposedModules : Env -> DocsNeed -> List ModuleName.Raw -> MVar (Maybe Dependencies) -> Task Never ( MVar (Maybe Dependencies), Dict String ModuleName.Raw Status )
crawlExposedModules env docsNeed modules dmvar =
    Utils.newEmptyMVar
        |> Task.andThen (crawlAndCollectStatuses env docsNeed modules)
        |> Task.map (\statuses -> ( dmvar, statuses ))


crawlAndCollectStatuses : Env -> DocsNeed -> List ModuleName.Raw -> MVar StatusDict -> Task Never (Dict String ModuleName.Raw Status)
crawlAndCollectStatuses env docsNeed modules mvar =
    Map.fromKeysA identity (fork statusEncoder << crawlModule env mvar docsNeed) modules
        |> Task.andThen (waitForCrawlResults mvar)


waitForCrawlResults : MVar StatusDict -> StatusDict -> Task Never (Dict String ModuleName.Raw Status)
waitForCrawlResults mvar roots =
    Utils.putMVar statusDictEncoder mvar roots
        |> Task.andThen (\_ -> Utils.dictMapM_ compare (Utils.readMVar statusDecoder) roots)
        |> Task.andThen (\_ -> Utils.readMVar statusDictDecoder mvar)
        |> Task.andThen (Utils.mapTraverse identity compare (Utils.readMVar statusDecoder))


buildCrawlResult : Env -> ( MVar (Maybe Dependencies), Dict String ModuleName.Raw Status ) -> { dmvar : MVar (Maybe Dependencies), statuses : Dict String ModuleName.Raw Status, env : Env }
buildCrawlResult env ( dmvar, statuses ) =
    { dmvar = dmvar, statuses = statuses, env = env }


{-| Compile phase for exposed modules: check midpoint and compile all modules.
-}
compileExposed : FilePath -> Maybe String -> Details.Details -> DocsGoal docs -> NE.Nonempty ModuleName.Raw -> { dmvar : MVar (Maybe Dependencies), statuses : Dict String ModuleName.Raw Status, env : Env } -> Task Never (Result Exit.BuildProblem docs)
compileExposed root maybeBuildDir details docsGoal exposed { dmvar, statuses, env } =
    checkMidpoint dmvar statuses
        |> Task.andThen (handleExposedMidpoint root maybeBuildDir details docsGoal exposed statuses env)


handleExposedMidpoint : FilePath -> Maybe String -> Details.Details -> DocsGoal docs -> NE.Nonempty ModuleName.Raw -> Dict String ModuleName.Raw Status -> Env -> Result Exit.BuildProjectProblem Dependencies -> Task Never (Result Exit.BuildProblem docs)
handleExposedMidpoint root maybeBuildDir details docsGoal exposed statuses env midpoint =
    case midpoint of
        Err problem ->
            Task.succeed (Err (Exit.BuildProjectProblem problem))

        Ok foreigns ->
            compileAndFinalize root maybeBuildDir details foreigns statuses env
                |> Task.andThen (finalizeExposed root docsGoal exposed)


{-| Compile all modules and write details.
-}
compileAndFinalize : FilePath -> Maybe String -> Details.Details -> Dependencies -> Dict String ModuleName.Raw Status -> Env -> Task Never (Dict String ModuleName.Raw BResult)
compileAndFinalize root maybeBuildDir details foreigns statuses env =
    Utils.newEmptyMVar
        |> Task.andThen (compileAllModules env foreigns statuses)
        |> Task.andThen (collectResultsAndWriteDetails root maybeBuildDir details)


compileAllModules : Env -> Dependencies -> Dict String ModuleName.Raw Status -> MVar ResultDict -> Task Never ( MVar ResultDict, Dict String ModuleName.Raw (MVar BResult) )
compileAllModules env foreigns statuses rmvar =
    forkWithKey identity compare bResultEncoder (checkModule env foreigns rmvar) statuses
        |> Task.map (\resultMVars -> ( rmvar, resultMVars ))


collectResultsAndWriteDetails : FilePath -> Maybe String -> Details.Details -> ( MVar (Dict String ModuleName.Raw (MVar BResult)), Dict String ModuleName.Raw (MVar BResult) ) -> Task Never (Dict String ModuleName.Raw BResult)
collectResultsAndWriteDetails root maybeBuildDir details ( rmvar, resultMVars ) =
    Utils.putMVar dictRawMVarBResultEncoder rmvar resultMVars
        |> Task.andThen (\_ -> Utils.mapTraverse identity compare (Utils.readMVar bResultDecoder) resultMVars)
        |> Task.andThen (writeDetailsAndReturn root maybeBuildDir details)


writeDetailsAndReturn : FilePath -> Maybe String -> Details.Details -> Dict String ModuleName.Raw BResult -> Task Never (Dict String ModuleName.Raw BResult)
writeDetailsAndReturn root maybeBuildDir details results =
    writeDetails root maybeBuildDir details results
        |> Task.map (\_ -> results)



-- ====== FROM PATHS ======


{-| Data contained within build artifacts.
-}
type alias ArtifactsData =
    { pkg : Pkg.Name
    , deps : Dependencies
    , roots : NE.Nonempty Root
    , modules : List Module
    }


{-| Complete build artifacts including compiled modules, dependency interfaces, and root modules.
-}
type Artifacts
    = Artifacts ArtifactsData


{-| Represents a compiled module, either freshly compiled or loaded from cache.
-}
type Module
    = Fresh ModuleName.Raw I.Interface Opt.LocalGraph (Maybe TOpt.LocalGraph) (Maybe TypeEnv.ModuleTypeEnv)
    | Cached ModuleName.Raw Bool (MVar CachedInterface)


{-| Map of dependency module interfaces needed for type checking.
-}
type alias Dependencies =
    Dict (List String) TypeCheck.Canonical I.DependencyInterface


{-| Build a project by compiling modules from specific file paths (e.g., for application builds).

This entry point discovers modules from the given file paths, crawls their dependencies,
and performs parallel incremental compilation.

-}
fromPaths : Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Bool -> NE.Nonempty FilePath -> Task Never (Result Exit.BuildProblem Artifacts)
fromPaths style root maybeBuildDir maybeKernelPackage details needsTypedOpt paths =
    Reporting.trackBuild artifactsDecoder artifactsEncoder style <|
        \key ->
            makeEnv key root maybeBuildDir maybeKernelPackage details needsTypedOpt
                |> Task.andThen (findAndBuildFromPaths root maybeBuildDir details paths)


findAndBuildFromPaths : FilePath -> Maybe String -> Details.Details -> NE.Nonempty FilePath -> Env -> Task Never (Result Exit.BuildProblem Artifacts)
findAndBuildFromPaths root maybeBuildDir details paths env =
    findRoots env paths
        |> Task.andThen (handleFoundRoots root maybeBuildDir details env)


handleFoundRoots : FilePath -> Maybe String -> Details.Details -> Env -> Result Exit.BuildProjectProblem (NE.Nonempty RootLocation) -> Task Never (Result Exit.BuildProblem Artifacts)
handleFoundRoots root maybeBuildDir details env elroots =
    case elroots of
        Err problem ->
            Task.succeed (Err (Exit.BuildProjectProblem problem))

        Ok lroots ->
            crawlPaths root maybeBuildDir details env lroots
                |> Task.andThen (compilePaths root maybeBuildDir details env)


{-| Context passed between crawl and compile phases for path-based builds.
-}
type alias PathsBuildContext =
    { dmvar : MVar (Maybe Dependencies)
    , statuses : Dict String ModuleName.Raw Status
    , sroots : NE.Nonempty RootStatus
    }


{-| Crawl phase for path-based builds: discover all module statuses and root statuses.
-}
crawlPaths : FilePath -> Maybe String -> Details.Details -> Env -> NE.Nonempty RootLocation -> Task Never PathsBuildContext
crawlPaths root maybeBuildDir details env lroots =
    Details.loadInterfaces root maybeBuildDir details
        |> Task.andThen (crawlPathRoots env lroots)


crawlPathRoots : Env -> NE.Nonempty RootLocation -> MVar (Maybe Dependencies) -> Task Never PathsBuildContext
crawlPathRoots env lroots dmvar =
    Utils.newMVar statusDictEncoder Dict.empty
        |> Task.andThen (crawlRootsAndCollect env lroots dmvar)


crawlRootsAndCollect : Env -> NE.Nonempty RootLocation -> MVar (Maybe Dependencies) -> MVar StatusDict -> Task Never PathsBuildContext
crawlRootsAndCollect env lroots dmvar smvar =
    Utils.nonEmptyListTraverse (fork rootStatusEncoder << crawlRoot env smvar) lroots
        |> Task.andThen (Utils.nonEmptyListTraverse (Utils.readMVar rootStatusDecoder))
        |> Task.andThen (collectPathStatuses dmvar smvar)


collectPathStatuses : MVar (Maybe Dependencies) -> MVar StatusDict -> NE.Nonempty RootStatus -> Task Never PathsBuildContext
collectPathStatuses dmvar smvar sroots =
    Utils.readMVar statusDictDecoder smvar
        |> Task.andThen (Utils.mapTraverse identity compare (Utils.readMVar statusDecoder))
        |> Task.map (\statuses -> { dmvar = dmvar, statuses = statuses, sroots = sroots })


{-| Compile phase for path-based builds: check midpoint, compile modules, and build artifacts.
-}
compilePaths : FilePath -> Maybe String -> Details.Details -> Env -> PathsBuildContext -> Task Never (Result Exit.BuildProblem Artifacts)
compilePaths root maybeBuildDir details env { dmvar, statuses, sroots } =
    checkMidpointAndRoots dmvar statuses sroots
        |> Task.andThen (handlePathsMidpoint root maybeBuildDir details env statuses sroots)


handlePathsMidpoint : FilePath -> Maybe String -> Details.Details -> Env -> Dict String ModuleName.Raw Status -> NE.Nonempty RootStatus -> Result Exit.BuildProjectProblem Dependencies -> Task Never (Result Exit.BuildProblem Artifacts)
handlePathsMidpoint root maybeBuildDir details env statuses sroots midpoint =
    case midpoint of
        Err problem ->
            Task.succeed (Err (Exit.BuildProjectProblem problem))

        Ok foreigns ->
            compilePathModules root maybeBuildDir details env foreigns statuses sroots


{-| Compile all modules for path-based builds and produce artifacts.
-}
compilePathModules : FilePath -> Maybe String -> Details.Details -> Env -> Dependencies -> Dict String ModuleName.Raw Status -> NE.Nonempty RootStatus -> Task Never (Result Exit.BuildProblem Artifacts)
compilePathModules root maybeBuildDir details env foreigns statuses sroots =
    Utils.newEmptyMVar
        |> Task.andThen (compilePathsWithMVar env foreigns statuses sroots)
        |> Task.andThen (finalizePathBuild root maybeBuildDir details env foreigns)


compilePathsWithMVar : Env -> Dependencies -> Dict String ModuleName.Raw Status -> NE.Nonempty RootStatus -> MVar ResultDict -> Task Never PathCompileState
compilePathsWithMVar env foreigns statuses sroots rmvar =
    forkWithKey identity compare bResultEncoder (checkModule env foreigns rmvar) statuses
        |> Task.andThen (checkRootsAndCollect env sroots rmvar)


type alias PathCompileState =
    { resultsMVars : Dict String ModuleName.Raw (MVar BResult)
    , rrootMVars : NE.Nonempty (MVar RootResult)
    }


checkRootsAndCollect : Env -> NE.Nonempty RootStatus -> MVar ResultDict -> Dict String ModuleName.Raw (MVar BResult) -> Task Never PathCompileState
checkRootsAndCollect env sroots rmvar resultsMVars =
    Utils.putMVar resultDictEncoder rmvar resultsMVars
        |> Task.andThen (\_ -> Utils.nonEmptyListTraverse (checkRoot env resultsMVars >> fork rootResultEncoder) sroots)
        |> Task.map (\rrootMVars -> { resultsMVars = resultsMVars, rrootMVars = rrootMVars })


finalizePathBuild : FilePath -> Maybe String -> Details.Details -> Env -> Dependencies -> { resultsMVars : Dict String ModuleName.Raw (MVar BResult), rrootMVars : NE.Nonempty (MVar RootResult) } -> Task Never (Result Exit.BuildProblem Artifacts)
finalizePathBuild root maybeBuildDir details env foreigns { resultsMVars, rrootMVars } =
    Utils.mapTraverse identity compare (Utils.readMVar bResultDecoder) resultsMVars
        |> Task.andThen (writeDetailsAndCollectRoots root maybeBuildDir details rrootMVars)
        |> Task.map (toArtifactsFromResults env foreigns)


writeDetailsAndCollectRoots : FilePath -> Maybe String -> Details.Details -> NE.Nonempty (MVar RootResult) -> Dict String ModuleName.Raw BResult -> Task Never ( Dict String ModuleName.Raw BResult, NE.Nonempty RootResult )
writeDetailsAndCollectRoots root maybeBuildDir details rrootMVars results =
    writeDetails root maybeBuildDir details results
        |> Task.andThen (\_ -> Utils.nonEmptyListTraverse (Utils.readMVar rootResultDecoder) rrootMVars)
        |> Task.map (\rroots -> ( results, rroots ))


toArtifactsFromResults : Env -> Dependencies -> ( Dict String ModuleName.Raw BResult, NE.Nonempty RootResult ) -> Result Exit.BuildProblem Artifacts
toArtifactsFromResults env foreigns ( results, rroots ) =
    toArtifacts env foreigns results rroots



-- ====== GET ROOT NAMES ======


{-| Extract the module names of all root modules from the build artifacts.
-}
getRootNames : Artifacts -> NE.Nonempty ModuleName.Raw
getRootNames (Artifacts a) =
    NE.map getRootName a.roots


getRootName : Root -> ModuleName.Raw
getRootName root =
    case root of
        Inside name ->
            name

        Outside name _ _ _ _ ->
            name



-- ====== CRAWL ======


type alias StatusDict =
    Dict String ModuleName.Raw (MVar Status)


type Status
    = SCached Details.Local
    | SChanged Details.Local String Src.Module DocsNeed
    | SBadImport Import.Problem
    | SBadSyntax FilePath File.Time String Syntax.Error
    | SForeign Pkg.Name
    | SKernel


crawlDeps : Env -> MVar StatusDict -> List ModuleName.Raw -> a -> Task Never a
crawlDeps env mvar deps blockedValue =
    Utils.takeMVar statusDictDecoder mvar
        |> Task.andThen (crawlNewDeps env mvar deps)
        |> Task.map (\_ -> blockedValue)


crawlNewDeps : Env -> MVar StatusDict -> List ModuleName.Raw -> StatusDict -> Task Never ()
crawlNewDeps env mvar deps statusDict =
    let
        crawlNew : ModuleName.Raw -> () -> Task Never (MVar Status)
        crawlNew name () =
            fork statusEncoder (crawlModule env mvar (DocsNeed False) name)

        depsDict : Dict String ModuleName.Raw ()
        depsDict =
            Map.fromKeys (\_ -> ()) deps

        newsDict : Dict String ModuleName.Raw ()
        newsDict =
            Dict.diff depsDict statusDict
    in
    Utils.mapTraverseWithKey identity compare crawlNew newsDict
        |> Task.andThen (updateStatusDictAndWait mvar statusDict)


updateStatusDictAndWait : MVar StatusDict -> StatusDict -> StatusDict -> Task Never ()
updateStatusDictAndWait mvar statusDict statuses =
    Utils.putMVar statusDictEncoder mvar (Dict.union statuses statusDict)
        |> Task.andThen (\_ -> Utils.dictMapM_ compare (Utils.readMVar statusDecoder) statuses)


crawlModule : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Task Never Status
crawlModule ((Env envData) as env) mvar ((DocsNeed needsDocs) as docsNeed) name =
    let
        elmFileName : String
        elmFileName =
            ModuleName.toFilePath name ++ ".elm"
    in
    findModulePaths envData.srcDirs elmFileName
        |> Task.andThen (crawlFoundPaths env mvar docsNeed name needsDocs envData.root envData.projectType envData.buildID envData.locals envData.foreigns)


findModulePaths : List AbsoluteSrcDir -> String -> Task Never (List FilePath)
findModulePaths srcDirs elmFileName =
    Utils.filterM File.exists (List.map (flip addRelative elmFileName) srcDirs)


crawlFoundPaths : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Bool -> FilePath -> Parse.ProjectType -> Details.BuildID -> Dict String ModuleName.Raw Details.Local -> Dict String ModuleName.Raw Details.Foreign -> List FilePath -> Task Never Status
crawlFoundPaths env mvar docsNeed name needsDocs root projectType buildID locals foreigns paths =
    case paths of
        [ path ] ->
            crawlSinglePath env mvar docsNeed name needsDocs buildID locals foreigns path

        p1 :: p2 :: ps ->
            Import.AmbiguousLocal (Utils.fpMakeRelative root p1) (Utils.fpMakeRelative root p2) (List.map (Utils.fpMakeRelative root) ps) |> SBadImport |> Task.succeed

        [] ->
            let
                (Env envData) =
                    env
            in
            crawlNoLocalPath name projectType foreigns envData.srcDirs


crawlSinglePath : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Bool -> Details.BuildID -> Dict String ModuleName.Raw Details.Local -> Dict String ModuleName.Raw Details.Foreign -> FilePath -> Task Never Status
crawlSinglePath env mvar docsNeed name needsDocs buildID locals foreigns path =
    case Dict.get identity name foreigns of
        Just (Details.Foreign dep deps) ->
            Import.Ambiguous path [] dep deps |> SBadImport |> Task.succeed

        Nothing ->
            File.getTime path
                |> Task.andThen (crawlWithTime env mvar docsNeed name needsDocs buildID locals path)


crawlWithTime : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Bool -> Details.BuildID -> Dict String ModuleName.Raw Details.Local -> FilePath -> File.Time -> Task Never Status
crawlWithTime env mvar docsNeed name needsDocs buildID locals path newTime =
    case Dict.get identity name locals of
        Nothing ->
            crawlFile env mvar docsNeed name path newTime buildID

        Just ((Details.Local localData) as local) ->
            if path /= localData.path || localData.time /= newTime || needsDocs then
                crawlFile env mvar docsNeed name path newTime localData.lastChange

            else
                crawlDeps env mvar localData.deps (SCached local)


crawlNoLocalPath : ModuleName.Raw -> Parse.ProjectType -> Dict String ModuleName.Raw Details.Foreign -> List AbsoluteSrcDir -> Task Never Status
crawlNoLocalPath name projectType foreigns srcDirs =
    case Dict.get identity name foreigns of
        Just (Details.Foreign dep deps) ->
            case deps of
                [] ->
                    SForeign dep |> Task.succeed

                d :: ds ->
                    Import.AmbiguousForeign dep d ds |> SBadImport |> Task.succeed

        Nothing ->
            if Name.isKernel name && Parse.isKernel projectType then
                let
                    pkg =
                        projectTypeToPkg projectType

                    foreignHomes =
                        Dict.map (\_ (Details.Foreign home _) -> home) foreigns
                in
                checkKernelExistsInDirs name pkg foreignHomes srcDirs

            else
                SBadImport Import.NotFound |> Task.succeed


checkKernelExistsInDirs : ModuleName.Raw -> Pkg.Name -> Dict String ModuleName.Raw Pkg.Name -> List AbsoluteSrcDir -> Task Never Status
checkKernelExistsInDirs name pkg foreignHomes srcDirs =
    case srcDirs of
        [] ->
            SBadImport Import.NotFound |> Task.succeed

        (AbsoluteSrcDir dir) :: rest ->
            let
                jsPath =
                    dir ++ "/" ++ ModuleName.toFilePath name ++ ".js"
            in
            File.exists jsPath
                |> Task.andThen
                    (\exists ->
                        if exists then
                            File.readUtf8 jsPath
                                |> Task.map
                                    (\bytes ->
                                        case Kernel.fromByteString pkg foreignHomes bytes of
                                            Just (Kernel.Content _ _) ->
                                                SKernel

                                            Nothing ->
                                                SKernel
                                    )

                        else
                            checkKernelExistsInDirs name pkg foreignHomes rest
                    )


crawlFile : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> FilePath -> File.Time -> Details.BuildID -> Task Never Status
crawlFile ((Env envData) as env) mvar docsNeed expectedName path time lastChange =
    File.readUtf8 (Utils.fpCombine envData.root path)
        |> Task.andThen
            (\source ->
                case Parse.fromByteString envData.projectType source of
                    Err err ->
                        SBadSyntax path time source err |> Task.succeed

                    Ok ((Src.Module srcData) as modul) ->
                        case srcData.name of
                            Nothing ->
                                SBadSyntax path time source (Syntax.ModuleNameUnspecified expectedName) |> Task.succeed

                            Just ((A.At _ actualName) as name) ->
                                if expectedName == actualName then
                                    let
                                        deps : List Name.Name
                                        deps =
                                            List.map Src.getImportName srcData.imports

                                        local : Details.Local
                                        local =
                                            Details.Local
                                                { path = path
                                                , time = time
                                                , deps = deps
                                                , hasMain = List.any isMain srcData.values
                                                , lastChange = lastChange
                                                , lastCompile = envData.buildID
                                                }
                                    in
                                    crawlDeps env mvar deps (SChanged local source modul docsNeed)

                                else
                                    SBadSyntax path time source (Syntax.ModuleNameMismatch expectedName name) |> Task.succeed
            )


isMain : A.Located Src.Value -> Bool
isMain (A.At _ (Src.Value v)) =
    let
        ( _, A.At _ name ) =
            v.name
    in
    name == Name.main_



-- ====== CHECK MODULE ======


type alias ResultDict =
    Dict String ModuleName.Raw (MVar BResult)


{-| Build result for a single module after compilation or cache lookup.

Tracks whether the module was freshly compiled, unchanged from cache, or encountered errors.

-}
type BResult
    = RNew Details.Local I.Interface Opt.LocalGraph (Maybe TOpt.LocalGraph) (Maybe TypeEnv.ModuleTypeEnv) (Maybe Docs.Module)
    | RSame Details.Local I.Interface Opt.LocalGraph (Maybe TOpt.LocalGraph) (Maybe TypeEnv.ModuleTypeEnv) (Maybe Docs.Module)
    | RCached Bool Details.BuildID (MVar CachedInterface)
    | RNotFound Import.Problem
    | RProblem Error.Module
    | RBlocked
    | RForeign I.Interface
    | RKernel
    | RKernelLocal (List Kernel.Chunk)


{-| State of a cached module interface: unneeded, successfully loaded, or corrupted.
-}
type CachedInterface
    = Unneeded
    | Loaded I.Interface
    | Corrupted


checkModule : Env -> Dependencies -> MVar ResultDict -> ModuleName.Raw -> Status -> Task Never BResult
checkModule ((Env envData) as env) foreigns resultsMVar name status =
    case status of
        SCached ((Details.Local localData) as local) ->
            checkCachedModule env envData.root envData.projectType resultsMVar name localData.path localData.time localData.deps localData.hasMain localData.lastChange localData.lastCompile local

        SChanged ((Details.Local localData) as local) source ((Src.Module srcData) as modul) docsNeed ->
            checkChangedModule env envData.root resultsMVar name localData.path localData.time localData.deps localData.lastCompile local source srcData.imports modul docsNeed

        SBadImport importProblem ->
            Task.succeed (RNotFound importProblem)

        SBadSyntax path time source err ->
            Error.BadSyntax err |> Error.Module name path time source |> RProblem |> Task.succeed

        SForeign home ->
            case Utils.find ModuleName.toComparableCanonical (TypeCheck.Canonical home name) foreigns of
                I.Public iface ->
                    Task.succeed (RForeign iface)

                I.Private _ _ _ ->
                    ("mistakenly seeing private interface for " ++ Pkg.toChars home ++ " " ++ name) |> crash

        SKernel ->
            Task.succeed RKernel


checkCachedModule :
    Env
    -> FilePath
    -> Parse.ProjectType
    -> MVar ResultDict
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> Details.BuildID
    -> Details.Local
    -> Task Never BResult
checkCachedModule env root projectType resultsMVar name path time deps hasMain lastChange lastCompile local =
    Utils.readMVar resultDictDecoder resultsMVar
        |> Task.andThen (\resultDict -> checkDeps root resultDict deps lastCompile)
        |> Task.andThen (handleCachedDepsStatus env root projectType name path time deps hasMain lastChange local)


handleCachedDepsStatus :
    Env
    -> FilePath
    -> Parse.ProjectType
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> Details.Local
    -> DepsStatus
    -> Task Never BResult
handleCachedDepsStatus ((Env envData) as env) root projectType name path time deps hasMain lastChange _ depsStatus =
    case depsStatus of
        DepsSame same cached ->
            -- Check if typed optimization is needed but .ecot doesn't exist
            if envData.needsTypedOpt then
                File.exists (Stuff.ecot root name)
                    |> Task.andThen (handleCachedWithTypedOptCheck env root projectType name path time deps hasMain lastChange same cached)

            else
                Utils.newEmptyMVar
                    |> Task.map (\mvar -> RCached hasMain lastChange mvar)

        DepsChange ifaces ->
            -- Dependencies changed, need to read source and recompile
            File.readUtf8 (Utils.fpCombine root path)
                |> Task.andThen (recompileCachedModule env root projectType name path time deps ifaces)

        DepsBlock ->
            Task.succeed RBlocked

        DepsNotFound _ ->
            -- Can't provide proper import errors without source, just block
            Task.succeed RBlocked


handleCachedWithTypedOptCheck :
    Env
    -> FilePath
    -> Parse.ProjectType
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> List Dep
    -> List CDep
    -> Bool
    -> Task Never BResult
handleCachedWithTypedOptCheck env root projectType name path time deps hasMain lastChange same cached ecotExists =
    if ecotExists then
        -- .ecot exists, can use cached
        Utils.newEmptyMVar
            |> Task.map (\mvar -> RCached hasMain lastChange mvar)

    else
        -- .ecot doesn't exist, need to recompile with typed optimization
        loadInterfaces root same cached
            |> Task.andThen (recompileIfInterfacesLoaded env root projectType name path time deps)


recompileIfInterfacesLoaded :
    Env
    -> FilePath
    -> Parse.ProjectType
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Maybe (Dict String ModuleName.Raw I.Interface)
    -> Task Never BResult
recompileIfInterfacesLoaded env root projectType name path time deps maybeIfaces =
    case maybeIfaces of
        Nothing ->
            Task.succeed RBlocked

        Just ifaces ->
            File.readUtf8 (Utils.fpCombine root path)
                |> Task.andThen (recompileCachedModule env root projectType name path time deps ifaces)


recompileCachedModule :
    Env
    -> FilePath
    -> Parse.ProjectType
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Dict String ModuleName.Raw I.Interface
    -> String
    -> Task Never BResult
recompileCachedModule env _ projectType name path time deps ifaces source =
    case Parse.fromByteString projectType source of
        Err err ->
            Error.BadSyntax err |> Error.Module name path time source |> RProblem |> Task.succeed

        Ok ((Src.Module srcData) as modul) ->
            let
                local =
                    Details.Local
                        { path = path
                        , time = time
                        , deps = deps
                        , hasMain = List.any isMain srcData.values
                        , lastChange = 0
                        , lastCompile = 0
                        }
            in
            compile env (DocsNeed False) local source ifaces modul


checkChangedModule :
    Env
    -> FilePath
    -> MVar ResultDict
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Details.BuildID
    -> Details.Local
    -> String
    -> List Src.Import
    -> Src.Module
    -> DocsNeed
    -> Task Never BResult
checkChangedModule env root resultsMVar name path time deps lastCompile local source imports modul docsNeed =
    Utils.readMVar resultDictDecoder resultsMVar
        |> Task.andThen (\resultDict -> checkDeps root resultDict deps lastCompile |> Task.map (\status -> ( resultDict, status )))
        |> Task.andThen (\( resultDict, depsStatus ) -> handleChangedDepsStatus env resultDict root name path time local source imports modul docsNeed depsStatus)


handleChangedDepsStatus :
    Env
    -> ResultDict
    -> FilePath
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> Details.Local
    -> String
    -> List Src.Import
    -> Src.Module
    -> DocsNeed
    -> DepsStatus
    -> Task Never BResult
handleChangedDepsStatus env resultDict root name path time local source imports modul docsNeed depsStatus =
    case depsStatus of
        DepsSame same cached ->
            -- Source changed, need to compile even if deps are same
            loadInterfaces root same cached
                |> Task.andThen (compileIfInterfacesLoaded env local source modul docsNeed)

        DepsChange ifaces ->
            compile env docsNeed local source ifaces modul

        DepsBlock ->
            Task.succeed RBlocked

        DepsNotFound problems ->
            makeImportError env resultDict name path time source imports problems


compileIfInterfacesLoaded :
    Env
    -> Details.Local
    -> String
    -> Src.Module
    -> DocsNeed
    -> Maybe (Dict String ModuleName.Raw I.Interface)
    -> Task Never BResult
compileIfInterfacesLoaded env local source modul docsNeed maybeIfaces =
    case maybeIfaces of
        Nothing ->
            Task.succeed RBlocked

        Just ifaces ->
            compile env docsNeed local source ifaces modul


makeImportError :
    Env
    -> ResultDict
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> String
    -> List Src.Import
    -> NE.Nonempty ( ModuleName.Raw, Import.Problem )
    -> Task Never BResult
makeImportError env resultDict name path time source imports problems =
    Error.BadImports (toImportErrors env resultDict imports problems) |> Error.Module name path time source |> RProblem |> Task.succeed



-- ====== CHECK DEPS ======


type DepsStatus
    = DepsChange (Dict String ModuleName.Raw I.Interface)
    | DepsSame (List Dep) (List CDep)
    | DepsBlock
    | DepsNotFound (NE.Nonempty ( ModuleName.Raw, Import.Problem ))


checkDeps : FilePath -> ResultDict -> List ModuleName.Raw -> Details.BuildID -> Task Never DepsStatus
checkDeps root results deps lastCompile =
    checkDepsHelp root results deps [] [] [] [] False 0 lastCompile


type alias Dep =
    ( ModuleName.Raw, I.Interface )


type alias CDep =
    ( ModuleName.Raw, MVar CachedInterface )


checkDepsHelp :
    FilePath
    -> ResultDict
    -> List ModuleName.Raw
    -> List Dep
    -> List Dep
    -> List CDep
    -> List ( ModuleName.Raw, Import.Problem )
    -> Bool
    -> Details.BuildID
    -> Details.BuildID
    -> Task Never DepsStatus
checkDepsHelp root results deps new same cached importProblems isBlocked lastDepChange lastCompile =
    case deps of
        dep :: otherDeps ->
            Utils.readMVar bResultDecoder (Utils.find identity dep results)
                |> Task.andThen
                    (\result ->
                        case result of
                            RNew (Details.Local localData) iface _ _ _ _ ->
                                checkDepsHelp root results otherDeps (( dep, iface ) :: new) same cached importProblems isBlocked (max localData.lastChange lastDepChange) lastCompile

                            RSame (Details.Local localData) iface _ _ _ _ ->
                                checkDepsHelp root results otherDeps new (( dep, iface ) :: same) cached importProblems isBlocked (max localData.lastChange lastDepChange) lastCompile

                            RCached _ lastChange mvar ->
                                checkDepsHelp root results otherDeps new same (( dep, mvar ) :: cached) importProblems isBlocked (max lastChange lastDepChange) lastCompile

                            RNotFound prob ->
                                checkDepsHelp root results otherDeps new same cached (( dep, prob ) :: importProblems) True lastDepChange lastCompile

                            RProblem _ ->
                                checkDepsHelp root results otherDeps new same cached importProblems True lastDepChange lastCompile

                            RBlocked ->
                                checkDepsHelp root results otherDeps new same cached importProblems True lastDepChange lastCompile

                            RForeign iface ->
                                checkDepsHelp root results otherDeps new (( dep, iface ) :: same) cached importProblems isBlocked lastDepChange lastCompile

                            RKernel ->
                                checkDepsHelp root results otherDeps new same cached importProblems isBlocked lastDepChange lastCompile

                            RKernelLocal _ ->
                                checkDepsHelp root results otherDeps new same cached importProblems isBlocked lastDepChange lastCompile
                    )

        [] ->
            case List.reverse importProblems of
                p :: ps ->
                    DepsNotFound (NE.Nonempty p ps) |> Task.succeed

                [] ->
                    if isBlocked then
                        DepsBlock |> Task.succeed

                    else if List.isEmpty new && lastDepChange <= lastCompile then
                        DepsSame same cached |> Task.succeed

                    else
                        loadInterfaces root same cached
                            |> Task.map
                                (\maybeLoaded ->
                                    case maybeLoaded of
                                        Nothing ->
                                            DepsBlock

                                        Just ifaces ->
                                            Dict.union (Dict.fromList identity new) ifaces |> DepsChange
                                )



-- ====== TO IMPORT ERROR ======


toImportErrors : Env -> ResultDict -> List Src.Import -> NE.Nonempty ( ModuleName.Raw, Import.Problem ) -> NE.Nonempty Import.Error
toImportErrors (Env envData) results imports problems =
    let
        knownModules : EverySet.EverySet String ModuleName.Raw
        knownModules =
            EverySet.fromList identity
                (List.concat
                    [ Dict.keys compare envData.foreigns
                    , Dict.keys compare envData.locals
                    , Dict.keys compare results
                    ]
                )

        unimportedModules : EverySet.EverySet String ModuleName.Raw
        unimportedModules =
            EverySet.diff knownModules (EverySet.fromList identity (List.map Src.getImportName imports))

        regionDict : Dict String Name.Name A.Region
        regionDict =
            Dict.fromList identity (List.map (\(Src.Import ( _, A.At region name ) _ _) -> ( name, region )) imports)

        toError : ( Name.Name, Import.Problem ) -> Import.Error
        toError ( name, problem ) =
            Import.Error
                { region = Utils.find identity name regionDict
                , name = name
                , unimportedModules = unimportedModules
                , problem = problem
                }
    in
    NE.map toError problems



-- ====== LOAD CACHED INTERFACES ======


loadInterfaces : FilePath -> List Dep -> List CDep -> Task Never (Maybe (Dict String ModuleName.Raw I.Interface))
loadInterfaces root same cached =
    Utils.listTraverse (fork maybeDepEncoder << loadInterface root) cached
        |> Task.andThen
            (\loading ->
                Utils.listTraverse (Utils.readMVar maybeDepDecoder) loading
                    |> Task.map
                        (\maybeLoaded ->
                            case Utils.sequenceListMaybe maybeLoaded of
                                Nothing ->
                                    Nothing

                                Just loaded ->
                                    Dict.union (Dict.fromList identity loaded) (Dict.fromList identity same) |> Just
                        )
            )


loadInterface : FilePath -> CDep -> Task Never (Maybe Dep)
loadInterface root ( name, ciMvar ) =
    Utils.takeMVar cachedInterfaceDecoder ciMvar
        |> Task.andThen
            (\cachedInterface ->
                case cachedInterface of
                    Corrupted ->
                        Utils.putMVar cachedInterfaceEncoder ciMvar cachedInterface
                            |> Task.map (\_ -> Nothing)

                    Loaded iface ->
                        Utils.putMVar cachedInterfaceEncoder ciMvar cachedInterface
                            |> Task.map (\_ -> Just ( name, iface ))

                    Unneeded ->
                        File.readBinary I.interfaceDecoder (Stuff.eci root name)
                            |> Task.andThen
                                (\maybeIface ->
                                    case maybeIface of
                                        Nothing ->
                                            Utils.putMVar cachedInterfaceEncoder ciMvar Corrupted
                                                |> Task.map (\_ -> Nothing)

                                        Just iface ->
                                            Utils.putMVar cachedInterfaceEncoder ciMvar (Loaded iface)
                                                |> Task.map (\_ -> Just ( name, iface ))
                                )
            )



-- ====== CHECK PROJECT ======


checkMidpoint : MVar (Maybe Dependencies) -> Dict String ModuleName.Raw Status -> Task Never (Result Exit.BuildProjectProblem Dependencies)
checkMidpoint dmvar statuses =
    case checkForCycles statuses of
        Nothing ->
            Utils.readMVar maybeDependenciesDecoder dmvar
                |> Task.map
                    (\maybeForeigns ->
                        case maybeForeigns of
                            Nothing ->
                                Err Exit.BP_CannotLoadDependencies

                            Just fs ->
                                Ok fs
                    )

        Just (NE.Nonempty name names) ->
            Utils.readMVar maybeDependenciesDecoder dmvar
                |> Task.map (\_ -> Err (Exit.BP_Cycle name names))


checkMidpointAndRoots : MVar (Maybe Dependencies) -> Dict String ModuleName.Raw Status -> NE.Nonempty RootStatus -> Task Never (Result Exit.BuildProjectProblem Dependencies)
checkMidpointAndRoots dmvar statuses sroots =
    case checkForCycles statuses of
        Nothing ->
            case checkUniqueRoots statuses sroots of
                Nothing ->
                    Utils.readMVar maybeDependenciesDecoder dmvar
                        |> Task.map
                            (\maybeForeigns ->
                                case maybeForeigns of
                                    Nothing ->
                                        Err Exit.BP_CannotLoadDependencies

                                    Just fs ->
                                        Ok fs
                            )

                Just problem ->
                    Utils.readMVar maybeDependenciesDecoder dmvar
                        |> Task.map (\_ -> Err problem)

        Just (NE.Nonempty name names) ->
            Utils.readMVar maybeDependenciesDecoder dmvar
                |> Task.map (\_ -> Err (Exit.BP_Cycle name names))



-- ====== CHECK FOR CYCLES ======


checkForCycles : Dict String ModuleName.Raw Status -> Maybe (NE.Nonempty ModuleName.Raw)
checkForCycles modules =
    let
        graph : List Node
        graph =
            Dict.foldr compare addToGraph [] modules

        sccs : List (Graph.SCC ModuleName.Raw)
        sccs =
            Graph.stronglyConnComp graph
    in
    checkForCyclesHelp sccs


checkForCyclesHelp : List (Graph.SCC ModuleName.Raw) -> Maybe (NE.Nonempty ModuleName.Raw)
checkForCyclesHelp sccs =
    case sccs of
        [] ->
            Nothing

        scc :: otherSccs ->
            case scc of
                Graph.AcyclicSCC _ ->
                    checkForCyclesHelp otherSccs

                Graph.CyclicSCC [] ->
                    checkForCyclesHelp otherSccs

                Graph.CyclicSCC (m :: ms) ->
                    Just (NE.Nonempty m ms)


type alias Node =
    ( ModuleName.Raw, ModuleName.Raw, List ModuleName.Raw )


addToGraph : ModuleName.Raw -> Status -> List Node -> List Node
addToGraph name status graph =
    let
        dependencies : List ModuleName.Raw
        dependencies =
            case status of
                SCached (Details.Local localData) ->
                    localData.deps

                SChanged (Details.Local localData) _ _ _ ->
                    localData.deps

                SBadImport _ ->
                    []

                SBadSyntax _ _ _ _ ->
                    []

                SForeign _ ->
                    []

                SKernel ->
                    []
    in
    ( name, name, dependencies ) :: graph



-- ====== CHECK UNIQUE ROOTS ======


checkUniqueRoots : Dict String ModuleName.Raw Status -> NE.Nonempty RootStatus -> Maybe Exit.BuildProjectProblem
checkUniqueRoots insides sroots =
    let
        outsidesDict : Dict String ModuleName.Raw (OneOrMore.OneOrMore FilePath)
        outsidesDict =
            Utils.mapFromListWith identity OneOrMore.more (List.filterMap rootStatusToNamePathPair (NE.toList sroots))
    in
    case Utils.mapTraverseWithKeyResult identity compare checkOutside outsidesDict of
        Err problem ->
            Just problem

        Ok outsides ->
            case Utils.sequenceDictResult_ identity compare (Utils.mapIntersectionWithKey identity compare checkInside outsides insides) of
                Ok () ->
                    Nothing

                Err problem ->
                    Just problem


rootStatusToNamePathPair : RootStatus -> Maybe ( ModuleName.Raw, OneOrMore.OneOrMore FilePath )
rootStatusToNamePathPair sroot =
    case sroot of
        SInside _ ->
            Nothing

        SOutsideOk (Details.Local localData) _ modul ->
            Just ( Src.getName modul, OneOrMore.one localData.path )

        SOutsideErr _ ->
            Nothing


checkOutside : ModuleName.Raw -> OneOrMore.OneOrMore FilePath -> Result Exit.BuildProjectProblem FilePath
checkOutside name paths =
    case OneOrMore.destruct NE.Nonempty paths of
        NE.Nonempty p [] ->
            Ok p

        NE.Nonempty p1 (p2 :: _) ->
            Err (Exit.BP_RootNameDuplicate name p1 p2)


checkInside : ModuleName.Raw -> FilePath -> Status -> Result Exit.BuildProjectProblem ()
checkInside name p1 status =
    case status of
        SCached (Details.Local localData) ->
            Err (Exit.BP_RootNameDuplicate name p1 localData.path)

        SChanged (Details.Local localData) _ _ _ ->
            Err (Exit.BP_RootNameDuplicate name p1 localData.path)

        SBadImport _ ->
            Ok ()

        SBadSyntax _ _ _ _ ->
            Ok ()

        SForeign _ ->
            Ok ()

        SKernel ->
            Ok ()



-- ====== COMPILE MODULE ======


compile : Env -> DocsNeed -> Details.Local -> String -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Task Never BResult
compile (Env envData) docsNeed (Details.Local localData) source ifaces modul =
    let
        pkg : Pkg.Name
        pkg =
            projectTypeToPkg envData.projectType
    in
    if envData.needsTypedOpt then
        compileWithTypedOpt envData.key envData.root pkg envData.buildID docsNeed localData.path localData.time localData.deps localData.hasMain localData.lastChange source ifaces modul

    else
        compileWithoutTypedOpt envData.key envData.root pkg envData.buildID docsNeed localData.path localData.time localData.deps localData.hasMain localData.lastChange source ifaces modul


{-| Context for compilation results, carrying all the values needed for finalization.
-}
type alias CompileResultContext =
    { key : Reporting.BKey
    , root : FilePath
    , buildID : Details.BuildID
    , path : FilePath
    , time : File.Time
    , deps : List ModuleName.Raw
    , main : Bool
    , lastChange : Details.BuildID
    , name : ModuleName.Raw
    , iface : I.Interface
    , objects : Opt.LocalGraph
    , typedObjects : Maybe TOpt.LocalGraph
    , typeEnv : Maybe TypeEnv.ModuleTypeEnv
    , docs : Maybe Docs.Module
    }


compileWithoutTypedOpt :
    Reporting.BKey
    -> FilePath
    -> Pkg.Name
    -> Details.BuildID
    -> DocsNeed
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> String
    -> Dict String ModuleName.Raw I.Interface
    -> Src.Module
    -> Task Never BResult
compileWithoutTypedOpt key root pkg buildID docsNeed path time deps main lastChange source ifaces modul =
    Compile.compile pkg ifaces modul
        |> Task.andThen (handleCompileResult key root pkg buildID docsNeed path time deps main lastChange source modul Nothing)


handleCompileResult :
    Reporting.BKey
    -> FilePath
    -> Pkg.Name
    -> Details.BuildID
    -> DocsNeed
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> String
    -> Src.Module
    -> Maybe TOpt.LocalGraph
    -> Result Error.Error Compile.Artifacts
    -> Task Never BResult
handleCompileResult key root pkg buildID docsNeed path time deps main lastChange source modul maybeTypedObjects result =
    case result of
        Err err ->
            Error.Module (Src.getName modul) path time source err |> RProblem |> Task.succeed

        Ok (Compile.Artifacts canonical annotations objects) ->
            case makeDocs docsNeed canonical of
                Err err ->
                    Error.Module (Src.getName modul) path time source (Error.BadDocs err) |> RProblem |> Task.succeed

                Ok docs ->
                    let
                        ctx =
                            { key = key
                            , root = root
                            , buildID = buildID
                            , path = path
                            , time = time
                            , deps = deps
                            , main = main
                            , lastChange = lastChange
                            , name = Src.getName modul
                            , iface = I.fromModule pkg canonical annotations
                            , objects = objects
                            , typedObjects = maybeTypedObjects
                            , typeEnv = Nothing
                            , docs = docs
                            }
                    in
                    writeObjectsAndFinalizeCompile ctx


writeObjectsAndFinalizeCompile : CompileResultContext -> Task Never BResult
writeObjectsAndFinalizeCompile ctx =
    File.writeBinary Opt.localGraphEncoder (Stuff.eco ctx.root ctx.name) ctx.objects
        |> Task.andThen (\_ -> writeTypedObjectsIfNeeded ctx)
        |> Task.andThen (\_ -> checkInterfaceAndFinalize ctx)


writeTypedObjectsIfNeeded : CompileResultContext -> Task Never ()
writeTypedObjectsIfNeeded ctx =
    case ( ctx.typedObjects, ctx.typeEnv ) of
        ( Just typedObjs, Just moduleEnv ) ->
            let
                artifact : TMod.TypedModuleArtifact
                artifact =
                    { typedGraph = typedObjs
                    , typeEnv = moduleEnv
                    }
            in
            File.writeBinary TMod.typedModuleArtifactEncoder (Stuff.ecot ctx.root ctx.name) artifact

        _ ->
            -- No typed info or type env (erased build); do not write .ecot
            Task.succeed ()


checkInterfaceAndFinalize : CompileResultContext -> Task Never BResult
checkInterfaceAndFinalize ctx =
    let
        eciPath =
            Stuff.eci ctx.root ctx.name
    in
    File.readBinary I.interfaceDecoder eciPath
        |> Task.andThen (finalizeBasedOnInterface ctx eciPath)


finalizeBasedOnInterface : CompileResultContext -> FilePath -> Maybe I.Interface -> Task Never BResult
finalizeBasedOnInterface ctx eciPath maybeOldi =
    case maybeOldi of
        Just oldi ->
            if oldi == ctx.iface then
                -- Interface unchanged, return RSame
                Reporting.report ctx.key Reporting.BDone
                    |> Task.map (\_ -> buildRSame ctx)

            else
                -- Interface changed, write new interface and return RNew
                File.writeBinary I.interfaceEncoder eciPath ctx.iface
                    |> Task.andThen (\_ -> Reporting.report ctx.key Reporting.BDone)
                    |> Task.map (\_ -> buildRNew ctx)

        Nothing ->
            -- No old interface, write new interface and return RNew
            File.writeBinary I.interfaceEncoder eciPath ctx.iface
                |> Task.andThen (\_ -> Reporting.report ctx.key Reporting.BDone)
                |> Task.map (\_ -> buildRNew ctx)


buildRSame : CompileResultContext -> BResult
buildRSame ctx =
    let
        local =
            Details.Local
                { path = ctx.path
                , time = ctx.time
                , deps = ctx.deps
                , hasMain = ctx.main
                , lastChange = ctx.lastChange
                , lastCompile = ctx.buildID
                }
    in
    RSame local ctx.iface ctx.objects ctx.typedObjects ctx.typeEnv ctx.docs


buildRNew : CompileResultContext -> BResult
buildRNew ctx =
    let
        local =
            Details.Local
                { path = ctx.path
                , time = ctx.time
                , deps = ctx.deps
                , hasMain = ctx.main
                , lastChange = ctx.buildID
                , lastCompile = ctx.buildID
                }
    in
    RNew local ctx.iface ctx.objects ctx.typedObjects ctx.typeEnv ctx.docs


compileWithTypedOpt :
    Reporting.BKey
    -> FilePath
    -> Pkg.Name
    -> Details.BuildID
    -> DocsNeed
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> String
    -> Dict String ModuleName.Raw I.Interface
    -> Src.Module
    -> Task Never BResult
compileWithTypedOpt key root pkg buildID docsNeed path time deps main lastChange source ifaces modul =
    Compile.compileTyped pkg ifaces modul
        |> Task.andThen (handleTypedCompileResult key root pkg buildID docsNeed path time deps main lastChange source modul)


handleTypedCompileResult :
    Reporting.BKey
    -> FilePath
    -> Pkg.Name
    -> Details.BuildID
    -> DocsNeed
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> String
    -> Src.Module
    -> Result Error.Error Compile.TypedArtifacts
    -> Task Never BResult
handleTypedCompileResult key root pkg buildID docsNeed path time deps main lastChange source modul result =
    case result of
        Err err ->
            Error.Module (Src.getName modul) path time source err |> RProblem |> Task.succeed

        Ok (Compile.TypedArtifacts typedArtifacts) ->
            case makeDocs docsNeed typedArtifacts.canonical of
                Err err ->
                    Error.Module (Src.getName modul) path time source (Error.BadDocs err) |> RProblem |> Task.succeed

                Ok docs ->
                    let
                        ctx =
                            { key = key
                            , root = root
                            , buildID = buildID
                            , path = path
                            , time = time
                            , deps = deps
                            , main = main
                            , lastChange = lastChange
                            , name = Src.getName modul
                            , iface = I.fromModule pkg typedArtifacts.canonical typedArtifacts.annotations
                            , objects = typedArtifacts.objects
                            , typedObjects = Just typedArtifacts.typedObjects
                            , typeEnv = Just typedArtifacts.typeEnv
                            , docs = docs
                            }
                    in
                    writeObjectsAndFinalizeCompile ctx


projectTypeToPkg : Parse.ProjectType -> Pkg.Name
projectTypeToPkg projectType =
    case projectType of
        Parse.Package pkg ->
            pkg

        Parse.Application ->
            Pkg.dummyName

        Parse.KernelApplication pkg ->
            pkg



-- ====== WRITE DETAILS ======


writeDetails : FilePath -> Maybe String -> Details.Details -> Dict String ModuleName.Raw BResult -> Task Never ()
writeDetails root maybeBuildDir (Details.Details detailsData) results =
    Details.Details { detailsData | locals = Dict.foldr compare addNewLocal detailsData.locals results } |> File.writeBinary Details.detailsEncoder (Stuff.detailsWithBuildDir root maybeBuildDir)


addNewLocal : ModuleName.Raw -> BResult -> Dict String ModuleName.Raw Details.Local -> Dict String ModuleName.Raw Details.Local
addNewLocal name result locals =
    case result of
        RNew local _ _ _ _ _ ->
            Dict.insert identity name local locals

        RSame local _ _ _ _ _ ->
            Dict.insert identity name local locals

        RCached _ _ _ ->
            locals

        RNotFound _ ->
            locals

        RProblem _ ->
            locals

        RBlocked ->
            locals

        RForeign _ ->
            locals

        RKernel ->
            locals

        RKernelLocal _ ->
            locals



-- ====== FINALIZE EXPOSED ======


finalizeExposed : FilePath -> DocsGoal docs -> NE.Nonempty ModuleName.Raw -> Dict String ModuleName.Raw BResult -> Task Never (Result Exit.BuildProblem docs)
finalizeExposed root docsGoal exposed results =
    case List.foldr (addImportProblems results) [] (NE.toList exposed) of
        p :: ps ->
            Exit.BuildProjectProblem (Exit.BP_MissingExposed (NE.Nonempty p ps)) |> Err |> Task.succeed

        [] ->
            case Dict.foldr compare (\_ -> addErrors) [] results of
                [] ->
                    Task.map Ok (finalizeDocs docsGoal results)

                e :: es ->
                    Exit.BuildBadModules root e es |> Err |> Task.succeed


addErrors : BResult -> List Error.Module -> List Error.Module
addErrors result errors =
    case result of
        RNew _ _ _ _ _ _ ->
            errors

        RSame _ _ _ _ _ _ ->
            errors

        RCached _ _ _ ->
            errors

        RNotFound _ ->
            errors

        RProblem e ->
            e :: errors

        RBlocked ->
            errors

        RForeign _ ->
            errors

        RKernel ->
            errors

        RKernelLocal _ ->
            errors


addImportProblems : Dict String ModuleName.Raw BResult -> ModuleName.Raw -> List ( ModuleName.Raw, Import.Problem ) -> List ( ModuleName.Raw, Import.Problem )
addImportProblems results name problems =
    case Utils.find identity name results of
        RNew _ _ _ _ _ _ ->
            problems

        RSame _ _ _ _ _ _ ->
            problems

        RCached _ _ _ ->
            problems

        RNotFound p ->
            ( name, p ) :: problems

        RProblem _ ->
            problems

        RBlocked ->
            problems

        RForeign _ ->
            problems

        RKernel ->
            problems

        RKernelLocal _ ->
            problems



-- ====== DOCS ======


{-| Specifies how to handle documentation during compilation.

Can keep docs in memory, write to a file, or ignore them entirely.

-}
type DocsGoal docs
    = KeepDocs (Dict String ModuleName.Raw BResult -> docs)
    | WriteDocs (Dict String ModuleName.Raw BResult -> Task Never docs)
    | IgnoreDocs docs


{-| Keep generated documentation in memory as a dictionary.
-}
keepDocs : DocsGoal (Dict String ModuleName.Raw Docs.Module)
keepDocs =
    KeepDocs (Utils.mapMapMaybe identity compare toDocs)


{-| Write generated documentation to a JSON file at the specified path.
-}
writeDocs : FilePath -> DocsGoal ()
writeDocs path =
    WriteDocs (E.writeUgly path << Docs.encode << Utils.mapMapMaybe identity compare toDocs)


{-| Ignore documentation generation during compilation.
-}
ignoreDocs : DocsGoal ()
ignoreDocs =
    IgnoreDocs ()


type DocsNeed
    = DocsNeed Bool


toDocsNeed : DocsGoal a -> DocsNeed
toDocsNeed goal =
    case goal of
        IgnoreDocs _ ->
            DocsNeed False

        WriteDocs _ ->
            DocsNeed True

        KeepDocs _ ->
            DocsNeed True


makeDocs : DocsNeed -> Can.Module -> Result EDocs.Error (Maybe Docs.Module)
makeDocs (DocsNeed isNeeded) modul =
    if isNeeded then
        case Docs.fromModule modul of
            Ok docs ->
                Ok (Just docs)

            Err err ->
                Err err

    else
        Ok Nothing


finalizeDocs : DocsGoal docs -> Dict String ModuleName.Raw BResult -> Task Never docs
finalizeDocs goal results =
    case goal of
        KeepDocs f ->
            f results |> Task.succeed

        WriteDocs f ->
            f results

        IgnoreDocs val ->
            Task.succeed val


toDocs : BResult -> Maybe Docs.Module
toDocs result =
    case result of
        RNew _ _ _ _ _ d ->
            d

        RSame _ _ _ _ _ d ->
            d

        RCached _ _ _ ->
            Nothing

        RNotFound _ ->
            Nothing

        RProblem _ ->
            Nothing

        RBlocked ->
            Nothing

        RForeign _ ->
            Nothing

        RKernel ->
            Nothing

        RKernelLocal _ ->
            Nothing



-------------------------------------------------------------------------------
------ NOW FOR SOME REPL STUFF -------------------------------------------------
--------------------------------------------------------------------------------
-- ====== FROM REPL ======


{-| Data contained within REPL build artifacts.
-}
type alias ReplArtifactsData =
    { home : TypeCheck.Canonical
    , modules : List Module
    , localizer : L.Localizer
    , annotations : Dict String Name.Name Can.Annotation
    }


{-| Build artifacts specific to REPL sessions, including type information for interactive evaluation.
-}
type ReplArtifacts
    = ReplArtifacts ReplArtifactsData


{-| Compile Elm source code for evaluation in a REPL session.

Parses the source, type checks it against available dependencies, and produces
artifacts suitable for interactive evaluation.

-}
fromRepl : FilePath -> Details.Details -> String -> Task Never (Result Exit.Repl ReplArtifacts)
fromRepl root details source =
    makeEnv Reporting.ignorer root Nothing Nothing details False
        |> Task.andThen
            (\((Env envData) as env) ->
                case Parse.fromByteString envData.projectType source of
                    Err syntaxError ->
                        Error.BadSyntax syntaxError |> Exit.ReplBadInput source |> Err |> Task.succeed

                    Ok ((Src.Module srcData) as modul) ->
                        let
                            deps : List Name.Name
                            deps =
                                List.map Src.getImportName srcData.imports
                        in
                        crawlRepl root Nothing details env deps
                            |> Task.andThen (compileRepl root Nothing details env source modul deps)
            )


{-| Context for REPL crawl and compile phases.
-}
type alias ReplBuildContext =
    { dmvar : MVar (Maybe Dependencies)
    , statuses : Dict String ModuleName.Raw Status
    }


{-| Crawl phase for REPL: discover module dependencies.
-}
crawlRepl : FilePath -> Maybe String -> Details.Details -> Env -> List Name.Name -> Task Never ReplBuildContext
crawlRepl root maybeBuildDir details env deps =
    Details.loadInterfaces root maybeBuildDir details
        |> Task.andThen
            (\dmvar ->
                Utils.newMVar statusDictEncoder Dict.empty
                    |> Task.andThen
                        (\mvar ->
                            crawlDeps env mvar deps ()
                                |> Task.andThen (\_ -> Utils.readMVar statusDictDecoder mvar)
                                |> Task.andThen (Utils.mapTraverse identity compare (Utils.readMVar statusDecoder))
                                |> Task.map (\statuses -> { dmvar = dmvar, statuses = statuses })
                        )
            )


{-| Compile phase for REPL: check midpoint and compile modules.
-}
compileRepl : FilePath -> Maybe String -> Details.Details -> Env -> String -> Src.Module -> List Name.Name -> ReplBuildContext -> Task Never (Result Exit.Repl ReplArtifacts)
compileRepl root maybeBuildDir details env source modul deps { dmvar, statuses } =
    checkMidpoint dmvar statuses
        |> Task.andThen
            (\midpoint ->
                case midpoint of
                    Err problem ->
                        Exit.ReplProjectProblem problem |> Err |> Task.succeed

                    Ok foreigns ->
                        compileReplModules root maybeBuildDir details env source modul deps foreigns statuses
            )


{-| Compile REPL modules and finalize artifacts.
-}
compileReplModules : FilePath -> Maybe String -> Details.Details -> Env -> String -> Src.Module -> List Name.Name -> Dependencies -> Dict String ModuleName.Raw Status -> Task Never (Result Exit.Repl ReplArtifacts)
compileReplModules root maybeBuildDir details env source modul deps foreigns statuses =
    Utils.newEmptyMVar
        |> Task.andThen
            (\rmvar ->
                forkWithKey identity compare bResultEncoder (checkModule env foreigns rmvar) statuses
                    |> Task.andThen
                        (\resultMVars ->
                            Utils.putMVar resultDictEncoder rmvar resultMVars
                                |> Task.andThen (\_ -> Utils.mapTraverse identity compare (Utils.readMVar bResultDecoder) resultMVars)
                                |> Task.andThen
                                    (\results ->
                                        writeDetails root maybeBuildDir details results
                                            |> Task.andThen (\_ -> checkDeps root resultMVars deps 0)
                                            |> Task.andThen (\depsStatus -> finalizeReplArtifacts env source modul depsStatus resultMVars results)
                                    )
                        )
            )


finalizeReplArtifacts : Env -> String -> Src.Module -> DepsStatus -> ResultDict -> Dict String ModuleName.Raw BResult -> Task Never (Result Exit.Repl ReplArtifacts)
finalizeReplArtifacts ((Env envData) as env) source ((Src.Module srcData) as modul) depsStatus resultMVars results =
    let
        pkg : Pkg.Name
        pkg =
            projectTypeToPkg envData.projectType

        compileInput : Dict String ModuleName.Raw I.Interface -> Task Never (Result Exit.Repl ReplArtifacts)
        compileInput ifaces =
            Compile.compile pkg ifaces modul
                |> Task.map
                    (\result ->
                        case result of
                            Ok (Compile.Artifacts ((Can.Module canData) as canonical) annotations objects) ->
                                let
                                    h : TypeCheck.Canonical
                                    h =
                                        canData.name

                                    m : Module
                                    m =
                                        Fresh (Src.getName modul) (I.fromModule pkg canonical annotations) objects Nothing Nothing

                                    ms : List Module
                                    ms =
                                        Dict.foldr compare addInside [] results
                                in
                                ReplArtifacts { home = h, modules = m :: ms, localizer = L.fromModule modul, annotations = annotations } |> Ok

                            Err errors ->
                                Exit.ReplBadInput source errors |> Err
                    )
    in
    case depsStatus of
        DepsChange ifaces ->
            compileInput ifaces

        DepsSame same cached ->
            loadInterfaces envData.root same cached
                |> Task.andThen
                    (\maybeLoaded ->
                        case maybeLoaded of
                            Just ifaces ->
                                compileInput ifaces

                            Nothing ->
                                Exit.ReplBadCache |> Err |> Task.succeed
                    )

        DepsBlock ->
            case Dict.foldr compare (\_ -> addErrors) [] results of
                [] ->
                    Exit.ReplBlocked |> Err |> Task.succeed

                e :: es ->
                    Exit.ReplBadLocalDeps envData.root e es |> Err |> Task.succeed

        DepsNotFound problems ->
            toImportErrors env resultMVars srcData.imports problems |> Error.BadImports |> Exit.ReplBadInput source |> Err |> Task.succeed



--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
------ AFTER THIS, EVERYTHING IS ABOUT HANDLING MODULES GIVEN BY FILEPATH ------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- ====== FIND ROOT ======


type RootLocation
    = LInside ModuleName.Raw
    | LOutside FilePath


findRoots : Env -> NE.Nonempty FilePath -> Task Never (Result Exit.BuildProjectProblem (NE.Nonempty RootLocation))
findRoots env paths =
    Utils.nonEmptyListTraverse (fork resultBuildProjectProblemRootInfoEncoder << getRootInfo env) paths
        |> Task.andThen
            (\mvars ->
                Utils.nonEmptyListTraverse (Utils.readMVar resultBuildProjectProblemRootInfoDecoder) mvars
                    |> Task.map
                        (\einfos ->
                            Utils.sequenceNonemptyListResult einfos |> Result.andThen checkRoots
                        )
            )


checkRoots : NE.Nonempty RootInfo -> Result Exit.BuildProjectProblem (NE.Nonempty RootLocation)
checkRoots infos =
    let
        toOneOrMore : RootInfo -> ( FilePath, OneOrMore.OneOrMore RootInfo )
        toOneOrMore ((RootInfo absolute _ _) as loc) =
            ( absolute, OneOrMore.one loc )

        fromOneOrMore : RootInfo -> List RootInfo -> Result Exit.BuildProjectProblem ()
        fromOneOrMore (RootInfo _ relative _) locs =
            case locs of
                [] ->
                    Ok ()

                (RootInfo _ relative2 _) :: _ ->
                    Err (Exit.BP_MainPathDuplicate relative relative2)
    in
    List.map toOneOrMore (NE.toList infos) |> Utils.mapFromListWith identity OneOrMore.more |> Utils.mapTraverseResult identity compare (OneOrMore.destruct fromOneOrMore) |> Result.map (\_ -> NE.map (\(RootInfo _ _ location) -> location) infos)



-- ====== ROOT INFO ======


type RootInfo
    = RootInfo FilePath FilePath RootLocation


getRootInfo : Env -> FilePath -> Task Never (Result Exit.BuildProjectProblem RootInfo)
getRootInfo env path =
    File.exists path
        |> Task.andThen
            (\exists ->
                if exists then
                    Utils.dirCanonicalizePath path |> Task.andThen (getRootInfoHelp env path)

                else
                    Task.succeed (Err (Exit.BP_PathUnknown path))
            )


getRootInfoHelp : Env -> FilePath -> FilePath -> Task Never (Result Exit.BuildProjectProblem RootInfo)
getRootInfoHelp (Env envData) path absolutePath =
    let
        ( dirs, file ) =
            Utils.fpSplitFileName absolutePath

        ( final, ext ) =
            Utils.fpSplitExtension file
    in
    if ext == ".elm" then
        let
            absoluteSegments : List String
            absoluteSegments =
                Utils.fpSplitDirectories dirs ++ [ final ]
        in
        case List.filterMap (isInsideSrcDirByPath absoluteSegments) envData.srcDirs of
            [] ->
                RootInfo absolutePath path (LOutside path) |> Ok |> Task.succeed

            [ ( _, Ok names ) ] ->
                let
                    name : String
                    name =
                        String.join "." names
                in
                Utils.filterM (isInsideSrcDirByName names ext) envData.srcDirs
                    |> Task.map
                        (\matchingDirs ->
                            case matchingDirs of
                                d1 :: d2 :: _ ->
                                    let
                                        p1 : FilePath
                                        p1 =
                                            addRelative d1 (Utils.fpJoinPath names ++ ext)

                                        p2 : FilePath
                                        p2 =
                                            addRelative d2 (Utils.fpJoinPath names ++ ext)
                                    in
                                    Exit.BP_RootNameDuplicate name p1 p2 |> Err

                                _ ->
                                    RootInfo absolutePath path (LInside name) |> Ok
                        )

            [ ( s, Err names ) ] ->
                Exit.BP_RootNameInvalid path s names |> Err |> Task.succeed

            ( s1, _ ) :: ( s2, _ ) :: _ ->
                Exit.BP_WithAmbiguousSrcDir path s1 s2 |> Err |> Task.succeed

    else
        Exit.BP_WithBadExtension path |> Err |> Task.succeed


isInsideSrcDirByName : List String -> String -> AbsoluteSrcDir -> Task Never Bool
isInsideSrcDirByName names extension srcDir =
    File.exists (addRelative srcDir (Utils.fpJoinPath names ++ extension))


isInsideSrcDirByPath : List String -> AbsoluteSrcDir -> Maybe ( FilePath, Result (List String) (List String) )
isInsideSrcDirByPath segments (AbsoluteSrcDir srcDir) =
    dropPrefix (Utils.fpSplitDirectories srcDir) segments
        |> Maybe.map
            (\names ->
                if List.all isGoodName names then
                    ( srcDir, Ok names )

                else
                    ( srcDir, Err names )
            )


isGoodName : String -> Bool
isGoodName name =
    case String.toList name of
        [] ->
            False

        char :: chars ->
            Char.isUpper char && List.all (\c -> Char.isAlphaNum c || c == '_') chars


{-| Drops the common prefix from two canonicalized paths.
INVARIANT: Dir.canonicalizePath has been run on both inputs.
-}
dropPrefix : List FilePath -> List FilePath -> Maybe (List FilePath)
dropPrefix roots paths =
    case roots of
        [] ->
            Just paths

        r :: rs ->
            case paths of
                [] ->
                    Nothing

                p :: ps ->
                    if r == p then
                        dropPrefix rs ps

                    else
                        Nothing



-- ====== CRAWL ROOTS ======


type RootStatus
    = SInside ModuleName.Raw
    | SOutsideOk Details.Local String Src.Module
    | SOutsideErr Error.Module


crawlRoot : Env -> MVar StatusDict -> RootLocation -> Task Never RootStatus
crawlRoot ((Env envData) as env) mvar root =
    case root of
        LInside name ->
            Utils.newEmptyMVar
                |> Task.andThen
                    (\statusMVar ->
                        Utils.takeMVar statusDictDecoder mvar
                            |> Task.andThen
                                (\statusDict ->
                                    Utils.putMVar statusDictEncoder mvar (Dict.insert identity name statusMVar statusDict)
                                        |> Task.andThen
                                            (\_ ->
                                                Task.andThen (Utils.putMVar statusEncoder statusMVar) (crawlModule env mvar (DocsNeed False) name)
                                                    |> Task.map (\_ -> SInside name)
                                            )
                                )
                    )

        LOutside path ->
            File.getTime path
                |> Task.andThen
                    (\time ->
                        File.readUtf8 path
                            |> Task.andThen
                                (\source ->
                                    case Parse.fromByteString envData.projectType source of
                                        Ok ((Src.Module srcData) as modul) ->
                                            let
                                                deps : List Name.Name
                                                deps =
                                                    List.map Src.getImportName srcData.imports

                                                local : Details.Local
                                                local =
                                                    Details.Local
                                                        { path = path
                                                        , time = time
                                                        , deps = deps
                                                        , hasMain = List.any isMain srcData.values
                                                        , lastChange = envData.buildID
                                                        , lastCompile = envData.buildID
                                                        }
                                            in
                                            crawlDeps env mvar deps (SOutsideOk local source modul)

                                        Err syntaxError ->
                                            Error.Module "???" path time source (Error.BadSyntax syntaxError) |> SOutsideErr |> Task.succeed
                                )
                    )



-- ====== CHECK ROOTS ======


type RootResult
    = RInside ModuleName.Raw
    | ROutsideOk ModuleName.Raw I.Interface Opt.LocalGraph (Maybe TOpt.LocalGraph) (Maybe TypeEnv.ModuleTypeEnv)
    | ROutsideErr Error.Module
    | ROutsideBlocked


checkRoot : Env -> ResultDict -> RootStatus -> Task Never RootResult
checkRoot ((Env envData) as env) results rootStatus =
    case rootStatus of
        SInside name ->
            Task.succeed (RInside name)

        SOutsideErr err ->
            Task.succeed (ROutsideErr err)

        SOutsideOk ((Details.Local localData) as local) source ((Src.Module srcData) as modul) ->
            checkDeps envData.root results localData.deps localData.lastCompile
                |> Task.andThen
                    (\depsStatus ->
                        case depsStatus of
                            DepsChange ifaces ->
                                compileOutside env local source ifaces modul

                            DepsSame same cached ->
                                loadInterfaces envData.root same cached
                                    |> Task.andThen
                                        (\maybeLoaded ->
                                            case maybeLoaded of
                                                Nothing ->
                                                    Task.succeed ROutsideBlocked

                                                Just ifaces ->
                                                    compileOutside env local source ifaces modul
                                        )

                            DepsBlock ->
                                Task.succeed ROutsideBlocked

                            DepsNotFound problems ->
                                Error.BadImports (toImportErrors env results srcData.imports problems) |> Error.Module (Src.getName modul) localData.path localData.time source |> ROutsideErr |> Task.succeed
                    )


compileOutside : Env -> Details.Local -> String -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Task Never RootResult
compileOutside (Env envData) (Details.Local localData) source ifaces modul =
    let
        pkg : Pkg.Name
        pkg =
            projectTypeToPkg envData.projectType

        name : Name.Name
        name =
            Src.getName modul
    in
    if envData.needsTypedOpt then
        Compile.compileTyped pkg ifaces modul
            |> Task.andThen
                (\result ->
                    case result of
                        Ok (Compile.TypedArtifacts typedArtifacts) ->
                            Reporting.report envData.key Reporting.BDone
                                |> Task.map
                                    (\_ ->
                                        ROutsideOk name (I.fromModule pkg typedArtifacts.canonical typedArtifacts.annotations) typedArtifacts.objects (Just typedArtifacts.typedObjects) (Just typedArtifacts.typeEnv)
                                    )

                        Err errors ->
                            Error.Module name localData.path localData.time source errors |> ROutsideErr |> Task.succeed
                )

    else
        Compile.compile pkg ifaces modul
            |> Task.andThen
                (\result ->
                    case result of
                        Ok (Compile.Artifacts canonical annotations objects) ->
                            Reporting.report envData.key Reporting.BDone
                                |> Task.map (\_ -> ROutsideOk name (I.fromModule pkg canonical annotations) objects Nothing Nothing)

                        Err errors ->
                            Error.Module name localData.path localData.time source errors |> ROutsideErr |> Task.succeed
                )



-- ====== TO ARTIFACTS ======


{-| Represents a root module, either from within the project or from a dependency.
-}
type Root
    = Inside ModuleName.Raw
    | Outside ModuleName.Raw I.Interface Opt.LocalGraph (Maybe TOpt.LocalGraph) (Maybe TypeEnv.ModuleTypeEnv)


toArtifacts : Env -> Dependencies -> Dict String ModuleName.Raw BResult -> NE.Nonempty RootResult -> Result Exit.BuildProblem Artifacts
toArtifacts (Env envData) foreigns results rootResults =
    case gatherProblemsOrMains results rootResults of
        Err (NE.Nonempty e es) ->
            Err (Exit.BuildBadModules envData.root e es)

        Ok roots ->
            Ok <|
                Artifacts
                    { pkg = projectTypeToPkg envData.projectType
                    , deps = foreigns
                    , roots = roots
                    , modules = Dict.foldr compare addInside (NE.foldr addOutside [] rootResults) results
                    }


gatherProblemsOrMains : Dict String ModuleName.Raw BResult -> NE.Nonempty RootResult -> Result (NE.Nonempty Error.Module) (NE.Nonempty Root)
gatherProblemsOrMains results (NE.Nonempty rootResult rootResults) =
    let
        addResult : RootResult -> ( List Error.Module, List Root ) -> ( List Error.Module, List Root )
        addResult result ( es, roots ) =
            case result of
                RInside n ->
                    ( es, Inside n :: roots )

                ROutsideOk n i o t e ->
                    ( es, Outside n i o t e :: roots )

                ROutsideErr err ->
                    ( err :: es, roots )

                ROutsideBlocked ->
                    ( es, roots )

        errors : List Error.Module
        errors =
            Dict.foldr compare (\_ -> addErrors) [] results
    in
    case ( rootResult, List.foldr addResult ( errors, [] ) rootResults ) of
        ( RInside n, ( [], ms ) ) ->
            Ok (NE.Nonempty (Inside n) ms)

        ( RInside _, ( e :: es, _ ) ) ->
            Err (NE.Nonempty e es)

        ( ROutsideOk n i o t env, ( [], ms ) ) ->
            Ok (NE.Nonempty (Outside n i o t env) ms)

        ( ROutsideOk _ _ _ _ _, ( e :: es, _ ) ) ->
            Err (NE.Nonempty e es)

        ( ROutsideErr e, ( es, _ ) ) ->
            Err (NE.Nonempty e es)

        ( ROutsideBlocked, ( [], _ ) ) ->
            crash "seems like eco-stuff/ is corrupted"

        ( ROutsideBlocked, ( e :: es, _ ) ) ->
            Err (NE.Nonempty e es)


addInside : ModuleName.Raw -> BResult -> List Module -> List Module
addInside name result modules =
    case result of
        RNew _ iface objs typedObjs typeEnv _ ->
            Fresh name iface objs typedObjs typeEnv :: modules

        RSame _ iface objs typedObjs typeEnv _ ->
            Fresh name iface objs typedObjs typeEnv :: modules

        RCached main _ mvar ->
            Cached name main mvar :: modules

        RNotFound _ ->
            crash (badInside name)

        RProblem _ ->
            crash (badInside name)

        RBlocked ->
            crash (badInside name)

        RForeign _ ->
            modules

        RKernel ->
            modules

        RKernelLocal _ ->
            modules


badInside : ModuleName.Raw -> String
badInside name =
    "Error from `" ++ name ++ "` should have been reported already."


addOutside : RootResult -> List Module -> List Module
addOutside root modules =
    case root of
        RInside _ ->
            modules

        ROutsideOk name iface objs typedObjs typeEnv ->
            Fresh name iface objs typedObjs typeEnv :: modules

        ROutsideErr _ ->
            modules

        ROutsideBlocked ->
            modules



-- ====== ENCODERS and DECODERS ======


dictRawMVarBResultEncoder : Dict String ModuleName.Raw (MVar BResult) -> Bytes.Encode.Encoder
dictRawMVarBResultEncoder =
    BE.assocListDict compare ModuleName.rawEncoder Utils.mVarEncoder


bResultEncoder : BResult -> Bytes.Encode.Encoder
bResultEncoder bResult =
    case bResult of
        RNew local iface objects typedObjects typeEnv docs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Details.localEncoder local
                , I.interfaceEncoder iface
                , Opt.localGraphEncoder objects
                , BE.maybe TOpt.localGraphEncoder typedObjects
                , BE.maybe TypeEnv.moduleTypeEnvEncoder typeEnv
                , BE.maybe Docs.bytesModuleEncoder docs
                ]

        RSame local iface objects typedObjects typeEnv docs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Details.localEncoder local
                , I.interfaceEncoder iface
                , Opt.localGraphEncoder objects
                , BE.maybe TOpt.localGraphEncoder typedObjects
                , BE.maybe TypeEnv.moduleTypeEnvEncoder typeEnv
                , BE.maybe Docs.bytesModuleEncoder docs
                ]

        RCached main lastChange (MVar ref) ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.bool main
                , BE.int lastChange
                , BE.int ref
                ]

        RNotFound importProblem ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Import.problemEncoder importProblem
                ]

        RProblem e ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Error.moduleEncoder e
                ]

        RBlocked ->
            Bytes.Encode.unsignedInt8 5

        RForeign iface ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , I.interfaceEncoder iface
                ]

        RKernel ->
            Bytes.Encode.unsignedInt8 7

        RKernelLocal chunks ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , BE.list Kernel.chunkEncoder chunks
                ]


bResultDecoder : Bytes.Decode.Decoder BResult
bResultDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map6 RNew
                            Details.localDecoder
                            I.interfaceDecoder
                            Opt.localGraphDecoder
                            (BD.maybe TOpt.localGraphDecoder)
                            (BD.maybe TypeEnv.moduleTypeEnvDecoder)
                            (BD.maybe Docs.bytesModuleDecoder)

                    1 ->
                        BD.map6 RSame
                            Details.localDecoder
                            I.interfaceDecoder
                            Opt.localGraphDecoder
                            (BD.maybe TOpt.localGraphDecoder)
                            (BD.maybe TypeEnv.moduleTypeEnvDecoder)
                            (BD.maybe Docs.bytesModuleDecoder)

                    2 ->
                        Bytes.Decode.map3 RCached
                            BD.bool
                            BD.int
                            (Bytes.Decode.map MVar BD.int)

                    3 ->
                        Bytes.Decode.map RNotFound Import.problemDecoder

                    4 ->
                        Bytes.Decode.map RProblem Error.moduleDecoder

                    5 ->
                        Bytes.Decode.succeed RBlocked

                    6 ->
                        Bytes.Decode.map RForeign I.interfaceDecoder

                    7 ->
                        Bytes.Decode.succeed RKernel

                    8 ->
                        Bytes.Decode.map RKernelLocal (BD.list Kernel.chunkDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


statusDictEncoder : StatusDict -> Bytes.Encode.Encoder
statusDictEncoder statusDict =
    BE.assocListDict compare ModuleName.rawEncoder Utils.mVarEncoder statusDict


statusDictDecoder : Bytes.Decode.Decoder StatusDict
statusDictDecoder =
    BD.assocListDict identity ModuleName.rawDecoder Utils.mVarDecoder


statusEncoder : Status -> Bytes.Encode.Encoder
statusEncoder status =
    case status of
        SCached local ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Details.localEncoder local
                ]

        SChanged local iface objects docs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Details.localEncoder local
                , BE.string iface
                , Src.moduleEncoder objects
                , docsNeedEncoder docs
                ]

        SBadImport importProblem ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , Import.problemEncoder importProblem
                ]

        SBadSyntax path time source err ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string path
                , File.timeEncoder time
                , BE.string source
                , Syntax.errorEncoder err
                ]

        SForeign home ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Pkg.nameEncoder home
                ]

        SKernel ->
            Bytes.Encode.unsignedInt8 5


statusDecoder : Bytes.Decode.Decoder Status
statusDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map SCached Details.localDecoder

                    1 ->
                        Bytes.Decode.map4 SChanged
                            Details.localDecoder
                            BD.string
                            Src.moduleDecoder
                            docsNeedDecoder

                    2 ->
                        Bytes.Decode.map SBadImport Import.problemDecoder

                    3 ->
                        Bytes.Decode.map4 SBadSyntax
                            BD.string
                            File.timeDecoder
                            BD.string
                            Syntax.errorDecoder

                    4 ->
                        Bytes.Decode.map SForeign Pkg.nameDecoder

                    5 ->
                        Bytes.Decode.succeed SKernel

                    _ ->
                        Bytes.Decode.fail
            )


rootStatusEncoder : RootStatus -> Bytes.Encode.Encoder
rootStatusEncoder rootStatus =
    case rootStatus of
        SInside name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.rawEncoder name
                ]

        SOutsideOk local source modul ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Details.localEncoder local
                , BE.string source
                , Src.moduleEncoder modul
                ]

        SOutsideErr err ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , Error.moduleEncoder err
                ]


rootStatusDecoder : Bytes.Decode.Decoder RootStatus
rootStatusDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map SInside ModuleName.rawDecoder

                    1 ->
                        Bytes.Decode.map3 SOutsideOk
                            Details.localDecoder
                            BD.string
                            Src.moduleDecoder

                    2 ->
                        Bytes.Decode.map SOutsideErr Error.moduleDecoder

                    _ ->
                        Bytes.Decode.fail
            )


resultDictEncoder : ResultDict -> Bytes.Encode.Encoder
resultDictEncoder =
    BE.assocListDict compare ModuleName.rawEncoder Utils.mVarEncoder


resultDictDecoder : Bytes.Decode.Decoder ResultDict
resultDictDecoder =
    BD.assocListDict identity ModuleName.rawDecoder Utils.mVarDecoder


rootResultEncoder : RootResult -> Bytes.Encode.Encoder
rootResultEncoder rootResult =
    case rootResult of
        RInside name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.rawEncoder name
                ]

        ROutsideOk name iface objs typedObjs typeEnv ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , ModuleName.rawEncoder name
                , I.interfaceEncoder iface
                , Opt.localGraphEncoder objs
                , BE.maybe TOpt.localGraphEncoder typedObjs
                , BE.maybe TypeEnv.moduleTypeEnvEncoder typeEnv
                ]

        ROutsideErr err ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , Error.moduleEncoder err
                ]

        ROutsideBlocked ->
            Bytes.Encode.unsignedInt8 3


rootResultDecoder : Bytes.Decode.Decoder RootResult
rootResultDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map RInside ModuleName.rawDecoder

                    1 ->
                        Bytes.Decode.map5 ROutsideOk
                            ModuleName.rawDecoder
                            I.interfaceDecoder
                            Opt.localGraphDecoder
                            (BD.maybe TOpt.localGraphDecoder)
                            (BD.maybe TypeEnv.moduleTypeEnvDecoder)

                    2 ->
                        Bytes.Decode.map ROutsideErr Error.moduleDecoder

                    3 ->
                        Bytes.Decode.succeed ROutsideBlocked

                    _ ->
                        Bytes.Decode.fail
            )


maybeDepEncoder : Maybe Dep -> Bytes.Encode.Encoder
maybeDepEncoder =
    BE.maybe depEncoder


maybeDepDecoder : Bytes.Decode.Decoder (Maybe Dep)
maybeDepDecoder =
    BD.maybe depDecoder


depEncoder : Dep -> Bytes.Encode.Encoder
depEncoder =
    BE.jsonPair ModuleName.rawEncoder I.interfaceEncoder


depDecoder : Bytes.Decode.Decoder Dep
depDecoder =
    BD.jsonPair ModuleName.rawDecoder I.interfaceDecoder


maybeDependenciesDecoder : Bytes.Decode.Decoder (Maybe Dependencies)
maybeDependenciesDecoder =
    BD.maybe (BD.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder I.dependencyInterfaceDecoder)


resultBuildProjectProblemRootInfoEncoder : Result Exit.BuildProjectProblem RootInfo -> Bytes.Encode.Encoder
resultBuildProjectProblemRootInfoEncoder =
    BE.result Exit.buildProjectProblemEncoder rootInfoEncoder


resultBuildProjectProblemRootInfoDecoder : Bytes.Decode.Decoder (Result Exit.BuildProjectProblem RootInfo)
resultBuildProjectProblemRootInfoDecoder =
    BD.result Exit.buildProjectProblemDecoder rootInfoDecoder


cachedInterfaceEncoder : CachedInterface -> Bytes.Encode.Encoder
cachedInterfaceEncoder cachedInterface =
    case cachedInterface of
        Unneeded ->
            Bytes.Encode.unsignedInt8 0

        Loaded iface ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , I.interfaceEncoder iface
                ]

        Corrupted ->
            Bytes.Encode.unsignedInt8 2


{-| Decode a cached interface from bytes.
-}
cachedInterfaceDecoder : Bytes.Decode.Decoder CachedInterface
cachedInterfaceDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Unneeded

                    1 ->
                        Bytes.Decode.map Loaded I.interfaceDecoder

                    2 ->
                        Bytes.Decode.succeed Corrupted

                    _ ->
                        Bytes.Decode.fail
            )


docsNeedEncoder : DocsNeed -> Bytes.Encode.Encoder
docsNeedEncoder (DocsNeed isNeeded) =
    BE.bool isNeeded


docsNeedDecoder : Bytes.Decode.Decoder DocsNeed
docsNeedDecoder =
    Bytes.Decode.map DocsNeed BD.bool


artifactsEncoder : Artifacts -> Bytes.Encode.Encoder
artifactsEncoder (Artifacts a) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoder a.pkg
        , dependenciesEncoder a.deps
        , BE.nonempty rootEncoder a.roots
        , BE.list moduleEncoder a.modules
        ]


artifactsDecoder : Bytes.Decode.Decoder Artifacts
artifactsDecoder =
    Bytes.Decode.map4 (\pkg_ deps_ roots_ modules_ -> Artifacts { pkg = pkg_, deps = deps_, roots = roots_, modules = modules_ })
        Pkg.nameDecoder
        dependenciesDecoder
        (BD.nonempty rootDecoder)
        (BD.list moduleDecoder)


dependenciesEncoder : Dependencies -> Bytes.Encode.Encoder
dependenciesEncoder =
    BE.assocListDict ModuleName.compareCanonical ModuleName.canonicalEncoder I.dependencyInterfaceEncoder


dependenciesDecoder : Bytes.Decode.Decoder Dependencies
dependenciesDecoder =
    BD.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder I.dependencyInterfaceDecoder


rootEncoder : Root -> Bytes.Encode.Encoder
rootEncoder root =
    case root of
        Inside name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.rawEncoder name
                ]

        Outside name iface objs typedObjs typeEnv ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , ModuleName.rawEncoder name
                , I.interfaceEncoder iface
                , Opt.localGraphEncoder objs
                , BE.maybe TOpt.localGraphEncoder typedObjs
                , BE.maybe TypeEnv.moduleTypeEnvEncoder typeEnv
                ]


rootDecoder : Bytes.Decode.Decoder Root
rootDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Inside ModuleName.rawDecoder

                    1 ->
                        Bytes.Decode.map5 Outside
                            ModuleName.rawDecoder
                            I.interfaceDecoder
                            Opt.localGraphDecoder
                            (BD.maybe TOpt.localGraphDecoder)
                            (BD.maybe TypeEnv.moduleTypeEnvDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


moduleEncoder : Module -> Bytes.Encode.Encoder
moduleEncoder modul =
    case modul of
        Fresh name iface objs typedObjs typeEnv ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.rawEncoder name
                , I.interfaceEncoder iface
                , Opt.localGraphEncoder objs
                , BE.maybe TOpt.localGraphEncoder typedObjs
                , BE.maybe TypeEnv.moduleTypeEnvEncoder typeEnv
                ]

        Cached name main mvar ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , ModuleName.rawEncoder name
                , BE.bool main
                , Utils.mVarEncoder mvar
                ]


moduleDecoder : Bytes.Decode.Decoder Module
moduleDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map5 Fresh
                            ModuleName.rawDecoder
                            I.interfaceDecoder
                            Opt.localGraphDecoder
                            (BD.maybe TOpt.localGraphDecoder)
                            (BD.maybe TypeEnv.moduleTypeEnvDecoder)

                    1 ->
                        Bytes.Decode.map3 Cached
                            ModuleName.rawDecoder
                            BD.bool
                            Utils.mVarDecoder

                    _ ->
                        Bytes.Decode.fail
            )


rootInfoEncoder : RootInfo -> Bytes.Encode.Encoder
rootInfoEncoder (RootInfo absolute relative location) =
    Bytes.Encode.sequence
        [ BE.string absolute
        , BE.string relative
        , rootLocationEncoder location
        ]


rootInfoDecoder : Bytes.Decode.Decoder RootInfo
rootInfoDecoder =
    Bytes.Decode.map3 RootInfo
        BD.string
        BD.string
        rootLocationDecoder


rootLocationEncoder : RootLocation -> Bytes.Encode.Encoder
rootLocationEncoder rootLocation =
    case rootLocation of
        LInside name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.rawEncoder name
                ]

        LOutside path ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string path
                ]


rootLocationDecoder : Bytes.Decode.Decoder RootLocation
rootLocationDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map LInside ModuleName.rawDecoder

                    1 ->
                        Bytes.Decode.map LOutside BD.string

                    _ ->
                        Bytes.Decode.fail
            )
