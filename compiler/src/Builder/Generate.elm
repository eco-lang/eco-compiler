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
    Task.eio identity
        (Utils.listTraverse (loadTypesHelp root maybeBuildDir) modules
            |> Task.andThen (collectAndMergeTypes ifaces)
        )


collectAndMergeTypes : Data.Map.Dict (List String) TypeCheck.Canonical I.DependencyInterface -> List (MVar (Maybe Extract.Types)) -> Task Never (Result Exit.Generate Extract.Types)
collectAndMergeTypes ifaces mvars =
    let
        foreigns : Extract.Types
        foreigns =
            Extract.mergeMany (Data.Map.values ModuleName.compareCanonical (Data.Map.map Extract.fromDependencyInterface ifaces))
    in
    Utils.listTraverse (Utils.takeMVar (BD.maybe Extract.typesDecoder)) mvars
        |> Task.map (mergeLoadedTypes foreigns)


mergeLoadedTypes : Extract.Types -> List (Maybe Extract.Types) -> Result Exit.Generate Extract.Types
mergeLoadedTypes foreigns results =
    case Utils.sequenceListMaybe results of
        Just ts ->
            Ok (Extract.merge foreigns (Extract.mergeMany ts))

        Nothing ->
            Err Exit.GenerateCannotLoadArtifacts


loadTypesHelp : FilePath -> Maybe String -> Build.Module -> Task Never (MVar (Maybe Extract.Types))
loadTypesHelp root maybeBuildDir modul =
    case modul of
        Build.Fresh name iface _ _ _ ->
            Utils.newMVar (Utils.maybeEncoder Extract.typesEncoder) (Just (Extract.fromInterface name iface))

        Build.Cached name _ ciMVar ->
            Utils.readMVar Build.cachedInterfaceDecoder ciMVar
                |> Task.andThen (handleCachedInterfaceForTypes root maybeBuildDir name)


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


type TypedLoadingObjects
    = TypedLoadingObjects
        (MVar (Maybe Details.PackageTypedArtifacts))
        (Data.Map.Dict String ModuleName.Raw (MVar (Maybe TMod.TypedModuleArtifact)))
        (Data.Map.Dict String ModuleName.Raw ModuleTyped)


loadTypedObjects : FilePath -> Maybe String -> Maybe ( Pkg.Name, FilePath ) -> Details.Details -> List Build.Module -> Task Exit.Generate TypedLoadingObjects
loadTypedObjects root maybeBuildDir maybeLocal details modules =
    Task.io
        (Details.loadTypedObjects root maybeBuildDir maybeLocal details
            |> Task.andThen (loadTypedModuleObjects root maybeBuildDir modules)
        )


loadTypedModuleObjects : FilePath -> Maybe String -> List Build.Module -> MVar (Maybe Details.PackageTypedArtifacts) -> Task Never TypedLoadingObjects
loadTypedModuleObjects root maybeBuildDir modules mvar =
    let
        -- Partition: Fresh modules with typed data go directly, others need MVar loading
        partition : List Build.Module -> ( List ( ModuleName.Raw, ModuleTyped ), List Build.Module ) -> ( List ( ModuleName.Raw, ModuleTyped ), List Build.Module )
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

                        _ ->
                            let
                                ( fresh, cached ) =
                                    acc
                            in
                            partition rest
                                ( fresh
                                , modul :: cached
                                )

        ( freshPairs, needLoading ) =
            partition modules ( [], [] )

        freshDict =
            Data.Map.fromList identity freshPairs
    in
    Utils.listTraverse (loadTypedObject root maybeBuildDir) needLoading
        |> Task.map (\mvars -> TypedLoadingObjects mvar (Data.Map.fromList identity mvars) freshDict)


loadTypedObject : FilePath -> Maybe String -> Build.Module -> Task Never ( ModuleName.Raw, MVar (Maybe TMod.TypedModuleArtifact) )
loadTypedObject root maybeBuildDir modul =
    case modul of
        Build.Fresh name _ _ _ _ ->
            -- Fresh without typed data (already filtered by partition above)
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadTypedCachedObject root maybeBuildDir name)

        Build.Cached name _ _ ->
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadTypedCachedObject root maybeBuildDir name)


forkLoadTypedCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe TMod.TypedModuleArtifact) -> Task Never ( ModuleName.Raw, MVar (Maybe TMod.TypedModuleArtifact) )
forkLoadTypedCachedObject root maybeBuildDir name mvar =
    Utils.forkIO (readAndStoreTypedCachedObject root maybeBuildDir name mvar)
        |> Task.map (\_ -> ( name, mvar ))


readAndStoreTypedCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe TMod.TypedModuleArtifact) -> Task Never ()
readAndStoreTypedCachedObject root maybeBuildDir name mvar =
    File.readBinary TMod.typedModuleArtifactDecoder (Stuff.ecotWithBuildDir root maybeBuildDir name)
        |> Task.andThen (storeTypedArtifactWithDefault mvar)


storeTypedArtifactWithDefault : MVar (Maybe TMod.TypedModuleArtifact) -> Maybe TMod.TypedModuleArtifact -> Task Never ()
storeTypedArtifactWithDefault mvar maybeArtifact =
    -- If .ecot file doesn't exist, return Nothing to signal an error
    -- This happens when modules were cached from a non-MLIR build
    Utils.putMVar (Utils.maybeEncoder TMod.typedModuleArtifactEncoder) mvar maybeArtifact



-- ====== FINALIZE TYPED OBJECTS ======


{-| Combined typed data for a module.
-}
type alias ModuleTyped =
    { graph : TOpt.LocalGraph
    , env : TypeEnv.ModuleTypeEnv
    }


type TypedObjects
    = TypedObjects TOpt.GlobalGraph TypeEnv.GlobalTypeEnv (Data.Map.Dict String ModuleName.Raw ModuleTyped)


finalizeTypedObjects : TypedLoadingObjects -> Task Exit.Generate TypedObjects
finalizeTypedObjects (TypedLoadingObjects mvar mvars freshModules) =
    Task.eio identity
        (Utils.takeMVar (BD.maybe Details.packageTypedArtifactsDecoder) mvar
            |> Task.andThen (collectTypedLocalArtifacts mvars freshModules)
        )


collectTypedLocalArtifacts : Data.Map.Dict String ModuleName.Raw (MVar (Maybe TMod.TypedModuleArtifact)) -> Data.Map.Dict String ModuleName.Raw ModuleTyped -> Maybe Details.PackageTypedArtifacts -> Task Never (Result Exit.Generate TypedObjects)
collectTypedLocalArtifacts mvars freshModules globalArtifacts =
    Utils.mapTraverse identity compare (Utils.takeMVar (BD.maybe TMod.typedModuleArtifactDecoder)) mvars
        |> Task.map (combineTypedGlobalAndLocalObjects freshModules globalArtifacts)


combineTypedGlobalAndLocalObjects : Data.Map.Dict String ModuleName.Raw ModuleTyped -> Maybe Details.PackageTypedArtifacts -> Data.Map.Dict String ModuleName.Raw (Maybe TMod.TypedModuleArtifact) -> Result Exit.Generate TypedObjects
combineTypedGlobalAndLocalObjects freshModules maybeGlobalArtifacts cachedResults =
    let
        -- Convert TypedModuleArtifact to ModuleTyped
        toModuleTyped : TMod.TypedModuleArtifact -> ModuleTyped
        toModuleTyped artifact =
            { graph = artifact.typedGraph
            , env = artifact.typeEnv
            }

        -- Sequence the dict of Maybe values from cached/MVar-loaded modules
        maybeCachedModules : Maybe (Data.Map.Dict String ModuleName.Raw ModuleTyped)
        maybeCachedModules =
            Utils.sequenceDictMaybe identity compare cachedResults
                |> Maybe.map (Data.Map.map (\_ -> toModuleTyped))

        -- Merge fresh (already ModuleTyped) with cached
        maybeLocalModules : Maybe (Data.Map.Dict String ModuleName.Raw ModuleTyped)
        maybeLocalModules =
            if Data.Map.isEmpty cachedResults then
                Just freshModules

            else
                Maybe.map (\cached -> Data.Map.union cached freshModules) maybeCachedModules
    in
    case ( maybeGlobalArtifacts, maybeLocalModules ) of
        ( Just globalArtifacts, Just localModules ) ->
            Ok (TypedObjects globalArtifacts.typedGraph globalArtifacts.typeEnv localModules)

        ( Nothing, Just localModules ) ->
            -- No package artifacts, just use empty globals
            Ok (TypedObjects TOpt.emptyGlobalGraph TypeEnv.emptyGlobalTypeEnv localModules)

        _ ->
            Err Exit.GenerateCannotLoadArtifacts


typedObjectsToGlobalGraph : TypedObjects -> TOpt.GlobalGraph
typedObjectsToGlobalGraph (TypedObjects globals _ locals) =
    Data.Map.foldr compare (\_ modTyped acc -> GA.addTypedLocalGraph modTyped.graph acc) globals locals


typedObjectsToGlobalTypeEnv : TypedObjects -> TypeEnv.GlobalTypeEnv
typedObjectsToGlobalTypeEnv (TypedObjects _ globalEnv locals) =
    -- Merge local module type envs into the global type env from packages
    Data.Map.foldr compare
        (\_ modTyped acc ->
            let
                modEnv : TypeEnv.ModuleTypeEnv
                modEnv =
                    modTyped.env
            in
            Data.Map.insert ModuleName.toComparableCanonical modEnv.home modEnv acc
        )
        globalEnv
        locals



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
        |> Task.andThen finalizeTypedObjects
        |> Task.andThen (buildMonoGraphFromObjects roots)


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


buildMonoGraphFromObjects : NE.Nonempty Build.Root -> TypedObjects -> Task Exit.Generate MonoBuildResult
buildMonoGraphFromObjects roots objects =
    let
        typedGraph : TOpt.GlobalGraph
        typedGraph =
            List.foldl addRootTypedGraph (typedObjectsToGlobalGraph objects) (NE.toList roots)

        globalTypeEnv : TypeEnv.GlobalTypeEnv
        globalTypeEnv =
            List.foldl addRootTypeEnv (typedObjectsToGlobalTypeEnv objects) (NE.toList roots)

        log msg =
            Task.io (IO.writeLn IO.stderr msg)
    in
    ( typedGraph, globalTypeEnv )
        |> (\( tGraph, typeEnv ) ->
                -- GC boundary: `objects`, `roots` are now unreachable.
                log "Monomorphization started..."
                    |> Task.andThen
                        (\_ ->
                            Monomorphize.monomorphizeWithLog log "main" typeEnv tGraph
                                |> Task.andThen
                                    (\result ->
                                        case result of
                                            Err err ->
                                                Task.throw (Exit.GenerateMonomorphizationError err)

                                            Ok monoGraph0 ->
                                                log "Monomorphization done."
                                                    |> Task.map (\_ -> monoGraph0)
                                    )
                        )
           )
        |> Task.andThen
            (\monoGraph0 ->
                -- GC boundary: `typedGraph` and `globalTypeEnv` are now unreachable.
                log "Inline + simplify started..."
                    |> Task.andThen
                        (\_ ->
                            let
                                ( simplifiedGraph, _ ) =
                                    MonoInlineSimplify.optimize monoGraph0
                            in
                            log "Inline + simplify done."
                                |> Task.map (\_ -> simplifiedGraph)
                        )
            )
        |> Task.andThen
            (\simplifiedGraph ->
                -- GC boundary: monomorphization state largely unreachable.
                log "Global optimization started..."
                    |> Task.andThen
                        (\_ ->
                            MonoGlobalOptimize.globalOptimizeWithLog log simplifiedGraph
                        )
            )
        |> Task.andThen
            (\monoGraph ->
                log "Global optimization done."
                    |> Task.map
                        (\_ ->
                            { monoGraph = monoGraph
                            , mode = Mode.Dev Nothing
                            }
                        )
            )


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
