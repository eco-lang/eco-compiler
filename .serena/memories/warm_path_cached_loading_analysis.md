# Warm Path (Cached .ecot Loading) Analysis

## Overview
This document traces the warm path for loading cached typed artifacts (.ecot files) in the compiler pipeline, contrasting with the cold path (untyped .eco files). The warm path is used by `buildMonoGraph` when targeting MLIR/monomorphization.

## Key Entry Point: buildMonoGraph

Located in `/work/compiler/src/Builder/Generate.elm:679-692`

```elm
buildMonoGraph root maybeBuildDir maybeLocal details (Build.Artifacts artifacts) =
    let
        roots = artifacts.roots
        -- Strip Opt.LocalGraph from Fresh modules: it's only needed by JS backend,
        -- not the MLIR/monomorphization path. Without this, 232 Opt.LocalGraph structures
        -- are pinned in memory as dead weight throughout the entire pipeline.
        modules = List.map stripUntypedGraph artifacts.modules
    in
    loadTypedObjects root maybeBuildDir maybeLocal details modules
        |> Task.andThen finalizeTypedObjects
        |> Task.andThen (buildMonoGraphFromObjects roots)
```

**Key insight**: Fresh modules have their untyped `Opt.LocalGraph` stripped before loading typed objects (memory efficiency win: 232 LocalGraph structures freed).

## Phase 1: Load Typed Objects - loadTypedObjects

Located in `/work/compiler/src/Builder/Generate.elm:491-495`

```elm
loadTypedObjects root maybeBuildDir maybeLocal details modules =
    Task.io
        (Details.loadTypedObjects root maybeBuildDir maybeLocal details
            |> Task.andThen (loadTypedModuleObjects root maybeBuildDir modules)
        )
```

This:
1. Loads global typed artifacts from Details (package-level type info)
2. Delegates to `loadTypedModuleObjects` to handle per-module loading

## Phase 2: Partition Fresh vs Cached - loadTypedModuleObjects

Located in `/work/compiler/src/Builder/Generate.elm:499-537`

```elm
loadTypedModuleObjects root maybeBuildDir modules mvar =
    let
        partition : List Build.Module -> (List (ModuleName.Raw, ModuleTyped), List Build.Module) 
                                        -> (List (ModuleName.Raw, ModuleTyped), List Build.Module)
        partition mods acc =
            case mods of
                [] -> acc
                modul :: rest ->
                    case modul of
                        Build.Fresh name _ _ (Just typedGraph) (Just typeEnv) ->
                            let (fresh, cached) = acc
                            in partition rest
                                ( (name, { graph = typedGraph, env = typeEnv }) :: fresh
                                , cached)
                        _ ->
                            let (fresh, cached) = acc
                            in partition rest
                                ( fresh
                                , modul :: cached)
        
        ( freshPairs, needLoading ) = partition modules ( [], [] )
        freshDict = Data.Map.fromList identity freshPairs
    in
    Utils.listTraverse (loadTypedObject root maybeBuildDir) needLoading
        |> Task.map (\mvars -> TypedLoadingObjects mvar (Data.Map.fromList identity mvars) freshDict)
```

**Data structures created:**
- `freshDict`: Map of `ModuleName.Raw -> ModuleTyped` (in-memory fresh modules)
  - Contains: `{ graph: TOpt.LocalGraph, env: TypeEnv.ModuleTypeEnv }`
  - Directly usable, no MVar needed
- `mvars`: List of `(ModuleName.Raw, MVar (Maybe TMod.TypedModuleArtifact))` for cached modules
- Returns: `TypedLoadingObjects mvar mvars freshDict`

**TypedLoadingObjects structure** (line 483-487):
```elm
type TypedLoadingObjects
    = TypedLoadingObjects
        (MVar (Maybe Details.PackageTypedArtifacts))     -- Global artifacts
        (Data.Map.Dict String ModuleName.Raw (MVar (Maybe TMod.TypedModuleArtifact)))  -- Per-module MVars
        (Data.Map.Dict String ModuleName.Raw ModuleTyped)  -- Fresh modules (no MVar)
```

## Phase 3: Load Individual Typed Objects - loadTypedObject

Located in `/work/compiler/src/Builder/Generate.elm:541-550`

```elm
loadTypedObject root maybeBuildDir modul =
    case modul of
        Build.Fresh name _ _ _ _ ->
            -- Fresh without typed data (already filtered by partition above)
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadTypedCachedObject root maybeBuildDir name)
        
        Build.Cached name _ _ ->
            Utils.newEmptyMVar
                |> Task.andThen (forkLoadTypedCachedObject root maybeBuildDir name)
```

Creates an empty MVar and forks off I/O to load the .ecot file.

### Phase 3a: Async Loading - forkLoadTypedCachedObject

Located in `/work/compiler/src/Builder/Generate.elm:554-556`

```elm
forkLoadTypedCachedObject root maybeBuildDir name mvar =
    Utils.forkIO (readAndStoreTypedCachedObject root maybeBuildDir name mvar)
        |> Task.map (\_ -> ( name, mvar ))
```

Spawns background task to read .ecot file and fill MVar.

### Phase 3b: Actually Read and Store - readAndStoreTypedCachedObject

Located in `/work/compiler/src/Builder/Generate.elm:560-562`

```elm
readAndStoreTypedCachedObject root maybeBuildDir name mvar =
    File.readBinary TMod.typedModuleArtifactDecoder (Stuff.ecotWithBuildDir root maybeBuildDir name)
        |> Task.andThen (storeTypedArtifactWithDefault mvar)
```

Reads the .ecot file and puts result into MVar.

### Phase 3c: Store Result - storeTypedArtifactWithDefault

Located in `/work/compiler/src/Builder/Generate.elm:566-569`

```elm
storeTypedArtifactWithDefault mvar maybeArtifact =
    -- If .ecot file doesn't exist, return Nothing to signal an error
    -- This happens when modules were cached from a non-MLIR build
    Utils.putMVar (Utils.maybeEncoder TMod.typedModuleArtifactEncoder) mvar maybeArtifact
```

Stores `Maybe TMod.TypedModuleArtifact` into MVar. Returns `Nothing` if file doesn't exist (e.g., cached from non-MLIR build).

## Phase 4: Finalize & Collect MVars - finalizeTypedObjects

Located in `/work/compiler/src/Builder/Generate.elm:589-593`

```elm
finalizeTypedObjects (TypedLoadingObjects mvar mvars freshModules) =
    Task.eio identity
        (Utils.takeMVar (BD.maybe Details.packageTypedArtifactsDecoder) mvar
            |> Task.andThen (collectTypedLocalArtifacts mvars freshModules)
        )
```

Takes (consumes) the global artifacts MVar, then collects all local MVars. **The MVar is consumed here - it's now empty and can be GC'd.**

### Phase 4a: Collect Local Artifacts - collectTypedLocalArtifacts

Located in `/work/compiler/src/Builder/Generate.elm:597-599`

```elm
collectTypedLocalArtifacts mvars freshModules globalArtifacts =
    Utils.mapTraverse identity compare (Utils.takeMVar (BD.maybe TMod.typedModuleArtifactDecoder)) mvars
        |> Task.map (combineTypedGlobalAndLocalObjects freshModules globalArtifacts)
```

Takes (consumes) each per-module MVar, extracting all `Maybe TMod.TypedModuleArtifact` values. **All MVars are now consumed and empty - GC eligible.**

### Phase 4b: Combine Global + Local - combineTypedGlobalAndLocalObjects

Located in `/work/compiler/src/Builder/Generate.elm:603-636`

```elm
combineTypedGlobalAndLocalObjects freshModules maybeGlobalArtifacts cachedResults =
    let
        toModuleTyped : TMod.TypedModuleArtifact -> ModuleTyped
        toModuleTyped artifact =
            { graph = artifact.typedGraph
            , env = artifact.typeEnv
            }
        
        maybeCachedModules : Maybe (Data.Map.Dict String ModuleName.Raw ModuleTyped)
        maybeCachedModules =
            Utils.sequenceDictMaybe identity compare cachedResults
                |> Maybe.map (Data.Map.map (\_ -> toModuleTyped))
        
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
            Ok (TypedObjects TOpt.emptyGlobalGraph TypeEnv.emptyGlobalTypeEnv localModules)
        
        _ ->
            Err Exit.GenerateCannotLoadArtifacts
```

**Transformation:**
- Converts `Dict ModuleName.Raw (Maybe TMod.TypedModuleArtifact)` → `Dict ModuleName.Raw ModuleTyped`
- Merges cached modules with fresh modules (fresh takes precedence in union)
- Extracts global typed graph and type env from global artifacts

**Returns: TypedObjects** (line 584-585):
```elm
type TypedObjects
    = TypedObjects TOpt.GlobalGraph TypeEnv.GlobalTypeEnv (Data.Map.Dict String ModuleName.Raw ModuleTyped)
```

## Phase 5: Build Mono Graph - buildMonoGraphFromObjects

Located in `/work/compiler/src/Builder/Generate.elm:709-773`

```elm
buildMonoGraphFromObjects roots objects =
    let
        typedGraph : TOpt.GlobalGraph
        typedGraph =
            List.foldl addRootTypedGraph (typedObjectsToGlobalGraph objects) (NE.toList roots)
        
        globalTypeEnv : TypeEnv.GlobalTypeEnv
        globalTypeEnv =
            List.foldl addRootTypeEnv (typedObjectsToGlobalTypeEnv objects) (NE.toList roots)
        
        log msg = Task.io (IO.writeLn IO.stderr msg)
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
```

**Key steps:**

1. **Combine typed graphs** via `typedObjectsToGlobalGraph` (line 640-641):
   ```elm
   typedObjectsToGlobalGraph (TypedObjects globals _ locals) =
       Data.Map.foldr compare (\_ modTyped acc -> GA.addTypedLocalGraph modTyped.graph acc) globals locals
   ```
   - Folds all local typed graphs into the global graph
   - **`TypedObjects` and `objects` parameter are now unreachable after this lambda.**

2. **Combine type envs** via `typedObjectsToGlobalTypeEnv` (line 645-657):
   ```elm
   typedObjectsToGlobalTypeEnv (TypedObjects _ globalEnv locals) =
       Data.Map.foldr compare
           (\_ modTyped acc ->
               let modEnv : TypeEnv.ModuleTypeEnv = modTyped.env
               in Data.Map.insert ModuleName.toComparableCanonical modEnv.home modEnv acc)
           globalEnv
           locals
   ```
   - Merges local type envs into global
   - Extracts module-level type envs and inserts them

3. **GC boundaries:**
   - After extracting `typedGraph` and `globalTypeEnv`: **`objects` and `roots` are unreachable** (can be GC'd)
   - After monomorphization: **`typedGraph` and `globalTypeEnv` are unreachable** (can be GC'd)
   - After inline+simplify: **monomorphization intermediate structures are unreachable** (can be GC'd)

## Comparison: Cold Path (Untyped .eco Files)

For reference, the cold path (JS backend) uses similar structure but with untyped `Opt.LocalGraph`:

### loadObjects (cold path):
```elm
loadObjects root maybeBuildDir details modules =
    Task.io
        (Details.loadObjects root maybeBuildDir details
            |> Task.andThen (loadModuleObjects root maybeBuildDir modules)
        )
```

### loadModuleObjects (cold path):
```elm
loadModuleObjects root maybeBuildDir modules mvar =
    let
        partitionModules : List Build.Module -> (List (ModuleName.Raw, Opt.LocalGraph), List Build.Module) 
                                               -> (List (ModuleName.Raw, Opt.LocalGraph), List Build.Module)
        partitionModules mods ( freshAcc, cachedAcc ) =
            case mods of
                [] -> ( freshAcc, cachedAcc )
                modul :: rest ->
                    case modul of
                        Build.Fresh name _ graph _ _ ->
                            partitionModules rest ( ( name, graph ) :: freshAcc, cachedAcc )
                        Build.Cached _ _ _ ->
                            partitionModules rest ( freshAcc, modul :: cachedAcc )
        
        ( freshPairs, needLoading ) = partitionModules modules ( [], [] )
        freshDict = Data.Map.fromList identity freshPairs
    in
    Utils.listTraverse (loadCachedObject root maybeBuildDir) needLoading
        |> Task.map (\mvars -> LoadingObjects mvar (Data.Map.fromList identity mvars) freshDict)
```

**Key differences:**
- Cold path uses `Opt.LocalGraph` instead of `ModuleTyped`
- Cold path stores in `LoadingObjects` instead of `TypedLoadingObjects`
- No global type env in cold path

### stripUntypedGraph

Located in `/work/compiler/src/Builder/Generate.elm:699-705`

```elm
stripUntypedGraph modul =
    case modul of
        Build.Fresh name iface _ typedObjs typeEnv ->
            Build.Fresh name iface (Opt.LocalGraph Nothing Data.Map.empty Dict.empty) typedObjs typeEnv
        
        Build.Cached _ _ _ ->
            modul
```

**Replaces** the `Opt.LocalGraph` from Fresh modules with an empty one. This is called in `buildMonoGraph` to strip dead weight before loading typed objects. The untyped graph is only needed by the JS backend, not by the MLIR path.

## Data Structure Lifecycle & GC Eligibility

### MVars and takeMVar Behavior

From `/work/eco-kernel-cpp/src/Eco/Kernel/MVar.js`:

- `_MVar_new`: Creates MVar with `{ value: undefined, waiters: [] }`
- `_MVar_take(id)`: 
  - If value exists: returns value, **sets value back to undefined**, wakes up waiters
  - If value undefined: adds to waiters queue
  - Returns: `Nothing` if MVar not found, otherwise the taken value
- `_MVar_read(id)`:
  - If value exists: returns value **without clearing it**
  - If value undefined: adds to waiters queue (non-consuming)

**Critical point**: `takeMVar` CONSUMES the value (clears it), making the MVar referenceable but with `undefined` value - eligible for GC if no other references.

### GC Timeline in Warm Path

1. **After `loadTypedModuleObjects` completes:**
   - MVars created but not yet filled (async I/O pending)
   - GC cannot touch MVars (refs held in `TypedLoadingObjects`)

2. **During `finalizeTypedObjects` → `collectTypedLocalArtifacts`:**
   - `takeMVar` called on global artifacts MVar → value extracted, MVar cleared
   - `mapTraverse ... takeMVar` called on all per-module MVars → all values extracted, all MVars cleared
   - **All MVars now have undefined values, eligible for GC if no refs**

3. **After `buildMonoGraphFromObjects` extracts graphs:**
   - `TypedObjects` struct (which held references to locals dict) consumed
   - `locals` dict (containing all `ModuleTyped` structures) no longer referenced
   - **`ModuleTyped` structs eligible for GC after graph/env extracted**

4. **After monomorphization:**
   - `typedGraph` and `globalTypeEnv` consumed by Monomorphize
   - **Original typed structures eligible for GC**

5. **After inline+simplify:**
   - Monomorphization intermediate structures released
   - **Mono graph state eligible for GC except for simplified result**

## Summary: Key Data Structures & Lifetimes

| Structure | Created | Consumed | Contents | GC Point |
|-----------|---------|----------|----------|----------|
| `TypedLoadingObjects` | `loadTypedModuleObjects` | `finalizeTypedObjects` | MVars + freshDict | After finalize |
| Global Artifacts MVar | `loadTypedObjects` | `finalizeTypedObjects` (takeMVar) | `Maybe Details.PackageTypedArtifacts` | After takeMVar |
| Per-module MVars | `loadTypedObject` | `collectTypedLocalArtifacts` (mapTraverse takeMVar) | `Maybe TMod.TypedModuleArtifact` | After collect |
| `TypedObjects` | `combineTypedGlobalAndLocalObjects` | `buildMonoGraphFromObjects` | Globals + LocalsDict | After graph extraction |
| Locals Dict | `combineTypedGlobalAndLocalObjects` | Folded into global | `ModuleTyped` structs | After folding |
| `typedGraph` | `buildMonoGraphFromObjects` | Passed to Monomorphize | `TOpt.GlobalGraph` | After Monomorphize |
| `globalTypeEnv` | `buildMonoGraphFromObjects` | Passed to Monomorphize | `TypeEnv.GlobalTypeEnv` | After Monomorphize |

## Critical Insights

1. **Fresh vs Cached distinction** is crucial for memory efficiency:
   - Fresh modules bypass MVar overhead (already in memory from compilation)
   - Cached modules use background I/O + MVars for lazy loading

2. **stripUntypedGraph is essential**:
   - Removes 232 `Opt.LocalGraph` structures that would otherwise be pinned in memory
   - They're only needed by JS backend, not MLIR path

3. **takeMVar (not readMVar) is used everywhere**:
   - Consumes values, allowing GC of MVar storage
   - Ensures single-consumer semantics

4. **GC boundaries are explicit**:
   - Comments mark where `objects`, `typedGraph`, `globalTypeEnv` become unreachable
   - Enables aggressive memory reclamation during pipeline passes

5. **TypedObjects is transient**:
   - Only holds the final merged locals dict before passing to Monomorphize
   - Quickly becomes unreachable after graph/env extraction

6. **MVar store remains in memory**:
   - Global JS store `_MVar_store` keeps MVar metadata even after takeMVar
   - This is unavoidable in the current design (IDs are long-lived)
