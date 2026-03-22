module Builder.Generate exposing
    ( javascriptBackend
    , dev, debug
    , prod
    , repl
    , MonoBuildResult, writeMonoMlirStreaming
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

@docs MonoBuildResult, writeMonoMlirStreaming

-}

import Builder.Build as Build
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
import Compiler.Data.Name as N
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Compiler.Type.Extract as Extract
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.CodeGen.JavaScript as JavaScript
import Compiler.Generate.MLIR.Backend as MLIR
import Compiler.Generate.Mode as Mode
import Compiler.GlobalOpt.MonoGlobalOptimize as MonoGlobalOptimize
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.Nitpick.Debug as Nitpick
import Compiler.Reporting.Render.Type.Localizer as L
import Data.Map
import Dict exposing (Dict)
import System.IO as IO exposing (FilePath, MVar)
import System.TypeCheck.IO as TypeCheck
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


loadTypesAndFinalize : FilePath -> Maybe String -> Data.Map.Dict (List String) TypeCheck.Canonical I.DependencyInterface -> List Build.Module -> LoadingObjects -> Task Exit.Generate ( Objects, Extract.Types )
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


generateWithBackend : CodeGen.CodeGen -> Int -> Mode.Mode -> Opt.GlobalGraph -> Data.Map.Dict (List String) TypeCheck.Canonical Opt.Main -> CodeGen.SourceMaps -> CodeGen.Output
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


generateReplOutput : CodeGen.CodeGen -> Bool -> L.Localizer -> TypeCheck.Canonical -> N.Name -> Dict N.Name Can.Annotation -> Objects -> CodeGen.Output
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
    case Data.Map.keys compare (Data.Map.filter (\_ -> Nitpick.hasDebugUses) locals) of
        [] ->
            Task.succeed ()

        m :: ms ->
            Task.throw (Exit.GenerateCannotOptimizeDebugValues m ms)



-- ====== GATHER MAINS ======


gatherMains : Pkg.Name -> Objects -> NE.Nonempty Build.Root -> Data.Map.Dict (List String) TypeCheck.Canonical Opt.Main
gatherMains pkg (Objects _ locals) roots =
    Data.Map.fromList ModuleName.toComparableCanonical (List.filterMap (lookupMain pkg locals) (NE.toList roots))


lookupMain : Pkg.Name -> Data.Map.Dict String ModuleName.Raw Opt.LocalGraph -> Build.Root -> Maybe ( TypeCheck.Canonical, Opt.Main )
lookupMain pkg locals root =
    let
        toPair : N.Name -> Opt.LocalGraph -> Maybe ( TypeCheck.Canonical, Opt.Main )
        toPair name (Opt.LocalGraph maybeMain _ _) =
            Maybe.map (Tuple.pair (TypeCheck.Canonical pkg name)) maybeMain
    in
    case root of
        Build.Inside name ->
            Data.Map.get identity name locals |> Maybe.andThen (toPair name)

        Build.Outside name _ g _ _ ->
            toPair name g



-- ====== LOADING OBJECTS ======


type LoadingObjects
    = LoadingObjects
        (MVar (Maybe Opt.GlobalGraph))
        (Data.Map.Dict String ModuleName.Raw (MVar (Maybe Opt.LocalGraph)))
        (Data.Map.Dict String ModuleName.Raw Opt.LocalGraph)


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
            Data.Map.fromList identity freshPairs
    in
    Utils.listTraverse (loadCachedObject root maybeBuildDir) needLoading
        |> Task.map (\mvars -> LoadingObjects mvar (Data.Map.fromList identity mvars) freshDict)


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
    = Objects Opt.GlobalGraph (Data.Map.Dict String ModuleName.Raw Opt.LocalGraph)


finalizeObjects : LoadingObjects -> Task Exit.Generate Objects
finalizeObjects (LoadingObjects mvar mvars freshModules) =
    Task.eio identity
        (Utils.takeMVar (BD.maybe Opt.globalGraphDecoder) mvar
            |> Task.andThen (collectLocalObjects mvars freshModules)
        )


collectLocalObjects : Data.Map.Dict String ModuleName.Raw (MVar (Maybe Opt.LocalGraph)) -> Data.Map.Dict String ModuleName.Raw Opt.LocalGraph -> Maybe Opt.GlobalGraph -> Task Never (Result Exit.Generate Objects)
collectLocalObjects mvars freshModules globalResult =
    Utils.mapTraverse identity compare (Utils.takeMVar (BD.maybe Opt.localGraphDecoder)) mvars
        |> Task.map (combineGlobalAndLocalObjects globalResult freshModules)


combineGlobalAndLocalObjects : Maybe Opt.GlobalGraph -> Data.Map.Dict String ModuleName.Raw Opt.LocalGraph -> Data.Map.Dict String ModuleName.Raw (Maybe Opt.LocalGraph) -> Result Exit.Generate Objects
combineGlobalAndLocalObjects globalResult freshModules cachedResults =
    case ( globalResult, Utils.sequenceDictMaybe identity compare cachedResults ) of
        ( Just globals, Just cachedLocals ) ->
            -- Merge fresh (already have graphs) with cached (loaded from MVars)
            Ok (Objects globals (Data.Map.union cachedLocals freshModules))

        _ ->
            Err Exit.GenerateCannotLoadArtifacts


objectsToGlobalGraph : Objects -> Opt.GlobalGraph
objectsToGlobalGraph (Objects globals locals) =
    Data.Map.foldr compare (\_ -> GA.addOptLocalGraph) globals locals



-- ====== LOAD TYPES ======


loadTypes : FilePath -> Maybe String -> Data.Map.Dict (List String) TypeCheck.Canonical I.DependencyInterface -> List Build.Module -> Task Exit.Generate Extract.Types
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


collectAndMergeTypes : Data.Map.Dict (List String) TypeCheck.Canonical I.DependencyInterface -> List Extract.Types -> List (MVar (Maybe Extract.Types)) -> Task Never (Result Exit.Generate Extract.Types)
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
    = TypedLoadingObjects
        (MVar (Maybe Details.PackageTypedArtifacts))
        (List ModuleName.Raw)
        (Data.Map.Dict String ModuleName.Raw ModuleTyped)
        FilePath
        (Maybe String)


loadTypedObjects : FilePath -> Maybe String -> Maybe ( Pkg.Name, FilePath ) -> Details.Details -> List Build.Module -> Task Exit.Generate TypedLoadingObjects
loadTypedObjects root maybeBuildDir maybeLocal details modules =
    Task.io
        (Details.loadTypedObjects root maybeBuildDir maybeLocal details
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
            Data.Map.fromList identity freshPairs
    in
    -- No MVars needed — cached modules will be loaded sequentially during merge
    Task.succeed (TypedLoadingObjects mvar cachedNames freshDict root maybeBuildDir)





-- ====== FINALIZE TYPED OBJECTS ======


{-| Combined typed data for a module.
-}
type alias ModuleTyped =
    { graph : TOpt.LocalGraph
    , env : TypeEnv.ModuleTypeEnv
    }


{-| Merged typed data: GlobalGraph + GlobalTypeEnv, ready for monomorphization.
Per-module data has been merged and discarded.
-}
type MergedTypedData
    = MergedTypedData TOpt.GlobalGraph TypeEnv.GlobalTypeEnv


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
    -> Data.Map.Dict String ModuleName.Raw ModuleTyped
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
            Data.Map.foldl compare
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
    -> TOpt.GlobalGraph
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
    FilePath
    -> Maybe String
    -> Maybe ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> Task Exit.Generate MonoBuildResult
buildMonoGraph root maybeBuildDir maybeLocal details (Build.Artifacts artifacts) =
    let
        roots =
            artifacts.roots

        -- Strip Opt.LocalGraph from Fresh modules: it's only needed by the JS backend,
        -- not the MLIR/monomorphization path. Without this, 232 Opt.LocalGraph structures
        -- are pinned in memory as dead weight throughout the entire pipeline.
        modules =
            List.map stripUntypedGraph artifacts.modules
    in
    loadTypedObjects root maybeBuildDir maybeLocal details modules
        |> Task.andThen finalizeAndMergeTypedObjects
        |> Task.andThen (buildMonoGraphFromMerged roots)


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


buildMonoGraphFromMerged : NE.Nonempty Build.Root -> MergedTypedData -> Task Exit.Generate MonoBuildResult
buildMonoGraphFromMerged roots (MergedTypedData mergedGraph mergedEnv) =
    let
        typedGraph : TOpt.GlobalGraph
        typedGraph =
            List.foldl addRootTypedGraph mergedGraph (NE.toList roots)

        globalTypeEnv : TypeEnv.GlobalTypeEnv
        globalTypeEnv =
            List.foldl addRootTypeEnv mergedEnv (NE.toList roots)
    in
    runMonoOptPipeline typedGraph globalTypeEnv


{-| Run the monomorphization → inline+simplify → global optimization pipeline.

Each phase is a separate top-level function to break JS closure scope capture.
Without this separation, Elm's compiled JS closures capture the full enclosing scope,
pinning data from earlier phases (e.g., TypedObjects, typedGraph, globalTypeEnv)
through subsequent phases where they are no longer needed.
-}
runMonoOptPipeline : TOpt.GlobalGraph -> TypeEnv.GlobalTypeEnv -> Task Exit.Generate MonoBuildResult
runMonoOptPipeline typedGraph globalTypeEnv =
    logStderr "Monomorphization started..."
        |> Task.andThen
            (\_ ->
                Monomorphize.monomorphizeWithLog logStderr "main" globalTypeEnv typedGraph
                    |> Task.andThen
                        (\result ->
                            case result of
                                Err err ->
                                    Task.throw (Exit.GenerateMonomorphizationError err)

                                Ok monoGraph0 ->
                                    logStderr "Monomorphization done."
                                        |> Task.map (\_ -> monoGraph0)
                        )
            )
        -- Hand off to a separate function so typedGraph and globalTypeEnv go out of scope
        |> Task.andThen runInlineSimplifyPhase


{-| Inline+simplify phase in its own scope so monomorphization inputs are GC-eligible.
-}
runInlineSimplifyPhase : Mono.MonoGraph -> Task Exit.Generate MonoBuildResult
runInlineSimplifyPhase monoGraph0 =
    logStderr "Inline + simplify started..."
        |> Task.andThen
            (\_ ->
                let
                    ( simplifiedGraph, _ ) =
                        MonoInlineSimplify.optimize monoGraph0
                in
                logStderr "Inline + simplify done."
                    |> Task.map (\_ -> simplifiedGraph)
            )
        -- Hand off to a separate function so monoGraph0 goes out of scope
        |> Task.andThen runGlobalOptPhase


{-| Global optimization phase in its own scope so inline+simplify inputs are GC-eligible.
-}
runGlobalOptPhase : Mono.MonoGraph -> Task Exit.Generate MonoBuildResult
runGlobalOptPhase simplifiedGraph =
    logStderr "Global optimization started..."
        |> Task.andThen
            (\_ ->
                MonoGlobalOptimize.globalOptimizeWithLog logStderr simplifiedGraph
            )
        |> Task.andThen
            (\monoGraph ->
                logStderr "Global optimization done."
                    |> Task.map
                        (\_ ->
                            { monoGraph = monoGraph
                            , mode = Mode.Dev Nothing
                            }
                        )
            )


logStderr : String -> Task x ()
logStderr msg =
    Task.io (IO.writeLn IO.stderr msg)


{-| Stream MLIR output directly to a file, avoiding holding the full text in memory.
-}
writeMonoMlirStreaming :
    Bool
    -> Int
    -> FilePath
    -> Maybe String
    -> Maybe ( Pkg.Name, FilePath )
    -> Details.Details
    -> Build.Artifacts
    -> FilePath
    -> Task Exit.Generate ()
writeMonoMlirStreaming _ _ root maybeBuildDir maybeLocal details artifacts target =
    buildMonoGraph root maybeBuildDir maybeLocal details artifacts
        |> Task.andThen
            (\{ monoGraph, mode } ->
                File.withStreamingWriter target
                    (\writeChunk ->
                        MLIR.streamMlirToWriter mode monoGraph writeChunk
                    )
                    |> Task.mapError never
            )


addRootTypedGraph : Build.Root -> TOpt.GlobalGraph -> TOpt.GlobalGraph
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
