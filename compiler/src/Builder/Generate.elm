module Builder.Generate exposing
    ( javascriptBackend
    , dev, debug
    , prod
    , MonoBuildResult, writeMonoMlirStreaming, writeMonoMlirStreamingBytecode
    )

{-| Turns the artifacts of a finished build into output: JavaScript through a
`CodeGen` backend, or MLIR through monomorphization and the middle end.

A build (`Builder.Build`) leaves each of its own modules either _fresh_,
compiled in this build with its graphs in memory, or _cached_, unchanged since
an earlier build, so that what code generation needs must be read back from
the files that build wrote. Both paths here start the same way: they gather
every module's graph, from memory or from disk, and merge it with the
dependencies' graph into one global graph. A module's file that cannot be read
fails generation with `GenerateCannotLoadArtifacts`.

The JavaScript path (`dev`, `debug`, `prod`) works on the untyped optimized
graph. It reads each cached module's `.eco` file on a thread of its own, finds
the `main` of each root, picks a `Mode` and hands everything to the backend.

The MLIR path (`writeMonoMlirStreaming`, `writeMonoMlirStreamingBytecode`)
works on the typed graph. It runs the middle end that `Compiler.Pipeline.Steps`
describes and adds what that module leaves to its caller: the validators
between the steps, phase timing under `Builder.Eco.FEStats`, and the census
lines. A _census_ is a report of what a pass did, or would do, written to
stderr when a report flag is on. Most of this file's length is the rendering
of those lines.

The MLIR path is shaped by peak memory. Cached modules' typed data is read and
merged one `.ecot` file at a time, so only one module's data is alive beside
the merged graph. Each phase is a separate top-level function chained with
`Task.andThen` rather than a closure, so that a phase's input graph is not
captured by anything that outlives it and can be collected once the next phase
has its output.


# Code Generation Backends

@docs javascriptBackend


# Development Builds

@docs dev, debug


# Production Builds

@docs prod


# Native MLIR Streaming

@docs MonoBuildResult, writeMonoMlirStreaming, writeMonoMlirStreamingBytecode

-}

import Array
import Builder.Build as Build
import Builder.Eco.FEStats as FEStats
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.GraphAssembly as GA
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Optimized as Opt
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedModuleArtifact as TMod
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as N exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Eco.Config as Config
import Compiler.Elm.Compiler.Type.Extract as Extract
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.CodeGen.JavaScript as JavaScript
import Compiler.Generate.MLIR.Backend as MLIR
import Compiler.Generate.MLIR.Names as MLIRNames
import Compiler.Generate.Mode as Mode
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.GlobalOpt.Borrow as Borrow
import Compiler.GlobalOpt.CafCensus as CafCensus
import Compiler.GlobalOpt.CafDedupe as CafDedupe
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.GlobalOpt.CseCensus as CseCensus
import Compiler.GlobalOpt.InlineSimplify as InlineSimplify
import Compiler.GlobalOpt.ListCombinators as ListCombinators
import Compiler.GlobalOpt.MapTemplate as MapTemplate
import Compiler.GlobalOpt.MonoCse as MonoCse
import Compiler.GlobalOpt.GenCallCensus as GenCallCensus
import Compiler.GlobalOpt.MonoGlobalOptimize as MonoGlobalOptimize
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.GlobalOpt.PreMono.AliasForward as AliasForward
import Compiler.GlobalOpt.PreMono.EtaExpand as EtaExpand
import Compiler.GlobalOpt.PreMono.Fresh as Fresh
import Compiler.GlobalOpt.PreMono.LiftClosedArgs as LiftClosedArgs
import Compiler.MonoSolver.Diff as MonoDiff
import Compiler.MonoSolver.Monomorphize as MonoSolver
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.ValidateLayout as ValidateLayout
import Compiler.Monomorphize.ValidateLimits as ValidateLimits
import Compiler.Nitpick.Debug as Nitpick
import Compiler.Pipeline.Steps as Steps
import Data.Map
import Dict exposing (Dict)
import System.IO exposing (FilePath, MVar)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== BACKENDS ======


{-| The JavaScript code generation backend (`Compiler.Generate.CodeGen.JavaScript`).
-}
javascriptBackend : CodeGen.CodeGen
javascriptBackend =
    JavaScript.backend



-- ====== GENERATORS ======


{-| Generates output in development mode with the types of every module attached,
as `Mode.Dev (Just types)`.

The types come from the dependency interfaces, the fresh modules' interfaces,
and each cached module's interface, which is read from its `.eci` file when the
build did not load it. Source files are read for source maps only when
`withSourceMaps` is set.

-}
debug : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
debug backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen (loadTypesAndFinalize root maybeBuildDir artifacts.deps artifacts.modules)
        |> Task.andThen (generateDebugOutput backend withSourceMaps leadingLines root artifacts.pkg artifacts.roots)


{-| Loads the types of every module, then waits for the object graphs `loading` is reading, and returns both.
-}
loadTypesAndFinalize : FilePath -> Maybe String -> Data.Map.Dict String ModuleName.Canonical I.DependencyInterface -> List Build.Module -> LoadingObjects -> Task Exit.Generate ( Objects, Extract.Types )
loadTypesAndFinalize root maybeBuildDir ifaces modules loading =
    loadTypes root maybeBuildDir ifaces modules
        |> Task.andThen (finalizeObjectsWithTypes loading)


{-| Waits for the object graphs `loading` is reading and pairs them with `types`.
-}
finalizeObjectsWithTypes : LoadingObjects -> Extract.Types -> Task Exit.Generate ( Objects, Extract.Types )
finalizeObjectsWithTypes loading types =
    finalizeObjects loading
        |> Task.map (\objects -> ( objects, types ))


{-| Generates debug-mode output from the loaded objects and types.
-}
generateDebugOutput : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Pkg.Name -> NE.Nonempty Build.Root -> ( Objects, Extract.Types ) -> Task Exit.Generate CodeGen.Output
generateDebugOutput backend withSourceMaps leadingLines root pkg roots ( objects, types ) =
    let
        mode =
            Mode.Dev (Just types)

        graph =
            objectsToGlobalGraph objects

        mains =
            gatherMains pkg objects roots
    in
    prepareSourceMaps withSourceMaps root
        |> Task.map (generateWithBackend backend leadingLines mode graph mains)


{-| Runs `backend` on the merged graph and the roots' `main` values.
-}
generateWithBackend : CodeGen.CodeGen -> Int -> Mode.Mode -> Opt.GlobalGraph -> Data.Map.Dict String ModuleName.Canonical Opt.Main -> CodeGen.SourceMaps -> CodeGen.Output
generateWithBackend backend leadingLines mode graph mains sourceMaps =
    backend.generate
        { sourceMaps = sourceMaps
        , leadingLines = leadingLines
        , mode = mode
        , graph = graph
        , mains = mains
        }


{-| Generates output in development mode, as `Mode.Dev Nothing`. Source files are
read for source maps only when `withSourceMaps` is set.
-}
dev : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
dev backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen finalizeObjects
        |> Task.andThen (generateDevOutput backend withSourceMaps leadingLines root artifacts.pkg artifacts.roots)


{-| Generates development-mode output from the loaded objects.
-}
generateDevOutput : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Pkg.Name -> NE.Nonempty Build.Root -> Objects -> Task Exit.Generate CodeGen.Output
generateDevOutput backend withSourceMaps leadingLines root pkg roots objects =
    let
        mode =
            Mode.Dev Nothing

        graph =
            objectsToGlobalGraph objects

        mains =
            gatherMains pkg objects roots
    in
    prepareSourceMaps withSourceMaps root
        |> Task.map (generateWithBackend backend leadingLines mode graph mains)


{-| Generates output in production mode, with record field names shortened
(`Mode.Prod`).

Fails with `GenerateCannotOptimizeDebugValues`, naming the modules, when any of
the build's own modules uses `Debug`. Dependency packages are not checked.

-}
prod : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
prod backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen finalizeObjects
        |> Task.andThen (checkDebugAndGenerate backend withSourceMaps leadingLines root artifacts.pkg artifacts.roots)


{-| Fails if any of the build's own modules uses `Debug`, and otherwise generates production-mode output.
-}
checkDebugAndGenerate : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Pkg.Name -> NE.Nonempty Build.Root -> Objects -> Task Exit.Generate CodeGen.Output
checkDebugAndGenerate backend withSourceMaps leadingLines root pkg roots objects =
    checkForDebugUses objects
        |> Task.andThen (\_ -> generateProdOutput backend withSourceMaps leadingLines root pkg roots objects)


{-| Generates production-mode output from the loaded objects, with field names shortened across the whole merged graph.
-}
generateProdOutput : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Pkg.Name -> NE.Nonempty Build.Root -> Objects -> Task Exit.Generate CodeGen.Output
generateProdOutput backend withSourceMaps leadingLines root pkg roots objects =
    let
        graph =
            objectsToGlobalGraph objects

        mode =
            Mode.Prod (Mode.shortenFieldNames graph)

        mains =
            gatherMains pkg objects roots
    in
    prepareSourceMaps withSourceMaps root
        |> Task.map (generateWithBackend backend leadingLines mode graph mains)


{-| Reads the source of every module of the project at `root` when `withSourceMaps` is set, and returns `NoSourceMaps` otherwise.
-}
prepareSourceMaps : Bool -> FilePath -> Task Exit.Generate CodeGen.SourceMaps
prepareSourceMaps withSourceMaps root =
    if withSourceMaps then
        Outline.getAllModulePaths root
            |> Task.andThen (Utils.mapTraverse ModuleName.toComparableCanonical File.readUtf8)
            |> Task.map CodeGen.SourceMaps
            |> Task.io

    else
        Task.succeed CodeGen.NoSourceMaps



-- ====== CHECK FOR DEBUG ======


{-| Fails with `GenerateCannotOptimizeDebugValues`, naming every one of the
build's own modules that uses `Debug` (`Compiler.Nitpick.Debug.hasDebugUses`),
and succeeds when none does.
-}
checkForDebugUses : Objects -> Task Exit.Generate ()
checkForDebugUses (Objects _ locals) =
    case Dict.keys (Dict.filter (\_ -> Nitpick.hasDebugUses) locals) of
        [] ->
            Task.succeed ()

        m :: ms ->
            Task.throw (Exit.GenerateCannotOptimizeDebugValues m ms)



-- ====== GATHER MAINS ======


{-| Returns the `main` of every root that has one, keyed by its canonical module name.
-}
gatherMains : Pkg.Name -> Objects -> NE.Nonempty Build.Root -> Data.Map.Dict String ModuleName.Canonical Opt.Main
gatherMains pkg (Objects _ locals) roots =
    Data.Map.fromList ModuleName.toComparableCanonical (List.filterMap (lookupMain pkg locals) (NE.toList roots))


{-| Returns the canonical name and `main` of `root`'s module, or `Nothing` when it
has no `main` or, for an inside root, is not among `locals`.
-}
lookupMain : Pkg.Name -> Dict ModuleName.Raw Opt.LocalGraph -> Build.Root -> Maybe ( ModuleName.Canonical, Opt.Main )
lookupMain pkg locals root =
    let
        toPair : N.Name -> Opt.LocalGraph -> Maybe ( ModuleName.Canonical, Opt.Main )
        toPair name (Opt.LocalGraph maybeMain _ _) =
            Maybe.map (Tuple.pair (ModuleName.Canonical pkg name)) maybeMain
    in
    case root of
        Build.Inside name ->
            Dict.get name locals |> Maybe.andThen (toPair name)

        Build.Outside name _ g _ _ ->
            toPair name g



-- ====== LOADING OBJECTS ======


{-| Object graphs that are still being read: an MVar for the dependencies' graph
and one for each cached module's local graph, each filled when its read ends,
beside the fresh modules' graphs already in memory. `Nothing` in an MVar means
the graph could not be read.
-}
type LoadingObjects
    = LoadingObjects (MVar (Maybe Opt.GlobalGraph)) (Dict ModuleName.Raw (MVar (Maybe Opt.LocalGraph))) (Dict ModuleName.Raw Opt.LocalGraph)


{-| Starts reading the dependencies' object graph and every cached module's `.eco`
file, and returns at once with the graphs still being read.
-}
loadObjects : FilePath -> Maybe String -> Details.Details -> List Build.Module -> Task Exit.Generate LoadingObjects
loadObjects root maybeBuildDir details modules =
    Task.io
        (Details.loadObjects root maybeBuildDir details
            |> Task.andThen (loadModuleObjects root maybeBuildDir modules)
        )


{-| Returns the loading state for `modules`: the fresh modules' graphs as they are,
and for each cached module an MVar that a forked read of its `.eco` file fills.
`mvar` is the dependencies' graph.
-}
loadModuleObjects : FilePath -> Maybe String -> List Build.Module -> MVar (Maybe Opt.GlobalGraph) -> Task Never LoadingObjects
loadModuleObjects root maybeBuildDir modules mvar =
    let
        partitionModules : List Build.Module -> ( List ( ModuleName.Raw, Opt.LocalGraph ), List Build.Module ) -> ( List ( ModuleName.Raw, Opt.LocalGraph ), List Build.Module )
        partitionModules mods ( freshAcc, cachedAcc ) =
            case mods of
                [] ->
                    ( freshAcc, cachedAcc )

                modul :: rest ->
                    case modul of
                        Build.Fresh name _ graph _ _ ->
                            partitionModules rest ( ( name, graph ) :: freshAcc, cachedAcc )

                        Build.Cached _ _ _ ->
                            partitionModules rest ( freshAcc, modul :: cachedAcc )

        ( freshPairs, needLoading ) =
            partitionModules modules ( [], [] )

        freshDict =
            Dict.fromList freshPairs
    in
    Utils.listTraverse (loadCachedObject root maybeBuildDir) needLoading
        |> Task.map (\mvars -> LoadingObjects mvar (Dict.fromList mvars) freshDict)


{-| Returns a cached module's name with an MVar that a forked thread fills from its
`.eco` file. Given a fresh module, which the caller has already set aside, it
returns a filled MVar holding an empty graph.
-}
loadCachedObject : FilePath -> Maybe String -> Build.Module -> Task Never ( ModuleName.Raw, MVar (Maybe Opt.LocalGraph) )
loadCachedObject root maybeBuildDir modul =
    case modul of
        Build.Cached name _ _ ->
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadCachedObject root maybeBuildDir name)

        Build.Fresh name _ _ _ _ ->
            Utils.newMVar (Utils.maybeEncoder Opt.localGraphEncoder) (Just (Opt.LocalGraph Nothing Data.Map.empty Dict.empty))
                |> Task.map (\mv -> ( name, mv ))


{-| Forks a thread that fills `mvar` from module `name`'s `.eco` file, and returns the pair at once.
-}
forkLoadCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Opt.LocalGraph) -> Task Never ( ModuleName.Raw, MVar (Maybe Opt.LocalGraph) )
forkLoadCachedObject root maybeBuildDir name mvar =
    Utils.forkIO (readAndStoreCachedObject root maybeBuildDir name mvar)
        |> Task.map (\_ -> ( name, mvar ))


{-| Reads module `name`'s `.eco` file into `mvar`, storing `Nothing` when it is missing or cannot be decoded.
-}
readAndStoreCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Opt.LocalGraph) -> Task Never ()
readAndStoreCachedObject root maybeBuildDir name mvar =
    File.readBinary Opt.localGraphDecoder (Stuff.ecoWithBuildDir root maybeBuildDir name)
        |> Task.andThen (Utils.putMVar (Utils.maybeEncoder Opt.localGraphEncoder) mvar)



-- ====== FINALIZE OBJECTS ======


{-| Every object graph JavaScript generation needs: the dependencies' global
graph, and the local graph of each of the build's own modules, by name.
-}
type Objects
    = Objects Opt.GlobalGraph (Dict ModuleName.Raw Opt.LocalGraph)


{-| Waits for every graph `loadObjects` started reading, failing with
`GenerateCannotLoadArtifacts` when any of them could not be read.
-}
finalizeObjects : LoadingObjects -> Task Exit.Generate Objects
finalizeObjects (LoadingObjects mvar mvars freshModules) =
    Task.eio identity
        (Utils.takeMVar (BD.maybe Opt.globalGraphDecoder) mvar
            |> Task.andThen (collectLocalObjects mvars freshModules)
        )


{-| Waits for each cached module's graph and combines them with `freshModules` and the dependencies' graph.
-}
collectLocalObjects : Dict ModuleName.Raw (MVar (Maybe Opt.LocalGraph)) -> Dict ModuleName.Raw Opt.LocalGraph -> Maybe Opt.GlobalGraph -> Task Never (Result Exit.Generate Objects)
collectLocalObjects mvars freshModules globalResult =
    Utils.dictTraverse (Utils.takeMVar (BD.maybe Opt.localGraphDecoder)) mvars
        |> Task.map (combineGlobalAndLocalObjects globalResult freshModules)


{-| Returns the objects when the dependencies' graph and every cached module's
graph were read, and `GenerateCannotLoadArtifacts` otherwise.
-}
combineGlobalAndLocalObjects : Maybe Opt.GlobalGraph -> Dict ModuleName.Raw Opt.LocalGraph -> Dict ModuleName.Raw (Maybe Opt.LocalGraph) -> Result Exit.Generate Objects
combineGlobalAndLocalObjects globalResult freshModules cachedResults =
    case ( globalResult, Utils.dictSequenceMaybe cachedResults ) of
        ( Just globals, Just cachedLocals ) ->
            Ok (Objects globals (Dict.union cachedLocals freshModules))

        _ ->
            Err Exit.GenerateCannotLoadArtifacts


{-| Merges every local graph into the dependencies' graph. Where a module and the
dependencies' graph hold a node for the same global, the module's node is kept.
-}
objectsToGlobalGraph : Objects -> Opt.GlobalGraph
objectsToGlobalGraph (Objects globals locals) =
    Dict.foldr (\_ -> GA.addOptLocalGraph) globals locals



-- ====== LOAD TYPES ======


{-| Returns the types of every module: those of the dependency interfaces
`ifaces`, of the fresh modules' interfaces, and of each cached module's
interface. Fails with `GenerateCannotLoadArtifacts` when a cached module's
interface is corrupt or its `.eci` file cannot be read.
-}
loadTypes : FilePath -> Maybe String -> Data.Map.Dict String ModuleName.Canonical I.DependencyInterface -> List Build.Module -> Task Exit.Generate Extract.Types
loadTypes root maybeBuildDir ifaces modules =
    let
        partitionTypes : List Build.Module -> ( List Extract.Types, List Build.Module ) -> ( List Extract.Types, List Build.Module )
        partitionTypes mods ( freshAcc, cachedAcc ) =
            case mods of
                [] ->
                    ( freshAcc, cachedAcc )

                modul :: rest ->
                    case modul of
                        Build.Fresh name iface _ _ _ ->
                            partitionTypes rest ( Extract.fromInterface name iface :: freshAcc, cachedAcc )

                        Build.Cached _ _ _ ->
                            partitionTypes rest ( freshAcc, modul :: cachedAcc )

        ( freshTypes, needLoading ) =
            partitionTypes modules ( [], [] )
    in
    Task.eio identity
        (Utils.listTraverse (loadTypesFromCached root maybeBuildDir) needLoading
            |> Task.andThen (collectAndMergeTypes ifaces freshTypes)
        )


{-| Waits for each cached module's types and merges them with `freshTypes` and the types of the dependency interfaces `ifaces`.
-}
collectAndMergeTypes : Data.Map.Dict String ModuleName.Canonical I.DependencyInterface -> List Extract.Types -> List (MVar (Maybe Extract.Types)) -> Task Never (Result Exit.Generate Extract.Types)
collectAndMergeTypes ifaces freshTypes mvars =
    let
        foreigns : Extract.Types
        foreigns =
            Extract.mergeMany (Data.Map.values (Data.Map.map Extract.fromDependencyInterface ifaces))
    in
    Utils.listTraverse (Utils.takeMVar (BD.maybe Extract.typesDecoder)) mvars
        |> Task.map (mergeLoadedTypes foreigns freshTypes)


{-| Merges `foreigns`, `freshTypes` and the cached modules' types, or fails with
`GenerateCannotLoadArtifacts` when any cached module's types are missing.
-}
mergeLoadedTypes : Extract.Types -> List Extract.Types -> List (Maybe Extract.Types) -> Result Exit.Generate Extract.Types
mergeLoadedTypes foreigns freshTypes cachedResults =
    case Utils.sequenceListMaybe cachedResults of
        Just ts ->
            Ok (Extract.merge foreigns (Extract.mergeMany (freshTypes ++ ts)))

        Nothing ->
            Err Exit.GenerateCannotLoadArtifacts


{-| Returns an MVar that holds, or will hold, a cached module's types, once the
build has filled the module's cached-interface MVar. Given a fresh module, which
the caller has already set aside, it returns the types of its interface.
-}
loadTypesFromCached : FilePath -> Maybe String -> Build.Module -> Task Never (MVar (Maybe Extract.Types))
loadTypesFromCached root maybeBuildDir modul =
    case modul of
        Build.Cached name _ ciMVar ->
            Utils.readMVar Build.cachedInterfaceDecoder ciMVar
                |> Task.andThen (handleCachedInterfaceForTypes root maybeBuildDir name)

        Build.Fresh name iface _ _ _ ->
            Utils.newMVar (Utils.maybeEncoder Extract.typesEncoder) (Just (Extract.fromInterface name iface))


{-| Returns an MVar for module `name`'s types, according to what the build did with
its interface. `Unneeded` forks a read of its `.eci` file, `Loaded` uses the
interface in hand, and `Corrupted` gives `Nothing`, which fails generation
later.
-}
handleCachedInterfaceForTypes : FilePath -> Maybe String -> ModuleName.Raw -> Build.CachedInterface -> Task Never (MVar (Maybe Extract.Types))
handleCachedInterfaceForTypes root maybeBuildDir name cachedInterface =
    case cachedInterface of
        Build.Unneeded ->
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadInterfaceTypes root maybeBuildDir name)

        Build.Loaded iface ->
            Utils.newMVar (Utils.maybeEncoder Extract.typesEncoder) (Just (Extract.fromInterface name iface))

        Build.Corrupted ->
            Utils.newMVar (Utils.maybeEncoder Extract.typesEncoder) Nothing


{-| Forks a thread that fills `mvar` from module `name`'s `.eci` file, and returns `mvar` at once.
-}
forkLoadInterfaceTypes : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Extract.Types) -> Task Never (MVar (Maybe Extract.Types))
forkLoadInterfaceTypes root maybeBuildDir name mvar =
    Utils.forkIO (loadAndStoreInterfaceTypes root maybeBuildDir name mvar)
        |> Task.map (\_ -> mvar)


{-| Reads module `name`'s `.eci` file and stores its types in `mvar`, or `Nothing` when it is missing or cannot be decoded.
-}
loadAndStoreInterfaceTypes : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Extract.Types) -> Task Never ()
loadAndStoreInterfaceTypes root maybeBuildDir name mvar =
    File.readBinary I.interfaceDecoder (Stuff.eciWithBuildDir root maybeBuildDir name)
        |> Task.andThen (\maybeIface -> Utils.putMVar (Utils.maybeEncoder Extract.typesEncoder) mvar (Maybe.map (Extract.fromInterface name) maybeIface))



-- ====== TYPED OBJECTS LOADING ======


{-| The typed inputs to the MLIR path before they are merged.

It holds an MVar for the dependencies' typed artifacts, whose `Err` lists the
files that could not be read; the names of the modules whose `.ecot` file must
be read; the typed data of the fresh modules already in memory; and the root
and build directory those files are under.

-}
type TypedLoadingObjects
    = TypedLoadingObjects (MVar (Result (List FilePath) Details.PackageTypedArtifacts)) (List ModuleName.Raw) (Dict ModuleName.Raw ModuleTyped) FilePath (Maybe String)


{-| Starts reading the dependencies' typed artifacts and sorts `modules` into those
whose typed data is in memory and those whose `.ecot` file must be read. It
reads no `.ecot` file itself.
-}
loadTypedObjects : FilePath -> Maybe String -> List ( Pkg.Name, FilePath ) -> Details.Details -> List Build.Module -> Task Exit.Generate TypedLoadingObjects
loadTypedObjects root maybeBuildDir localPackages details modules =
    Task.io
        (Details.loadTypedObjects localPackages details
            |> Task.andThen (loadTypedModuleObjects root maybeBuildDir modules)
        )


{-| Returns the typed loading state for `modules`. A fresh module that carries both
a typed graph and a type env is kept in memory; every other module is listed to
be read from its `.ecot` file.
-}
loadTypedModuleObjects : FilePath -> Maybe String -> List Build.Module -> MVar (Result (List FilePath) Details.PackageTypedArtifacts) -> Task Never TypedLoadingObjects
loadTypedModuleObjects root maybeBuildDir modules mvar =
    let
        partition : List Build.Module -> ( List ( ModuleName.Raw, ModuleTyped ), List ModuleName.Raw ) -> ( List ( ModuleName.Raw, ModuleTyped ), List ModuleName.Raw )
        partition mods acc =
            case mods of
                [] ->
                    acc

                modul :: rest ->
                    case modul of
                        Build.Fresh name _ _ (Just typedGraph) (Just typeEnv) ->
                            let
                                ( fresh, cached ) =
                                    acc
                            in
                            partition rest
                                ( ( name, { graph = typedGraph, env = typeEnv } ) :: fresh
                                , cached
                                )

                        Build.Fresh name _ _ _ _ ->
                            let
                                ( fresh, cached ) =
                                    acc
                            in
                            partition rest
                                ( fresh
                                , name :: cached
                                )

                        Build.Cached name _ _ ->
                            let
                                ( fresh, cached ) =
                                    acc
                            in
                            partition rest
                                ( fresh
                                , name :: cached
                                )

        ( freshPairs, cachedNames ) =
            partition modules ( [], [] )

        freshDict =
            Dict.fromList freshPairs
    in
    Task.succeed (TypedLoadingObjects mvar cachedNames freshDict root maybeBuildDir)



-- ====== FINALIZE TYPED OBJECTS ======


{-| One module's typed graph and type env.
-}
type alias ModuleTyped =
    { graph : TOpt.LocalGraph Name
    , env : TypeEnv.ModuleTypeEnv
    }


{-| The typed global graph and the global type env, with every module of the build and every dependency merged in.
-}
type MergedTypedData
    = MergedTypedData (TOpt.GlobalGraph Name) TypeEnv.GlobalTypeEnv


{-| Waits for the dependencies' typed artifacts, then merges every module's typed
graph and type env into them.

Cached modules are read from their `.ecot` files one at a time, so that only one
module's data is alive at once beside the merged result. Fails with
`GenerateCannotLoadPackageArtifacts` when a dependency's typed artifacts could
not be read, and with `GenerateCannotLoadArtifacts` when an `.ecot` file could
not.

-}
finalizeAndMergeTypedObjects : TypedLoadingObjects -> Task Exit.Generate MergedTypedData
finalizeAndMergeTypedObjects (TypedLoadingObjects mvar cachedModulesList freshModules root maybeBuildDir) =
    Task.eio identity
        (Utils.takeMVar (BD.result (BD.list BD.string) Details.packageTypedArtifactsDecoder) mvar
            |> Task.andThen (streamLoadAndMerge cachedModulesList freshModules root maybeBuildDir)
        )


{-| Merges the fresh modules' typed data into the dependencies' typed artifacts,
then the cached modules' data one `.ecot` file at a time. When the
dependencies' artifacts are an `Err`, fails with
`GenerateCannotLoadPackageArtifacts` naming the unreadable files.
-}
streamLoadAndMerge :
    List ModuleName.Raw
    -> Dict ModuleName.Raw ModuleTyped
    -> FilePath
    -> Maybe String
    -> Result (List FilePath) Details.PackageTypedArtifacts
    -> Task Never (Result Exit.Generate MergedTypedData)
streamLoadAndMerge cachedNames freshModules root maybeBuildDir loadedGlobalArtifacts =
    case loadedGlobalArtifacts of
        Err unreadablePaths ->
            Task.succeed (Err (Exit.GenerateCannotLoadPackageArtifacts unreadablePaths))

        Ok globalArtifacts ->
            let
                ( mergedGraph, mergedEnv ) =
                    Dict.foldl
                        (\_ modTyped ( g, e ) ->
                            ( GA.addTypedLocalGraph modTyped.graph g
                            , Data.Map.insert ModuleName.toComparableCanonical modTyped.env.home modTyped.env e
                            )
                        )
                        ( globalArtifacts.typedGraph, globalArtifacts.typeEnv )
                        freshModules
            in
            streamLoadAndMergeCached cachedNames root maybeBuildDir mergedGraph mergedEnv


{-| Reads each module in `remaining` from its `.ecot` file and merges it into
`graph` and `env`, one at a time, so that each module's data can be collected
before the next is read. Fails with `GenerateCannotLoadArtifacts` at the first
file that cannot be read.
-}
streamLoadAndMergeCached :
    List ModuleName.Raw
    -> FilePath
    -> Maybe String
    -> TOpt.GlobalGraph Name
    -> TypeEnv.GlobalTypeEnv
    -> Task Never (Result Exit.Generate MergedTypedData)
streamLoadAndMergeCached remaining root maybeBuildDir graph env =
    case remaining of
        [] ->
            Task.succeed (Ok (MergedTypedData graph env))

        name :: rest ->
            File.readBinary TMod.typedModuleArtifactDecoder (Stuff.ecotWithBuildDir root maybeBuildDir name)
                |> Task.andThen
                    (\maybeArtifact ->
                        case maybeArtifact of
                            Nothing ->
                                Task.succeed (Err Exit.GenerateCannotLoadArtifacts)

                            Just artifact ->
                                let
                                    graph2 =
                                        GA.addTypedLocalGraph artifact.typedGraph graph

                                    env2 =
                                        Data.Map.insert ModuleName.toComparableCanonical artifact.typeEnv.home artifact.typeEnv env
                                in
                                streamLoadAndMergeCached rest root maybeBuildDir graph2 env2
                    )



-- ====== MONOMORPHIZED GENERATION ======


{-| The monomorphized and optimized program, with the mode to generate MLIR from it
in. The mode is always `Mode.Dev Nothing`.
-}
type alias MonoBuildResult =
    { monoGraph : Mono.MonoGraph
    , mode : Mode.Mode
    }


{-| Returns the monomorphized and optimized program for the build's artifacts.

It drops the build's cached-interface MVars, clears the fresh modules' untyped
graphs, merges every module's typed data with the dependencies', and runs the
middle end with its validators and census lines.

-}
buildMonoGraph :
    Config.EcoConfig
    -> FEStats.Handle
    -> FilePath
    -> Maybe String
    -> List ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> Task Exit.Generate MonoBuildResult
buildMonoGraph ecoConfig stats root maybeBuildDir localPackages details (Build.Artifacts artifacts) =
    let
        roots =
            artifacts.roots

        -- Only the JavaScript path reads the untyped graphs; clearing them lets them be collected.
        modules =
            List.map stripUntypedGraph artifacts.modules
    in
    -- Nothing on this path reads the cached-interface MVars, and an MVar keeps
    -- its contents alive until it is dropped.
    Task.io (Utils.listTraverse_ dropCachedInterfaceMVar artifacts.modules)
        |> Task.andThen (\_ -> loadTypedObjects root maybeBuildDir localPackages details modules)
        |> Task.andThen finalizeAndMergeTypedObjects
        |> Task.andThen (buildMonoGraphFromMerged ecoConfig stats roots)


{-| Drops a cached module's interface MVar, and does nothing for a fresh module.
-}
dropCachedInterfaceMVar : Build.Module -> Task Never ()
dropCachedInterfaceMVar modul =
    case modul of
        Build.Cached _ _ mvar ->
            Utils.dropMVar mvar

        Build.Fresh _ _ _ _ _ ->
            Task.succeed ()


{-| Returns a fresh module with its untyped local graph replaced by an empty one, and a cached module unchanged.
-}
stripUntypedGraph : Build.Module -> Build.Module
stripUntypedGraph modul =
    case modul of
        Build.Fresh name iface _ typedObjs typeEnv ->
            Build.Fresh name iface (Opt.LocalGraph Nothing Data.Map.empty Dict.empty) typedObjs typeEnv

        Build.Cached _ _ _ ->
            modul


{-| Adds the outside roots' typed graphs and type envs, assigns ids
(`Compiler.Pipeline.Steps.prepare`), and runs the rest of the middle end on the
result.
-}
buildMonoGraphFromMerged : Config.EcoConfig -> FEStats.Handle -> NE.Nonempty Build.Root -> MergedTypedData -> Task Exit.Generate MonoBuildResult
buildMonoGraphFromMerged ecoConfig stats roots (MergedTypedData mergedGraph mergedEnv) =
    let
        typedGraph : TOpt.GlobalGraph Name
        typedGraph =
            List.foldl addRootTypedGraph mergedGraph (NE.toList roots)

        globalTypeEnv : TypeEnv.GlobalTypeEnv
        globalTypeEnv =
            List.foldl addRootTypeEnv mergedEnv (NE.toList roots)

        assigned : EntryPrep.Assigned
        assigned =
            Steps.prepare ecoConfig typedGraph
    in
    -- The rest runs as a following step, so that the graph before id
    -- assignment, this function's argument, can be collected.
    Task.succeed ( assigned, globalTypeEnv )
        |> Task.andThen (\( a, env ) -> runMonoOptPipeline ecoConfig stats env a)


{-| Runs the pre-monomorphization passes (`Compiler.Pipeline.Steps.preMono`),
under `mono.validate` checks that they minted fresh ids for what they copied,
and monomorphizes the result.

Under `inline.report` it writes a census line for each pre-mono pass, whatever
that pass's own flag says. Alias forwarding and η-expansion with their flag off
report what they would have rewritten, the pre-mono inliner with its flag off
reports empty metrics, and the closed-lambda-argument census
(`Compiler.GlobalOpt.PreMono.LiftClosedArgs`), which has no transform behind
it, is taken of the graph after all three.

-}
runMonoOptPipeline : Config.EcoConfig -> FEStats.Handle -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Task Exit.Generate MonoBuildResult
runMonoOptPipeline ecoConfig stats globalTypeEnv assignedRaw =
    let
        pre =
            Steps.preMono ecoConfig assignedRaw

        assigned1 =
            pre.assigned

        writeReport line =
            if ecoConfig.inline.report then
                Task.io (System.IO.writeLn System.IO.stderr line)

            else
                Task.succeed ()

        preLiftReport () =
            if ecoConfig.inline.report then
                writeReport (renderPreLiftReport (LiftClosedArgs.census assigned1.graph))

            else
                Task.succeed ()
    in
    writeReport (renderPreAliasForwardReport ecoConfig.inline.aliasForward pre.aliasForward)
        |> Task.andThen (\_ -> writeReport (renderPreEtaReport ecoConfig.inline.etaExpand pre.etaExpand))
        |> Task.andThen (\_ -> writeReport (renderPreInlineReport pre.inline))
        |> Task.andThen (\_ -> preLiftReport ())
        |> Task.andThen (\_ -> validateMinted ecoConfig assigned1)
        |> Task.andThen
            (\_ ->
                monoPipelineFrom ecoConfig stats globalTypeEnv assigned1
            )


{-| Fails with `GenerateMonomorphizationError` when, under `mono.validate`,
`Compiler.Pipeline.Steps.checkMinted` finds a missing or repeated id.
-}
validateMinted : Config.EcoConfig -> EntryPrep.Assigned -> Task Exit.Generate ()
validateMinted ecoConfig assigned =
    case Steps.checkMinted ecoConfig assigned of
        Ok () ->
            Task.succeed ()

        Err message ->
            Task.throw (Exit.GenerateMonomorphizationError message)


{-| Fails with `GenerateMonomorphizationError` when, under `mono.validate` with
`inline.pruneDead` on, `Compiler.Pipeline.Steps.checkPruned` finds a live
specialization that references a pruned one (MONO\_011).
-}
validatePruned : Config.EcoConfig -> Mono.MonoGraph -> Task Exit.Generate ()
validatePruned ecoConfig graph =
    case Steps.checkPruned ecoConfig graph of
        Ok () ->
            Task.succeed ()

        Err message ->
            Task.throw (Exit.GenerateMonomorphizationError message)


{-| Monomorphizes `assigned`, then runs inlining and global optimization, and
returns the result.

The LSS census, when the engine returns one, is written to stderr. Stage arity
is checked after monomorphization and again at the end, whatever
`mono.validate` says; under `mono.validate`, layout is checked after
monomorphization and closure staging at the end. A failed check fails with
`GenerateMonomorphizationError`.

-}
monoPipelineFrom : Config.EcoConfig -> FEStats.Handle -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Task Exit.Generate MonoBuildResult
monoPipelineFrom ecoConfig stats globalTypeEnv assigned =
    FEStats.withPhaseLazy stats
        FEStats.PhaseMono
        (\() ->
            case Steps.monomorphize ecoConfig globalTypeEnv assigned of
                Err err ->
                    Task.throw (Exit.GenerateMonomorphizationError err)

                Ok ( monoGraph0, maybeLssReport ) ->
                    (case maybeLssReport of
                        Just report ->
                            Task.io (System.IO.writeLn System.IO.stderr report)
                                |> Task.map (\_ -> monoGraph0)

                        Nothing ->
                            Task.succeed monoGraph0
                    )
                        -- Not behind mono.validate.
                        |> Task.andThen validateStageArityLimit
                        |> Task.andThen
                            (\g ->
                                case Steps.checkLayout ecoConfig g of
                                    Ok g1 ->
                                        Task.succeed g1

                                    Err message ->
                                        Task.throw (Exit.GenerateMonomorphizationError message)
                            )
        )
        -- A separate function, so that the monomorphizer's inputs can be collected.
        |> Task.andThen (runInlineSimplifyPhase ecoConfig stats)
        |> Task.andThen
            (\result ->
                validateStageArityLimit result.monoGraph
                    |> Task.map (\_ -> result)
            )
        |> Task.andThen
            (\result ->
                case Steps.checkClosureStaging ecoConfig result.monoGraph of
                    Ok _ ->
                        Task.succeed result

                    Err message ->
                        Task.throw (Exit.GenerateMonomorphizationError message)
            )


{-| Returns the graph, or fails with a `STAGE ARITY LIMIT` error listing every
closure with more parameters plus captured variables than a closure stage can
hold (`Compiler.Pipeline.Steps.checkStageArity`). This check does not depend on
`mono.validate`.
-}
validateStageArityLimit : Mono.MonoGraph -> Task Exit.Generate Mono.MonoGraph
validateStageArityLimit g =
    case Steps.checkStageArity g of
        Ok g1 ->
            Task.succeed g1

        Err message ->
            Task.throw (Exit.GenerateMonomorphizationError message)


{-| Runs the post-monomorphization inliner (`Compiler.Pipeline.Steps.inline`),
then the prune and its census, then global optimization, each as a separate
step so that its input graph can be collected.
-}
runInlineSimplifyPhase : Config.EcoConfig -> FEStats.Handle -> Mono.MonoGraph -> Task Exit.Generate MonoBuildResult
runInlineSimplifyPhase ecoConfig stats monoGraph0 =
    FEStats.withPhaseLazy stats
        FEStats.PhaseInlineSimplify
        (\() ->
            let
                ( inlinedGraph, inlineMetrics ) =
                    Steps.inline ecoConfig monoGraph0
            in
            -- The prune runs in the next step: this callback captures
            -- `monoGraph0`, which stays alive until the callback returns.
            Task.succeed ( inlinedGraph, inlineMetrics )
                |> Task.andThen (pruneAndReportInline ecoConfig)
        )
        |> Task.andThen (runGlobalOptPhase ecoConfig ecoConfig.mono.lss.report ecoConfig.list.report ecoConfig.borrow ecoConfig.cafMemo ecoConfig.cse stats)


{-| Under `inline.pruneDead`, removes the specializations the inliner left
unreferenced (`Compiler.Pipeline.Steps.prune`); otherwise the graph is
unchanged. It checks the result with `validatePruned`.

Under `inline.report` it first writes the inline and prune census lines, taken
of the pruned graph.
-}
pruneAndReportInline : Config.EcoConfig -> ( Mono.MonoGraph, MonoInlineSimplify.Metrics ) -> Task Exit.Generate Mono.MonoGraph
pruneAndReportInline ecoConfig ( inlinedGraph, inlineMetrics ) =
    let
        simplifiedGraph =
            Steps.prune ecoConfig inlinedGraph
    in
    if ecoConfig.inline.report then
        Task.io
            (System.IO.writeLn System.IO.stderr
                (renderInlineReportWith ecoConfig.inline inlineMetrics simplifiedGraph
                    ++ "\n"
                    ++ renderPruneReport inlinedGraph simplifiedGraph
                )
            )
            |> Task.andThen (\_ -> validatePruned ecoConfig simplifiedGraph)
            |> Task.map (\_ -> simplifiedGraph)

    else
        validatePruned ecoConfig simplifiedGraph
            |> Task.map (\_ -> simplifiedGraph)


{-| Renders the alias forwarding census line, ending with the 20 targets with the
largest counts. The line opens `pre-afwd:` when `enabled`, and
`pre-afwd-census:` when not, in which case the counts are of what the pass
would have rewritten.
-}
renderPreAliasForwardReport : Bool -> AliasForward.Metrics -> String
renderPreAliasForwardReport enabled m =
    let
        topTargets =
            Dict.toList m.byTarget
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 20
                |> List.map (\( name, n ) -> name ++ "=" ++ String.fromInt n)
                |> String.join " "

        prefix =
            if enabled then
                "pre-afwd: "

            else
                "pre-afwd-census: "
    in
    prefix
        ++ "aliases="
        ++ String.fromInt m.aliases
        ++ " globalTargets="
        ++ String.fromInt m.globalTargets
        ++ " kernelTargets="
        ++ String.fromInt m.kernelTargets
        ++ " chainsMax="
        ++ String.fromInt m.chainsMax
        ++ " cycles="
        ++ String.fromInt m.cycles
        ++ " callsRewritten="
        ++ String.fromInt m.callsRewritten
        ++ " callsRewrittenKernel="
        ++ String.fromInt m.callsRewrittenKernel
        ++ " callsKeptKernelPartial="
        ++ String.fromInt m.callsKeptKernelPartial
        ++ " callsKeptKernelOver="
        ++ String.fromInt m.callsKeptKernelOver
        ++ " callsKeptKernelPoly="
        ++ String.fromInt m.callsKeptKernelPoly
        ++ " callsKeptKernelMeta="
        ++ String.fromInt m.callsKeptKernelMeta
        ++ " argRefsRewritten="
        ++ String.fromInt m.argRefsRewritten
        ++ " argRefsKeptKernel="
        ++ String.fromInt m.argRefsKeptKernel
        ++ " depsExtended="
        ++ String.fromInt m.depsExtended
        ++ " bodiesSeen="
        ++ String.fromInt m.bodiesSeen
        ++ "\n  top: "
        ++ topTargets


{-| Renders the η-expansion census line, with the 20 most expanded and the 20 most
declined names. The line opens `pre-eta:` when `enabled`, and
`pre-eta-census:` when not, in which case the counts are of what the pass would
have rewritten.
-}
renderPreEtaReport : Bool -> EtaExpand.Metrics -> String
renderPreEtaReport enabled m =
    let
        topExpanded =
            Dict.toList m.byName
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 20
                |> List.map (\( name, n ) -> name ++ "=" ++ String.fromInt n)
                |> String.join " "

        topDeclined =
            Dict.toList m.notCheapByName
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 20
                |> List.map (\( name, n ) -> name ++ "=" ++ String.fromInt n)
                |> String.join " "

        prefix =
            if enabled then
                "pre-eta: "

            else
                "pre-eta-census: "
    in
    prefix
        ++ "defs="
        ++ String.fromInt m.defs
        ++ " cycleDefs="
        ++ String.fromInt m.cycleDefs
        ++ " conts="
        ++ String.fromInt m.conts
        ++ " merged="
        ++ String.fromInt m.merged
        ++ " pushed="
        ++ String.fromInt m.pushed
        ++ " declined.notCheap="
        ++ String.fromInt m.notCheap
        ++ " declined.noDeficit="
        ++ String.fromInt m.noDeficit
        ++ " declined.noSpine="
        ++ String.fromInt m.noSpine
        ++ " declined.tailDef="
        ++ String.fromInt m.tailDef
        ++ " declined.cycleValue="
        ++ String.fromInt m.cycleValue
        ++ " declined.kernelAlias="
        ++ String.fromInt m.kernelAlias
        ++ " declined.ctorAlias="
        ++ String.fromInt m.ctorAlias
        ++ " declined.noPeel="
        ++ String.fromInt m.noPeel
        ++ " declined.arityCap="
        ++ String.fromInt m.declinedArityCap
        ++ " bodiesSeen="
        ++ String.fromInt m.bodiesSeen
        ++ "\n  deficit: 1="
        ++ String.fromInt m.deficit1
        ++ " 2="
        ++ String.fromInt m.deficit2
        ++ " 3+="
        ++ String.fromInt m.deficit3
        ++ "   cheapShare="
        ++ String.fromInt m.cheapYes
        ++ "/"
        ++ String.fromInt m.cheapSeen
        ++ "\n  top: "
        ++ topExpanded
        ++ "\n  topDeclined: "
        ++ topDeclined


{-| Renders the closed-lambda-argument census line, `pre-lift-census:`, with the
20 callees with the largest liftable and loopifiable counts. No transform
stands behind it.
-}
renderPreLiftReport : LiftClosedArgs.Metrics -> String
renderPreLiftReport m =
    let
        topBy d =
            Dict.toList d
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 20
                |> List.map (\( name, n ) -> name ++ "=" ++ String.fromInt n)
                |> String.join " "
    in
    "pre-lift-census: candidates="
        ++ String.fromInt m.candidates
        ++ " closed="
        ++ String.fromInt m.closed
        ++ " capturing="
        ++ String.fromInt m.capturing
        ++ " liftable="
        ++ String.fromInt m.liftable
        ++ " declined.cycle="
        ++ String.fromInt m.declinedCycle
        ++ " declined.port="
        ++ String.fromInt m.declinedPort
        ++ " declined.tailDef="
        ++ String.fromInt m.declinedTailDef
        ++ " declined.varCycle="
        ++ String.fromInt m.declinedVarCycle
        ++ " declined.loopifiableCallee="
        ++ String.fromInt m.declinedLoopifiable
        ++ " lambdasSeen="
        ++ String.fromInt m.lambdasSeen
        ++ " callsSeen="
        ++ String.fromInt m.callsSeen
        ++ " recursiveGlobals="
        ++ String.fromInt m.recursiveGlobals
        ++ " loopifiableGlobals="
        ++ String.fromInt m.loopifiableGlobals
        ++ "\n  liftable by callee: "
        ++ topBy m.byCallee
        ++ "\n  loopifiable by callee: "
        ++ topBy m.byCalleeLoopifiable


{-| Renders the pre-mono inliner's census line, `pre-inline-simplify:`, followed by
its breakdown of the undetermined, over-budget and higher-order candidates.
-}
renderPreInlineReport : InlineSimplify.Metrics -> String
renderPreInlineReport m =
    let
        topCallees =
            Dict.toList m.inlinedByCallee
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 20
                |> List.map (\( callee, n ) -> callee ++ "=" ++ String.fromInt n)
                |> String.join " "
    in
    "pre-inline-simplify: inlined="
        ++ String.fromInt m.inlineCount
        ++ " candidates="
        ++ String.fromInt m.candidates
        ++ " recursiveSkipped="
        ++ String.fromInt m.recursiveSkipped
        ++ " overBudget="
        ++ String.fromInt m.overBudget
        ++ " polymorphic="
        ++ String.fromInt m.polymorphic
        ++ " polyKernel="
        ++ String.fromInt m.polyKernel
        ++ " rowPoly="
        ++ String.fromInt m.rowPoly
        ++ " superVar="
        ++ String.fromInt m.superVar
        ++ " hofParam="
        ++ String.fromInt m.hofParam
        ++ " undetermined="
        ++ String.fromInt m.undetermined
        ++ " bodiesSeen="
        ++ String.fromInt m.bodiesSeen
        ++ "\n  top: "
        ++ topCallees
        ++ "\npre-inline Q1: undCallerPoly="
        ++ String.fromInt m.undCallerPoly
        ++ " undLocal="
        ++ String.fromInt m.undLocal
        ++ " undBodyOnly="
        ++ String.fromInt m.undBodyOnly
        ++ " undLeak(annBinders=0)="
        ++ String.fromInt m.undLeak
        ++ " overBudget(11-15,16-25,26-50,>50)="
        ++ (case m.overBudgetBuckets of
                ( b1, b2, ( b3, b4 ) ) ->
                    String.join "," (List.map String.fromInt [ b1, b2, b3, b4 ])
           )
        ++ " hofArg(lambda,global,other)="
        ++ String.join "," (List.map String.fromInt [ m.hofArgLambda, m.hofArgGlobal, m.hofArgOther ])
        ++ "\n  undeterminedByCallee: "
        ++ top 40 m.undeterminedByCallee
        ++ "\n  undCallerPolyByCallee: "
        ++ top 40 m.undCallerPolyByCallee
        ++ "\n  undLocalByCallee: "
        ++ top 60 m.undLocalByCallee
        ++ "\n  undBodyOnlyByCallee: "
        ++ top 40 m.undBodyOnlyByCallee
        ++ "\n  hofNames: "
        ++ String.join " " m.hofNames
        ++ "\n  polyKernelNames: "
        ++ String.join " " m.polyKernelNames
        ++ "\n  superVarNames: "
        ++ String.join " " m.superVarNames
        ++ "\n  overBudgetCosts: "
        ++ (m.overBudgetCosts
                |> List.sortBy Tuple.second
                |> List.map (\( n, c ) -> n ++ "=" ++ String.fromInt c)
                |> String.join " "
           )


{-| Returns the `n` entries of `d` with the largest counts, largest first, as space-separated `k=v` tokens.
-}
top : Int -> Dict String Int -> String
top n d =
    Dict.toList d
        |> List.sortBy (\( _, v ) -> negate v)
        |> List.take n
        |> List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
        |> String.join " "


{-| Renders the prune census line from the graph `before` and `after` the prune:
how many specializations were removed and kept, and the 20 globals that lost the
most. A removed specialization is counted under its global in `before`'s
registry, or under `?` when it has none.
-}
renderPruneReport : Mono.MonoGraph -> Mono.MonoGraph -> String
renderPruneReport (Mono.MonoGraph before) (Mono.MonoGraph after) =
    let
        ( prunedCount, keptCount, byGlobal ) =
            Array.foldl
                (\entry ( specId, ( nPruned, nKept, acc ) ) ->
                    case entry of
                        Nothing ->
                            ( specId + 1, ( nPruned, nKept, acc ) )

                        Just _ ->
                            case Array.get specId after.nodes |> Maybe.andThen identity of
                                Just _ ->
                                    ( specId + 1, ( nPruned, nKept + 1, acc ) )

                                Nothing ->
                                    let
                                        name =
                                            case Array.get specId before.registry.reverseMapping |> Maybe.andThen identity of
                                                Just ( g, _ ) ->
                                                    Mono.toComparableGlobal g

                                                Nothing ->
                                                    "?"
                                    in
                                    ( specId + 1
                                    , ( nPruned + 1
                                      , nKept
                                      , Dict.update name (\v -> Just (1 + Maybe.withDefault 0 v)) acc
                                      )
                                    )
                )
                ( 0, ( 0, 0, Dict.empty ) )
                before.nodes
                |> Tuple.second

        topPruned =
            Dict.toList byGlobal
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 20
                |> List.map (\( name, n ) -> name ++ "=" ++ String.fromInt n)
                |> String.join " "
    in
    "post-inline-prune: pruned="
        ++ String.fromInt prunedCount
        ++ " kept="
        ++ String.fromInt keptCount
        ++ "\n  top pruned globals: "
        ++ (if String.isEmpty topPruned then
                "(none)"

            else
                topPruned
           )


{-| Renders the post-mono inliner's census lines: every inlined callee, the pass
metrics, the identity-clearing reshapes, the uids of returned reshapes, the
inline redundancy counts, the top 20 callees, the residual closures and the
function results. The closure counts and the residual breakdowns are taken of
`graph`.
-}
renderInlineReportWith : Config.InlineConfig -> MonoInlineSimplify.Metrics -> Mono.MonoGraph -> String
renderInlineReportWith inlineConfig m graph =
    let
        topCallees =
            Dict.toList m.inlinedByCallee
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 20
                |> List.map (\( callee, n ) -> callee ++ "=" ++ String.fromInt n)
                |> String.join " "

        taxonomy =
            MonoInlineSimplify.residualTaxonomy inlineConfig graph
                |> List.map (\( bucket, n ) -> bucket ++ "=" ++ String.fromInt n)
                |> String.join " "

        fnResults =
            MonoInlineSimplify.functionResultCensus graph
                |> List.map (\( bucket, n ) -> bucket ++ "=" ++ String.fromInt n)
                |> String.join " "
    in
    String.join "\n"
        [ "inline all callees: "
            ++ (Dict.toList m.inlinedByCallee
                    |> List.sortBy (\( _, n ) -> negate n)
                    |> List.map (\( callee, n ) -> callee ++ "=" ++ String.fromInt n)
                    |> String.join " "
               )
        , "inline-simplify: inlined="
            ++ String.fromInt m.inlineCount
            ++ " beta="
            ++ String.fromInt m.betaReductions
            ++ " betaForwards="
            ++ String.fromInt m.betaForwards
            ++ " partialMerges="
            ++ String.fromInt m.partialMerges
            ++ " loopified="
            ++ String.fromInt m.hofLoopified
            ++ "/"
            ++ String.fromInt m.loopifiable
            ++ " letDCE="
            ++ String.fromInt m.letEliminations
            ++ " kernelLetDCE="
            ++ String.fromInt m.kernelLetDCE
            ++ " deadLets="
            ++ String.fromInt m.deadLets
            ++ " deadBareKernelVar="
            ++ String.fromInt m.deadBareKernelVar
            ++ " deadDroppableKernelLets="
            ++ String.fromInt m.deadDroppableKernelLets
            ++ " closureDCE="
            ++ String.fromInt m.closureDCE
            ++ " raised="
            ++ String.fromInt m.arityRaised
            ++ " raiseSkipped="
            ++ String.fromInt m.arityRaiseSkipped
            ++ " declinedPreserveSets="
            ++ String.fromInt m.declinedPreserveSets
            ++ " declinedArityCap="
            ++ String.fromInt m.declinedArityCap
            ++ " closuresRemaining="
            ++ String.fromInt (MonoInlineSimplify.countClosures graph)
        , "inline reshapes (P0 axis 1: identity-clearing reshapes; axis 2: residual use shape): cleared="
            ++ String.fromInt
                (Dict.foldl
                    (\k c a ->
                        if String.startsWith "RESHAPES|" k then
                            a

                        else
                            a + c
                    )
                    0
                    m.clearedMembers
                )
            ++ " reshapesTotal="
            ++ String.fromInt
                (Dict.foldl
                    (\k c a ->
                        if String.startsWith "RESHAPES|" k then
                            a + c

                        else
                            a
                    )
                    0
                    m.clearedMembers
                )
            ++ " bySite="
            ++ (Dict.toList m.clearedMembers
                    |> List.filter (\( k, _ ) -> String.startsWith "RESHAPES|" k)
                    |> List.map (\( k, c ) -> String.dropLeft 9 k ++ ":" ++ String.fromInt c)
                    |> String.join ","
               )
            ++ " | "
            ++ (let
                    axis2 =
                        MonoInlineSimplify.reshapeCensus m.clearedMembers graph

                    shown =
                        Dict.toList axis2
                            |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                            |> String.join " "
                in
                if String.isEmpty shown then
                    "(no residuals located)"

                else
                    shown
               )
        , "inline reshapes RETURNED uids (P0 §7.3 join key for ECO_DISPATCH_STATS): "
            ++ (let
                    us =
                        MonoInlineSimplify.reshapeReturnedUids m.clearedMembers graph
                in
                if List.isEmpty us then
                    "(none)"

                else
                    String.join "," (List.map String.fromInt us)
               )
        , "inline P0 redundancy (plans/pre-mono-inline-simplify.md §8): inlines="
            ++ String.fromInt m.inlineCount
            ++ " distinctSourceSites="
            ++ String.fromInt (Dict.size m.inlineSourceSites)
            ++ " distinctCallees="
            ++ String.fromInt (Dict.size m.inlinedByCallee)
        , "inline top callees: "
            ++ (if String.isEmpty topCallees then
                    "(none)"

                else
                    topCallees
               )
        , "residual closures: "
            ++ (if String.isEmpty taxonomy then
                    "(none)"

                else
                    taxonomy
               )
        , "function results: "
            ++ (if String.isEmpty fnResults then
                    "(none)"

                else
                    fnResults
               )
        ]


{-| Runs global optimization (`Compiler.Pipeline.Steps.globalOptCore`, then `cse`,
`dedupe` and `hoist`) and writes its census lines, returning the final graph.

Each piece is its own step, so that its input graph can be collected once the
next piece has its output. A census that needs an intermediate graph is
rendered in the step where that graph is alive, and every line is written by
the last step. `mapTemplateCfg` is the whole build configuration; the other
configuration arguments are parts of it.

-}
runGlobalOptPhase : Config.EcoConfig -> Bool -> Bool -> Config.BorrowConfig -> Config.CafMemoConfig -> Config.CseConfig -> FEStats.Handle -> Mono.MonoGraph -> Task Exit.Generate MonoBuildResult
runGlobalOptPhase mapTemplateCfg lssReport listReport borrowCfg cafMemo cseCfg stats simplifiedGraph =
    let
        cfg : GlobalOptCfg
        cfg =
            { mapTemplateCfg = mapTemplateCfg
            , lssReport = lssReport
            , listReport = listReport
            , borrowCfg = borrowCfg
            , cafMemo = cafMemo
            , cseCfg = cseCfg
            }
    in
    FEStats.withPhaseLazy stats
        FEStats.PhaseGlobalOpt
        (\() ->
            Task.succeed (Steps.globalOptCore mapTemplateCfg simplifiedGraph)
                |> Task.andThen (globalOptCseStep cfg)
                |> Task.andThen (globalOptDedupeStep cfg)
                |> Task.andThen (globalOptHoistStep cfg)
                |> Task.andThen (globalOptReportStep cfg)
        )


{-| The configuration the global optimization steps read, kept apart from any graph
so that no step captures one. `mapTemplateCfg` is the whole `EcoConfig`.
-}
type alias GlobalOptCfg =
    { mapTemplateCfg : Config.EcoConfig
    , lssReport : Bool
    , listReport : Bool
    , borrowCfg : Config.BorrowConfig
    , cafMemo : Config.CafMemoConfig
    , cseCfg : Config.CseConfig
    }


{-| What the global optimization steps carry besides the current graph: each
piece's statistics and the census text already rendered. A name for
`Compiler.Pipeline.Steps.GlobalOptResult`.
-}
type alias GlobalOptCarry =
    Steps.GlobalOptResult


{-| Runs common subexpression elimination of pure calls (`Compiler.Pipeline.Steps.cse`) as a step.
-}
globalOptCseStep : GlobalOptCfg -> ( Mono.MonoGraph, MonoGlobalOptimize.GlobalOptStats ) -> Task x ( Mono.MonoGraph, GlobalOptCarry )
globalOptCseStep cfg goResult =
    Task.succeed (Steps.cse cfg.mapTemplateCfg goResult)


{-| Runs CAF dedupe and the pre-hoist CAF census (`Compiler.Pipeline.Steps.dedupe`) as a step.
-}
globalOptDedupeStep : GlobalOptCfg -> ( Mono.MonoGraph, GlobalOptCarry ) -> Task x ( Mono.MonoGraph, GlobalOptCarry )
globalOptDedupeStep cfg cseResult =
    Task.succeed (Steps.dedupe cfg.mapTemplateCfg cseResult)


{-| Runs CAF hoisting (`Compiler.Pipeline.Steps.hoist`) as a step.
-}
globalOptHoistStep : GlobalOptCfg -> ( Mono.MonoGraph, GlobalOptCarry ) -> Task x ( Mono.MonoGraph, GlobalOptCarry )
globalOptHoistStep cfg dedupeResult =
    Task.succeed (Steps.hoist cfg.mapTemplateCfg dedupeResult)


{-| Writes the global optimization census lines to stderr and returns the final
graph with `Mode.Dev Nothing`.

The lines come in this order, each under its own flag: CAF dedupe statistics,
CSE statistics, the CSE census, the pre-hoist CAF census, CAF hoist statistics,
the post-hoist CAF census (which needs hoisting on as well as `cafMemo.census`),
the list combinator and `List.map` template censuses (`list.report`), the
`lss globalopt:` line with the AbiCloning census (`mono.lss.report`), the
generic-call census (`mono.stagingReport`) and the borrow census
(`borrow.report`).

-}
globalOptReportStep : GlobalOptCfg -> ( Mono.MonoGraph, GlobalOptCarry ) -> Task Exit.Generate MonoBuildResult
globalOptReportStep cfg ( hoistedGraph, carry ) =
    let
        { lssReport, listReport, borrowCfg, cafMemo, cseCfg, mapTemplateCfg } =
            cfg

        { goStats, cseStats, dedupeStats, hoistStats } =
            carry

        censusCfg =
            { minNodes = cafMemo.hoist.minNodes }

        result =
            { monoGraph = hoistedGraph
            , mode = Mode.Dev Nothing
            }

        writeLnErr line =
            Task.io (System.IO.writeLn System.IO.stderr line)

        writeMaybe maybeLine =
            case maybeLine of
                Just line ->
                    writeLnErr line

                Nothing ->
                    Task.succeed ()

        cseCensus =
            carry.cseCensus

        cafCensusPre =
            carry.cafCensusPre
    in
    (if cafMemo.dedupe then
        writeLnErr (CafDedupe.renderStats dedupeStats)

     else
        Task.succeed ()
    )
        |> Task.andThen
            (\_ ->
                if cseCfg.enabled then
                    writeLnErr (MonoCse.renderStats cseStats)

                else
                    Task.succeed ()
            )
        |> Task.andThen (\_ -> writeMaybe cseCensus)
        |> Task.andThen (\_ -> writeMaybe cafCensusPre)
        |> Task.andThen
            (\_ ->
                if cafMemo.hoist.enabled then
                    writeLnErr (CafHoist.renderStats hoistStats)

                else
                    Task.succeed ()
            )
        |> Task.andThen
            (\_ ->
                if cafMemo.census && cafMemo.hoist.enabled then
                    writeLnErr (CafCensus.report "caf-census(post-hoist)" censusCfg hoistedGraph)

                else
                    Task.succeed ()
            )
        |> Task.andThen
            (\_ ->
                if listReport then
                    writeLnErr (ListCombinators.report hoistedGraph)

                else
                    Task.succeed ()
            )
        |> Task.andThen
            (\_ ->
                if listReport then
                    -- Derived here from the final graph rather than taken
                    -- from the backend, which derives it again for emission.
                    writeLnErr
                        (MapTemplate.report
                            (MapTemplate.derive mapTemplateCfg hoistedGraph)
                        )

                else
                    Task.succeed ()
            )
        |> Task.andThen
            (\_ ->
                if lssReport then
                    Task.io
                        (System.IO.writeLn System.IO.stderr
                            ("lss globalopt: dispatchUpgraded="
                                ++ String.fromInt goStats.abiCloning.dispatchUpgraded
                                ++ " stampedPapPrefix="
                                ++ String.fromInt goStats.abiCloning.stampedPapPrefix
                                ++ " stampedPapGlobal="
                                ++ String.fromInt goStats.abiCloning.stampedPapGlobal
                                ++ " stampedStaged="
                                ++ String.fromInt goStats.abiCloning.stampedStaged
                                ++ " declinedBlocked="
                                ++ String.fromInt goStats.abiCloning.declinedBlocked
                                ++ " declinedNoInstance="
                                ++ String.fromInt goStats.abiCloning.declinedNoInstance
                                ++ " declinedShape="
                                ++ String.fromInt goStats.abiCloning.declinedShape
                                ++ " (arity="
                                ++ String.fromInt goStats.abiCloning.declinedShapeArity
                                ++ " [zero="
                                ++ String.fromInt goStats.abiCloning.declinedShapeArityZero
                                ++ " under="
                                ++ String.fromInt goStats.abiCloning.declinedShapeArityUnder
                                ++ " over="
                                ++ String.fromInt goStats.abiCloning.declinedShapeArityOver
                                ++ "] bucketMiss="
                                ++ String.fromInt goStats.abiCloning.declinedShapeBucketMiss
                                ++ " layout="
                                ++ String.fromInt goStats.abiCloning.declinedShapeLayout
                                ++ " char="
                                ++ String.fromInt goStats.abiCloning.declinedShapeChar
                                ++ " nonArrow="
                                ++ String.fromInt goStats.abiCloning.declinedShapeNonArrow
                                ++ ") declinedAbiMismatch="
                                ++ String.fromInt goStats.abiCloning.declinedAbiMismatch
                                ++ " declinedBodyMismatch="
                                ++ String.fromInt goStats.abiCloning.declinedBodyMismatch
                                ++ " devirtPost(fn/ctor/noSpec/ambiguous)="
                                ++ String.fromInt goStats.abiCloning.devirtPost.fn
                                ++ "/"
                                ++ String.fromInt goStats.abiCloning.devirtPost.ctor
                                ++ "/"
                                ++ String.fromInt goStats.abiCloning.devirtPost.noSpec
                                ++ "/"
                                ++ String.fromInt goStats.abiCloning.devirtPost.ambiguous
                                ++ " multiInstanceGroups="
                                ++ String.fromInt goStats.abiCloning.multiInstanceGroups
                                ++ "\n"
                                ++ abiCensusLines goStats.abiCloning
                            )
                        )
                        |> Task.map (\_ -> result)

                else
                    Task.succeed result
            )
        |> Task.andThen
            (\_ ->
                if mapTemplateCfg.mono.stagingReport then
                    writeLnErr (stagingCensusLine goStats)
                        |> Task.map (\_ -> result)

                else
                    Task.succeed result
            )
        |> Task.andThen
            (\_ ->
                if borrowCfg.report then
                    writeLnErr (Borrow.renderStats goStats.borrow)
                        |> Task.map (\_ -> result)

                else
                    Task.succeed result
            )


{-| Renders the generic-call census line, `lss gencall:`.
-}
stagingCensusLine : MonoGlobalOptimize.GlobalOptStats -> String
stagingCensusLine goStats =
    "lss gencall: " ++ GenCallCensus.render goStats.genCalls


{-| Renders the AbiCloning census lines that follow the `lss globalopt:` line:
declines and blocked members by member, call sites with several candidate
members, callee shapes, and the instance-qualified tables by host.

Some labels state a smaller count than the table can hold. The table labelled
`top400` takes up to 1,200,000 entries, `noInstance by host+guard top80` up to
400,000, and `declines by host top60` up to 4,000.

-}
abiCensusLines : AbiCloning.AbiCloningStats -> String
abiCensusLines abi =
    let
        lambdaSym lid =
            case lid of
                Mono.AnonymousLambda home uid ->
                    MLIRNames.canonicalToMLIRName home ++ "_lambda_" ++ String.fromInt uid

        repsFor mid =
            Dict.get mid abi.memberReps
                |> Maybe.withDefault []
                |> List.take 4
                |> List.map lambdaSym
                |> String.join ","

        topOf d n =
            Dict.toList d
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take n

        declineTop =
            topOf abi.declineByMember 20
                |> List.map (\( mid, c ) -> String.fromInt mid ++ ":" ++ String.fromInt c ++ ":" ++ repsFor mid)
                |> String.join " "

        multiHist =
            Dict.toList abi.multiSetSiteHist
                |> List.map (\( k, c ) -> String.fromInt k ++ "->" ++ String.fromInt c)
                |> String.join " "

        multiTop =
            topOf abi.multiSetMembers 12
                |> List.map (\( mid, c ) -> String.fromInt mid ++ ":" ++ String.fromInt c ++ ":" ++ repsFor mid)
                |> String.join " "

        shapes =
            Dict.toList abi.topSiteShapes
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        unknownShapes =
            Dict.toList abi.varSiteShapes
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        iqHosts =
            Dict.toList abi.instQual.byHost
                |> List.filter (\( k, _ ) -> not (String.endsWith "|stamped" k))
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take 4000
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        iqArityOverHosts =
            byReason "|arityOver" 80

        iqNoInstanceHosts =
            byReason "|noInstance" 40

        byReason suffix n =
            Dict.toList abi.instQual.byHost
                |> List.filter (\( k, _ ) -> String.endsWith suffix k)
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take n
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        blockedLine =
            abi.blockedMembers
                |> List.map
                    (\( mid, maybeBlocker ) ->
                        String.fromInt mid
                            ++ ":"
                            ++ (case maybeBlocker of
                                    Just lid ->
                                        lambdaSym lid

                                    Nothing ->
                                        "(mu-tie)"
                               )
                    )
                |> String.join " "
    in
    String.join "\n"
        [ "lss census declineByMember top20 (member:count:repSyms): " ++ declineTop
        , "lss census blockedMembers (member:blockerSym): "
            ++ (if String.isEmpty blockedLine then
                    "(none)"

                else
                    blockedLine
               )
        , "lss census multiSetSites |set|->sites: "
            ++ (if String.isEmpty multiHist then
                    "(none)"

                else
                    multiHist
               )
        , "lss census multiSiteShapes (one MSITE line per shape; sites<TAB>size|kinds|nIds|identities):\n"
            ++ (let
                    rows =
                        List.sortBy (\( _, n ) -> -n) (Dict.toList abi.instQual.multiSites)
                in
                if List.isEmpty rows then
                    "MSITE\t(none)\t0"

                else
                    String.join "\n"
                        (List.map
                            (\( k, n ) -> "MSITE\t" ++ String.fromInt n ++ "\t" ++ k)
                            rows
                        )
               )
        , "lss census multiSetMembers top12 (member:count:repSyms): "
            ++ (if String.isEmpty multiTop then
                    "(none)"

                else
                    multiTop
               )
        , "lss census topSiteShapes (LTop callee shapes): "
            ++ (if String.isEmpty shapes then
                    "(none)"

                else
                    shapes
               )
        , "lss census instQual pap WOULDSTAMP by host+spec top400: "
            ++ (let
                    ps =
                        Dict.toList abi.instQual.papSites
                            |> List.sortBy (\( _, c ) -> negate c)
                            |> List.take 1200000
                            |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                            |> String.join " "
                in
                if String.isEmpty ps then
                    "(none)"

                else
                    ps
               )
        , "lss census instQual noInstance GUARD TOTALS (UNTRUNCATED - a take ranked by site count silently hides fragmented hosts): "
            ++ (let
                    -- A key is `<host>|<why>`, and `why` may itself contain `|`.
                    whyOf k =
                        String.join "|" (List.drop 1 (String.split "|" k))

                    tot =
                        Dict.foldl
                            (\k c acc -> Dict.update (whyOf k) (\v -> Just (Maybe.withDefault 0 v + c)) acc)
                            Dict.empty
                            abi.instQual.niGuard
                in
                Dict.toList tot
                    |> List.sortBy (\( _, c ) -> negate c)
                    |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                    |> String.join " "
               )
        , "lss census instQual noInstance by host+guard top80: "
            ++ (let
                    g =
                        Dict.toList abi.instQual.niGuard
                            |> List.sortBy (\( _, c ) -> negate c)
                            |> List.take 400000
                            |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                            |> String.join " "
                in
                if String.isEmpty g then
                    "(none)"

                else
                    g
               )
        , "lss census instQual g1absentl SHAPE (callee shape|argCount) + distinct members: "
            ++ (let
                    pick pre =
                        Dict.toList abi.instQual.absentL
                            |> List.filter (\( k, _ ) -> String.startsWith pre k)

                    members =
                        pick "M|"

                    sites =
                        List.foldl (\( _, c ) a -> a + c) 0 members

                    render rows =
                        rows
                            |> List.sortBy (\( _, c ) -> negate c)
                            |> List.take 40
                            |> List.map (\( k, c ) -> String.dropLeft 2 k ++ "=" ++ String.fromInt c)
                            |> String.join " "
                in
                "sites="
                    ++ String.fromInt sites
                    ++ " distinctMembers="
                    ++ String.fromInt (List.length members)
                    ++ "  shapes: "
                    ++ render (pick "S|")
                    ++ "\n  by host+shape: "
                    ++ render (pick "H|")
                    ++ "\n  key shape: "
                    ++ render (pick "K|")
                    ++ "\n  source lambda's closures now: "
                    ++ render (pick "R|")
                    ++ "\n  members (id=sites): "
                    ++ (members
                            |> List.sortBy (\( _, c ) -> negate c)
                            |> List.take 2000
                            |> List.map (\( k, c ) -> String.dropLeft 2 k ++ "=" ++ String.fromInt c)
                            |> String.join " "
                       )
                    ++ "\n  sites (T|host|spec|member|outcome): "
                    ++ (pick "T|"
                            |> List.take 60000
                            |> List.map (\( k, c ) -> String.dropLeft 2 k ++ "=" ++ String.fromInt c)
                            |> String.join " "
                       )
                    ++ "\n  indexed members (I|id|rep uids|n): "
                    ++ (pick "I|"
                            |> List.take 6000
                            |> List.map (\( k, _ ) -> String.dropLeft 2 k)
                            |> String.join " "
                       )
               )
        , "lss census instQual flatStamped: " ++ String.fromInt abi.instQual.flatStamped
        , "lss census instQual overApply shape (firstStage->argCount|peel|reason): "
            ++ (let
                    sh =
                        Dict.toList abi.instQual.shape
                            |> List.sortBy (\( _, c ) -> negate c)
                            |> List.take 4000
                            |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                            |> String.join " "
                in
                if String.isEmpty sh then
                    "(none)"

                else
                    sh
               )
        , "lss census instQual arityOver by host top80: "
            ++ (if String.isEmpty iqArityOverHosts then
                    "(none)"

                else
                    iqArityOverHosts
               )
        , "lss census instQual noInstance by host top40: "
            ++ (if String.isEmpty iqNoInstanceHosts then
                    "(none)"

                else
                    iqNoInstanceHosts
               )
        , "lss census instQual declines by host top60: "
            ++ (if String.isEmpty iqHosts then
                    "(none)"

                else
                    iqHosts
               )
        , "lss census varSiteShapes (LVar callee shapes): "
            ++ (if String.isEmpty unknownShapes then
                    "(none)"

                else
                    unknownShapes
               )
        ]


{-| Builds the program as the module docstring describes and writes it to `target`
as MLIR text, in chunks as it is generated. The constant-thunk census is written
first, under `constThunksReport`.
-}
writeMonoMlirStreaming :
    Config.EcoConfig
    -> FEStats.Handle
    -> FilePath
    -> Maybe String
    -> List ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> FilePath
    -> Task Exit.Generate ()
writeMonoMlirStreaming ecoConfig stats root maybeBuildDir localPackages details artifacts target =
    buildMonoGraph ecoConfig stats root maybeBuildDir localPackages details artifacts
        |> Task.andThen
            (\{ monoGraph, mode } ->
                constThunkCensus ecoConfig monoGraph
                    |> Task.andThen
                        (\_ ->
                            FEStats.withPhaseLazy stats
                                FEStats.PhaseMlir
                                (\() ->
                                    File.withStreamingWriter target
                                        (\writeChunk ->
                                            MLIR.streamMlirToWriter ecoConfig mode monoGraph writeChunk
                                        )
                                        |> Task.mapError never
                                )
                        )
            )


{-| Builds the program as `writeMonoMlirStreaming` does and writes it to `target`
as MLIR bytecode.
-}
writeMonoMlirStreamingBytecode :
    Config.EcoConfig
    -> FEStats.Handle
    -> FilePath
    -> Maybe String
    -> List ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> FilePath
    -> Task Exit.Generate ()
writeMonoMlirStreamingBytecode ecoConfig stats root maybeBuildDir localPackages details artifacts target =
    buildMonoGraph ecoConfig stats root maybeBuildDir localPackages details artifacts
        |> Task.andThen
            (\{ monoGraph, mode } ->
                constThunkCensus ecoConfig monoGraph
                    |> Task.andThen
                        (\_ ->
                            FEStats.withPhaseLazy stats
                                FEStats.PhaseMlir
                                (\() ->
                                    MLIR.streamMlirBytecode ecoConfig mode monoGraph target
                                        |> Task.mapError never
                                )
                        )
            )


{-| Writes the constant-thunk census (`Compiler.Generate.MLIR.Backend.constThunkReport`)
to stderr when `constThunksReport` is on.
-}
constThunkCensus : Config.EcoConfig -> Mono.MonoGraph -> Task x ()
constThunkCensus ecoConfig monoGraph =
    if ecoConfig.constThunksReport then
        Task.io (System.IO.writeLn System.IO.stderr (MLIR.constThunkReport ecoConfig monoGraph))

    else
        Task.succeed ()


{-| Merges an outside root's typed graph into `graph`. An inside root, or an outside root with no typed graph, leaves it unchanged.
-}
addRootTypedGraph : Build.Root -> TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
addRootTypedGraph root graph =
    case root of
        Build.Inside _ ->
            -- Inside roots are already in the modules list
            graph

        Build.Outside _ _ _ maybeTypedGraph _ ->
            case maybeTypedGraph of
                Just typedGraph ->
                    GA.addTypedLocalGraph typedGraph graph

                Nothing ->
                    graph


{-| Adds an outside root's type env to `globalEnv`. An inside root, or an outside root with no type env, leaves it unchanged.
-}
addRootTypeEnv : Build.Root -> TypeEnv.GlobalTypeEnv -> TypeEnv.GlobalTypeEnv
addRootTypeEnv root globalEnv =
    case root of
        Build.Inside _ ->
            -- Inside roots are already in the modules list
            globalEnv

        Build.Outside _ _ _ _ maybeTypeEnv ->
            case maybeTypeEnv of
                Just modEnv ->
                    Data.Map.insert ModuleName.toComparableCanonical modEnv.home modEnv globalEnv

                Nothing ->
                    globalEnv
