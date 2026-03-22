# Cold vs Warm Stage 5 Bootstrap Run Memory Analysis

## Summary
The warm run uses MORE memory than the cold run due to differences in how MVars are populated in the Build and Generate phases. In a cold run, .ecot cache files are deleted and fresh compilation happens. In a warm run, .ecot files exist and modules are loaded from cache, but this creates a critical memory retention issue.

## Key Data Flow Differences

### Cold Run Path
1. **Build.elm**: All modules are compiled, resulting in `RNew` or `RSame` -> creates `Fresh` modules
2. **Details.elm**: Fresh compilation generates `ArtifactsFresh ifaces objs` in the Details extras
3. **Generate.elm loadObjects()**: 
   - `ArtifactsFresh _ o` -> creates MVar with data already populated via `Utils.newMVar (Just o)`
   - Data is immediately available, not loaded from disk
4. **Module objects**: Loaded synchronously into memory, then explicitly referenced

### Warm Run Path (The Problem)
1. **Build.elm**: Modules checked, dependencies unchanged -> creates `RCached` -> creates `Cached` modules
2. **Details.elm**: Cached Details loaded from disk with `ArtifactsCached` in extras
3. **Generate.elm loadObjects()**:
   - `ArtifactsCached` -> forks async file read via `File.readBinary Opt.globalGraphDecoder (Stuff.objects...)`
   - Returns MVar immediately, but data still loading in background thread
4. **Generate.elm loadTypedObjects()**: 
   - Always forks async file reads via `Utils.forkIO`
   - Creates MVars for both Fresh AND Cached modules (no optimization for Fresh)

## Root Cause: Asymmetric MVar Handling

### For Regular Objects (loadObjects in Details.elm:285-295):
```
Case ArtifactsFresh _ o:
    Utils.newMVar (Just o)  -- Data pre-populated, immediate
Case ArtifactsCached:
    fork (File.readBinary...)  -- Async loading from disk
```

### For Typed Objects (loadTypedObjects in Generate.elm:499-537):
```
Fresh modules without typed data:
    Utils.newEmptyMVar + forkLoadTypedCachedObject  -- Always async I/O!
Cached modules:
    Utils.newEmptyMVar + forkLoadTypedCachedObject  -- Always async I/O!
```

**The asymmetry**: Fresh modules' typed objects are ALWAYS loaded asynchronously from .ecot files, even when they exist. Only cold runs benefit from pre-population of regular objects via ArtifactsFresh.

## Memory Retention Issue

In warm run:
1. MVars for .ecot files are created but not yet filled
2. `buildMonoGraph` calls `stripUntypedGraph` to free Opt.LocalGraph from Fresh modules
3. BUT the TypedModuleArtifact is being loaded from disk asynchronously
4. These MVars remain active throughout monomorphization:
   - Monomorphize.monomorphizeWithLog() 
   - MonoInlineSimplify.optimize()
   - MonoGlobalOptimize.globalOptimizeWithLog()
5. The comment in buildMonoGraphFromObjects shows GC boundaries: "GC boundary: `objects`, `roots` are now unreachable" (line 725)
   - But in warm run, the MVars for typed objects from .ecot files are NOT unreachable
   - They're still being awaited in Task combinators

## In Cold Run
1. ArtifactsFresh pre-populates objects synchronously
2. `stripUntypedGraph` removes the Opt.LocalGraph
3. Only the needed TypedModuleArtifact data flows forward
4. MVars are simpler and complete earlier
5. GC boundary is cleaner because objects were never in MVars pending I/O

## In Warm Run (Paradox)
1. Objects loaded via ArtifactsCached (async, but completed by buildMonoGraph)
2. TypedObjects ALWAYS loaded async from .ecot files via loadTypedObject()
3. MVars for 232 Fresh modules' TypedModuleArtifacts stay alive during:
   - buildMonoGraph
   - typedObjectsToGlobalGraph
   - Monomorphization
   - Inline+Simplify
   - Global Optimize
4. These MVars hold references to pending I/O operations and their buffers
5. The "GC boundary" comment at line 725 doesn't help warm run because:
   - The MVars are awaited later in combinator chains
   - Task monads don't truly release MVars until the end of Task pipeline

## Evidence from Code

### buildMonoGraph (Generate.elm:673-692):
```elm
loadTypedObjects root maybeBuildDir maybeLocal details modules
    |> Task.andThen finalizeTypedObjects
    |> Task.andThen (buildMonoGraphFromObjects roots)
```

### loadTypedModuleObjects (Generate.elm:499-537):
```elm
partition modules ( [], [] )  -- Fresh with typed data vs everything else
-- For Fresh: directly into freshDict
-- For everything else: stored in MVars for async loading
TypedLoadingObjects mvar (Data.Map.fromList identity mvars) freshDict
```

### finalizeTypedObjects (Generate.elm:589-593):
```elm
Task.eio identity
    (Utils.takeMVar ... mvar  -- Reads package artifacts MVar
        |> Task.andThen (collectTypedLocalArtifacts mvars freshModules)  -- Reads all MVars
    )
```

The MVars are only fully consumed in finalizeTypedObjects, but at that point we're already in the monomorphization pipeline where they stay referenced.

## Solution Possibilities

1. **Option A**: Add pre-population for typed objects in cold path like regular objects
2. **Option B**: Explicitly drop MVars after finalizeTypedObjects completes (force GC boundary)
3. **Option C**: Load .ecot files eagerly in Details like .objects files
4. **Option D**: Implement explicit task cancellation/cleanup after finalizeTypedObjects
