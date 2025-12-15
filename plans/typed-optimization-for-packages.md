# Plan: Typed Optimization for Packages (.guidato files)

## Problem Statement

The MLIR backend requires typed optimized AST (`TOpt.GlobalGraph`) for monomorphization, but package dependencies (elm/html, elm/core, etc.) are currently only compiled to untyped optimized AST (`Opt.GlobalGraph`). This results in package functions becoming `MonoExtern` placeholders in the MLIR output instead of actual code.

### Current Flow (Packages)
```
Package Source → Canonicalize → TypeCheck → Optimize → Opt.LocalGraph → artifacts.dat
```

### Required Flow
```
Package Source → Canonicalize → TypeCheck → Optimize → Opt.LocalGraph
                                          ↓
                                   TypedOptimize → TOpt.LocalGraph → artifacts.dat (extended)
```

## Architecture Overview

### Current Package Compilation (Details.elm)

```
verifyDep
  └→ build
      └→ buildPackage
          └→ compilePackageModules
              └→ compile (uses Compile.compile - NO typed optimization)
                  └→ DResult = RLocal I.Interface Opt.LocalGraph (Maybe Docs)
              └→ writePackageArtifacts
                  └→ Artifacts = (Dict ModuleName I.DependencyInterface) Opt.GlobalGraph
                  └→ Write to artifacts.dat
```

### Key Files to Modify

| File | Purpose |
|------|---------|
| `Builder/Elm/Details.elm` | Package compilation orchestration |
| `Builder/Build.elm` | Build environment with `needsTypedOpt` flag |
| `Builder/Generate.elm` | Loading typed objects for code generation |
| `Compiler/Compile.elm` | Module compilation (already has `compileTyped`) |

## Implementation Plan

### Step 1: Add Stuff.typedPackageArtifacts Path Helper

**File:** `Builder/Stuff.elm`

Add a new path helper for the typed artifacts file:

```elm
typedPackageArtifacts : PackageCache -> Pkg.Name -> V.Version -> FilePath
typedPackageArtifacts cache pkg vsn =
    package cache pkg vsn ++ "/typed-artifacts.dat"
```

### Step 2: Add needsTypedOpt to Env

**File:** `Builder/Elm/Details.elm`

Add `needsTypedOpt` flag to the environment:

```elm
type alias EnvData =
    { key : Reporting.DKey
    , scope : BW.Scope
    , root : FilePath
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , connection : Solver.Connection
    , registry : Registry.Registry
    , needsTypedOpt : Bool  -- NEW
    }
```

Update `makeEnv` and callers to accept/pass this flag.

### Step 3: Extend DResult for Typed Compilation

**File:** `Builder/Elm/Details.elm`

Current:
```elm
type DResult
    = RLocal I.Interface Opt.LocalGraph (Maybe Docs.Module)
    | RForeign I.Interface
    | RKernelLocal (List Kernel.Chunk)
    | RKernelForeign
```

Change to:
```elm
type DResult
    = RLocal I.Interface Opt.LocalGraph (Maybe TOpt.LocalGraph) (Maybe Docs.Module)
    | RForeign I.Interface
    | RKernelLocal (List Kernel.Chunk)
    | RKernelForeign
```

### Step 4: Add Typed Compilation to Package Build Context

**File:** `Builder/Elm/Details.elm`

```elm
type alias BuildContext =
    { key : Reporting.DKey
    , cache : Stuff.PackageCache
    , pkg : Pkg.Name
    , vsn : V.Version
    , fingerprint : Fingerprint
    , fingerprints : EverySet ... Fingerprint
    , needsTypedOpt : Bool  -- NEW
    }
```

### Step 5: Check for Typed Artifacts Before Using Cache

**File:** `Builder/Elm/Details.elm`

Modify `handleArtifactCache` to check for typed artifacts when needed:

```elm
handleArtifactCache : VerifyDepContext -> Maybe ArtifactCache -> Task Never Dep
handleArtifactCache ctx maybeCache =
    case maybeCache of
        Nothing ->
            build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint EverySet.empty ctx.needsTypedOpt

        Just (ArtifactCache fingerprints artifacts) ->
            if EverySet.member toComparableFingerprint ctx.fingerprint fingerprints then
                -- Check if we need typed artifacts but don't have them
                if ctx.needsTypedOpt then
                    checkTypedArtifactsExist ctx fingerprints artifacts
                else
                    Task.map (\_ -> Ok artifacts) (Reporting.report ctx.key Reporting.DBuilt)
            else
                build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint fingerprints ctx.needsTypedOpt


checkTypedArtifactsExist : VerifyDepContext -> ... -> Artifacts -> Task Never Dep
checkTypedArtifactsExist ctx fingerprints artifacts =
    File.exists (Stuff.typedPackageArtifacts ctx.cache ctx.pkg ctx.vsn)
        |> Task.andThen
            (\exists ->
                if exists then
                    Task.map (\_ -> Ok artifacts) (Reporting.report ctx.key Reporting.DBuilt)
                else
                    -- Rebuild with typed optimization
                    build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint fingerprints True
            )
```

### Step 6: Modify compile to Support Typed Optimization

**File:** `Builder/Elm/Details.elm`

```elm
compile : Pkg.Name -> Bool -> MVar ... -> Status -> Task Never (Maybe DResult)
compile pkg needsTypedOpt mvar status =
    case status of
        SLocal docsStatus deps modul ->
            ...
            if needsTypedOpt then
                Compile.compileTyped pkg ifaces modul
                    |> Task.map (handleTypedResult docsStatus)
            else
                Compile.compile pkg ifaces modul
                    |> Task.map (handleUntypedResult docsStatus)
        ...


handleTypedResult : DocsStatus -> Result ... ( I.Interface, Opt.LocalGraph, TOpt.LocalGraph ) -> Maybe DResult
handleTypedResult docsStatus result =
    case result of
        Ok ( iface, objects, typedObjects ) ->
            Just (RLocal iface objects (Just typedObjects) (docsFromStatus docsStatus))
        Err _ ->
            Nothing


handleUntypedResult : DocsStatus -> Result ... ( I.Interface, Opt.LocalGraph ) -> Maybe DResult
handleUntypedResult docsStatus result =
    case result of
        Ok ( iface, objects ) ->
            Just (RLocal iface objects Nothing (docsFromStatus docsStatus))
        Err _ ->
            Nothing
```

### Step 7: Add gatherTypedObjects Function

**File:** `Builder/Elm/Details.elm`

```elm
gatherTypedObjects : Dict String ModuleName.Raw DResult -> TOpt.GlobalGraph
gatherTypedObjects results =
    Dict.foldr compare addTypedLocalGraph TOpt.empty results


addTypedLocalGraph : ModuleName.Raw -> DResult -> TOpt.GlobalGraph -> TOpt.GlobalGraph
addTypedLocalGraph _ result graph =
    case result of
        RLocal _ _ (Just typedGraph) _ ->
            TOpt.addLocalGraph typedGraph graph

        _ ->
            graph
```

### Step 8: Write Typed Artifacts to Separate File

**File:** `Builder/Elm/Details.elm`

Modify `writePackageArtifacts`:

```elm
writePackageArtifacts : BuildContext -> Dict ... -> DocsStatus -> Dict ... (Maybe DResult) -> Task Never Dep
writePackageArtifacts ctx exposedDict docsStatus maybeResults =
    case Utils.sequenceDictMaybe identity compare maybeResults of
        Nothing ->
            reportBuildBroken ctx

        Just results ->
            let
                path = Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/artifacts.dat"
                typedPath = Stuff.typedPackageArtifacts ctx.cache ctx.pkg ctx.vsn

                ifaces = gatherInterfaces exposedDict results
                objects = gatherObjects results
                artifacts = Artifacts ifaces objects
                fingerprints = EverySet.insert toComparableFingerprint ctx.fingerprint ctx.fingerprints
            in
            writeDocs ctx.cache ctx.pkg ctx.vsn docsStatus results
                |> Task.andThen (\_ -> File.writeBinary artifactCacheEncoder path (ArtifactCache fingerprints artifacts))
                |> Task.andThen (\_ ->
                    if ctx.needsTypedOpt then
                        let typedObjects = gatherTypedObjects results
                        in File.writeBinary TOpt.globalGraphEncoder typedPath typedObjects
                    else
                        Task.succeed ()
                )
                |> Task.andThen (\_ -> Reporting.report ctx.key Reporting.DBuilt)
                |> Task.map (\_ -> Ok artifacts)
```

### Step 9: Load Typed Package Artifacts in Generate.elm

**File:** `Builder/Generate.elm`

Update `loadTypedObjects` to load from package typed-artifacts.dat files:

```elm
loadTypedObjects : FilePath -> Details.Details -> Task Never (MVar (Maybe TOpt.GlobalGraph))
loadTypedObjects root details =
    fork (Utils.maybeEncoder TOpt.globalGraphEncoder)
        (loadAllTypedObjects root details)


loadAllTypedObjects : FilePath -> Details.Details -> Task Never (Maybe TOpt.GlobalGraph)
loadAllTypedObjects root details =
    -- Load local typed objects
    File.readBinary TOpt.globalGraphDecoder (Stuff.typedObjects root)
        |> Task.andThen
            (\maybeLocal ->
                -- Load typed objects from all dependencies
                loadPackageTypedObjects details
                    |> Task.map (combineWithLocal maybeLocal)
            )


loadPackageTypedObjects : Details.Details -> Task Never TOpt.GlobalGraph
loadPackageTypedObjects (Details.Details detailsData) =
    -- For each dependency in detailsData.deps, load typed-artifacts.dat
    Utils.mapTraverse identity Pkg.compareName loadSinglePackageTypedObjects detailsData.deps
        |> Task.map (Dict.foldl Pkg.compareName (\_ graph acc -> TOpt.addGlobalGraph graph acc) TOpt.empty)


loadSinglePackageTypedObjects : Details.Dep -> Task Never TOpt.GlobalGraph
loadSinglePackageTypedObjects dep =
    let
        path = Stuff.typedPackageArtifacts cache dep.pkg dep.vsn
    in
    File.readBinary TOpt.globalGraphDecoder path
        |> Task.map (Maybe.withDefault TOpt.empty)


combineWithLocal : Maybe TOpt.GlobalGraph -> TOpt.GlobalGraph -> Maybe TOpt.GlobalGraph
combineWithLocal maybeLocal packageGraphs =
    case maybeLocal of
        Just local ->
            Just (TOpt.addGlobalGraph local packageGraphs)

        Nothing ->
            if TOpt.isEmpty packageGraphs then
                Nothing
            else
                Just packageGraphs
```

### Step 10: Thread needsTypedOpt Through Entry Points

**File:** `Builder/Elm/Details.elm`

Update `load` and `verifyInstall` to accept `needsTypedOpt`:

```elm
load : Reporting.Style -> BW.Scope -> FilePath -> Bool -> Task Exit.Details Details
load style scope root needsTypedOpt =
    ...


verifyInstall : BW.Scope -> FilePath -> Bool -> Solver.Env -> Outline.Outline -> Task Never (Result Exit.Details ())
verifyInstall scope root needsTypedOpt (Solver.Env env) outline =
    ...
```

**File:** `Terminal/Make.elm` (or wherever MLIR backend is selected)

Pass `needsTypedOpt = True` when MLIR output is requested:

```elm
handleMlirOutput : ... -> Task Exit.Make ()
handleMlirOutput ctx target artifacts =
    Details.load style scope root True  -- needsTypedOpt = True for MLIR
        |> Task.andThen ...
```

## Implementation Order

1. **Phase 1: Infrastructure** (Low risk)
   - Add `Stuff.typedPackageArtifacts` path helper
   - Extend `DResult` type with `Maybe TOpt.LocalGraph`
   - Update `DResult` encoders/decoders

2. **Phase 2: Threading needsTypedOpt** (Medium risk)
   - Add `needsTypedOpt` to `EnvData` in Details.elm
   - Add `needsTypedOpt` to `BuildContext`
   - Add `needsTypedOpt` to `VerifyDepContext`
   - Update `makeEnv`, `verifyDep`, `build` signatures
   - Thread flag from entry points (`load`, `verifyInstall`)

3. **Phase 3: Package Compilation** (Medium risk)
   - Modify `compile` to conditionally use `Compile.compileTyped`
   - Add `gatherTypedObjects` function
   - Modify `writePackageArtifacts` to write `typed-artifacts.dat`
   - Add `checkTypedArtifactsExist` for cache validation

4. **Phase 4: Loading** (Medium risk)
   - Update `loadTypedObjects` in Generate.elm
   - Add `loadPackageTypedObjects` to load from dependencies
   - Add `loadSinglePackageTypedObjects` helper
   - Combine package and local typed objects

5. **Phase 5: Entry Point Integration** (Medium risk)
   - Update `Terminal/Make.elm` to pass `needsTypedOpt=True` for MLIR
   - Update callers of `Details.load` as needed
   - Test end-to-end with MLIR backend

## Design Decisions

### Q1: When to generate typed optimization for packages?

**Decision: On-demand generation (Option B)**

Only generate typed optimization when the MLIR backend is being used. This requires:
- Threading `needsTypedOpt` flag through the dependency verification chain
- Checking for `typed-artifacts.dat` existence when `needsTypedOpt=True`
- Triggering rebuild if typed artifacts are missing

### Q2: Where to store typed package objects?

**Decision: Separate `typed-artifacts.dat` file (Option B)**

Store typed objects in a separate file alongside `artifacts.dat`:
```
~/.guida/packages/{author}/{pkg}/{version}/
├── artifacts.dat           # Existing: interfaces + Opt.GlobalGraph
├── typed-artifacts.dat     # NEW: TOpt.GlobalGraph
└── src/
```

Benefits:
- No changes to existing `artifacts.dat` format
- Can skip loading typed artifacts when not needed
- Clear separation of concerns

### Q3: Cache invalidation strategy?

**Decision: Rebuild on demand (Option A)**

When `needsTypedOpt=True` and `typed-artifacts.dat` is missing:
- Trigger a rebuild of that package with typed optimization enabled
- Write `typed-artifacts.dat` alongside existing `artifacts.dat`
- Subsequent builds will use cached typed artifacts

## Testing Strategy

1. **Unit Tests:**
   - `DResult` encoder/decoder roundtrip with typed objects
   - `TOpt.GlobalGraph` encoder/decoder roundtrip
   - `Stuff.typedPackageArtifacts` path generation

2. **Integration Tests:**
   - Build elm/core with `needsTypedOpt=True`
   - Verify `typed-artifacts.dat` is created
   - Verify `TOpt.GlobalGraph` is populated correctly
   - Build project using elm/core, verify typed objects loaded from packages

3. **Cache Invalidation Tests:**
   - Build project with JS backend (no typed artifacts generated)
   - Switch to MLIR backend
   - Verify packages are rebuilt with typed optimization
   - Verify `typed-artifacts.dat` files are created

4. **End-to-End Tests:**
   - Compile Hello.elm with MLIR backend
   - Verify `Html.text` is included as real code, not `MonoExtern`
   - Check all `spec_id` references resolve to defined functions
   - Compare function count before/after (should have many more functions)

## Estimated Scope

| Phase | Files Modified | Complexity |
|-------|----------------|------------|
| Phase 1: Infrastructure | 2 (Stuff.elm, Details.elm) | Low |
| Phase 2: Threading needsTypedOpt | 2-3 (Details.elm, Build.elm, callers) | Medium |
| Phase 3: Package Compilation | 1 (Details.elm) | Medium |
| Phase 4: Loading | 1-2 (Generate.elm, possibly Stuff.elm) | Medium |
| Phase 5: Entry Point Integration | 2 (Make.elm, possibly others) | Medium |

**Total: ~5-7 files modified**

## Key Files Summary

| File | Changes |
|------|---------|
| `Builder/Stuff.elm` | Add `typedPackageArtifacts` path helper |
| `Builder/Elm/Details.elm` | Main changes: DResult, contexts, compile, write artifacts |
| `Builder/Build.elm` | May need `needsTypedOpt` in Env if not already there |
| `Builder/Generate.elm` | Load typed objects from packages |
| `Terminal/Make.elm` | Pass `needsTypedOpt=True` for MLIR output |
