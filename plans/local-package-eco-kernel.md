# Plan: `eco/kernel` as a Real Kernel Package via `--local-package`

## Summary

Add a `--local-package pkg=path` CLI flag that lets the compiler resolve a package dependency from a local filesystem path instead of downloading it. Use this to make `eco/kernel` a proper package dependency of the kernel-mode compiler build, replacing the ad-hoc `KernelApplication` source-directory approach. Kernel JS from `Eco.Kernel.*` flows through the existing standard package pipeline (`parseAndCrawlKernel` → `SKernelLocal` → `RKernelLocal` → `GA.addOptKernel`).

## Design Decisions

| Decision | Choice |
|----------|--------|
| Solver version lookup | Hardcode version 1.0.0 for local packages |
| Package source resolution | Compiler reads from configured local path |
| Generality | Fully general `--local-package` mechanism |
| Configuration method | CLI flag only, no elm.json changes |
| Artifact location | Written into the local package directory |
| Multiple local packages | Single `--local-package` flag for now |

## What's Already Done

- `Name.isKernel` (`compiler/src/Compiler/Data/Name.elm:148`) already recognizes `"Eco.Kernel."` prefix
- `Name.getKernel` (`compiler/src/Compiler/Data/Name.elm:133`) works for both prefixes (both 11 chars)
- `Pkg.isKernel` (`compiler/src/Compiler/Elm/Package.elm:118`) already accepts `author == eco`
- `eco-kernel-cpp/elm.json` already defines `eco/kernel` as a package with version `1.0.0`
- `SKernelLocal`/`RKernelLocal` fully wired in `Details.elm` through `parseAndCrawlKernel` → `compile` → `addLocalOptGraph` → `GA.addOptKernel`

## Steps

### Step 1: Extend `PackageCache` with a local package override

**File:** `compiler/src/Builder/Stuff.elm`

- Change `type PackageCache = PackageCache String` to `PackageCache String (Maybe (Pkg.Name, FilePath))`
- Modify `Stuff.package` to check the local override first:
  ```elm
  package (PackageCache dir maybeLocal) name version =
      case maybeLocal of
          Just ( localPkg, localPath ) ->
              if localPkg == name then localPath
              else fpCombine dir (fpCombine (Pkg.toString name) (V.toChars version))
          Nothing ->
              fpCombine dir (fpCombine (Pkg.toString name) (V.toChars version))
  ```
- Add `isLocalPackage : PackageCache -> Pkg.Name -> Bool`
- Update `getPackageCache` to accept a `Maybe (Pkg.Name, FilePath)` parameter
- Update `packageCacheEncoder`/`packageCacheDecoder` to handle the new field
- Update `withRegistryLock`, `registry` to destructure the new shape (they only use the dir string)

**Why:** `Stuff.package` is the single resolution point used by `getConstraints` (solver), `verifyDep` (Details), `build`/`buildWithDirectDeps`/`writePackageArtifacts` (Details), `typedPackageArtifacts`, etc. Changing it once makes local packages work transparently everywhere.

### Step 2: Add `--local-package` CLI flag

**Files:** `compiler/src/Terminal/Make.elm`, `compiler/src/Terminal/Main.elm`

- Add `localPackage : Maybe (Pkg.Name, FilePath)` to `FlagsData`
- Add flag parser:
  ```elm
  localPackage : Parser
  localPackage =
      Parser { singular = "local package mapping", plural = "local package mappings"
             , suggest = \_ -> Task.succeed []
             , examples = \_ -> Task.succeed [ "eco/kernel=../eco-kernel-cpp" ] }

  parseLocalPackage : String -> Maybe (Pkg.Name, FilePath)
  parseLocalPackage str =
      case String.split "=" str of
          [ pkgStr, path ] ->
              Maybe.map (\pkg -> ( pkg, path )) (parseKernelPackage pkgStr)
          _ -> Nothing
  ```
- Register in `Terminal/Main.elm` with `Chomp.chompNormalFlag "local-package" Make.localPackage Make.parseLocalPackage`
- Add `localPackage` to the `Flags` constructor and flag specification
- Thread the parsed value through `runHelp` → `loadDetailsAndBuild` → into `PackageCache` creation

**Threading path:** The local package info must reach `Stuff.getPackageCache`. Currently `getPackageCache` is called in `Solver.initEnv` (line 789), `Details.loadTypedObjects` (line 221), `Outline.elm` (line 492), and various Terminal modules. Pass `Maybe (Pkg.Name, FilePath)` into `Solver.initEnv` which creates the `PackageCache`. For other call sites that don't know about local packages, they use `getPackageCache` with `Nothing`.

### Step 3: Inject local package version into the solver

**File:** `compiler/src/Builder/Deps/Solver.elm`

In the `explore` function (around line 569) where version lookup happens:

```elm
-- Current:
case Registry.getVersions name st.registry of ...

-- New:
if Stuff.isLocalPackage st.cache name then
    -- TODO: Read version from local elm.json instead of hardcoding
    case List.filter (C.satisfies constraint) [ V.Version 1 0 0 ] of
        [] -> Task.succeed (ISBack state)
        v :: _ -> ... continue with v ...
else
    case Registry.getVersions name st.registry of ...
```

The constraint from the application's `elm.json` (e.g., `"eco/kernel": "1.0.0"`) will match the hardcoded version. The solver then calls `getConstraints` which reads from `Stuff.package cache pkg vsn` — this resolves to the local path automatically via Step 1, so it reads `../eco-kernel-cpp/elm.json` for the package's dependency constraints.

### Step 4: Add error handling for missing local packages

**Files:** `compiler/src/Builder/Elm/Details.elm`, `compiler/src/Builder/Reporting/Exit.elm`

In `handleDepExistence` (line 790):

```elm
handleDepExistence ctx exists =
    if exists then
        handleCachedDep ctx
    else if Stuff.isLocalPackage ctx.cache ctx.pkg then
        Task.succeed (Err (Just (Exit.BD_LocalPackageNotFound ctx.pkg)))
    else
        downloadAndBuildDep ctx
```

Add `BD_LocalPackageNotFound Pkg.Name` variant to the appropriate Exit type with message: "Local package eco/kernel not found. Check the path in your --local-package flag."

In the happy path, `Stuff.package` resolves to the local path, `dirDoesDirectoryExist` finds `src/` there, `exists` is `True`, and the existing build path works. This error handling is only for wrong paths.

### Step 5: Add `ecoKernel` constant and `isKernelPackage` predicate

**File:** `compiler/src/Compiler/Elm/Package.elm`

```elm
ecoKernel : Pkg.Name
ecoKernel = toName eco "kernel"

isKernelPackage : Pkg.Name -> Bool
isKernelPackage pkg = pkg == kernel || pkg == ecoKernel
```

Search for `== Pkg.kernel` across the codebase and replace with `Pkg.isKernelPackage pkg` where the intent is "can this package contain kernel modules."

### Step 6: Update `build-kernel/elm.json`

**File:** `compiler/build-kernel/elm.json`

Remove `"src-kernel"` from `source-directories`. Add `"eco/kernel": "1.0.0"` to `dependencies.direct`:

```json
{
    "type": "application",
    "source-directories": ["../src"],
    "dependencies": {
        "direct": {
            "eco/kernel": "1.0.0",
            ...existing deps...
        },
        ...
    }
}
```

### Step 7: Update bootstrap build invocation

Update build scripts/CMake to invoke the kernel build as:

```bash
node eco-boot.js make src/Main.elm --local-package eco/kernel=../eco-kernel-cpp --output bin/eco-node.js
```

Instead of:
```bash
node eco-boot.js make src/Main.elm --kernel-package eco/compiler --output bin/eco-node.js
```

The compiler automatically:
1. Resolves `eco/kernel` to `../eco-kernel-cpp` (via `Stuff.package` local override)
2. Solver finds `eco/kernel 1.0.0` (hardcoded version for local packages)
3. Solver reads constraints from `../eco-kernel-cpp/elm.json`
4. `verifyDep` finds `../eco-kernel-cpp/src/` exists → builds the package
5. `parseAndCrawlKernel` parses `Eco.Kernel.*.js` → `SKernelLocal` → `RKernelLocal`
6. `addLocalOptGraph` calls `GA.addOptKernel` → kernel chunks in global graph
7. Artifacts cached at `../eco-kernel-cpp/artifacts.dat`

No separate "build eco/kernel as a package" step is needed.

### Step 8: (Future, not this PR) Clean up `KernelApplication`

Once the package-based path is stable:
- Remove `KernelApplication` from `Parse.Module.ProjectType`
- Remove `maybeKernelPackage` from `FlagsData` and all threading
- Remove `checkKernelExistsInDirs` from `Build.elm`
- Remove `--kernel-package` flag

## Assumptions

- The local path `../eco-kernel-cpp` is resolved relative to CWD at invocation time
- Artifacts written to `../eco-kernel-cpp/artifacts.dat` should be added to `.gitignore`
- The XHR bootstrap build (`build-xhr/elm.json`) is completely unaffected
- Only one `--local-package` flag is supported at a time
- Version `1.0.0` is hardcoded for local packages (TODO to read from local `elm.json`)
- The `toKernelGlobal` hardcoding of `Pkg.kernel` for kernel global keys is acceptable (eco and elm kernel modules share the logical kernel namespace, no naming conflicts in practice)
- `eco-boot.js` can handle `type: "package"` elm.json files for dependency resolution
