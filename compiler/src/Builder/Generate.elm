module Builder.Generate exposing
    ( javascriptBackend
    , dev, debug
    , prod
    , repl
    , MonoBuildResult, writeMonoMlirStreaming, writeMonoMlirStreamingBytecode
    )

{-| Code generation orchestration for the Elm compiler.

This module coordinates the transformation of compiled Elm code into executable output
through various code generation backends. It handles loading optimized artifacts from
disk, preparing them for code generation, and invoking the appropriate backend to
produce JavaScript, MLIR, or other target code.


# Code Generation Backends

@docs javascriptBackend


# Development Builds

@docs dev, debug


# Production Builds

@docs prod


# REPL Code Generation

@docs repl


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
import Compiler.AST.Canonical as Can
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
import Compiler.Nitpick.Debug as Nitpick
import Compiler.Reporting.Render.Type.Localizer as L
import Data.Map
import Dict exposing (Dict)
import System.IO exposing (FilePath, MVar)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== BACKENDS ======
{- NOTE: This is used by Make, Repl, and Reactor right now. But it may be
   desirable to have Repl and Reactor to keep foreign objects in memory
   to make things a bit faster?
-}


{-| Standard JavaScript code generation backend.
-}
javascriptBackend : CodeGen.CodeGen
javascriptBackend =
    JavaScript.backend



-- ====== GENERATORS ======


{-| Generates debug-mode output with type information for runtime type checking.
-}
debug : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
debug backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen (loadTypesAndFinalize root maybeBuildDir artifacts.deps artifacts.modules)
        |> Task.andThen (generateDebugOutput backend withSourceMaps leadingLines root artifacts.pkg artifacts.roots)


loadTypesAndFinalize : FilePath -> Maybe String -> Data.Map.Dict String ModuleName.Canonical I.DependencyInterface -> List Build.Module -> LoadingObjects -> Task Exit.Generate ( Objects, Extract.Types )
loadTypesAndFinalize root maybeBuildDir ifaces modules loading =
    loadTypes root maybeBuildDir ifaces modules
        |> Task.andThen (finalizeObjectsWithTypes loading)


finalizeObjectsWithTypes : LoadingObjects -> Extract.Types -> Task Exit.Generate ( Objects, Extract.Types )
finalizeObjectsWithTypes loading types =
    finalizeObjects loading
        |> Task.map (\objects -> ( objects, types ))


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


generateWithBackend : CodeGen.CodeGen -> Int -> Mode.Mode -> Opt.GlobalGraph -> Data.Map.Dict String ModuleName.Canonical Opt.Main -> CodeGen.SourceMaps -> CodeGen.Output
generateWithBackend backend leadingLines mode graph mains sourceMaps =
    backend.generate
        { sourceMaps = sourceMaps
        , leadingLines = leadingLines
        , mode = mode
        , graph = graph
        , mains = mains
        }


{-| Generates development-mode output without optimization.
-}
dev : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
dev backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen finalizeObjects
        |> Task.andThen (generateDevOutput backend withSourceMaps leadingLines root artifacts.pkg artifacts.roots)


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


{-| Generates production-mode output with optimizations and minified field names.
-}
prod : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
prod backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen finalizeObjects
        |> Task.andThen (checkDebugAndGenerate backend withSourceMaps leadingLines root artifacts.pkg artifacts.roots)


checkDebugAndGenerate : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Pkg.Name -> NE.Nonempty Build.Root -> Objects -> Task Exit.Generate CodeGen.Output
checkDebugAndGenerate backend withSourceMaps leadingLines root pkg roots objects =
    checkForDebugUses objects
        |> Task.andThen (\_ -> generateProdOutput backend withSourceMaps leadingLines root pkg roots objects)


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


prepareSourceMaps : Bool -> FilePath -> Task Exit.Generate CodeGen.SourceMaps
prepareSourceMaps withSourceMaps root =
    if withSourceMaps then
        Outline.getAllModulePaths root
            |> Task.andThen (Utils.mapTraverse ModuleName.toComparableCanonical ModuleName.compareCanonical File.readUtf8)
            |> Task.map CodeGen.SourceMaps
            |> Task.io

    else
        Task.succeed CodeGen.NoSourceMaps


{-| Generates code for REPL evaluation with type annotation display.
-}
repl : CodeGen.CodeGen -> FilePath -> Details.Details -> Bool -> Build.ReplArtifacts -> N.Name -> Task Exit.Generate CodeGen.Output
repl backend root details ansi (Build.ReplArtifacts replArtifacts) name =
    loadObjects root Nothing details replArtifacts.modules
        |> Task.andThen finalizeObjects
        |> Task.map (generateReplOutput backend ansi replArtifacts.localizer replArtifacts.home name replArtifacts.annotations)


generateReplOutput : CodeGen.CodeGen -> Bool -> L.Localizer -> ModuleName.Canonical -> N.Name -> Dict N.Name (Can.Annotation Name) -> Objects -> CodeGen.Output
generateReplOutput backend ansi localizer home name annotations objects =
    let
        graph : Opt.GlobalGraph
        graph =
            objectsToGlobalGraph objects
    in
    backend.generateForRepl
        { ansi = ansi
        , localizer = localizer
        , graph = graph
        , home = home
        , name = name
        , annotation = Utils.dictFind name annotations
        }



-- ====== CHECK FOR DEBUG ======


checkForDebugUses : Objects -> Task Exit.Generate ()
checkForDebugUses (Objects _ locals) =
    case Dict.keys (Dict.filter (\_ -> Nitpick.hasDebugUses) locals) of
        [] ->
            Task.succeed ()

        m :: ms ->
            Task.throw (Exit.GenerateCannotOptimizeDebugValues m ms)



-- ====== GATHER MAINS ======


gatherMains : Pkg.Name -> Objects -> NE.Nonempty Build.Root -> Data.Map.Dict String ModuleName.Canonical Opt.Main
gatherMains pkg (Objects _ locals) roots =
    Data.Map.fromList ModuleName.toComparableCanonical (List.filterMap (lookupMain pkg locals) (NE.toList roots))


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


type LoadingObjects
    = LoadingObjects (MVar (Maybe Opt.GlobalGraph)) (Dict ModuleName.Raw (MVar (Maybe Opt.LocalGraph))) (Dict ModuleName.Raw Opt.LocalGraph)


loadObjects : FilePath -> Maybe String -> Details.Details -> List Build.Module -> Task Exit.Generate LoadingObjects
loadObjects root maybeBuildDir details modules =
    Task.io
        (Details.loadObjects root maybeBuildDir details
            |> Task.andThen (loadModuleObjects root maybeBuildDir modules)
        )


loadModuleObjects : FilePath -> Maybe String -> List Build.Module -> MVar (Maybe Opt.GlobalGraph) -> Task Never LoadingObjects
loadModuleObjects root maybeBuildDir modules mvar =
    let
        -- Partition: Fresh modules have their graph in memory, Cached need MVar I/O
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


loadCachedObject : FilePath -> Maybe String -> Build.Module -> Task Never ( ModuleName.Raw, MVar (Maybe Opt.LocalGraph) )
loadCachedObject root maybeBuildDir modul =
    case modul of
        Build.Cached name _ _ ->
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadCachedObject root maybeBuildDir name)

        Build.Fresh name _ _ _ _ ->
            -- Should not reach here after partitioning, but handle gracefully
            Utils.newMVar (Utils.maybeEncoder Opt.localGraphEncoder) (Just (Opt.LocalGraph Nothing Data.Map.empty Dict.empty))
                |> Task.map (\mv -> ( name, mv ))


forkLoadCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Opt.LocalGraph) -> Task Never ( ModuleName.Raw, MVar (Maybe Opt.LocalGraph) )
forkLoadCachedObject root maybeBuildDir name mvar =
    Utils.forkIO (readAndStoreCachedObject root maybeBuildDir name mvar)
        |> Task.map (\_ -> ( name, mvar ))


readAndStoreCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Opt.LocalGraph) -> Task Never ()
readAndStoreCachedObject root maybeBuildDir name mvar =
    File.readBinary Opt.localGraphDecoder (Stuff.ecoWithBuildDir root maybeBuildDir name)
        |> Task.andThen (Utils.putMVar (Utils.maybeEncoder Opt.localGraphEncoder) mvar)



-- ====== FINALIZE OBJECTS ======


type Objects
    = Objects Opt.GlobalGraph (Dict ModuleName.Raw Opt.LocalGraph)


finalizeObjects : LoadingObjects -> Task Exit.Generate Objects
finalizeObjects (LoadingObjects mvar mvars freshModules) =
    Task.eio identity
        (Utils.takeMVar (BD.maybe Opt.globalGraphDecoder) mvar
            |> Task.andThen (collectLocalObjects mvars freshModules)
        )


collectLocalObjects : Dict ModuleName.Raw (MVar (Maybe Opt.LocalGraph)) -> Dict ModuleName.Raw Opt.LocalGraph -> Maybe Opt.GlobalGraph -> Task Never (Result Exit.Generate Objects)
collectLocalObjects mvars freshModules globalResult =
    Utils.dictTraverse (Utils.takeMVar (BD.maybe Opt.localGraphDecoder)) mvars
        |> Task.map (combineGlobalAndLocalObjects globalResult freshModules)


combineGlobalAndLocalObjects : Maybe Opt.GlobalGraph -> Dict ModuleName.Raw Opt.LocalGraph -> Dict ModuleName.Raw (Maybe Opt.LocalGraph) -> Result Exit.Generate Objects
combineGlobalAndLocalObjects globalResult freshModules cachedResults =
    case ( globalResult, Utils.dictSequenceMaybe cachedResults ) of
        ( Just globals, Just cachedLocals ) ->
            -- Merge fresh (already have graphs) with cached (loaded from MVars)
            Ok (Objects globals (Dict.union cachedLocals freshModules))

        _ ->
            Err Exit.GenerateCannotLoadArtifacts


objectsToGlobalGraph : Objects -> Opt.GlobalGraph
objectsToGlobalGraph (Objects globals locals) =
    Dict.foldr (\_ -> GA.addOptLocalGraph) globals locals



-- ====== LOAD TYPES ======


loadTypes : FilePath -> Maybe String -> Data.Map.Dict String ModuleName.Canonical I.DependencyInterface -> List Build.Module -> Task Exit.Generate Extract.Types
loadTypes root maybeBuildDir ifaces modules =
    let
        -- Partition: Fresh modules already have interfaces in memory
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


collectAndMergeTypes : Data.Map.Dict String ModuleName.Canonical I.DependencyInterface -> List Extract.Types -> List (MVar (Maybe Extract.Types)) -> Task Never (Result Exit.Generate Extract.Types)
collectAndMergeTypes ifaces freshTypes mvars =
    let
        foreigns : Extract.Types
        foreigns =
            Extract.mergeMany (Data.Map.values ModuleName.compareCanonical (Data.Map.map Extract.fromDependencyInterface ifaces))
    in
    Utils.listTraverse (Utils.takeMVar (BD.maybe Extract.typesDecoder)) mvars
        |> Task.map (mergeLoadedTypes foreigns freshTypes)


mergeLoadedTypes : Extract.Types -> List Extract.Types -> List (Maybe Extract.Types) -> Result Exit.Generate Extract.Types
mergeLoadedTypes foreigns freshTypes cachedResults =
    case Utils.sequenceListMaybe cachedResults of
        Just ts ->
            Ok (Extract.merge foreigns (Extract.mergeMany (freshTypes ++ ts)))

        Nothing ->
            Err Exit.GenerateCannotLoadArtifacts


loadTypesFromCached : FilePath -> Maybe String -> Build.Module -> Task Never (MVar (Maybe Extract.Types))
loadTypesFromCached root maybeBuildDir modul =
    case modul of
        Build.Cached name _ ciMVar ->
            Utils.readMVar Build.cachedInterfaceDecoder ciMVar
                |> Task.andThen (handleCachedInterfaceForTypes root maybeBuildDir name)

        Build.Fresh name iface _ _ _ ->
            -- Should not reach here after partitioning
            Utils.newMVar (Utils.maybeEncoder Extract.typesEncoder) (Just (Extract.fromInterface name iface))


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


forkLoadInterfaceTypes : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Extract.Types) -> Task Never (MVar (Maybe Extract.Types))
forkLoadInterfaceTypes root maybeBuildDir name mvar =
    Utils.forkIO (loadAndStoreInterfaceTypes root maybeBuildDir name mvar)
        |> Task.map (\_ -> mvar)


loadAndStoreInterfaceTypes : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Extract.Types) -> Task Never ()
loadAndStoreInterfaceTypes root maybeBuildDir name mvar =
    File.readBinary I.interfaceDecoder (Stuff.eciWithBuildDir root maybeBuildDir name)
        |> Task.andThen (\maybeIface -> Utils.putMVar (Utils.maybeEncoder Extract.typesEncoder) mvar (Maybe.map (Extract.fromInterface name) maybeIface))



-- ====== TYPED OBJECTS LOADING ======


{-| Typed loading state: global artifacts MVar, list of cached module names
(for sequential .ecot loading), Fresh modules dict, and root/buildDir for file paths.
-}
type TypedLoadingObjects
    = TypedLoadingObjects (MVar (Maybe Details.PackageTypedArtifacts)) (List ModuleName.Raw) (Dict ModuleName.Raw ModuleTyped) FilePath (Maybe String)


loadTypedObjects : FilePath -> Maybe String -> Maybe ( Pkg.Name, FilePath ) -> Details.Details -> List Build.Module -> Task Exit.Generate TypedLoadingObjects
loadTypedObjects root maybeBuildDir maybeLocal details modules =
    Task.io
        (Details.loadTypedObjects maybeLocal details
            |> Task.andThen (loadTypedModuleObjects root maybeBuildDir modules)
        )


loadTypedModuleObjects : FilePath -> Maybe String -> List Build.Module -> MVar (Maybe Details.PackageTypedArtifacts) -> Task Never TypedLoadingObjects
loadTypedModuleObjects root maybeBuildDir modules mvar =
    let
        -- Partition: Fresh modules with typed data go directly, others need .ecot loading
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
    -- No MVars needed — cached modules will be loaded sequentially during merge
    Task.succeed (TypedLoadingObjects mvar cachedNames freshDict root maybeBuildDir)



-- ====== FINALIZE TYPED OBJECTS ======


{-| Combined typed data for a module.
-}
type alias ModuleTyped =
    { graph : TOpt.LocalGraph Name
    , env : TypeEnv.ModuleTypeEnv
    }


{-| Merged typed data: GlobalGraph + GlobalTypeEnv, ready for monomorphization.
Per-module data has been merged and discarded.
-}
type MergedTypedData
    = MergedTypedData (TOpt.GlobalGraph Name) TypeEnv.GlobalTypeEnv


{-| Finalize typed objects by sequentially loading and merging per-module data
into GlobalGraph/GlobalTypeEnv. Each .ecot file is loaded, deserialized, merged,
and discarded before the next is loaded. Only one module's data is alive at a
time (plus the growing merged structures), avoiding the ~1400MB peak from
loading all 232 modules simultaneously.
-}
finalizeAndMergeTypedObjects : TypedLoadingObjects -> Task Exit.Generate MergedTypedData
finalizeAndMergeTypedObjects (TypedLoadingObjects mvar cachedModulesList freshModules root maybeBuildDir) =
    Task.eio identity
        (Utils.takeMVar (BD.maybe Details.packageTypedArtifactsDecoder) mvar
            |> Task.andThen (streamLoadAndMerge cachedModulesList freshModules root maybeBuildDir)
        )


{-| Stream-load-and-merge: first merge Fresh modules (already in memory),
then sequentially load each cached module's .ecot file, merge, and discard.
-}
streamLoadAndMerge :
    List ModuleName.Raw
    -> Dict ModuleName.Raw ModuleTyped
    -> FilePath
    -> Maybe String
    -> Maybe Details.PackageTypedArtifacts
    -> Task Never (Result Exit.Generate MergedTypedData)
streamLoadAndMerge cachedNames freshModules root maybeBuildDir maybeGlobalArtifacts =
    let
        ( baseGraph, baseEnv ) =
            case maybeGlobalArtifacts of
                Nothing ->
                    ( TOpt.emptyGlobalGraph, TypeEnv.emptyGlobalTypeEnv )

                Just globalArtifacts ->
                    ( globalArtifacts.typedGraph, globalArtifacts.typeEnv )

        -- Merge Fresh modules (pure fold, no I/O needed)
        ( mergedGraph, mergedEnv ) =
            Dict.foldl
                (\_ modTyped ( g, e ) ->
                    ( GA.addTypedLocalGraph modTyped.graph g
                    , Data.Map.insert ModuleName.toComparableCanonical modTyped.env.home modTyped.env e
                    )
                )
                ( baseGraph, baseEnv )
                freshModules
    in
    -- Sequentially load and merge cached modules
    streamLoadAndMergeCached cachedNames root maybeBuildDir mergedGraph mergedEnv


{-| Sequentially load each cached module's .ecot file, merge into the running
GlobalGraph/GlobalTypeEnv, then discard. The per-module data goes out of scope
after merging, becoming GC-eligible before the next module is loaded.
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
                                -- artifact goes out of scope here; GC can reclaim it
                                streamLoadAndMergeCached rest root maybeBuildDir graph2 env2
                    )



-- ====== MONOMORPHIZED GENERATION ======


{-| Result of monomorphized code generation, containing the mono graph and compilation mode.
-}
type alias MonoBuildResult =
    { monoGraph : Mono.MonoGraph
    , mode : Mode.Mode
    }


buildMonoGraph :
    Config.EcoConfig
    -> FEStats.Handle
    -> FilePath
    -> Maybe String
    -> Maybe ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> Task Exit.Generate MonoBuildResult
buildMonoGraph ecoConfig stats root maybeBuildDir maybeLocal details (Build.Artifacts artifacts) =
    let
        roots =
            artifacts.roots

        -- Strip Opt.LocalGraph from Fresh modules: it's only needed by the JS backend,
        -- not the MLIR/monomorphization path. Without this, 232 Opt.LocalGraph structures
        -- are pinned in memory as dead weight throughout the entire pipeline.
        modules =
            List.map stripUntypedGraph artifacts.modules
    in
    -- Row 4 (plans/frontend-heap-release.md §7.2): drop the cached-interface
    -- MVars first. Nothing on the MLIR path reads them (only the JS debug
    -- path's `loadTypes` does), and an MVar is an off-heap GC root until
    -- dropped (HEAP_005). Never drop them inside Build: `checkRoot`'s
    -- `loadInterfaces` takes them.
    Task.io (Utils.listTraverse_ dropCachedInterfaceMVar artifacts.modules)
        |> Task.andThen (\_ -> loadTypedObjects root maybeBuildDir maybeLocal details modules)
        |> Task.andThen finalizeAndMergeTypedObjects
        |> Task.andThen (buildMonoGraphFromMerged ecoConfig stats roots)


dropCachedInterfaceMVar : Build.Module -> Task Never ()
dropCachedInterfaceMVar modul =
    case modul of
        Build.Cached _ _ mvar ->
            Utils.dropMVar mvar

        Build.Fresh _ _ _ _ _ ->
            Task.succeed ()


{-| Remove the untyped Opt.LocalGraph from a Fresh module.
The MLIR/monomorphization path only needs the typed graph and type env.
-}
stripUntypedGraph : Build.Module -> Build.Module
stripUntypedGraph modul =
    case modul of
        Build.Fresh name iface _ typedObjs typeEnv ->
            Build.Fresh name iface (Opt.LocalGraph Nothing Data.Map.empty Dict.empty) typedObjs typeEnv

        Build.Cached _ _ _ ->
            modul


buildMonoGraphFromMerged : Config.EcoConfig -> FEStats.Handle -> NE.Nonempty Build.Root -> MergedTypedData -> Task Exit.Generate MonoBuildResult
buildMonoGraphFromMerged ecoConfig stats roots (MergedTypedData mergedGraph mergedEnv) =
    let
        typedGraph : TOpt.GlobalGraph Name
        typedGraph =
            List.foldl addRootTypedGraph mergedGraph (NE.toList roots)

        globalTypeEnv : TypeEnv.GlobalTypeEnv
        globalTypeEnv =
            List.foldl addRootTypeEnv mergedEnv (NE.toList roots)

        -- PHASE 0 — `AssignMVarIds` runs HERE, in front of the pre-mono
        -- passes, so they operate on `MVarId`s rather than on names
        -- (`plans/pre-mono-lss-transforms-00-assign-mvar-ids-first.md`). It
        -- also synthesizes the entry's flags decoder, exactly as it did at
        -- each engine's own entry point. Identity therefore EXISTS during the
        -- pre-mono passes: anything they create or copy must mint through
        -- `PreMono.Fresh`, and `validateMinted` checks that under
        -- `mono.validate`.
        assigned : EntryPrep.Assigned
        assigned =
            EntryPrep.assign (assignFlagsFor ecoConfig) "main" typedGraph
    in
    -- Row 5 (plans/frontend-heap-release.md §7.3): assignment is its OWN step.
    -- This callback's argument (the merged Name-typed graph) is rooted until
    -- it returns, so handing `( assigned, globalTypeEnv )` to a following step
    -- is what lets the Name-typed graph die before the pre-mono rewrites.
    Task.succeed ( assigned, globalTypeEnv )
        |> Task.andThen (\( a, env ) -> runMonoOptPipeline ecoConfig stats env a)


{-| Run the monomorphization → inline+simplify → global optimization pipeline.

Each phase is a separate top-level function to break JS closure scope capture.
Without this separation, Elm's compiled JS closures capture the full enclosing scope,
pinning data from earlier phases (e.g., TypedObjects, typedGraph, globalTypeEnv)
through subsequent phases where they are no longer needed.

-}
runMonoOptPipeline : Config.EcoConfig -> FEStats.Handle -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Task Exit.Generate MonoBuildResult
runMonoOptPipeline ecoConfig stats globalTypeEnv assignedRaw =
    let
        -- `assignedRaw` is `EntryPrep.assign`'s result, computed in the
        -- previous step (`buildMonoGraphFromMerged`, row 5).
        --
        -- PRE-MONO ALIAS FORWARDING
        -- (plans/pre-mono-lss-transforms-04-alias-forwarding.md §3.6). Slot 2:
        -- FIRST after assignment, before η-expansion — item 1 reads the
        -- callee's declared arity, and after forwarding that is the target's.
        -- DEFAULT-ON since 2026-09-14 (call-stats Run 14); `ECO_INLINE_ALIAS_FORWARD=0`
        -- turns it off. With the flag
        -- off and `inline.report` on it runs as a CENSUS and returns the graph
        -- untouched (`pre-afwd-census:`); with both off it is not called.
        -- The pass mints nothing, so the id allocator passes through.
        ( assigned0, afwdMetrics ) =
            if ecoConfig.inline.aliasForward || ecoConfig.inline.report then
                let
                    ( gAfwd, stateAfwd, metrics ) =
                        AliasForward.run ecoConfig.inline assignedRaw.mvarState assignedRaw.graph
                in
                ( { assignedRaw | graph = gAfwd, mvarState = stateAfwd }, metrics )

            else
                ( assignedRaw, AliasForward.emptyMetrics )

        preAfwdReport =
            if ecoConfig.inline.report then
                Task.io
                    (System.IO.writeLn System.IO.stderr
                        (renderPreAliasForwardReport ecoConfig.inline.aliasForward afwdMetrics)
                    )

            else
                Task.succeed ()

        -- PRE-MONO ETA EXPANSION
        -- (plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md).
        -- Default OFF; `ECO_INLINE_ETA_EXPAND=1` turns it on. With BOTH the
        -- flag and `inline.report` off the pass is not called at all, so the
        -- default path does not so much as walk the graph (R9).
        --
        -- With `inline.report` on and the flag off it runs as a CENSUS: `run`
        -- classifies every body and returns the graph and the id allocator
        -- UNTOUCHED, which is Step 1's measurement — the deficit histogram and
        -- `cheapShare` that say whether the gate is tuned before a run is spent.
        --
        -- Placed BEFORE the pre-mono inliner (that plan's §2.8) so the inliner
        -- sees SATURATED calls rather than the 2-of-3 PAPs its `hofParam` guard
        -- declines, and before monomorphization because LSS runs inside the
        -- solver: the saturated shape has to exist by the time the analysis
        -- looks at it.
        ( assignedEta, etaMetrics ) =
            if ecoConfig.inline.etaExpand || ecoConfig.inline.report then
                let
                    ( gEta, stateEta, metrics ) =
                        EtaExpand.run ecoConfig.inline assigned0.mvarState assigned0.graph
                in
                ( { assigned0 | graph = gEta, mvarState = stateEta }, metrics )

            else
                ( assigned0, EtaExpand.emptyMetrics )

        preEtaReport =
            if ecoConfig.inline.report then
                Task.io
                    (System.IO.writeLn System.IO.stderr
                        (renderPreEtaReport ecoConfig.inline.etaExpand etaMetrics)
                    )

            else
                Task.succeed ()

        -- PRE-MONO inliner (plans/pre-mono-inline-simplify.md). DEFAULT-OFF
        -- again since 2026-09-15 (call-stats Runs 17-20: +0.29 % generic
        -- dispatch for 484 bytes, after `aliasForward` took over its
        -- population); `ECO_INLINE_PRE_MONO=1` turns it on.
        ( assigned1, preInlineMetrics ) =
            if ecoConfig.inline.preMono then
                let
                    ( g1, state1, metrics ) =
                        InlineSimplify.optimize ecoConfig.inline assignedEta.mvarState assignedEta.graph
                in
                ( { assignedEta | graph = g1, mvarState = state1 }, metrics )

            else
                ( assignedEta, InlineSimplify.emptyMetrics )

        preInlineReport =
            if ecoConfig.inline.report then
                Task.io
                    (System.IO.writeLn System.IO.stderr
                        (renderPreInlineReport preInlineMetrics)
                    )

            else
                Task.succeed ()

        -- CENSUS ONLY, no rewrite
        -- (plans/pre-mono-lss-transforms-03-lift-closed-lambda-args.md §5
        -- layer C). Runs on the graph the lift would see: after η-expansion
        -- and after the pre-mono inliner, which is where §3.5 puts the pass.
        -- There is no flag because there is no transform yet — the plan is
        -- census-gated and this is the gate's own instrument.
        preLiftReport =
            if ecoConfig.inline.report then
                Task.io
                    (System.IO.writeLn System.IO.stderr
                        (renderPreLiftReport (LiftClosedArgs.census assigned1.graph))
                    )

            else
                Task.succeed ()
    in
    preAfwdReport
        |> Task.andThen (\_ -> preEtaReport)
        |> Task.andThen (\_ -> preInlineReport)
        |> Task.andThen (\_ -> preLiftReport)
        |> Task.andThen (\_ -> validateMinted ecoConfig assigned1)
        |> Task.andThen
            (\_ ->
                monoPipelineFrom ecoConfig stats globalTypeEnv assigned1
            )


{-| The assignment flags for the selected engine. The solver passes its
`LssConfig`'s; the subst and diff engines pass `( False, False )` — changing
those would move their output.
-}
assignFlagsFor : Config.EcoConfig -> ( Bool, Bool )
assignFlagsFor ecoConfig =
    case ecoConfig.mono.engine of
        Config.EngineSolver ->
            ( True, ecoConfig.mono.lss.arrowCensus )

        Config.EngineSubst ->
            ( False, False )

        Config.EngineDiff ->
            ( False, False )


{-| Under `mono.validate` (`ECO_MONO_VALIDATE=1`), check that every pre-mono
pass minted identity for what it created and copied.

The DUPLICATE-id half is the one that earns its keep: a missing id declines
visibly, a repeated one is two bodies under a single member and is silent.

-}
validateMinted : Config.EcoConfig -> EntryPrep.Assigned -> Task Exit.Generate ()
validateMinted ecoConfig assigned =
    if ecoConfig.mono.validate then
        case Fresh.assertMinted assigned.graph of
            Ok () ->
                Task.succeed ()

            Err message ->
                Task.throw
                    (Exit.GenerateMonomorphizationError
                        ("pre-mono identity validator: " ++ message)
                    )

    else
        Task.succeed ()


{-| Under `mono.validate` (`ECO_MONO_VALIDATE=1`), check that the post-inline
prune left the graph CLOSED: every `MonoVarGlobal` in a live node names a live
node (`plans/post-inline-dead-spec-prune.md` §4 R1, MONO\_011).

This is the gate on the one real risk in that pass. Reachability is only as
good as the adjacency it walks, and an adjacency that misses a reference
shape prunes a live spec — which is silent here and surfaces as a CGEN\_044
dangling `eco.call` at lowering, or as a crash. An earlier prune attempt
(`plans/prune-bitset-calledges-reachability.md`) failed exactly this way
across 702 tests. Checking closure directly costs one walk under a flag and
cannot share a blind spot with the collector, because it matches the same
single constructor from the other side.

-}
validatePruned : Config.EcoConfig -> Mono.MonoGraph -> Task Exit.Generate ()
validatePruned ecoConfig (Mono.MonoGraph record) =
    if not (ecoConfig.mono.validate && ecoConfig.inline.pruneDead) then
        Task.succeed ()

    else
        let
            isLive specId =
                case Array.get specId record.nodes of
                    Just (Just _) ->
                        True

                    _ ->
                        False

            -- Hoisted: `collectSpecEdges` walks the whole graph, so computing
            -- it inside the fold would be quadratic in the spec count.
            edges =
                MonoTraverse.collectSpecEdges record.nodes

            dangling =
                Array.foldl
                    (\entry ( specId, acc ) ->
                        case entry of
                            Nothing ->
                                ( specId + 1, acc )

                            Just _ ->
                                ( specId + 1
                                , case Array.get specId edges |> Maybe.andThen identity of
                                    Just targets ->
                                        List.foldl
                                            (\t a ->
                                                if isLive t then
                                                    a

                                                else
                                                    ( specId, t ) :: a
                                            )
                                            acc
                                            targets

                                    Nothing ->
                                        acc
                                )
                    )
                    ( 0, [] )
                    record.nodes
                    |> Tuple.second
        in
        case dangling of
            [] ->
                Task.succeed ()

            ( from, to ) :: rest ->
                Task.throw
                    (Exit.GenerateMonomorphizationError
                        ("MONO_011: post-inline prune removed a LIVE specialization — spec "
                            ++ String.fromInt from
                            ++ " references pruned spec "
                            ++ String.fromInt to
                            ++ " ("
                            ++ String.fromInt (1 + List.length rest)
                            ++ " dangling references in total). The edge collector "
                            ++ "(MonoTraverse.collectSpecEdges) missed a reference shape."
                        )
                    )


monoPipelineFrom : Config.EcoConfig -> FEStats.Handle -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Task Exit.Generate MonoBuildResult
monoPipelineFrom ecoConfig stats globalTypeEnv assigned =
    FEStats.withPhaseLazy stats
        FEStats.PhaseMono
        (\() ->
            case selectMonomorphizer ecoConfig globalTypeEnv assigned of
            Err err ->
                Task.throw (Exit.GenerateMonomorphizationError err)

            Ok ( monoGraph0, maybeLssReport ) ->
                (case maybeLssReport of
                    Just report ->
                        -- LSS census (lss.report / ECO_MONO_LSS_REPORT=1):
                        -- stderr side-channel, never stdout (MLIR text mode
                        -- owns stdout).
                        Task.io (System.IO.writeLn System.IO.stderr report)
                            |> Task.map (\_ -> monoGraph0)

                    Nothing ->
                        Task.succeed monoGraph0
                )
                    |> Task.andThen
                        (\g ->
                            -- MONO_029 layout-agreement validator
                            -- (ECO_MONO_VALIDATE=1): engine-agnostic, fails
                            -- the compile on any layout-disagreeing views.
                            if ecoConfig.mono.validate then
                                case ValidateLayout.validate g of
                                    [] ->
                                        Task.succeed g

                                    violations ->
                                        Task.throw
                                            (Exit.GenerateMonomorphizationError
                                                ("ECO_MONO_VALIDATE: "
                                                    ++ String.fromInt (List.length violations)
                                                    ++ " MONO_029 layout violations\n"
                                                    ++ String.join "\n" violations
                                                )
                                            )

                            else
                                Task.succeed g
                        )
        )
        -- Hand off to a separate function so typedGraph and globalTypeEnv go out of scope
        |> Task.andThen (runInlineSimplifyPhase ecoConfig stats)


{-| Choose the monomorphizer engine per `eco-config.json` / `ECO_MONO_ENGINE`.
`EngineSubst` (default) is the original engine; `EngineSolver` is the new
solver-based one; `EngineDiff` runs both and asserts their output matches. This
is the single production dispatch point between the two engines.
-}
selectMonomorphizer : Config.EcoConfig -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String ( Mono.MonoGraph, Maybe String )
selectMonomorphizer ecoConfig globalTypeEnv assigned =
    case ecoConfig.mono.engine of
        Config.EngineSubst ->
            Result.map (\g -> ( g, Nothing )) (Monomorphize.monomorphizeWithLimitsAssigned ecoConfig.mono.limits "main" globalTypeEnv assigned)

        Config.EngineSolver ->
            MonoSolver.monomorphizeWithReportAssigned ecoConfig.mono.lss ecoConfig.mono.limits "main" globalTypeEnv assigned

        Config.EngineDiff ->
            -- Diff forces lss off internally; no census.
            Result.map (\g -> ( g, Nothing )) (MonoDiff.runAssigned ecoConfig.mono.diffDump "main" globalTypeEnv assigned)


{-| Inline+simplify phase in its own scope so monomorphization inputs are GC-eligible.
-}
runInlineSimplifyPhase : Config.EcoConfig -> FEStats.Handle -> Mono.MonoGraph -> Task Exit.Generate MonoBuildResult
runInlineSimplifyPhase ecoConfig stats monoGraph0 =
    FEStats.withPhaseLazy stats
        FEStats.PhaseInlineSimplify
        (\() ->
         let
            -- list.chunks: keep the shunted combinators' call sites intact —
            -- their tiny delegate bodies (reverse = foldl cons [] etc.) are
            -- otherwise threshold-inlined everywhere, and the generation-time
            -- kernel shunt (Generate.MLIR.Functions.listChunksShunt) only
            -- rewrites the spec definitions, not pasted copies.
            chunkBlacklist =
                if ecoConfig.list.chunks then
                    [ "List.reverse", "List.append", "List.concat", "List.take", "List.drop" ]

                else
                    []

            -- list.mapTemplate: same reason, one rung up. The template
            -- replaces the `List.map` spec DEFINITION at generation time, so a
            -- foldr body already pasted into a caller would keep the old
            -- lowering and silently escape the template. Blacklisting is
            -- name-level and wholesale by necessity: entries are qualified
            -- source names matched by `globalToQualifiedName`, and this pass
            -- runs BEFORE GlobalOpt/AbiCloning, so the licensed SET does not
            -- exist yet and per-spec blacklisting is impossible. Consequence,
            -- stated honestly: with the flag on, UNLICENSED map sites are
            -- behaviourally identical to today but not necessarily
            -- byte-identical — their specs stop being inline candidates.
            -- Byte-identity is certified flag-OFF only (plan Gate 2).
            mapTemplateBlacklist =
                if ecoConfig.list.mapTemplate then
                    [ "List.map" ]

                else
                    []

            effectiveInlineConfig =
                case chunkBlacklist ++ mapTemplateBlacklist of
                    [] ->
                        ecoConfig.inline

                    extra ->
                        let
                            cfg =
                                ecoConfig.inline
                        in
                        { cfg | blacklist = cfg.blacklist ++ extra }

            -- `inline.postMono` (ECO_INLINE_POST_MONO=0) is the EARLY arm of
            -- the position A/B (plans/pre-mono-inline-simplify.md §7): it
            -- skips this pass so the pre-mono `InlineSimplify` is the only
            -- inliner running. DEFAULT-ON, so the default path is unchanged.
            ( inlinedGraph, inlineMetrics ) =
                if ecoConfig.inline.postMono then
                    MonoInlineSimplify.optimize effectiveInlineConfig monoGraph0

                else
                    ( monoGraph0, MonoInlineSimplify.emptyMetrics )
         in
         -- E-a (plans/frontend-heap-release.md §7.4): the prune and the census
         -- run in the NEXT step. This thunk captures `monoGraph0`, and the
         -- running callback stays rooted until it returns, so doing the prune
         -- here would keep the pre-inline graph live through it.
         Task.succeed ( inlinedGraph, inlineMetrics )
            |> Task.andThen (pruneAndReportInline ecoConfig)
        )
        -- Hand off to a separate function so monoGraph0 goes out of scope
        |> Task.andThen (runGlobalOptPhase ecoConfig ecoConfig.mono.lss.report ecoConfig.list.report ecoConfig.borrow ecoConfig.cafMemo ecoConfig.cse stats)


{-| The second step of the inline phase (E-a): the post-inline dead-spec prune,
the inline census and the prune validator. A top-level function so the step
captures only `ecoConfig`, never the pre-inline graph.
-}
pruneAndReportInline : Config.EcoConfig -> ( Mono.MonoGraph, MonoInlineSimplify.Metrics ) -> Task Exit.Generate Mono.MonoGraph
pruneAndReportInline ecoConfig ( inlinedGraph, inlineMetrics ) =
    let
        -- POST-INLINE DEAD-SPEC PRUNE
        -- (plans/post-inline-dead-spec-prune.md). The inliner orphans a
        -- specialization whenever it inlines the only reference to it, and
        -- nothing removed those: `Prune` runs at the END of
        -- monomorphization and the inliner returns `callEdges =
        -- Array.empty`. HERE is the only position where a
        -- `MonoVarGlobal`-reachability is exact — everything that
        -- references a spec by another route (AbiCloning's
        -- `fastEvaluatorSpec`, post-settle devirt targets, CafHoist's
        -- mints) runs after `runGlobalOptPhase`.
        simplifiedGraph =
            if ecoConfig.inline.pruneDead then
                Prune.pruneAfterInline inlinedGraph

            else
                inlinedGraph
    in
    if ecoConfig.inline.report then
        -- Inline census (inline.report / ECO_INLINE_REPORT=1): pass
        -- metrics + the static count of closures surviving the pass
        -- (HOF-elimination plan H0.2). stderr, like the LSS census.
        --
        -- Rendered over the PRUNED graph: `closuresRemaining` and the
        -- residual taxonomy counted closures in dead specs until the prune
        -- existed, so every one of those figures steps down once when it
        -- lands (plan §4 R3 — a correction, not a regression).
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


{-| Census line for pre-mono alias forwarding
(`plans/pre-mono-lss-transforms-04-alias-forwarding.md` §7).

`pre-afwd-census:` when the flag is off (the map was built and the walk
counted, nothing was rewritten) and `pre-afwd:` when it is on, so a log cannot
be misread as evidence that the rewrite happened.

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


{-| Census line for pre-mono η-expansion
(`plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md` §2.8).

`pre-eta-census:` when the flag is off (the classifier ran, nothing was
rewritten) and `pre-eta:` when it is on, so a log cannot be misread as evidence
that the rewrite happened.

`bodiesSeen` is the denominator whose zero is impossible — the pre-mono
inliner's lesson: `defs = 0` reads identically whether the pass refused
everything or matched no node shape at all.

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


{-| Census line for the closed-lambda-argument LIFT
(`plans/pre-mono-lss-transforms-03-lift-closed-lambda-args.md` §5 layer C).

Named `pre-lift-census:`, never `pre-lift:` — there is no transform behind it,
and the η line's lesson is that a census must not be readable as evidence that
a rewrite happened.

`candidates` is the denominator whose zero is impossible; `closed` is the §5
build gate's number and `liftable` is that number after R1 removes the callees
loopify would claim.

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


{-| Census line for the PRE-mono inliner (`plans/pre-mono-inline-simplify.md`).
Deliberately mirrors the `inline-simplify:` line's leading fields so the two
positions can be diffed directly.
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


{-| Top-N entries of a count dict, largest first, as `k=v` tokens.
-}
top : Int -> Dict String Int -> String
top n d =
    Dict.toList d
        |> List.sortBy (\( _, v ) -> negate v)
        |> List.take n
        |> List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
        |> String.join " "


renderInlineReport : MonoInlineSimplify.Metrics -> Mono.MonoGraph -> String
renderInlineReport m graph =
    renderInlineReportWith Config.default.inline m graph


{-| Census line for the post-inline dead-spec prune
(`plans/post-inline-dead-spec-prune.md` §3.5).

`pruned` is specs the prune removed, `kept` what survived; a `pruned=0` next to
a large `kept` is the flag being off, which the line says outright rather than
leaving the reader to infer. Pruned specs are attributed to their GLOBAL via
the pre-prune `reverseMapping`, because a spec id means nothing across compiles
and a global name is the join key to every other census here.

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
            ++ " closuresRemaining="
            ++ String.fromInt (MonoInlineSimplify.countClosures graph)

        -- P0 (plans/lss-inline-member-propagation.md §7): identity-clearing
        -- reshapes, and §7.1's use-shape split that decides §5 vs §6.
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


{-| Global optimization phase in its own scope so inline+simplify inputs are GC-eligible.

E-b (plans/frontend-heap-release.md §7.5): each pass is its OWN step —
GlobalOpt, CSE, CAF dedupe, CAF hoist — so a pass's input graph dies as soon as
the next pass has produced its output, instead of every intermediate being kept
by one eager `let` rooted at `simplifiedGraph`. The census lines that need an
intermediate graph are rendered to a `Maybe String` IN the step where that graph
is live (the `if` is outside any closure, §10 trap 2), and every stderr line is
still written in the original order by the last step.

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
            Task.succeed
                (MonoGlobalOptimize.globalOptimizeWithStats
                    mapTemplateCfg.mono.lss.stamp.census
                    borrowCfg
                    mapTemplateCfg.list.mapTemplate
                    simplifiedGraph
                )
                |> Task.andThen (globalOptCseStep cfg)
                |> Task.andThen (globalOptDedupeStep cfg)
                |> Task.andThen (globalOptHoistStep cfg)
                |> Task.andThen (globalOptReportStep cfg)
        )


{-| The configuration the GlobalOpt steps read (E-b). Flags and small records
only — never a graph.
-}
type alias GlobalOptCfg =
    { mapTemplateCfg : Config.EcoConfig
    , lssReport : Bool
    , listReport : Bool
    , borrowCfg : Config.BorrowConfig
    , cafMemo : Config.CafMemoConfig
    , cseCfg : Config.CseConfig
    }


{-| What the GlobalOpt steps carry besides the current graph: pass stats and
census lines already rendered from graphs that are now dead.
-}
type alias GlobalOptCarry =
    { goStats : MonoGlobalOptimize.GlobalOptStats
    , cseStats : MonoCse.Stats
    , cseCensus : Maybe String
    , dedupeStats : CafDedupe.Stats
    , cafCensusPre : Maybe String
    , hoistStats : CafHoist.Stats
    }


{-| kernel-opt-13 C2: bounded-scope CSE of pure calls. Runs HERE,
post-annotation, because it adds MonoLet bindings and annotateCallStaging is
O(2^let-depth); and BEFORE CafDedupe, so CSE never has to reason about specs
dedupe is about to merge away.
-}
globalOptCseStep : GlobalOptCfg -> ( Mono.MonoGraph, MonoGlobalOptimize.GlobalOptStats ) -> Task x ( Mono.MonoGraph, GlobalOptCarry )
globalOptCseStep cfg ( goGraph, goStats ) =
    let
        -- kernel-opt-13 C1 census, on `goGraph` -- the same object
        -- `MonoCse.run` consumes, so the census numbers and the pass's input
        -- are the same graph. Output-only.
        cseCensus =
            if cfg.cseCfg.report then
                Just (CseCensus.report "" cfg.cseCfg.minCost goGraph)

            else
                Nothing

        ( cseGraph, cseStats ) =
            if cfg.cseCfg.enabled then
                MonoCse.run
                    { minCost = cfg.cseCfg.minCost, maxPerDef = cfg.cseCfg.maxPerDef }
                    goGraph

            else
                ( goGraph, MonoCse.emptyStats )
    in
    Task.succeed
        ( cseGraph
        , { goStats = goStats
          , cseStats = cseStats
          , cseCensus = cseCensus
          , dedupeStats = CafDedupe.emptyStats
          , cafCensusPre = Nothing
          , hoistStats = CafHoist.emptyStats
          }
        )


{-| CAF spec dedupe (cafMemo.dedupe / ECO\_CAF\_DEDUPE=1): merge structurally
identical nullary specs BEFORE census/hoist so downstream counts see the deduped
graph. Its stats line IS the dedupe census.
-}
globalOptDedupeStep : GlobalOptCfg -> ( Mono.MonoGraph, GlobalOptCarry ) -> Task x ( Mono.MonoGraph, GlobalOptCarry )
globalOptDedupeStep cfg ( cseGraph, carry ) =
    let
        ( optimizedGraph, dedupeStats ) =
            if cfg.cafMemo.dedupe then
                CafDedupe.run cseGraph

            else
                ( cseGraph, CafDedupe.emptyStats )

        -- Inner-CAF opportunity census (cafMemo.census / ECO_CAF_CENSUS=1)
        -- over the PRE-hoist graph: the opportunity baseline. stderr, like
        -- the LSS census.
        cafCensusPre =
            if cfg.cafMemo.census then
                Just (CafCensus.report "caf-census" { minNodes = cfg.cafMemo.hoist.minNodes } optimizedGraph)

            else
                Nothing
    in
    Task.succeed ( optimizedGraph, { carry | dedupeStats = dedupeStats, cafCensusPre = cafCensusPre } )


{-| CAF hoisting (plans/caf-hoist-closed-expressions.md DQ3 order: GlobalOpt →
census(pre) → hoist → hoist stats → census(post)).
-}
globalOptHoistStep : GlobalOptCfg -> ( Mono.MonoGraph, GlobalOptCarry ) -> Task x ( Mono.MonoGraph, GlobalOptCarry )
globalOptHoistStep cfg ( optimizedGraph, carry ) =
    let
        ( hoistedGraph, hoistStats ) =
            if cfg.cafMemo.hoist.enabled then
                CafHoist.run
                    { minNodes = cfg.cafMemo.hoist.minNodes
                    , maxHoists = cfg.cafMemo.hoist.maxHoists
                    }
                    optimizedGraph

            else
                ( optimizedGraph, CafHoist.emptyStats )
    in
    Task.succeed ( hoistedGraph, { carry | hoistStats = hoistStats } )


{-| The last GlobalOpt step: every stderr line, in the original order, then the
result. Only the final (hoisted) graph is live here.
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
                    -- POST-hoist residue: the H2 collapse gate.
                    writeLnErr (CafCensus.report "caf-census(post-hoist)" censusCfg hoistedGraph)

                else
                    Task.succeed ()
            )
        |> Task.andThen
            (\_ ->
                if listReport then
                    -- List-combinator recognition census (list.report /
                    -- ECO_LIST_REPORT=1; chunked-list plan §6 L1.1).
                    -- stderr, like the LSS census; compared against the
                    -- L0 static census (§11.a) as the recognition gate.
                    writeLnErr (ListCombinators.report hoistedGraph)

                else
                    Task.succeed ()
            )
        |> Task.andThen
            (\_ ->
                if listReport then
                    -- List.map template licence census
                    -- (plans/list-map-mlir-template.md Gate 3:
                    -- licensed + declined* == recognized). Rides on the
                    -- same env flag as the combinator census and is
                    -- derived from the SAME graph codegen will see, so the
                    -- printed numbers are the numbers emission acts on.
                    -- The derivation is repeated here rather than threaded
                    -- out of Backend: this is a census-only path, and
                    -- paying CsePurity.analyze twice under
                    -- ECO_LIST_REPORT=1 is cheaper than a plumbing seam
                    -- that could drift from what emission actually used.
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
                    -- GlobalOpt census line (stderr, like the mono census above):
                    -- staging wrapper insertions + AbiCloning singleton-upgrade
                    -- outcomes (design §9.4's retirement counters).
                    Task.io
                        (System.IO.writeLn System.IO.stderr
                            ("lss globalopt: wrappersInserted="
                                ++ String.fromInt goStats.wrappersInserted
                                ++ " dispatchUpgraded="
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
                                ++ " stampedWrapperInstances="
                                ++ String.fromInt goStats.abiCloning.stampedWrapperInstances
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
                -- Borrow-inference census (borrow.report / ECO_BORROW_REPORT):
                -- the real B2 uniqueness/sharing oracle census. stderr,
                -- graph-inert.
                if borrowCfg.report then
                    writeLnErr (Borrow.renderStats goStats.borrow)
                        |> Task.map (\_ -> result)

                else
                    Task.succeed result
            )


{-| Census lines (2026-07-21, plans/lss-dispatch-value-extraction.md open
questions): per-member decline attribution (+ rep symbols for the runtime
census join), the multi-set site histogram (E3 de-risk), and the LTop
callee-shape split (E8 sizing). Report-only.
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

        -- Phase 1a/3: the "still a variable" half of the old undifferentiated
        -- ⊤ site population (plans/lss-unknown-elimination.md §2.5).
        unknownShapes =
            Dict.toList abi.varSiteShapes
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        -- The go/no-go table: per HOST global, how its consulted call sites
        -- resolved. The join key against the caller-attributed runtime
        -- dispatch census. UNTRUNCATED on purpose: a take ranked by site
        -- count silently drops hosts whose sites fragment across a rich key.
        iqHosts =
            Dict.toList abi.instQual.byHost
                |> List.filter (\( k, _ ) -> not (String.endsWith "|stamped" k))
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take 4000
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        -- arityOver is 34.8 % of all declines and hosts every hot fold
        -- callback (plans/lss-instance-qualified-members.md §12.5). Its own
        -- line, wide, because it is the successor target and the JOIN KEY for
        -- the caller-attributed dynamic census.
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

        -- LSS_026 §11: blocked members with their blocker instance — the
        -- adopting synthetic closure's symbol names the wrapped def.
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
                    -- key is `<host>|<why>` and `why` itself contains
                    -- `|` (e.g. `g3over|1->2|peelable`), so drop the
                    -- FIRST segment and rejoin the rest.
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


{-| Stream MLIR output directly to a file, avoiding holding the full text in memory.
-}
writeMonoMlirStreaming :
    Config.EcoConfig
    -> FEStats.Handle
    -> Bool
    -> Int
    -> FilePath
    -> Maybe String
    -> Maybe ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> FilePath
    -> Task Exit.Generate ()
writeMonoMlirStreaming ecoConfig stats _ _ root maybeBuildDir maybeLocal details artifacts target =
    buildMonoGraph ecoConfig stats root maybeBuildDir maybeLocal details artifacts
        |> Task.andThen
            (\{ monoGraph, mode } ->
                constThunkCensus ecoConfig monoGraph
                    |> Task.andThen (\_ ->
                FEStats.withPhaseLazy stats
                    FEStats.PhaseMlir
                    (\() ->
                        File.withStreamingWriter target
                        (\writeChunk ->
                            MLIR.streamMlirToWriter ecoConfig mode monoGraph writeChunk
                        )
                        |> Task.mapError never
                    ))
            )


{-| Generate MLIR bytecode using the streaming encoder.
Processes funcs one at a time to reduce peak memory usage.
-}
writeMonoMlirStreamingBytecode :
    Config.EcoConfig
    -> FEStats.Handle
    -> Bool
    -> Int
    -> FilePath
    -> Maybe String
    -> Maybe ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> FilePath
    -> Task Exit.Generate ()
writeMonoMlirStreamingBytecode ecoConfig stats _ _ root maybeBuildDir maybeLocal details artifacts target =
    buildMonoGraph ecoConfig stats root maybeBuildDir maybeLocal details artifacts
        |> Task.andThen
            (\{ monoGraph, mode } ->
                constThunkCensus ecoConfig monoGraph
                    |> Task.andThen (\_ ->
                FEStats.withPhaseLazy stats
                    FEStats.PhaseMlir
                    (\() ->
                        MLIR.streamMlirBytecode ecoConfig mode monoGraph target
                        |> Task.mapError never
                    ))
            )


{-| CGEN\_082 census (`ECO_CONST_THUNK_REPORT=1`): stderr, before codegen.
-}
constThunkCensus : Config.EcoConfig -> Mono.MonoGraph -> Task x ()
constThunkCensus ecoConfig monoGraph =
    if ecoConfig.constThunksReport then
        Task.io (System.IO.writeLn System.IO.stderr (MLIR.constThunkReport ecoConfig monoGraph))

    else
        Task.succeed ()


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
