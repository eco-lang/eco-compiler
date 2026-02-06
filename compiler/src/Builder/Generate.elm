module Builder.Generate exposing
    ( javascriptBackend, mlirBackend
    , dev, debug, monoDev
    , prod
    , repl
    )

{-| Code generation orchestration for the Elm compiler.

This module coordinates the transformation of compiled Elm code into executable output
through various code generation backends. It handles loading optimized artifacts from
disk, preparing them for code generation, and invoking the appropriate backend to
produce JavaScript, MLIR, or other target code.


# Code Generation Backends

@docs javascriptBackend, mlirBackend


# Development Builds

@docs dev, debug, monoDev


# Production Builds

@docs prod


# REPL Code Generation

@docs repl

-}

import Builder.Build as Build
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.File as File
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
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.GlobalOpt.MonoGlobalOptimize as MonoGlobalOptimize
import Compiler.Nitpick.Debug as Nitpick
import Compiler.Reporting.Render.Type.Localizer as L
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Main as Utils exposing (FilePath, MVar)
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


{-| MLIR code generation backend for monomorphized programs.
-}
mlirBackend : CodeGen.MonoCodeGen
mlirBackend =
    MLIR.backend



-- ====== GENERATORS ======


{-| Generates debug-mode output with type information for runtime type checking.
-}
debug : CodeGen.CodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
debug backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen (loadTypesAndFinalize root maybeBuildDir artifacts.deps artifacts.modules)
        |> Task.andThen (generateDebugOutput backend withSourceMaps leadingLines root artifacts.pkg artifacts.roots)


loadTypesAndFinalize : FilePath -> Maybe String -> Dict (List String) TypeCheck.Canonical I.DependencyInterface -> List Build.Module -> LoadingObjects -> Task Exit.Generate ( Objects, Extract.Types )
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


generateWithBackend : CodeGen.CodeGen -> Int -> Mode.Mode -> Opt.GlobalGraph -> Dict (List String) TypeCheck.Canonical Opt.Main -> CodeGen.SourceMaps -> CodeGen.Output
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


generateReplOutput : CodeGen.CodeGen -> Bool -> L.Localizer -> TypeCheck.Canonical -> N.Name -> Dict String N.Name Can.Annotation -> Objects -> CodeGen.Output
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
        , annotation = Utils.find identity name annotations
        }



-- ====== CHECK FOR DEBUG ======


checkForDebugUses : Objects -> Task Exit.Generate ()
checkForDebugUses (Objects _ locals) =
    case Dict.keys compare (Dict.filter (\_ -> Nitpick.hasDebugUses) locals) of
        [] ->
            Task.succeed ()

        m :: ms ->
            Task.throw (Exit.GenerateCannotOptimizeDebugValues m ms)



-- ====== GATHER MAINS ======


gatherMains : Pkg.Name -> Objects -> NE.Nonempty Build.Root -> Dict (List String) TypeCheck.Canonical Opt.Main
gatherMains pkg (Objects _ locals) roots =
    Dict.fromList ModuleName.toComparableCanonical (List.filterMap (lookupMain pkg locals) (NE.toList roots))


lookupMain : Pkg.Name -> Dict String ModuleName.Raw Opt.LocalGraph -> Build.Root -> Maybe ( TypeCheck.Canonical, Opt.Main )
lookupMain pkg locals root =
    let
        toPair : N.Name -> Opt.LocalGraph -> Maybe ( TypeCheck.Canonical, Opt.Main )
        toPair name (Opt.LocalGraph maybeMain _ _) =
            Maybe.map (Tuple.pair (TypeCheck.Canonical pkg name)) maybeMain
    in
    case root of
        Build.Inside name ->
            Dict.get identity name locals |> Maybe.andThen (toPair name)

        Build.Outside name _ g _ _ ->
            toPair name g



-- ====== LOADING OBJECTS ======


type LoadingObjects
    = LoadingObjects (MVar (Maybe Opt.GlobalGraph)) (Dict String ModuleName.Raw (MVar (Maybe Opt.LocalGraph)))


loadObjects : FilePath -> Maybe String -> Details.Details -> List Build.Module -> Task Exit.Generate LoadingObjects
loadObjects root maybeBuildDir details modules =
    Task.io
        (Details.loadObjects root maybeBuildDir details
            |> Task.andThen (loadModuleObjects root maybeBuildDir modules)
        )


loadModuleObjects : FilePath -> Maybe String -> List Build.Module -> MVar (Maybe Opt.GlobalGraph) -> Task Never LoadingObjects
loadModuleObjects root maybeBuildDir modules mvar =
    Utils.listTraverse (loadObject root maybeBuildDir) modules
        |> Task.map (\mvars -> LoadingObjects mvar (Dict.fromList identity mvars))


loadObject : FilePath -> Maybe String -> Build.Module -> Task Never ( ModuleName.Raw, MVar (Maybe Opt.LocalGraph) )
loadObject root maybeBuildDir modul =
    case modul of
        Build.Fresh name _ graph _ _ ->
            Utils.newMVar (Utils.maybeEncoder Opt.localGraphEncoder) (Just graph)
                |> Task.map (\mvar -> ( name, mvar ))

        Build.Cached name _ _ ->
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadCachedObject root maybeBuildDir name)


forkLoadCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Opt.LocalGraph) -> Task Never ( ModuleName.Raw, MVar (Maybe Opt.LocalGraph) )
forkLoadCachedObject root maybeBuildDir name mvar =
    Utils.forkIO (readAndStoreCachedObject root maybeBuildDir name mvar)
        |> Task.map (\_ -> ( name, mvar ))


readAndStoreCachedObject : FilePath -> Maybe String -> ModuleName.Raw -> MVar (Maybe Opt.LocalGraph) -> Task Never ()
readAndStoreCachedObject root maybeBuildDir name mvar =
    File.readBinary Opt.localGraphDecoder (Stuff.guidaoWithBuildDir root maybeBuildDir name)
        |> Task.andThen (Utils.putMVar (Utils.maybeEncoder Opt.localGraphEncoder) mvar)



-- ====== FINALIZE OBJECTS ======


type Objects
    = Objects Opt.GlobalGraph (Dict String ModuleName.Raw Opt.LocalGraph)


finalizeObjects : LoadingObjects -> Task Exit.Generate Objects
finalizeObjects (LoadingObjects mvar mvars) =
    Task.eio identity
        (Utils.readMVar (BD.maybe Opt.globalGraphDecoder) mvar
            |> Task.andThen (collectLocalObjects mvars)
        )


collectLocalObjects : Dict String ModuleName.Raw (MVar (Maybe Opt.LocalGraph)) -> Maybe Opt.GlobalGraph -> Task Never (Result Exit.Generate Objects)
collectLocalObjects mvars globalResult =
    Utils.mapTraverse identity compare (Utils.readMVar (BD.maybe Opt.localGraphDecoder)) mvars
        |> Task.map (combineGlobalAndLocalObjects globalResult)


combineGlobalAndLocalObjects : Maybe Opt.GlobalGraph -> Dict String ModuleName.Raw (Maybe Opt.LocalGraph) -> Result Exit.Generate Objects
combineGlobalAndLocalObjects globalResult results =
    case Maybe.map2 Objects globalResult (Utils.sequenceDictMaybe identity compare results) of
        Just loaded ->
            Ok loaded

        Nothing ->
            Err Exit.GenerateCannotLoadArtifacts


objectsToGlobalGraph : Objects -> Opt.GlobalGraph
objectsToGlobalGraph (Objects globals locals) =
    Dict.foldr compare (\_ -> Opt.addLocalGraph) globals locals



-- ====== LOAD TYPES ======


loadTypes : FilePath -> Maybe String -> Dict (List String) TypeCheck.Canonical I.DependencyInterface -> List Build.Module -> Task Exit.Generate Extract.Types
loadTypes root maybeBuildDir ifaces modules =
    Task.eio identity
        (Utils.listTraverse (loadTypesHelp root maybeBuildDir) modules
            |> Task.andThen (collectAndMergeTypes ifaces)
        )


collectAndMergeTypes : Dict (List String) TypeCheck.Canonical I.DependencyInterface -> List (MVar (Maybe Extract.Types)) -> Task Never (Result Exit.Generate Extract.Types)
collectAndMergeTypes ifaces mvars =
    let
        foreigns : Extract.Types
        foreigns =
            Extract.mergeMany (Dict.values ModuleName.compareCanonical (Dict.map Extract.fromDependencyInterface ifaces))
    in
    Utils.listTraverse (Utils.readMVar (BD.maybe Extract.typesDecoder)) mvars
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
    File.readBinary I.interfaceDecoder (Stuff.guidaiWithBuildDir root maybeBuildDir name)
        |> Task.andThen (\maybeIface -> Utils.putMVar (Utils.maybeEncoder Extract.typesEncoder) mvar (Maybe.map (Extract.fromInterface name) maybeIface))



-- ====== TYPED OBJECTS LOADING ======


type TypedLoadingObjects
    = TypedLoadingObjects (MVar (Maybe Details.PackageTypedArtifacts)) (Dict String ModuleName.Raw (MVar (Maybe TMod.TypedModuleArtifact)))


loadTypedObjects : FilePath -> Maybe String -> Details.Details -> List Build.Module -> Task Exit.Generate TypedLoadingObjects
loadTypedObjects root maybeBuildDir details modules =
    Task.io
        (Details.loadTypedObjects root maybeBuildDir details
            |> Task.andThen (loadTypedModuleObjects root maybeBuildDir modules)
        )


loadTypedModuleObjects : FilePath -> Maybe String -> List Build.Module -> MVar (Maybe Details.PackageTypedArtifacts) -> Task Never TypedLoadingObjects
loadTypedModuleObjects root maybeBuildDir modules mvar =
    Utils.listTraverse (loadTypedObject root maybeBuildDir) modules
        |> Task.map (\mvars -> TypedLoadingObjects mvar (Dict.fromList identity mvars))


loadTypedObject : FilePath -> Maybe String -> Build.Module -> Task Never ( ModuleName.Raw, MVar (Maybe TMod.TypedModuleArtifact) )
loadTypedObject root maybeBuildDir modul =
    case modul of
        Build.Fresh name _ _ maybeTypedGraph maybeTypeEnv ->
            -- Use the typed graph and type env from the build if available
            case ( maybeTypedGraph, maybeTypeEnv ) of
                ( Just typedGraph, Just typeEnv ) ->
                    let
                        artifact : TMod.TypedModuleArtifact
                        artifact =
                            { typedGraph = typedGraph
                            , typeEnv = typeEnv
                            }
                    in
                    Utils.newMVar (Utils.maybeEncoder TMod.typedModuleArtifactEncoder) (Just artifact)
                        |> Task.map (\mvar -> ( name, mvar ))

                _ ->
                    -- No typed info available, create empty MVar (will fall back to cached)
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
    File.readBinary TMod.typedModuleArtifactDecoder (Stuff.guidatoWithBuildDir root maybeBuildDir name)
        |> Task.andThen (storeTypedArtifactWithDefault mvar)


storeTypedArtifactWithDefault : MVar (Maybe TMod.TypedModuleArtifact) -> Maybe TMod.TypedModuleArtifact -> Task Never ()
storeTypedArtifactWithDefault mvar maybeArtifact =
    -- If .guidato file doesn't exist, return Nothing to signal an error
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
    = TypedObjects TOpt.GlobalGraph TypeEnv.GlobalTypeEnv (Dict String ModuleName.Raw ModuleTyped)


finalizeTypedObjects : TypedLoadingObjects -> Task Exit.Generate TypedObjects
finalizeTypedObjects (TypedLoadingObjects mvar mvars) =
    Task.eio identity
        (Utils.readMVar (BD.maybe Details.packageTypedArtifactsDecoder) mvar
            |> Task.andThen (collectTypedLocalArtifacts mvars)
        )


collectTypedLocalArtifacts : Dict String ModuleName.Raw (MVar (Maybe TMod.TypedModuleArtifact)) -> Maybe Details.PackageTypedArtifacts -> Task Never (Result Exit.Generate TypedObjects)
collectTypedLocalArtifacts mvars globalArtifacts =
    Utils.mapTraverse identity compare (Utils.readMVar (BD.maybe TMod.typedModuleArtifactDecoder)) mvars
        |> Task.map (combineTypedGlobalAndLocalObjects globalArtifacts)


combineTypedGlobalAndLocalObjects : Maybe Details.PackageTypedArtifacts -> Dict String ModuleName.Raw (Maybe TMod.TypedModuleArtifact) -> Result Exit.Generate TypedObjects
combineTypedGlobalAndLocalObjects maybeGlobalArtifacts results =
    let
        -- Convert TypedModuleArtifact to ModuleTyped
        toModuleTyped : TMod.TypedModuleArtifact -> ModuleTyped
        toModuleTyped artifact =
            { graph = artifact.typedGraph
            , env = artifact.typeEnv
            }

        -- Sequence the dict of Maybe values
        maybeLocalModules : Maybe (Dict String ModuleName.Raw ModuleTyped)
        maybeLocalModules =
            Utils.sequenceDictMaybe identity compare results
                |> Maybe.map (Dict.map (\_ -> toModuleTyped))
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
    Dict.foldr compare (\_ modTyped acc -> TOpt.addLocalGraph modTyped.graph acc) globals locals


typedObjectsToGlobalTypeEnv : TypedObjects -> TypeEnv.GlobalTypeEnv
typedObjectsToGlobalTypeEnv (TypedObjects _ globalEnv locals) =
    -- Merge local module type envs into the global type env from packages
    Dict.foldr compare
        (\_ modTyped acc ->
            let
                modEnv : TypeEnv.ModuleTypeEnv
                modEnv =
                    modTyped.env
            in
            Dict.insert ModuleName.toComparableCanonical modEnv.home modEnv acc
        )
        globalEnv
        locals



-- ====== MONOMORPHIZED GENERATION ======


{-| Generates monomorphized output for MLIR mono backend after specializing polymorphic functions.
-}
monoDev : CodeGen.MonoCodeGen -> Bool -> Int -> FilePath -> Maybe String -> Details.Details -> Build.Artifacts -> Task Exit.Generate CodeGen.Output
monoDev backend withSourceMaps leadingLines root maybeBuildDir details (Build.Artifacts artifacts) =
    loadTypedObjects root maybeBuildDir details artifacts.modules
        |> Task.andThen finalizeTypedObjects
        |> Task.andThen (generateMonoDevOutput backend withSourceMaps leadingLines root artifacts.roots)


generateMonoDevOutput : CodeGen.MonoCodeGen -> Bool -> Int -> FilePath -> NE.Nonempty Build.Root -> TypedObjects -> Task Exit.Generate CodeGen.Output
generateMonoDevOutput backend withSourceMaps leadingLines root roots objects =
    let
        mode : Mode.Mode
        mode =
            Mode.Dev Nothing

        baseGraph : TOpt.GlobalGraph
        baseGraph =
            typedObjectsToGlobalGraph objects

        baseTypeEnv : TypeEnv.GlobalTypeEnv
        baseTypeEnv =
            typedObjectsToGlobalTypeEnv objects

        -- Add typed graphs from roots (for Outside roots that have typed graphs)
        typedGraph : TOpt.GlobalGraph
        typedGraph =
            List.foldl addRootTypedGraph baseGraph (NE.toList roots)

        -- Add type envs from roots (for Outside roots that have type envs)
        globalTypeEnv : TypeEnv.GlobalTypeEnv
        globalTypeEnv =
            List.foldl addRootTypeEnv baseTypeEnv (NE.toList roots)
    in
    case Monomorphize.monomorphize "main" globalTypeEnv typedGraph of
        Err err ->
            Task.throw (Exit.GenerateMonomorphizationError err)

        Ok monoGraph0 ->
            let
                monoGraph =
                    MonoGlobalOptimize.globalOptimize globalTypeEnv monoGraph0
            in
            prepareSourceMaps withSourceMaps root
                |> Task.map (generateMonoOutput backend leadingLines mode monoGraph globalTypeEnv)


generateMonoOutput : CodeGen.MonoCodeGen -> Int -> Mode.Mode -> Mono.MonoGraph -> TypeEnv.GlobalTypeEnv -> CodeGen.SourceMaps -> CodeGen.Output
generateMonoOutput backend leadingLines mode monoGraph typeEnv sourceMaps =
    backend.generate
        { sourceMaps = sourceMaps
        , leadingLines = leadingLines
        , mode = mode
        , graph = monoGraph
        , typeEnv = typeEnv
        }


addRootTypedGraph : Build.Root -> TOpt.GlobalGraph -> TOpt.GlobalGraph
addRootTypedGraph root graph =
    case root of
        Build.Inside _ ->
            -- Inside roots are already in the modules list
            graph

        Build.Outside _ _ _ maybeTypedGraph _ ->
            case maybeTypedGraph of
                Just typedGraph ->
                    TOpt.addLocalGraph typedGraph graph

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
                    Dict.insert ModuleName.toComparableCanonical modEnv.home modEnv globalEnv

                Nothing ->
                    globalEnv
