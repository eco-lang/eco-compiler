module Builder.Build exposing
    ( Artifacts(..), ArtifactsData, BResult, Module(..), Root(..)
    , CachedInterface(..), Dependencies
    , DocsGoal, keepDocs, ignoreDocs, writeDocs
    , fromExposed, fromPaths, fromPathsWith, CacheMode(..)
    , getRootNames, cachedInterfaceDecoder
    )

{-| Compiles a project's own modules, reusing what earlier builds left on disk
wherever it can. Packages are compiled elsewhere: this module starts from the
project details that `Builder.Elm.Details` loads, which hold the dependencies'
interfaces and an entry for each project module recording what the last build
that compiled it saw.

A build is asked for in one of two ways. `fromExposed` names modules and
produces their documentation, or nothing; it always uses the erased pipeline
and always writes caches. `fromPaths` and `fromPathsWith` name `.elm` files and
produce `Artifacts` for code generation. A file named this way is a _root_. An
_inside root_ lies in one of the project's source directories and is the module
its path there names. An _outside root_ lies outside every source directory: it
is compiled on its own in every build, and nothing about it is cached.

Every build has two phases, and each forks one thread per module.

The _crawl_ discovers the modules. Starting from the roots, it finds each
module's file in the source directories, decides the module's `Status`, and
crawls the modules it imports. A module that no source directory has is looked
for among the _foreign_ modules, those a direct dependency exposes, and, in a
kernel project, among kernel `.js` files. Between the phases the build stops on
an import cycle, or when the dependency interfaces could not be loaded.

The _check_ decides each module's `BResult` once its imports have theirs. A
module's details entry records its file's path and modification time, and two
`BuildID`s, which number builds: `lastChange`, the build at which its interface
last changed, and `lastCompile`, the build at which it was last compiled. A
module is reused from disk when all of these hold:

  - its file has the recorded path and the recorded modification time,
    compared for equality, so an older file counts as changed too;
  - no documentation is needed for it;
  - no import's `lastChange` is later than its `lastCompile`;
  - the artifact this kind of build reads is on disk: the `.ecot` file for a
    typed build, the `.eco` file for an untyped one.

Otherwise it is compiled. If its new interface differs from its `.eci` file on
disk, its `lastChange` becomes the current build. If not, it keeps its
`lastChange`, except that a module whose file had not changed is compiled with
a `lastChange` of 0 and records that. A module is _blocked_, and not compiled,
when one of its imports failed or a cached import's interface could not be
read.

A build that writes caches writes each compiled module's `.eci` file when its
interface changed, then its `.eco` or `.ecot` file, and finally `d.dat` with
the compiled modules' new entries. A `OneShot` build writes none of them.

Threads hand values to each other through MVars (see `Utils.Main`). Every take,
read and put passes a byte encoder or decoder for the value, which only the XHR
runtime uses, and an MVar keeps its value alive until it is dropped, so the
status, result and root MVars are dropped once their values have been read.


# Build Results

@docs Artifacts, ArtifactsData, BResult, Module, Root


# Module Status

@docs CachedInterface, Dependencies


# Documentation Generation

@docs DocsGoal, keepDocs, ignoreDocs, writeDocs


# Build Entry Points

@docs fromExposed, fromPaths, fromPathsWith, CacheMode


# Utilities

@docs getRootNames, cachedInterfaceDecoder

-}

import Basics.Extra exposing (flip)
import Builder.Eco.FEStats as FEStats
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
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Interface as I
import Compiler.Elm.Kernel as Kernel
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Graph as Graph
import Compiler.Json.Encode as E
import Compiler.Parse.Module as Parse
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error as Error
import Compiler.Reporting.Error.Docs as EDocs
import Compiler.Reporting.Error.Import as Import
import Compiler.Reporting.Error.Syntax as Syntax
import Data.Map
import Data.Set as EverySet
import Dict exposing (Dict)
import System.IO exposing (FilePath, MVar(..))
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== ENVIRONMENT ======


{-| Everything the threads of one build share: where the project is, how it is
laid out, what its details record, and the options the build was started with.

`projectType` is a `KernelApplication` when an application was built with a
kernel package name. `needsTypedOpt` selects the typed pipeline, whose
per-module artifact is `.ecot`, over the erased one, whose artifact is `.eco`.
`locals` and `foreigns` are the details' entries for the project's modules and
for the modules the direct dependencies expose.

-}
type alias EnvData =
    { key : Reporting.BKey
    , root : String
    , maybeBuildDir : Maybe String
    , projectType : Parse.ProjectType
    , srcDirs : List AbsoluteSrcDir
    , buildID : Details.BuildID
    , locals : Dict ModuleName.Raw Details.Local
    , foreigns : Dict ModuleName.Raw Details.Foreign
    , needsTypedOpt : Bool
    , stats : FEStats.Handle
    , cacheMode : CacheMode
    }


{-| The shared settings of one build (see `EnvData`), made by `makeEnv`.
-}
type Env
    = Env EnvData


{-| Whether a build writes its per-module caches.

`WriteCaches` writes each compiled module's `.eci` when its interface changed,
then its `.eco` or `.ecot`, and records the compiled modules in `d.dat`.
`OneShot` writes none of these, so a later build finds the caches as they were
before this one ran. The returned artifacts are the same in either mode.

-}
type CacheMode
    = WriteCaches
    | OneShot


{-| Builds the `Env` for one build from the project details, resolving the
source directories against `root` and canonicalizing them. A package's only
source directory is `src`. An application becomes a kernel application, with
its modules belonging to that package, when `maybeKernelPackage` names one; for
a package `maybeKernelPackage` is ignored.
-}
makeEnv : CacheMode -> Reporting.BKey -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Bool -> FEStats.Handle -> Task Never Env
makeEnv cacheMode key root maybeBuildDir maybeKernelPackage (Details.Details detailsData) needsTypedOpt stats =
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
                            , stats = stats
                            , cacheMode = cacheMode
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
                            , stats = stats
                            , cacheMode = cacheMode
                            }
                    )



-- ====== SOURCE DIRECTORY ======


{-| A source directory as a canonical absolute path. Values are made by
`toAbsoluteSrcDir`, and `dropPrefix` relies on the canonical form to compare a
root's path with the directory.
-}
type AbsoluteSrcDir
    = AbsoluteSrcDir FilePath


{-| Resolves a source directory from the outline against the project `root` and
canonicalizes it.
-}
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


{-| Returns `path` inside the source directory.
-}
addRelative : AbsoluteSrcDir -> FilePath -> FilePath
addRelative (AbsoluteSrcDir srcDir) path =
    Utils.fpCombine srcDir path



-- ====== FORK ======


{-| Starts `work` on a thread of its own and returns at once with the MVar its
result will be put into, written with `encoder`.
-}
fork : (a -> Bytes.Encode.Encoder) -> Task Never a -> Task Never (MVar a)
fork encoder work =
    Utils.newEmptyMVar
        |> Task.andThen
            (\mvar ->
                Utils.forkIO (Task.andThen (Utils.putMVar encoder mvar) work)
                    |> Task.map (\_ -> mvar)
            )


{-| Forks `func` for every entry of `dict` and returns the MVars their results
will arrive in, under the same keys.
-}
dictForkWithKey : (b -> Bytes.Encode.Encoder) -> (comparable -> a -> Task Never b) -> Dict comparable a -> Task Never (Dict comparable (MVar b))
dictForkWithKey encoder func dict =
    Utils.dictTraverseWithKey (\k v -> fork encoder (func k v)) dict



-- ====== FROM EXPOSED ======


{-| Compiles the named modules and everything they import, then produces what
`docsGoal` asks for.

Documentation is generated only for the named modules, and when the goal needs
it each of them is compiled even if its cached artifacts could be reused. The
build fails with `BP_MissingExposed` when a named module cannot be found, with
an import cycle or a dependency loading failure, and otherwise with every
module that has errors. It always uses the erased pipeline and always writes
caches.

-}
fromExposed : Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> DocsGoal docs -> FEStats.Handle -> NE.Nonempty ModuleName.Raw -> Task Never (Result Exit.BuildProblem docs)
fromExposed style root maybeBuildDir maybeKernelPackage details docsGoal stats ((NE.Nonempty e es) as exposed) =
    Reporting.trackBuild style <|
        \key ->
            makeEnv WriteCaches key root maybeBuildDir maybeKernelPackage details False stats
                |> Task.andThen (crawlExposed root maybeBuildDir details docsGoal (e :: es))
                |> Task.andThen (compileExposed root maybeBuildDir details docsGoal exposed)


{-| Starts loading the dependency interfaces and crawls from `modules`, which
need documentation when `docsGoal` does, and returns every crawled module's
status with the MVar the interfaces will arrive in.
-}
crawlExposed : FilePath -> Maybe String -> Details.Details -> DocsGoal docs -> List ModuleName.Raw -> Env -> Task Never { dmvar : MVar (Maybe Dependencies), statuses : Dict ModuleName.Raw Status, env : Env }
crawlExposed root maybeBuildDir details docsGoal modules env =
    let
        docsNeed : DocsNeed
        docsNeed =
            toDocsNeed docsGoal
    in
    Details.loadInterfaces root maybeBuildDir details
        |> Task.andThen (crawlExposedModules env docsNeed modules)
        |> Task.map (buildCrawlResult env)


{-| Crawls from `modules` and pairs every crawled module's status with `dmvar`.
-}
crawlExposedModules : Env -> DocsNeed -> List ModuleName.Raw -> MVar (Maybe Dependencies) -> Task Never ( MVar (Maybe Dependencies), Dict ModuleName.Raw Status )
crawlExposedModules env docsNeed modules dmvar =
    Utils.newEmptyMVar
        |> Task.andThen (crawlAndCollectStatuses env docsNeed modules)
        |> Task.map (\statuses -> ( dmvar, statuses ))


{-| Forks a crawler for each of `modules` and returns the status of every
module crawled, the named ones and all they import.

The status dict MVar is still empty while the crawlers start, so any crawler
that reaches an import waits until the named modules' own MVars are in the
dict, and none of them is crawled a second time.

-}
crawlAndCollectStatuses : Env -> DocsNeed -> List ModuleName.Raw -> MVar StatusDict -> Task Never (Dict ModuleName.Raw Status)
crawlAndCollectStatuses env docsNeed modules mvar =
    Utils.dictFromKeysA (fork statusEncoder << crawlModule env mvar docsNeed) modules
        |> Task.andThen (waitForCrawlResults mvar)


{-| Puts `roots` into the status dict MVar, waits for each of their statuses,
and returns every status in the dict, dropping the MVars (see
`takeAndDropStatuses`).
-}
waitForCrawlResults : MVar StatusDict -> StatusDict -> Task Never (Dict ModuleName.Raw Status)
waitForCrawlResults mvar roots =
    Utils.putMVar statusDictEncoder mvar roots
        |> Task.andThen (\_ -> Utils.dictMapM__ (Utils.readMVar statusDecoder) roots)
        |> Task.andThen (\_ -> takeAndDropStatuses mvar)


{-| Takes the status dict out of `smvar`, reads every status in it, then drops
every status MVar and `smvar` itself, and returns the statuses.

An `SChanged` status holds a module's source text and parsed module, and an
MVar keeps its value alive until it is dropped, so without this they would stay
alive for the rest of the run. The roots' MVars are in the dict too and are
dropped with the rest.

Call this only once every root's status has been read. Each crawler waits for
the statuses of the crawlers it forks before putting its own, so by then no
crawl is still running and nothing reads these MVars again.

-}
takeAndDropStatuses : MVar StatusDict -> Task Never (Dict ModuleName.Raw Status)
takeAndDropStatuses smvar =
    Utils.takeMVar statusDictDecoder smvar
        |> Task.andThen
            (\sdict ->
                Utils.dictTraverse (Utils.readMVar statusDecoder) sdict
                    |> Task.andThen
                        (\statuses ->
                            Utils.dictMapM__ Utils.dropMVar sdict
                                |> Task.andThen (\_ -> Utils.dropMVar smvar)
                                |> Task.map (\_ -> statuses)
                        )
            )


{-| Packages the outcome of a crawl with `env` for the compile phase.
-}
buildCrawlResult : Env -> ( MVar (Maybe Dependencies), Dict ModuleName.Raw Status ) -> { dmvar : MVar (Maybe Dependencies), statuses : Dict ModuleName.Raw Status, env : Env }
buildCrawlResult env ( dmvar, statuses ) =
    { dmvar = dmvar, statuses = statuses, env = env }


{-| Checks the crawl for an import cycle and for the dependency interfaces and,
if neither fails, compiles every crawled module and produces the result for
`exposed`.
-}
compileExposed : FilePath -> Maybe String -> Details.Details -> DocsGoal docs -> NE.Nonempty ModuleName.Raw -> { dmvar : MVar (Maybe Dependencies), statuses : Dict ModuleName.Raw Status, env : Env } -> Task Never (Result Exit.BuildProblem docs)
compileExposed root maybeBuildDir details docsGoal exposed { dmvar, statuses, env } =
    checkMidpoint dmvar statuses
        |> Task.andThen (handleExposedMidpoint root maybeBuildDir details docsGoal exposed statuses env)


{-| Returns the problem the midpoint check found, or compiles every crawled
module, writes the details, and produces the result for `exposed`.
-}
handleExposedMidpoint : FilePath -> Maybe String -> Details.Details -> DocsGoal docs -> NE.Nonempty ModuleName.Raw -> Dict ModuleName.Raw Status -> Env -> Result Exit.BuildProjectProblem Dependencies -> Task Never (Result Exit.BuildProblem docs)
handleExposedMidpoint root maybeBuildDir details docsGoal exposed statuses env midpoint =
    case midpoint of
        Err problem ->
            Task.succeed (Err (Exit.BuildProjectProblem problem))

        Ok foreigns ->
            compileAndFinalize root maybeBuildDir details foreigns statuses env
                |> Task.andThen (finalizeExposed root docsGoal exposed)


{-| Compiles every crawled module, writes `d.dat` with the compiled modules'
new entries, and returns every module's result. The details are written
whatever the build's `CacheMode`.
-}
compileAndFinalize : FilePath -> Maybe String -> Details.Details -> Dependencies -> Dict ModuleName.Raw Status -> Env -> Task Never (Dict ModuleName.Raw BResult)
compileAndFinalize root maybeBuildDir details foreigns statuses env =
    Utils.newEmptyMVar
        |> Task.andThen (compileAllModules env foreigns statuses)
        |> Task.andThen (collectResultsAndWriteDetails root maybeBuildDir details)


{-| Forks a check of every crawled module and returns their result MVars,
together with `rmvar`, the MVar the checks read them from, which is still
empty.
-}
compileAllModules : Env -> Dependencies -> Dict ModuleName.Raw Status -> MVar ResultDict -> Task Never ( MVar ResultDict, Dict ModuleName.Raw (MVar BResult) )
compileAllModules env foreigns statuses rmvar =
    dictForkWithKey bResultEncoder (checkModule env foreigns rmvar) statuses
        |> Task.map (\resultMVars -> ( rmvar, resultMVars ))


{-| Gives the checks the result MVars, waits for every result, drops the MVars,
then writes the details and returns the results.
-}
collectResultsAndWriteDetails : FilePath -> Maybe String -> Details.Details -> ( MVar (Dict ModuleName.Raw (MVar BResult)), Dict ModuleName.Raw (MVar BResult) ) -> Task Never (Dict ModuleName.Raw BResult)
collectResultsAndWriteDetails root maybeBuildDir details ( rmvar, resultMVars ) =
    Utils.putMVar dictRawMVarBResultEncoder rmvar resultMVars
        |> Task.andThen (\_ -> Utils.dictTraverse (Utils.readMVar bResultDecoder) resultMVars)
        |> Task.andThen
            (\results ->
                Utils.dictMapM__ Utils.dropMVar resultMVars
                    |> Task.andThen (\_ -> Utils.dropMVar rmvar)
                    |> Task.andThen (\_ -> writeDetailsAndReturn root maybeBuildDir details results)
            )


{-| Writes `d.dat` with the entries of the modules compiled in `results` and
returns `results`.
-}
writeDetailsAndReturn : FilePath -> Maybe String -> Details.Details -> Dict ModuleName.Raw BResult -> Task Never (Dict ModuleName.Raw BResult)
writeDetailsAndReturn root maybeBuildDir details results =
    writeDetails root maybeBuildDir details results
        |> Task.map (\_ -> results)



-- ====== FROM PATHS ======


{-| What a build from paths hands on: the package the project's modules belong
to, the dependency interfaces, the roots in the order they were given, and the
compiled modules.

`pkg` is a placeholder name for an application that is not a kernel
application. `modules` holds the project's modules and the outside roots, not
foreign or kernel modules.

-}
type alias ArtifactsData =
    { pkg : Pkg.Name
    , deps : Dependencies
    , roots : NE.Nonempty Root
    , modules : List Module
    }


{-| The result of a successful build from paths (see `ArtifactsData`).
-}
type Artifacts
    = Artifacts ArtifactsData


{-| One compiled project module, as the artifacts carry it.

`Fresh` is a module compiled in this build, including an outside root. It
carries its interface and its erased graph, which on a typed build is the
presence-only stub `Compiler.AST.Optimized` describes, and its typed graph and
type environment, which are `Nothing` on an untyped build.

`Cached` is a module reused from disk without compiling. Its `Bool` says
whether it defines `main`, and its MVar holds its interface once some module
has needed it read from the `.eci` file (see `CachedInterface`).

-}
type Module
    = Fresh ModuleName.Raw I.Interface Opt.LocalGraph (Maybe (TOpt.LocalGraph Name)) (Maybe TypeEnv.ModuleTypeEnv)
    | Cached ModuleName.Raw Bool (MVar CachedInterface)


{-| The interfaces of the modules the project's dependencies provide, keyed by
canonical module name.

Modules that a direct dependency does not expose, and every module of an
indirect dependency, have private interfaces holding only their types;
`Builder.Elm.Details` decides which. This is a name for a `Data.Map.Dict`, not
a new type.

-}
type alias Dependencies =
    Data.Map.Dict String ModuleName.Canonical I.DependencyInterface


{-| Compiles the modules at `paths` and everything they import, writing caches,
and returns the artifacts. `needsTypedOpt` selects the typed pipeline over the
erased one.

The build fails when a path cannot be a root: there is no file at it, it does
not end in `.elm`, it lies in two source directories, its path below a source
directory is not a module name, or another source directory has the same
module. It also fails on an import cycle, when the dependency interfaces cannot
be loaded, and with every module and outside root that has errors.

-}
fromPaths : Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Bool -> FEStats.Handle -> NE.Nonempty FilePath -> Task Never (Result Exit.BuildProblem Artifacts)
fromPaths =
    fromPathsWith WriteCaches


{-| Does what `fromPaths` does, writing caches only when `cacheMode` is
`WriteCaches`.
-}
fromPathsWith : CacheMode -> Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Bool -> FEStats.Handle -> NE.Nonempty FilePath -> Task Never (Result Exit.BuildProblem Artifacts)
fromPathsWith cacheMode style root maybeBuildDir maybeKernelPackage details needsTypedOpt stats paths =
    Reporting.trackBuild style <|
        \key ->
            makeEnv cacheMode key root maybeBuildDir maybeKernelPackage details needsTypedOpt stats
                |> Task.andThen (findAndBuildFromPaths root maybeBuildDir details paths)


{-| Locates the roots at `paths` and, when they are all valid, crawls and
compiles from them.
-}
findAndBuildFromPaths : FilePath -> Maybe String -> Details.Details -> NE.Nonempty FilePath -> Env -> Task Never (Result Exit.BuildProblem Artifacts)
findAndBuildFromPaths root maybeBuildDir details paths env =
    findRoots env paths
        |> Task.andThen (handleFoundRoots root maybeBuildDir details env)


{-| Returns the problem found while locating the roots, or crawls and compiles
from them.
-}
handleFoundRoots : FilePath -> Maybe String -> Details.Details -> Env -> Result Exit.BuildProjectProblem (NE.Nonempty RootLocation) -> Task Never (Result Exit.BuildProblem Artifacts)
handleFoundRoots root maybeBuildDir details env elroots =
    case elroots of
        Err problem ->
            Task.succeed (Err (Exit.BuildProjectProblem problem))

        Ok lroots ->
            crawlPaths root maybeBuildDir details env lroots
                |> Task.andThen (compilePaths root maybeBuildDir details env)


{-| What the crawl of a build from paths passes to its compile phase: the MVar
the dependency interfaces will arrive in, every crawled module's status, and
each root's status in the order the roots were given.
-}
type alias PathsBuildContext =
    { dmvar : MVar (Maybe Dependencies)
    , statuses : Dict ModuleName.Raw Status
    , sroots : NE.Nonempty RootStatus
    }


{-| Starts loading the dependency interfaces and crawls from the roots.
-}
crawlPaths : FilePath -> Maybe String -> Details.Details -> Env -> NE.Nonempty RootLocation -> Task Never PathsBuildContext
crawlPaths root maybeBuildDir details env lroots =
    Details.loadInterfaces root maybeBuildDir details
        |> Task.andThen (crawlPathRoots env lroots)


{-| Crawls from the roots, starting from an empty status dict.
-}
crawlPathRoots : Env -> NE.Nonempty RootLocation -> MVar (Maybe Dependencies) -> Task Never PathsBuildContext
crawlPathRoots env lroots dmvar =
    Utils.newMVar statusDictEncoder Dict.empty
        |> Task.andThen (crawlRootsAndCollect env lroots dmvar)


{-| Forks a crawler for each root and returns the roots' statuses and every
crawled module's status, dropping their MVars once read.
-}
crawlRootsAndCollect : Env -> NE.Nonempty RootLocation -> MVar (Maybe Dependencies) -> MVar StatusDict -> Task Never PathsBuildContext
crawlRootsAndCollect env lroots dmvar smvar =
    Utils.nonEmptyListTraverse (fork rootStatusEncoder << crawlRoot env smvar) lroots
        |> Task.andThen readAndDropRootStatuses
        |> Task.andThen (collectPathStatuses dmvar smvar)


{-| Waits for every root's status, then drops the roots' MVars and returns the
statuses. An `SOutsideOk` status holds the root's source text and parsed
module, which the MVar would otherwise keep alive.
-}
readAndDropRootStatuses : NE.Nonempty (MVar RootStatus) -> Task Never (NE.Nonempty RootStatus)
readAndDropRootStatuses rootMVars =
    Utils.nonEmptyListTraverse (Utils.readMVar rootStatusDecoder) rootMVars
        |> Task.andThen
            (\sroots ->
                Utils.nonEmptyListTraverse Utils.dropMVar rootMVars
                    |> Task.map (\_ -> sroots)
            )


{-| Reads every crawled module's status (see `takeAndDropStatuses`) and returns
it with `dmvar` and `sroots` for the compile phase.
-}
collectPathStatuses : MVar (Maybe Dependencies) -> MVar StatusDict -> NE.Nonempty RootStatus -> Task Never PathsBuildContext
collectPathStatuses dmvar smvar sroots =
    takeAndDropStatuses smvar
        |> Task.map (\statuses -> { dmvar = dmvar, statuses = statuses, sroots = sroots })


{-| Checks the crawl for an import cycle, for two roots with one module name and
for the dependency interfaces and, if none fails, compiles and returns the
artifacts.
-}
compilePaths : FilePath -> Maybe String -> Details.Details -> Env -> PathsBuildContext -> Task Never (Result Exit.BuildProblem Artifacts)
compilePaths root maybeBuildDir details env { dmvar, statuses, sroots } =
    checkMidpointAndRoots dmvar statuses sroots
        |> Task.andThen (handlePathsMidpoint root maybeBuildDir details env statuses sroots)


{-| Returns the problem the midpoint check found, or compiles every crawled
module and root and returns the artifacts.
-}
handlePathsMidpoint : FilePath -> Maybe String -> Details.Details -> Env -> Dict ModuleName.Raw Status -> NE.Nonempty RootStatus -> Result Exit.BuildProjectProblem Dependencies -> Task Never (Result Exit.BuildProblem Artifacts)
handlePathsMidpoint root maybeBuildDir details env statuses sroots midpoint =
    case midpoint of
        Err problem ->
            Task.succeed (Err (Exit.BuildProjectProblem problem))

        Ok foreigns ->
            compilePathModules root maybeBuildDir details env foreigns statuses sroots


{-| Compiles every crawled module and every outside root, writes the details
unless the build is `OneShot`, and turns the results into artifacts.
-}
compilePathModules : FilePath -> Maybe String -> Details.Details -> Env -> Dependencies -> Dict ModuleName.Raw Status -> NE.Nonempty RootStatus -> Task Never (Result Exit.BuildProblem Artifacts)
compilePathModules root maybeBuildDir details env foreigns statuses sroots =
    Utils.newEmptyMVar
        |> Task.andThen (compilePathsWithMVar env foreigns statuses sroots)
        |> Task.andThen (finalizePathBuild root maybeBuildDir details env foreigns)


{-| Forks a check of every crawled module, then a check of every root.
-}
compilePathsWithMVar : Env -> Dependencies -> Dict ModuleName.Raw Status -> NE.Nonempty RootStatus -> MVar ResultDict -> Task Never PathCompileState
compilePathsWithMVar env foreigns statuses sroots rmvar =
    dictForkWithKey bResultEncoder (checkModule env foreigns rmvar) statuses
        |> Task.andThen (checkRootsAndCollect env sroots rmvar)


{-| The MVars the compile phase of a build from paths waits on: the one the
checks read the result MVars from, each module's result MVar, and each root's
result MVar.
-}
type alias PathCompileState =
    { rmvar : MVar ResultDict
    , resultsMVars : Dict ModuleName.Raw (MVar BResult)
    , rrootMVars : NE.Nonempty (MVar RootResult)
    }


{-| Gives the module checks the result MVars, then forks a check of every root.
-}
checkRootsAndCollect : Env -> NE.Nonempty RootStatus -> MVar ResultDict -> Dict ModuleName.Raw (MVar BResult) -> Task Never PathCompileState
checkRootsAndCollect env sroots rmvar resultsMVars =
    Utils.putMVar resultDictEncoder rmvar resultsMVars
        |> Task.andThen (\_ -> Utils.nonEmptyListTraverse (checkRoot env resultsMVars >> fork rootResultEncoder) sroots)
        |> Task.map (\rrootMVars -> { rmvar = rmvar, resultsMVars = resultsMVars, rrootMVars = rrootMVars })


{-| Waits for every module's result and every root's result, writes the details
unless the build is `OneShot`, drops all those MVars and `rmvar`, and builds
the artifacts.

The module result MVars are dropped only after every root's result has been
read, because the check of an outside root reads them and would fail to find
one that had already been dropped. Once every root's result is in, every check
has finished and nothing reads these MVars again.

-}
finalizePathBuild : FilePath -> Maybe String -> Details.Details -> Env -> Dependencies -> PathCompileState -> Task Never (Result Exit.BuildProblem Artifacts)
finalizePathBuild root maybeBuildDir details env foreigns { rmvar, resultsMVars, rrootMVars } =
    Utils.dictTraverse (Utils.readMVar bResultDecoder) resultsMVars
        |> Task.andThen (writeDetailsAndCollectRoots (envCacheMode env) root maybeBuildDir details rrootMVars)
        |> Task.andThen
            (\collected ->
                Utils.dictMapM__ Utils.dropMVar resultsMVars
                    |> Task.andThen (\_ -> Utils.nonEmptyListTraverse Utils.dropMVar rrootMVars)
                    |> Task.andThen (\_ -> Utils.dropMVar rmvar)
                    |> Task.map (\_ -> collected)
            )
        |> Task.map (toArtifactsFromResults env foreigns)


{-| Writes `d.dat` with the entries of the modules compiled in `results`, unless
`cacheMode` is `OneShot`, then waits for every root's result.
-}
writeDetailsAndCollectRoots : CacheMode -> FilePath -> Maybe String -> Details.Details -> NE.Nonempty (MVar RootResult) -> Dict ModuleName.Raw BResult -> Task Never ( Dict ModuleName.Raw BResult, NE.Nonempty RootResult )
writeDetailsAndCollectRoots cacheMode root maybeBuildDir details rrootMVars results =
    (case cacheMode of
        WriteCaches ->
            writeDetails root maybeBuildDir details results

        OneShot ->
            -- No local entries may claim artifacts this build did not write.
            Task.succeed ()
    )
        |> Task.andThen (\_ -> Utils.nonEmptyListTraverse (Utils.readMVar rootResultDecoder) rrootMVars)
        |> Task.map (\rroots -> ( results, rroots ))


{-| Returns the build's `CacheMode`.
-}
envCacheMode : Env -> CacheMode
envCacheMode (Env envData) =
    envData.cacheMode


{-| Builds the artifacts, or the errors, from the module results and the root
results (see `toArtifacts`).
-}
toArtifactsFromResults : Env -> Dependencies -> ( Dict ModuleName.Raw BResult, NE.Nonempty RootResult ) -> Result Exit.BuildProblem Artifacts
toArtifactsFromResults env foreigns ( results, rroots ) =
    toArtifacts env foreigns results rroots



-- ====== GET ROOT NAMES ======


{-| Returns the module name of every root, in the order the roots were given.
-}
getRootNames : Artifacts -> NE.Nonempty ModuleName.Raw
getRootNames (Artifacts a) =
    NE.map getRootName a.roots


{-| Returns the module name of a root.
-}
getRootName : Root -> ModuleName.Raw
getRootName root =
    case root of
        Inside name ->
            name

        Outside name _ _ _ _ ->
            name



-- ====== CRAWL ======


{-| The crawl's shared table: for each module a crawler has taken on, the MVar
its status will arrive in.

A crawler takes the table's MVar, forks a crawl for each import not yet in it,
and puts the table back with those imports added, so no import is forked twice.
`crawlRoot` adds an inside root without that check.

-}
type alias StatusDict =
    Dict ModuleName.Raw (MVar Status)


{-| What the crawl found out about one module.

`SCached` is a module whose file has the path and modification time its
details entry records, and which needs no documentation. It carries that entry.

`SChanged` is a module that must be compiled. It carries a new details entry,
the source text, the parsed module, and whether it needs documentation. The
entry's `lastCompile` is the current build, and its `lastChange` is the old
entry's, or the current build for a module with no entry.

`SBadImport` is a module that cannot be found, or that is ambiguous: two
source directories have it, a source directory has it and a direct dependency
exposes it, or two direct dependencies expose it.

`SBadSyntax` is a module that does not parse, or whose header names no module
or a different module from the one its path names.

`SForeign` is a module that one direct dependency exposes, the one named.

`SKernel` is a kernel module whose `.js` file a source directory of a kernel
project has.

-}
type Status
    = SCached Details.Local
    | SChanged Details.Local String Src.Module DocsNeed
    | SBadImport Import.Problem
    | SBadSyntax FilePath File.Time String Syntax.Error
    | SForeign Pkg.Name
    | SKernel


{-| Forks a crawler for each of `deps` that no crawler has yet taken on, waits
for the statuses of those it forked, and then returns `blockedValue`.
-}
crawlDeps : Env -> MVar StatusDict -> List ModuleName.Raw -> a -> Task Never a
crawlDeps env mvar deps blockedValue =
    Utils.takeMVar statusDictDecoder mvar
        |> Task.andThen (crawlNewDeps env mvar deps)
        |> Task.map (\_ -> blockedValue)


{-| Forks a crawler for each of `deps` not already in `statusDict`, puts the
enlarged dict back into `mvar`, and waits for the new crawls. The imports are
crawled without documentation.
-}
crawlNewDeps : Env -> MVar StatusDict -> List ModuleName.Raw -> StatusDict -> Task Never ()
crawlNewDeps env mvar deps statusDict =
    let
        crawlNew : ModuleName.Raw -> () -> Task Never (MVar Status)
        crawlNew name () =
            fork statusEncoder (crawlModule env mvar (DocsNeed False) name)

        depsDict : Dict ModuleName.Raw ()
        depsDict =
            Dict.fromList (List.map (\k -> ( k, () )) deps)

        newsDict : Dict ModuleName.Raw ()
        newsDict =
            Dict.diff depsDict statusDict
    in
    Utils.dictTraverseWithKey crawlNew newsDict
        |> Task.andThen (updateStatusDictAndWait mvar statusDict)


{-| Puts `statusDict` with `statuses` added back into `mvar` and waits until
each MVar in `statuses` has its status.
-}
updateStatusDictAndWait : MVar StatusDict -> StatusDict -> StatusDict -> Task Never ()
updateStatusDictAndWait mvar statusDict statuses =
    Utils.putMVar statusDictEncoder mvar (Dict.union statuses statusDict)
        |> Task.andThen (\_ -> Utils.dictMapM__ (Utils.readMVar statusDecoder) statuses)


{-| Crawls the module `name`: finds its file in the source directories, decides
its status, and crawls its imports. The time taken, including waiting for
those imports, is recorded under the crawl stage of `FEStats`.
-}
crawlModule : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Task Never Status
crawlModule ((Env envData) as env) mvar ((DocsNeed needsDocs) as docsNeed) name =
    let
        elmFileName : String
        elmFileName =
            ModuleName.toFilePath name ++ ".elm"
    in
    FEStats.withModuleStage envData.stats FEStats.Crawl name <|
        (findModulePaths envData.srcDirs elmFileName
            |> Task.andThen (crawlFoundPaths env mvar docsNeed name needsDocs envData.root envData.projectType envData.buildID envData.locals envData.foreigns)
        )


{-| Returns the paths of the source directories' files named `elmFileName` that
exist.
-}
findModulePaths : List AbsoluteSrcDir -> String -> Task Never (List FilePath)
findModulePaths srcDirs elmFileName =
    Utils.filterM File.exists (List.map (flip addRelative elmFileName) srcDirs)


{-| Returns the status of `name` given the files found for it. One file is
crawled; two or more are an ambiguous import, with paths relative to `root`;
none means the module is looked for among foreign and kernel modules.
-}
crawlFoundPaths : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Bool -> FilePath -> Parse.ProjectType -> Details.BuildID -> Dict ModuleName.Raw Details.Local -> Dict ModuleName.Raw Details.Foreign -> List FilePath -> Task Never Status
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


{-| Returns the status of a module whose file is at `path`. When a direct
dependency also exposes the name, the import is ambiguous; otherwise the file's
modification time decides whether the module is cached.
-}
crawlSinglePath : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Bool -> Details.BuildID -> Dict ModuleName.Raw Details.Local -> Dict ModuleName.Raw Details.Foreign -> FilePath -> Task Never Status
crawlSinglePath env mvar docsNeed name needsDocs buildID locals foreigns path =
    case Dict.get name foreigns of
        Just (Details.Foreign dep deps) ->
            Import.Ambiguous path [] dep deps |> SBadImport |> Task.succeed

        Nothing ->
            File.getTime path
                |> Task.andThen (crawlWithTime env mvar docsNeed name needsDocs buildID locals path)


{-| Returns `SCached`, after crawling the recorded imports, when the module's
details entry has `path` and `newTime` and no documentation is needed;
otherwise reads and parses the file (see `crawlFile`).
-}
crawlWithTime : Env -> MVar StatusDict -> DocsNeed -> ModuleName.Raw -> Bool -> Details.BuildID -> Dict ModuleName.Raw Details.Local -> FilePath -> File.Time -> Task Never Status
crawlWithTime env mvar docsNeed name needsDocs buildID locals path newTime =
    case Dict.get name locals of
        Nothing ->
            crawlFile env mvar docsNeed name path newTime buildID

        Just ((Details.Local localData) as local) ->
            if path /= localData.path || localData.time /= newTime || needsDocs then
                crawlFile env mvar docsNeed name path newTime localData.lastChange

            else
                crawlDeps env mvar localData.deps (SCached local)


{-| Returns the status of a module that no source directory has: `SForeign`
when exactly one direct dependency exposes it, an ambiguous import when several
do, and, for a kernel module name in a kernel project, whatever
`checkKernelExistsInDirs` finds. Anything else is not found.
-}
crawlNoLocalPath : ModuleName.Raw -> Parse.ProjectType -> Dict ModuleName.Raw Details.Foreign -> List AbsoluteSrcDir -> Task Never Status
crawlNoLocalPath name projectType foreigns srcDirs =
    case Dict.get name foreigns of
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

                    foreignHomes : Dict ModuleName.Raw Pkg.Name
                    foreignHomes =
                        Dict.map (\_ (Details.Foreign home _) -> home) foreigns
                in
                checkKernelExistsInDirs name pkg foreignHomes srcDirs

            else
                SBadImport Import.NotFound |> Task.succeed


{-| Returns `SKernel` when one of `srcDirs` has the kernel module's `.js` file,
and a not-found import otherwise.

The file is read and parsed, but the result is `SKernel` whether or not it
parses.

-}
checkKernelExistsInDirs : ModuleName.Raw -> Pkg.Name -> Dict ModuleName.Raw Pkg.Name -> List AbsoluteSrcDir -> Task Never Status
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


{-| Reads and parses the module file at `path`. Returns `SChanged`, with a new
details entry carrying `lastChange` and the current build as `lastCompile`,
after crawling the module's imports. Returns `SBadSyntax` when the file does
not parse or its header names no module or a module other than `expectedName`.
-}
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


{-| Tells whether a top-level value is named `main`.
-}
isMain : A.Located Src.Value -> Bool
isMain (A.At _ (Src.Value v)) =
    let
        ( _, A.At _ name ) =
            v.name
    in
    name == Name.main_



-- ====== CHECK MODULE ======


{-| For each crawled module, the MVar its check result will arrive in. The
checks read this dict from an MVar that is filled only after every check has
been forked.
-}
type alias ResultDict =
    Dict ModuleName.Raw (MVar BResult)


{-| The outcome of checking one module.

`RNew` and `RSame` are modules compiled in this build. Each carries the new
details entry, the interface, the erased graph, the typed graph and type
environment (`Nothing` on an untyped build) and the documentation (`Nothing`
unless it was needed). `RNew` means the interface differs from the `.eci` file
on disk, or none could be read; `RSame` means it is the same.

`RCached` is a module reused from disk. It carries whether the module defines
`main`, its `lastChange`, and the MVar its interface is read through.

`RNotFound` is a module that cannot be found or is ambiguous.

`RProblem` is a module with errors.

`RBlocked` is a module that was not compiled because of its imports: one
failed, a cached interface could not be read, or, for a module whose file did
not change, an import could not be found.

`RForeign` is a module a direct dependency provides, with its interface.

`RKernel` is a kernel module.

`RKernelLocal` is never produced by this module; it is only encoded and
decoded.

-}
type BResult
    = RNew Details.Local I.Interface Opt.LocalGraph (Maybe (TOpt.LocalGraph Name)) (Maybe TypeEnv.ModuleTypeEnv) (Maybe Docs.Module)
    | RSame Details.Local I.Interface Opt.LocalGraph (Maybe (TOpt.LocalGraph Name)) (Maybe TypeEnv.ModuleTypeEnv) (Maybe Docs.Module)
    | RCached Bool Details.BuildID (MVar CachedInterface)
    | RNotFound Import.Problem
    | RProblem Error.Module
    | RBlocked
    | RForeign I.Interface
    | RKernel
    | RKernelLocal (List Kernel.Chunk)


{-| The interface of a cached module, as far as this build has needed it.

`Unneeded` means its `.eci` file has not been read. `Loaded` carries the
interface read from it. `Corrupted` means the file was missing or could not be
decoded, and every module that needs it is blocked.

The MVar holding it is created full, and each reader takes it and puts it back,
so the file is read at most once in a build.

-}
type CachedInterface
    = Unneeded
    | Loaded I.Interface
    | Corrupted


{-| Returns the result for one crawled module from its crawl status, waiting
for its imports' results where they matter. The time taken is recorded under
the check stage of `FEStats`.

A foreign module whose interface is private crashes the compiler.

-}
checkModule : Env -> Dependencies -> MVar ResultDict -> ModuleName.Raw -> Status -> Task Never BResult
checkModule ((Env envData) as env) foreigns resultsMVar name status =
    FEStats.withModuleStage envData.stats FEStats.Check name <|
        case status of
            SCached (Details.Local localData) ->
                checkCachedModule env envData.root envData.projectType resultsMVar name localData.path localData.time localData.deps localData.hasMain localData.lastChange localData.lastCompile

            SChanged ((Details.Local localData) as local) source ((Src.Module srcData) as modul) docsNeed ->
                checkChangedModule env envData.root resultsMVar name localData.path localData.time localData.deps localData.lastCompile local source srcData.imports modul docsNeed

            SBadImport importProblem ->
                Task.succeed (RNotFound importProblem)

            SBadSyntax path time source err ->
                Error.BadSyntax err |> Error.Module name path time source |> RProblem |> Task.succeed

            SForeign home ->
                case Utils.find ModuleName.toComparableCanonical (ModuleName.Canonical home name) foreigns of
                    I.Public iface ->
                        Task.succeed (RForeign iface)

                    I.Private _ _ _ ->
                        ("mistakenly seeing private interface for " ++ Pkg.toChars home ++ " " ++ name) |> crash

            SKernel ->
                Task.succeed RKernel


{-| Returns the result for a module whose file has not changed: reused if its
imports allow it, otherwise compiled again from its file (see
`handleCachedDepsStatus`).
-}
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
    -> Task Never BResult
checkCachedModule ((Env envData) as env) root projectType resultsMVar name path time deps hasMain lastChange lastCompile =
    Utils.readMVar resultDictDecoder resultsMVar
        |> Task.andThen (\resultDict -> checkDeps root envData.maybeBuildDir resultDict deps lastCompile)
        |> Task.andThen (handleCachedDepsStatus env root projectType name path time deps hasMain lastChange)


{-| Decides the result of a module whose file has not changed from its imports'
`DepsStatus`.

With no import changed, the module is reused only if the artifact this build
reads is on disk, `.ecot` on a typed build and `.eco` on an untyped one. A
module last compiled for the other kind of build looks unchanged, but may lack
that artifact, and is compiled again when it is missing. With a changed import
the module is compiled again. A failed import blocks it, and so does an import
that cannot be found, since the module's source has not been read to report
the error against.

-}
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
    -> DepsStatus
    -> Task Never BResult
handleCachedDepsStatus ((Env envData) as env) root projectType name path time deps hasMain lastChange depsStatus =
    case depsStatus of
        DepsSame same cached ->
            let
                artifactPath : FilePath
                artifactPath =
                    if envData.needsTypedOpt then
                        Stuff.ecotWithBuildDir root envData.maybeBuildDir name

                    else
                        Stuff.ecoWithBuildDir root envData.maybeBuildDir name
            in
            File.exists artifactPath
                |> Task.andThen (handleCachedWithArtifactCheck env root projectType name path time deps hasMain lastChange same cached)

        DepsChange ifaces ->
            File.readUtf8 (Utils.fpCombine root path)
                |> Task.andThen (recompileCachedModule env projectType name path time deps ifaces)

        DepsBlock ->
            Task.succeed RBlocked

        DepsNotFound _ ->
            Task.succeed RBlocked


{-| Returns `RCached` when `artifactExists`, with the interface MVar created
full, holding `Unneeded`: `loadInterface` takes that MVar and puts it back, and
would wait forever on an empty one. Otherwise loads the imports' interfaces and
compiles the module again, or blocks it when one cannot be read.
-}
handleCachedWithArtifactCheck :
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
handleCachedWithArtifactCheck ((Env envData) as env) root projectType name path time deps hasMain lastChange same cached artifactExists =
    if artifactExists then
        Utils.newMVar cachedInterfaceEncoder Unneeded
            |> Task.map (\mvar -> RCached hasMain lastChange mvar)

    else
        loadInterfaces root envData.maybeBuildDir same cached
            |> Task.andThen (recompileIfInterfacesLoaded env root projectType name path time deps)


{-| Compiles a module whose file has not changed again, from its file, when its
imports' interfaces were loaded, and blocks it otherwise.
-}
recompileIfInterfacesLoaded :
    Env
    -> FilePath
    -> Parse.ProjectType
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Maybe (Dict ModuleName.Raw I.Interface)
    -> Task Never BResult
recompileIfInterfacesLoaded env root projectType name path time deps maybeIfaces =
    case maybeIfaces of
        Nothing ->
            Task.succeed RBlocked

        Just ifaces ->
            File.readUtf8 (Utils.fpCombine root path)
                |> Task.andThen (recompileCachedModule env projectType name path time deps ifaces)


{-| Parses `source` and compiles it, without documentation, for a module whose
file has not changed.

The new details entry starts with `lastChange` and `lastCompile` at 0, so if
the interface turns out unchanged the module records a `lastChange` of 0 rather
than the build at which its interface last changed.

-}
recompileCachedModule :
    Env
    -> Parse.ProjectType
    -> ModuleName.Raw
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Dict ModuleName.Raw I.Interface
    -> String
    -> Task Never BResult
recompileCachedModule env projectType name path time deps ifaces source =
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


{-| Returns the result for a module the crawl found changed: waits for its
imports' results and compiles it unless they prevent it.
-}
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
checkChangedModule ((Env envData) as env) root resultsMVar name path time deps lastCompile local source imports modul docsNeed =
    Utils.readMVar resultDictDecoder resultsMVar
        |> Task.andThen (\resultDict -> checkDeps root envData.maybeBuildDir resultDict deps lastCompile |> Task.map (\status -> ( resultDict, status )))
        |> Task.andThen (\( resultDict, depsStatus ) -> handleChangedDepsStatus env resultDict root name path time local source imports modul docsNeed depsStatus)


{-| Compiles a changed module against its imports' interfaces, reading the
cached ones when no import changed. It is blocked when an import failed, and
an import that cannot be found is reported against its source.
-}
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
handleChangedDepsStatus ((Env envData) as env) resultDict root name path time local source imports modul docsNeed depsStatus =
    case depsStatus of
        DepsSame same cached ->
            loadInterfaces root envData.maybeBuildDir same cached
                |> Task.andThen (compileIfInterfacesLoaded env local source modul docsNeed)

        DepsChange ifaces ->
            compile env docsNeed local source ifaces modul

        DepsBlock ->
            Task.succeed RBlocked

        DepsNotFound problems ->
            makeImportError env resultDict name path time source imports problems


{-| Compiles the module when its imports' interfaces were loaded, and blocks it
otherwise.
-}
compileIfInterfacesLoaded :
    Env
    -> Details.Local
    -> String
    -> Src.Module
    -> DocsNeed
    -> Maybe (Dict ModuleName.Raw I.Interface)
    -> Task Never BResult
compileIfInterfacesLoaded env local source modul docsNeed maybeIfaces =
    case maybeIfaces of
        Nothing ->
            Task.succeed RBlocked

        Just ifaces ->
            compile env docsNeed local source ifaces modul


{-| Returns an `RProblem` reporting each import in `problems`, located at its
import line in `source`.
-}
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


{-| What the results of a module's imports say about it, compared with the
module's `lastCompile`.

`DepsNotFound` lists the imports that cannot be found or are ambiguous, in
import order. It wins over everything else.

`DepsBlock` means an import has errors or is blocked, or a cached import's
interface could not be read.

`DepsSame` means no import was compiled with a new interface in this build and
no import's `lastChange` is later than `lastCompile`. It carries the
interfaces already in memory and the MVars of the cached ones, which are read
only if the module is compiled after all.

`DepsChange` is the remaining case, and carries every import's interface.

Kernel imports count for nothing, and foreign imports never make a change.

-}
type DepsStatus
    = DepsChange (Dict ModuleName.Raw I.Interface)
    | DepsSame (List Dep) (List CDep)
    | DepsBlock
    | DepsNotFound (NE.Nonempty ( ModuleName.Raw, Import.Problem ))


{-| Waits for the result of each of `deps` and returns their `DepsStatus`
against `lastCompile`.
-}
checkDeps : FilePath -> Maybe String -> ResultDict -> List ModuleName.Raw -> Details.BuildID -> Task Never DepsStatus
checkDeps root maybeBuildDir results deps lastCompile =
    checkDepsHelp root maybeBuildDir results deps [] [] [] [] False 0 lastCompile


{-| An imported module with its interface in memory.
-}
type alias Dep =
    ( ModuleName.Raw, I.Interface )


{-| A cached imported module, with the MVar its interface is read through.
-}
type alias CDep =
    ( ModuleName.Raw, MVar CachedInterface )


{-| Sorts each import's result into the interfaces of imports compiled with a
new interface (`new`), the other interfaces in memory (`same`), the cached
ones, and the import problems, noting whether any import blocks the module and
the latest `lastChange` among imports, then decides the `DepsStatus`.
-}
checkDepsHelp :
    FilePath
    -> Maybe String
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
checkDepsHelp root maybeBuildDir results deps new same cached importProblems isBlocked lastDepChange lastCompile =
    case deps of
        dep :: otherDeps ->
            Utils.readMVar bResultDecoder (Utils.dictFind dep results)
                |> Task.andThen
                    (\result ->
                        case result of
                            RNew (Details.Local localData) iface _ _ _ _ ->
                                checkDepsHelp root maybeBuildDir results otherDeps (( dep, iface ) :: new) same cached importProblems isBlocked (max localData.lastChange lastDepChange) lastCompile

                            RSame (Details.Local localData) iface _ _ _ _ ->
                                checkDepsHelp root maybeBuildDir results otherDeps new (( dep, iface ) :: same) cached importProblems isBlocked (max localData.lastChange lastDepChange) lastCompile

                            RCached _ lastChange mvar ->
                                checkDepsHelp root maybeBuildDir results otherDeps new same (( dep, mvar ) :: cached) importProblems isBlocked (max lastChange lastDepChange) lastCompile

                            RNotFound prob ->
                                checkDepsHelp root maybeBuildDir results otherDeps new same cached (( dep, prob ) :: importProblems) True lastDepChange lastCompile

                            RProblem _ ->
                                checkDepsHelp root maybeBuildDir results otherDeps new same cached importProblems True lastDepChange lastCompile

                            RBlocked ->
                                checkDepsHelp root maybeBuildDir results otherDeps new same cached importProblems True lastDepChange lastCompile

                            RForeign iface ->
                                checkDepsHelp root maybeBuildDir results otherDeps new (( dep, iface ) :: same) cached importProblems isBlocked lastDepChange lastCompile

                            RKernel ->
                                checkDepsHelp root maybeBuildDir results otherDeps new same cached importProblems isBlocked lastDepChange lastCompile

                            RKernelLocal _ ->
                                checkDepsHelp root maybeBuildDir results otherDeps new same cached importProblems isBlocked lastDepChange lastCompile
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
                        loadInterfaces root maybeBuildDir same cached
                            |> Task.map
                                (\maybeLoaded ->
                                    case maybeLoaded of
                                        Nothing ->
                                            DepsBlock

                                        Just ifaces ->
                                            Dict.union (Dict.fromList new) ifaces |> DepsChange
                                )



-- ====== TO IMPORT ERROR ======


{-| Turns import problems into import errors located at their import lines.
Each error carries the modules the project knows of that this module does not
import, which the report uses for suggestions.
-}
toImportErrors : Env -> ResultDict -> List Src.Import -> NE.Nonempty ( ModuleName.Raw, Import.Problem ) -> NE.Nonempty Import.Error
toImportErrors (Env envData) results imports problems =
    let
        knownModules : EverySet.EverySet String ModuleName.Raw
        knownModules =
            EverySet.fromList identity
                (List.concat
                    [ Dict.keys envData.foreigns
                    , Dict.keys envData.locals
                    , Dict.keys results
                    ]
                )

        unimportedModules : EverySet.EverySet String ModuleName.Raw
        unimportedModules =
            EverySet.diff knownModules (EverySet.fromList identity (List.map Src.getImportName imports))

        regionDict : Dict Name.Name A.Region
        regionDict =
            Dict.fromList (List.map (\(Src.Import ( _, A.At region name ) _ _) -> ( name, region )) imports)

        toError : ( Name.Name, Import.Problem ) -> Import.Error
        toError ( name, problem ) =
            Import.Error
                { region = Utils.dictFind name regionDict
                , name = name
                , unimportedModules = unimportedModules
                , problem = problem
                }
    in
    NE.map toError problems



-- ====== LOAD CACHED INTERFACES ======


{-| Returns every interface in `same` and `cached`, reading the cached ones in
parallel, or `Nothing` when any cached interface cannot be read.
-}
loadInterfaces : FilePath -> Maybe String -> List Dep -> List CDep -> Task Never (Maybe (Dict ModuleName.Raw I.Interface))
loadInterfaces root maybeBuildDir same cached =
    Utils.listTraverse (fork maybeDepEncoder << loadInterface root maybeBuildDir) cached
        |> Task.andThen
            (\loading ->
                Utils.listTraverse (Utils.readMVar maybeDepDecoder) loading
                    |> Task.map
                        (\maybeLoaded ->
                            case Utils.sequenceListMaybe maybeLoaded of
                                Nothing ->
                                    Nothing

                                Just loaded ->
                                    Dict.union (Dict.fromList loaded) (Dict.fromList same) |> Just
                        )
            )


{-| Returns a cached import's interface, reading its `.eci` file the first time
and leaving the outcome in its MVar for later readers. Gives `Nothing` when the
file is missing or cannot be decoded.
-}
loadInterface : FilePath -> Maybe String -> CDep -> Task Never (Maybe Dep)
loadInterface root maybeBuildDir ( name, ciMvar ) =
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
                        File.readBinary I.interfaceDecoder (Stuff.eciWithBuildDir root maybeBuildDir name)
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


{-| Takes the dependency interfaces out of `dmvar` and drops it. The midpoint
check is its only reader, once per build.
-}
takeAndDropDependencies : MVar (Maybe Dependencies) -> Task Never (Maybe Dependencies)
takeAndDropDependencies dmvar =
    Utils.takeMVar maybeDependenciesDecoder dmvar
        |> Task.andThen (\deps -> Utils.dropMVar dmvar |> Task.map (\_ -> deps))


{-| Checks the crawled modules for an import cycle, then returns the dependency
interfaces, or `BP_CannotLoadDependencies` when they could not be loaded. The
interfaces' MVar is dropped either way.
-}
checkMidpoint : MVar (Maybe Dependencies) -> Dict ModuleName.Raw Status -> Task Never (Result Exit.BuildProjectProblem Dependencies)
checkMidpoint dmvar statuses =
    case checkForCycles statuses of
        Nothing ->
            takeAndDropDependencies dmvar
                |> Task.map
                    (\maybeForeigns ->
                        case maybeForeigns of
                            Nothing ->
                                Err Exit.BP_CannotLoadDependencies

                            Just fs ->
                                Ok fs
                    )

        Just (NE.Nonempty name names) ->
            takeAndDropDependencies dmvar
                |> Task.map (\_ -> Err (Exit.BP_Cycle name names))


{-| Does what `checkMidpoint` does, and also checks for two roots with one
module name (see `checkUniqueRoots`) before taking the interfaces.
-}
checkMidpointAndRoots : MVar (Maybe Dependencies) -> Dict ModuleName.Raw Status -> NE.Nonempty RootStatus -> Task Never (Result Exit.BuildProjectProblem Dependencies)
checkMidpointAndRoots dmvar statuses sroots =
    case checkForCycles statuses of
        Nothing ->
            case checkUniqueRoots statuses sroots of
                Nothing ->
                    takeAndDropDependencies dmvar
                        |> Task.map
                            (\maybeForeigns ->
                                case maybeForeigns of
                                    Nothing ->
                                        Err Exit.BP_CannotLoadDependencies

                                    Just fs ->
                                        Ok fs
                            )

                Just problem ->
                    takeAndDropDependencies dmvar
                        |> Task.map (\_ -> Err problem)

        Just (NE.Nonempty name names) ->
            takeAndDropDependencies dmvar
                |> Task.map (\_ -> Err (Exit.BP_Cycle name names))



-- ====== CHECK FOR CYCLES ======


{-| Returns the modules of one import cycle among the crawled modules, if there
is one. A module that imports itself is such a cycle.
-}
checkForCycles : Dict ModuleName.Raw Status -> Maybe (NE.Nonempty ModuleName.Raw)
checkForCycles modules =
    let
        graph : List Node
        graph =
            Dict.foldr addToGraph [] modules

        sccs : List (Graph.SCC ModuleName.Raw)
        sccs =
            Graph.stronglyConnComp graph
    in
    checkForCyclesHelp sccs


{-| Returns the members of the first cyclic component of `sccs`, if any.
-}
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


{-| A module in the import graph: its name, as both the node and its key, and
the modules it imports.
-}
type alias Node =
    ( ModuleName.Raw, ModuleName.Raw, List ModuleName.Raw )


{-| Adds a crawled module to the import graph. Only cached and changed modules
have edges.
-}
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


{-| Looks for an outside root whose module name another outside root, or a
module the crawl found in a source directory, also has, and returns
`BP_RootNameDuplicate` for it.

The outside roots are grouped by name with `Utils.dictFromListWith`, which
returns an empty dict for any input, so as written this always returns
`Nothing`.

-}
checkUniqueRoots : Dict ModuleName.Raw Status -> NE.Nonempty RootStatus -> Maybe Exit.BuildProjectProblem
checkUniqueRoots insides sroots =
    let
        outsidesDict : Dict ModuleName.Raw (OneOrMore.OneOrMore FilePath)
        outsidesDict =
            Utils.dictFromListWith OneOrMore.more (List.filterMap rootStatusToNamePathPair (NE.toList sroots))
    in
    case Utils.dictTraverseWithKeyResult checkOutside outsidesDict of
        Err problem ->
            Just problem

        Ok outsides ->
            case Utils.dictSequenceResult (Utils.dictIntersectionWithKey checkInside outsides insides) |> Result.map (\_ -> ()) of
                Ok () ->
                    Nothing

                Err problem ->
                    Just problem


{-| Returns the module name and path of an outside root that parsed, and
`Nothing` for any other root.
-}
rootStatusToNamePathPair : RootStatus -> Maybe ( ModuleName.Raw, OneOrMore.OneOrMore FilePath )
rootStatusToNamePathPair sroot =
    case sroot of
        SInside _ ->
            Nothing

        SOutsideOk (Details.Local localData) _ modul ->
            Just ( Src.getName modul, OneOrMore.one localData.path )

        SOutsideErr _ ->
            Nothing


{-| Returns the path of the outside root named `name`, or `BP_RootNameDuplicate`
with two of the paths when several outside roots have that name.
-}
checkOutside : ModuleName.Raw -> OneOrMore.OneOrMore FilePath -> Result Exit.BuildProjectProblem FilePath
checkOutside name paths =
    case OneOrMore.destruct NE.Nonempty paths of
        NE.Nonempty p [] ->
            Ok p

        NE.Nonempty p1 (p2 :: _) ->
            Err (Exit.BP_RootNameDuplicate name p1 p2)


{-| Fails with `BP_RootNameDuplicate` when the module `name`, which the outside
root at `p1` also defines, is one the crawl found in a source directory.
-}
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


{-| Compiles a module from `source` against `ifaces` and returns `RNew`,
`RSame` or `RProblem`, writing its artifacts as the build's `CacheMode`
allows. The typed pipeline is used when the build needs it. The time taken is
recorded under the build stage of `FEStats`.
-}
compile : Env -> DocsNeed -> Details.Local -> String -> Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never BResult
compile (Env envData) docsNeed (Details.Local localData) source ifaces modul =
    let
        pkg : Pkg.Name
        pkg =
            projectTypeToPkg envData.projectType

        modName : Name
        modName =
            Src.getName modul
    in
    FEStats.withModuleStage envData.stats FEStats.Build modName <|
        if envData.needsTypedOpt then
            compileWithTypedOpt envData.key envData.root envData.maybeBuildDir envData.cacheMode pkg envData.buildID docsNeed localData.path localData.time localData.deps localData.hasMain localData.lastChange source ifaces modul

        else
            compileWithoutTypedOpt envData.key envData.root envData.maybeBuildDir envData.cacheMode pkg envData.buildID docsNeed localData.path localData.time localData.deps localData.hasMain localData.lastChange source ifaces modul


{-| Everything needed to write a compiled module's artifacts and build its
result. `buildID` is the current build, `lastChange` the module's value before
this compilation, and `main` whether it defines `main`.
-}
type alias CompileResultContext =
    { key : Reporting.BKey
    , root : FilePath
    , maybeBuildDir : Maybe String
    , cacheMode : CacheMode
    , buildID : Details.BuildID
    , path : FilePath
    , time : File.Time
    , deps : List ModuleName.Raw
    , main : Bool
    , lastChange : Details.BuildID
    , name : ModuleName.Raw
    , iface : I.Interface
    , objects : Opt.LocalGraph
    , typedObjects : Maybe (TOpt.LocalGraph Name)
    , typeEnv : Maybe TypeEnv.ModuleTypeEnv
    , docs : Maybe Docs.Module
    }


{-| Compiles a module through the erased pipeline and handles the outcome (see
`handleCompileResult`).
-}
compileWithoutTypedOpt :
    Reporting.BKey
    -> FilePath
    -> Maybe String
    -> CacheMode
    -> Pkg.Name
    -> Details.BuildID
    -> DocsNeed
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> String
    -> Dict ModuleName.Raw I.Interface
    -> Src.Module
    -> Task Never BResult
compileWithoutTypedOpt key root maybeBuildDir cacheMode pkg buildID docsNeed path time deps main lastChange source ifaces modul =
    Compile.compile pkg ifaces modul
        |> Task.andThen (handleCompileResult key root maybeBuildDir cacheMode pkg buildID docsNeed path time deps main lastChange source modul Nothing)


{-| Turns the outcome of compiling a module into its result. Errors, and
documentation errors when documentation is needed, give `RProblem`; otherwise
the artifacts are written (see `writeObjectsAndFinalizeCompile`).
-}
handleCompileResult :
    Reporting.BKey
    -> FilePath
    -> Maybe String
    -> CacheMode
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
    -> Maybe (TOpt.LocalGraph Name)
    -> Result Error.Error Compile.Artifacts
    -> Task Never BResult
handleCompileResult key root maybeBuildDir cacheMode pkg buildID docsNeed path time deps main lastChange source modul maybeTypedObjects result =
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
                            , maybeBuildDir = maybeBuildDir
                            , cacheMode = cacheMode
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


{-| Writes a compiled module's artifacts, reports one module done, and returns
`RNew` when its interface differs from the `.eci` file on disk, or none could
be read, and `RSame` otherwise.

Nothing is written in `OneShot` mode, and otherwise the `.eci` file is written
only when the interface changed. It is written before the `.eco` or `.ecot`
file: a later build reuses the module once that file exists, so a crash in
between may leave an interface without its object but never an object without
its interface.

-}
writeObjectsAndFinalizeCompile : CompileResultContext -> Task Never BResult
writeObjectsAndFinalizeCompile ctx =
    let
        eciPath : FilePath
        eciPath =
            Stuff.eciWithBuildDir ctx.root ctx.maybeBuildDir ctx.name
    in
    File.readBinary I.interfaceDecoder eciPath
        |> Task.andThen
            (\maybeOld ->
                let
                    changed : Bool
                    changed =
                        maybeOld /= Just ctx.iface
                in
                (if changed && ctx.cacheMode == WriteCaches then
                    File.writeBinary I.interfaceEncoder eciPath ctx.iface

                 else
                    Task.succeed ()
                )
                    |> Task.andThen (\_ -> writeUntypedObjectsIfNeeded ctx)
                    |> Task.andThen (\_ -> writeTypedObjectsIfNeeded ctx)
                    |> Task.andThen (\_ -> Reporting.report ctx.key Reporting.BDone)
                    |> Task.map
                        (\_ ->
                            if changed then
                                buildRNew ctx

                            else
                                buildRSame ctx
                        )
            )


{-| Writes the module's `.eco` file on an untyped build that writes caches. A
typed build, one with typed objects, writes none.
-}
writeUntypedObjectsIfNeeded : CompileResultContext -> Task Never ()
writeUntypedObjectsIfNeeded ctx =
    case ( ctx.cacheMode, ctx.typedObjects ) of
        ( OneShot, _ ) ->
            Task.succeed ()

        ( WriteCaches, Just _ ) ->
            Task.succeed ()

        ( WriteCaches, Nothing ) ->
            File.writeBinary Opt.localGraphEncoder (Stuff.ecoWithBuildDir ctx.root ctx.maybeBuildDir ctx.name) ctx.objects


{-| Writes the module's `.ecot` file, holding its typed graph and type
environment, on a typed build that writes caches.
-}
writeTypedObjectsIfNeeded : CompileResultContext -> Task Never ()
writeTypedObjectsIfNeeded ctx =
    case ( ctx.cacheMode, ctx.typedObjects, ctx.typeEnv ) of
        ( WriteCaches, Just typedObjs, Just moduleEnv ) ->
            let
                artifact : TMod.TypedModuleArtifact
                artifact =
                    { typedGraph = typedObjs
                    , typeEnv = moduleEnv
                    }
            in
            File.writeBinary TMod.typedModuleArtifactEncoder (Stuff.ecotWithBuildDir ctx.root ctx.maybeBuildDir ctx.name) artifact

        _ ->
            Task.succeed ()


{-| Returns `RSame` with a details entry that keeps the module's `lastChange`
and records the current build as `lastCompile`.
-}
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


{-| Returns `RNew` with a details entry that records the current build as both
`lastChange` and `lastCompile`.
-}
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


{-| Compiles a module through the typed pipeline and handles the outcome (see
`handleTypedCompileResult`).
-}
compileWithTypedOpt :
    Reporting.BKey
    -> FilePath
    -> Maybe String
    -> CacheMode
    -> Pkg.Name
    -> Details.BuildID
    -> DocsNeed
    -> FilePath
    -> File.Time
    -> List ModuleName.Raw
    -> Bool
    -> Details.BuildID
    -> String
    -> Dict ModuleName.Raw I.Interface
    -> Src.Module
    -> Task Never BResult
compileWithTypedOpt key root maybeBuildDir cacheMode pkg buildID docsNeed path time deps main lastChange source ifaces modul =
    Compile.compileTyped pkg ifaces modul
        |> Task.andThen (handleTypedCompileResult key root maybeBuildDir cacheMode pkg buildID docsNeed path time deps main lastChange source modul)


{-| Does what `handleCompileResult` does for the outcome of a typed compile,
whose result also carries the typed graph and type environment.
-}
handleTypedCompileResult :
    Reporting.BKey
    -> FilePath
    -> Maybe String
    -> CacheMode
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
handleTypedCompileResult key root maybeBuildDir cacheMode pkg buildID docsNeed path time deps main lastChange source modul result =
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
                            , maybeBuildDir = maybeBuildDir
                            , cacheMode = cacheMode
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


{-| Returns the package the project's modules belong to: the package's own name,
the kernel package of a kernel application, or `Pkg.dummyName` for any other
application.
-}
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


{-| Writes `d.dat` with the entries of the modules compiled in `results`
replaced. Every other entry is kept as it was.
-}
writeDetails : FilePath -> Maybe String -> Details.Details -> Dict ModuleName.Raw BResult -> Task Never ()
writeDetails root maybeBuildDir (Details.Details detailsData) results =
    Details.Details { detailsData | locals = Dict.foldr addNewLocal detailsData.locals results } |> File.writeBinary Details.detailsEncoder (Stuff.detailsWithBuildDir root maybeBuildDir)


{-| Records a module's new details entry when it was compiled in this build.
-}
addNewLocal : ModuleName.Raw -> BResult -> Dict ModuleName.Raw Details.Local -> Dict ModuleName.Raw Details.Local
addNewLocal name result locals =
    case result of
        RNew local _ _ _ _ _ ->
            Dict.insert name local locals

        RSame local _ _ _ _ _ ->
            Dict.insert name local locals

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


{-| Produces the result of a build from exposed modules: `BP_MissingExposed`
for the named modules that cannot be found, else `BuildBadModules` with every
module that has errors, else what the docs goal asks for.
-}
finalizeExposed : FilePath -> DocsGoal docs -> NE.Nonempty ModuleName.Raw -> Dict ModuleName.Raw BResult -> Task Never (Result Exit.BuildProblem docs)
finalizeExposed root docsGoal exposed results =
    case List.foldr (addImportProblems results) [] (NE.toList exposed) of
        p :: ps ->
            Exit.BuildProjectProblem (Exit.BP_MissingExposed (NE.Nonempty p ps)) |> Err |> Task.succeed

        [] ->
            case Dict.foldr (\_ -> addErrors) [] results of
                [] ->
                    Task.map Ok (finalizeDocs docsGoal results)

                e :: es ->
                    Exit.BuildBadModules root e es |> Err |> Task.succeed


{-| Adds a module's errors to `errors` when its result is `RProblem`.
-}
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


{-| Adds the problem of the module `name` to `problems` when its result is
`RNotFound`.
-}
addImportProblems : Dict ModuleName.Raw BResult -> ModuleName.Raw -> List ( ModuleName.Raw, Import.Problem ) -> List ( ModuleName.Raw, Import.Problem )
addImportProblems results name problems =
    case Utils.dictFind name results of
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


{-| What a build from exposed modules does with documentation, which decides
what the build returns: the documentation itself (`keepDocs`), the outcome of
writing it to a file (`writeDocs`), or nothing, with no documentation
generated (`ignoreDocs`). These three are the only ways to make one.

Any goal but `ignoreDocs` makes the build generate documentation for the
modules it names, and a module whose documentation cannot be generated fails
the build.

-}
type DocsGoal docs
    = KeepDocs (Dict ModuleName.Raw BResult -> docs)
    | WriteDocs (Dict ModuleName.Raw BResult -> Task Never docs)
    | IgnoreDocs docs


{-| A docs goal that returns the documentation of every module that has some,
keyed by module name.
-}
keepDocs : DocsGoal (Dict ModuleName.Raw Docs.Module)
keepDocs =
    KeepDocs (\results -> Utils.dictMapMaybe toDocs results)


{-| Produces a docs goal that writes the documentation of every module that has
some to `path`, as JSON.
-}
writeDocs : FilePath -> DocsGoal ()
writeDocs path =
    WriteDocs (\results -> E.writeUgly path (Docs.encode (Utils.dictMapMaybe toDocs results)))


{-| A docs goal that generates no documentation.
-}
ignoreDocs : DocsGoal ()
ignoreDocs =
    IgnoreDocs ()


{-| Whether a module's documentation must be generated.
-}
type DocsNeed
    = DocsNeed Bool


{-| Returns whether a docs goal needs documentation.
-}
toDocsNeed : DocsGoal a -> DocsNeed
toDocsNeed goal =
    case goal of
        IgnoreDocs _ ->
            DocsNeed False

        WriteDocs _ ->
            DocsNeed True

        KeepDocs _ ->
            DocsNeed True


{-| Returns the module's documentation, or the error that prevents it, when it
is needed, and `Nothing` when it is not.
-}
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


{-| Produces the docs goal's result from the module results.
-}
finalizeDocs : DocsGoal docs -> Dict ModuleName.Raw BResult -> Task Never docs
finalizeDocs goal results =
    case goal of
        KeepDocs f ->
            f results |> Task.succeed

        WriteDocs f ->
            f results

        IgnoreDocs val ->
            Task.succeed val


{-| Returns the documentation in a module's result, if it has any.
-}
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



--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
------ AFTER THIS, EVERYTHING IS ABOUT HANDLING MODULES GIVEN BY FILEPATH ------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- ====== FIND ROOT ======


{-| Where a root given by path lies. `LInside` is a file in a source directory,
named by its module name. `LOutside` is a file outside every source directory,
by its path as given.
-}
type RootLocation
    = LInside ModuleName.Raw
    | LOutside FilePath


{-| Locates every root path in parallel. Fails with the problem of an invalid
path, or when two paths lead to the same file (see `checkRoots`).
-}
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


{-| Returns each root's location after checking that no two paths lead to the
same file (`BP_MainPathDuplicate`).

The paths are grouped with `Utils.dictFromListWith`, which returns an empty
dict for any input, so as written this check never fails.

-}
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
    List.map toOneOrMore (NE.toList infos) |> Utils.dictFromListWith OneOrMore.more |> Utils.dictTraverseResult (OneOrMore.destruct fromOneOrMore) |> Result.map (\_ -> NE.map (\(RootInfo _ _ location) -> location) infos)



-- ====== ROOT INFO ======


{-| A root path: canonical and absolute, as it was given, and where it lies.
-}
type RootInfo
    = RootInfo FilePath FilePath RootLocation


{-| Locates one root path, failing with `BP_PathUnknown` when there is no file
at it.
-}
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


{-| Decides where a root lies from `absolutePath`, its canonical form.

A path not ending in `.elm` fails with `BP_WithBadExtension`. A file outside
every source directory is an outside root. A file in exactly one is an inside
root named by its path below that directory, unless a part of that path is not
a valid module name part (`BP_RootNameInvalid`) or another source directory
also has the module (`BP_RootNameDuplicate`). A file in two source directories
fails with `BP_WithAmbiguousSrcDir`.

-}
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


{-| Tells whether `srcDir` has the module file whose path parts are `names`.
-}
isInsideSrcDirByName : List String -> String -> AbsoluteSrcDir -> Task Never Bool
isInsideSrcDirByName names extension srcDir =
    File.exists (addRelative srcDir (Utils.fpJoinPath names ++ extension))


{-| Returns, when the path `segments` lies under `srcDir`, the directory and
the segments below it: `Ok` when each is a valid module name part, `Err`
otherwise.
-}
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


{-| Tells whether a path segment can be part of a module name: an ASCII
upper-case letter followed by ASCII letters, digits or underscores.
-}
isGoodName : String -> Bool
isGoodName name =
    case String.toList name of
        [] ->
            False

        char :: chars ->
            Char.isUpper char && List.all (\c -> Char.isAlphaNum c || c == '_') chars


{-| Returns `paths` with `roots` removed from its front, or `Nothing` when
`roots` is not a prefix of it. Segments are compared as text, so both must come
from canonicalized paths.
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


{-| What the crawl found out about one root.

`SInside` names an inside root, whose status is in the status dict like any
other module's.

`SOutsideOk` is an outside root that parsed. It carries a details entry whose
`lastChange` and `lastCompile` are the current build, the source text, and the
parsed module.

`SOutsideErr` is an outside root that did not parse, reported under the module
name `???`.

-}
type RootStatus
    = SInside ModuleName.Raw
    | SOutsideOk Details.Local String Src.Module
    | SOutsideErr Error.Module


{-| Crawls one root. An inside root is put into the status dict, replacing any
entry already there for its name, and crawled like a module. An outside root
is read and parsed, and its imports are crawled.
-}
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
                                    Utils.putMVar statusDictEncoder mvar (Dict.insert name statusMVar statusDict)
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


{-| The outcome of checking one root.

`RInside` names an inside root, whose result is among the module results.

`ROutsideOk` is an outside root that compiled, with its interface, its erased
graph, and its typed graph and type environment (`Nothing` on an untyped
build).

`ROutsideErr` is an outside root with errors.

`ROutsideBlocked` is an outside root that was not compiled because an import
failed or a cached interface could not be read.

-}
type RootResult
    = RInside ModuleName.Raw
    | ROutsideOk ModuleName.Raw I.Interface Opt.LocalGraph (Maybe (TOpt.LocalGraph Name)) (Maybe TypeEnv.ModuleTypeEnv)
    | ROutsideErr Error.Module
    | ROutsideBlocked


{-| Checks one root. An outside root is compiled whenever its imports allow,
even if nothing changed, without documentation.
-}
checkRoot : Env -> ResultDict -> RootStatus -> Task Never RootResult
checkRoot ((Env envData) as env) results rootStatus =
    case rootStatus of
        SInside name ->
            Task.succeed (RInside name)

        SOutsideErr err ->
            Task.succeed (ROutsideErr err)

        SOutsideOk ((Details.Local localData) as local) source ((Src.Module srcData) as modul) ->
            checkDeps envData.root envData.maybeBuildDir results localData.deps localData.lastCompile
                |> Task.andThen
                    (\depsStatus ->
                        case depsStatus of
                            DepsChange ifaces ->
                                compileOutside env local source ifaces modul

                            DepsSame same cached ->
                                loadInterfaces envData.root envData.maybeBuildDir same cached
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


{-| Compiles an outside root against `ifaces`, and reports one module done when
it succeeds. Nothing is written to disk.
-}
compileOutside : Env -> Details.Local -> String -> Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never RootResult
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


{-| A root of a build from paths, in the artifacts.

`Inside` is an inside root: a project module, named by its path in a source
directory.

`Outside` is an outside root: a file outside every source directory, compiled
in this build and never cached. It carries the module's interface, its erased
graph, and, on a typed build, its typed graph and type environment.

Each root's module is also among the artifacts' `modules`.

-}
type Root
    = Inside ModuleName.Raw
    | Outside ModuleName.Raw I.Interface Opt.LocalGraph (Maybe (TOpt.LocalGraph Name)) (Maybe TypeEnv.ModuleTypeEnv)


{-| Returns the artifacts of a build from paths, or the errors of every module
and root that has them.
-}
toArtifacts : Env -> Dependencies -> Dict ModuleName.Raw BResult -> NE.Nonempty RootResult -> Result Exit.BuildProblem Artifacts
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
                    , modules = Dict.foldr addInside (NE.foldr addOutside [] rootResults) results
                    }


{-| Returns the roots, in the order given, when no module and no root has
errors, and the errors otherwise. A blocked outside root is left out of the
roots. The compiler crashes, with a message blaming a corrupted `eco-stuff/`
directory, only when the first root is blocked and nothing has errors.
-}
gatherProblemsOrMains : Dict ModuleName.Raw BResult -> NE.Nonempty RootResult -> Result (NE.Nonempty Error.Module) (NE.Nonempty Root)
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
            Dict.foldr (\_ -> addErrors) [] results
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


{-| Adds a project module to `modules`: `Fresh` when it was compiled in this
build, `Cached` when it was reused. Foreign and kernel modules are skipped.

A module that was not found, has errors or is blocked crashes the compiler,
which expects such a result to have failed the build already. A module blocked
only by a cached interface that could not be read gets here with no module
error reported.

-}
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


{-| Returns the crash message for a module whose failure should already have
been reported.
-}
badInside : ModuleName.Raw -> String
badInside name =
    "Error from `" ++ name ++ "` should have been reported already."


{-| Adds an outside root that compiled to `modules`, as `Fresh`.
-}
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


{-| Encodes the module result MVars, for the MVar the checks read them from.
-}
dictRawMVarBResultEncoder : Dict ModuleName.Raw (MVar BResult) -> Bytes.Encode.Encoder
dictRawMVarBResultEncoder =
    BE.stdDict ModuleName.rawEncoder Utils.mVarEncoder


{-| Encodes a module result, tagged 0 to 8 in constructor order.
-}
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


{-| A decoder for what `bResultEncoder` writes.
-}
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


{-| Encodes the status dict, for its MVar.
-}
statusDictEncoder : StatusDict -> Bytes.Encode.Encoder
statusDictEncoder =
    BE.stdDict ModuleName.rawEncoder Utils.mVarEncoder


{-| A decoder for what `statusDictEncoder` writes.
-}
statusDictDecoder : Bytes.Decode.Decoder StatusDict
statusDictDecoder =
    BD.stdDict ModuleName.rawDecoder Utils.mVarDecoder


{-| Encodes a crawl status, tagged 0 to 5 in constructor order.
-}
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


{-| A decoder for what `statusEncoder` writes.
-}
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


{-| Encodes a root's crawl status, tagged 0 to 2 in constructor order.
-}
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


{-| A decoder for what `rootStatusEncoder` writes.
-}
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


{-| Encodes the module result MVars, for the MVar the checks read them from.
-}
resultDictEncoder : ResultDict -> Bytes.Encode.Encoder
resultDictEncoder =
    BE.stdDict ModuleName.rawEncoder Utils.mVarEncoder


{-| A decoder for what `resultDictEncoder` writes.
-}
resultDictDecoder : Bytes.Decode.Decoder ResultDict
resultDictDecoder =
    BD.stdDict ModuleName.rawDecoder Utils.mVarDecoder


{-| Encodes a root's result, tagged 0 to 3 in constructor order.
-}
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


{-| A decoder for what `rootResultEncoder` writes.
-}
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


{-| Encodes a loaded import interface, or its absence.
-}
maybeDepEncoder : Maybe Dep -> Bytes.Encode.Encoder
maybeDepEncoder =
    BE.maybe depEncoder


{-| A decoder for what `maybeDepEncoder` writes.
-}
maybeDepDecoder : Bytes.Decode.Decoder (Maybe Dep)
maybeDepDecoder =
    BD.maybe depDecoder


{-| Encodes an import's name and interface as a pair.
-}
depEncoder : Dep -> Bytes.Encode.Encoder
depEncoder =
    BE.jsonPair ModuleName.rawEncoder I.interfaceEncoder


{-| A decoder for what `depEncoder` writes.
-}
depDecoder : Bytes.Decode.Decoder Dep
depDecoder =
    BD.jsonPair ModuleName.rawDecoder I.interfaceDecoder


{-| A decoder for the dependency interfaces, or their absence, as
`Builder.Elm.Details.loadInterfaces` puts them into their MVar.
-}
maybeDependenciesDecoder : Bytes.Decode.Decoder (Maybe Dependencies)
maybeDependenciesDecoder =
    BD.maybe (BD.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder I.dependencyInterfaceDecoder)


{-| Encodes the outcome of locating one root.
-}
resultBuildProjectProblemRootInfoEncoder : Result Exit.BuildProjectProblem RootInfo -> Bytes.Encode.Encoder
resultBuildProjectProblemRootInfoEncoder =
    BE.result Exit.buildProjectProblemEncoder rootInfoEncoder


{-| A decoder for what `resultBuildProjectProblemRootInfoEncoder` writes.
-}
resultBuildProjectProblemRootInfoDecoder : Bytes.Decode.Decoder (Result Exit.BuildProjectProblem RootInfo)
resultBuildProjectProblemRootInfoDecoder =
    BD.result Exit.buildProjectProblemDecoder rootInfoDecoder


{-| Encodes a `CachedInterface`, tagged 0 to 2 in constructor order.
-}
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


{-| A decoder for a `CachedInterface` as it is stored in its MVar: tag 0 is
`Unneeded`, 1 is `Loaded` followed by the interface, and 2 is `Corrupted`.
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


{-| Encodes whether documentation is needed.
-}
docsNeedEncoder : DocsNeed -> Bytes.Encode.Encoder
docsNeedEncoder (DocsNeed isNeeded) =
    BE.bool isNeeded


{-| A decoder for what `docsNeedEncoder` writes.
-}
docsNeedDecoder : Bytes.Decode.Decoder DocsNeed
docsNeedDecoder =
    Bytes.Decode.map DocsNeed BD.bool


{-| Encodes a root's absolute path, given path and location.
-}
rootInfoEncoder : RootInfo -> Bytes.Encode.Encoder
rootInfoEncoder (RootInfo absolute relative location) =
    Bytes.Encode.sequence
        [ BE.string absolute
        , BE.string relative
        , rootLocationEncoder location
        ]


{-| A decoder for what `rootInfoEncoder` writes.
-}
rootInfoDecoder : Bytes.Decode.Decoder RootInfo
rootInfoDecoder =
    Bytes.Decode.map3 RootInfo
        BD.string
        BD.string
        rootLocationDecoder


{-| Encodes a root's location, tagged 0 for inside and 1 for outside.
-}
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


{-| A decoder for what `rootLocationEncoder` writes.
-}
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
