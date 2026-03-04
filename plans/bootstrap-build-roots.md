# Bootstrap Build Roots

## Goal

Set up separate build roots for the two initial bootstrapping stages:

1. **Step 1 (XHR build)**: Stock Elm compiler → `guida.js` (using XHR IO via `src-xhr/`)
2. **Step 2 (Kernel build)**: `guida.js` self-compiles → `eco-boot.js` (using eco kernel JS)

This replaces the current scheme of multiple `elm-*.json` files at the compiler root with proper build directories, and establishes the kernel namespace machinery needed for self-compilation.

## Evidence from Code Investigation

### Source-directories: `../src` works with stock Elm

**Tested empirically**: Stock Elm 0.19.1 (from npm) accepts `"../src"` in `source-directories`. Created `/tmp/elm-test-parent-dir/subdir/elm.json` with `"source-directories": ["../src"]`, ran `elm make` from `subdir/` — compilation proceeded past source directory validation (only failed at type checking because the test `main` wasn't a Program). Symlinks also work.

This means both build directories can run `elm make` directly from their own location, using `"../src"` and `"../src-xhr"` to reference the parent's source directories. No copy-to-root pattern needed.

### Application namespace

When building an application, `Build.projectTypeToPkg` returns `Pkg.dummyName` = `("author", "project")` (`Compiler/Elm/Package.elm:155`). This dummy name is used as the package identifier for all modules compiled in application mode. It is referenced in `Build.elm` at compilation (line 1333), artifact assembly (line 2332), and REPL (line 1934). Changing this to a real package name (e.g., `("eco", "compiler")`) would give the project a proper identity for kernel privileges.

### Four kernel module gates

There are exactly four checks that must all pass for kernel modules to work:

1. **`Name.isKernel`** (`Compiler/Data/Name.elm:148`): `String.startsWith "Elm.Kernel."` — only recognizes `Elm.Kernel.*` prefix. `"Eco.Kernel.File"` returns **False**. Both `"Elm.Kernel."` and `"Eco.Kernel."` are 11 characters, so `getKernel` (which does `String.dropLeft 11`) works identically for both.

2. **`Pkg.isKernel`** (`Compiler/Elm/Package.elm:118`): `author == elm || author == elmExplorations` — only `"elm"` and `"elm-explorations"` are whitelisted.

3. **`Parse.isKernel`** (`Compiler/Parse/Module.elm:109`): Returns `True` only for `Package pkg` where `Pkg.isKernel pkg`. Returns `False` for `Application`. This is checked when parsing source files (line 158 for infixes, line 271 for effect managers) and critically in `Build.crawlNoLocalPath` (line 611) for kernel import resolution.

4. **`Build.checkKernelExists`** (`Builder/Build.elm:619`): Hardcodes `File.exists ("src/" ++ ModuleName.toFilePath name ++ ".js")` — only looks in `"src/"` relative to CWD. For packages, `Details.crawlKernel` (line 1477) correctly uses the package's source directory, but the application-mode code path does not.

### Kernel JS import resolution

Traced through `Compiler/Elm/Kernel.elm:addImport` (line 404):
- If `Name.isKernel importName` → kernel import: `getKernel "Eco.Kernel.Scheduler"` returns `"Scheduler"`, variables map to `JsVar "Scheduler" "succeed"` → generates `_Scheduler_succeed` in output.
- This is identical to what `Elm.Kernel.Scheduler` generates, meaning `Eco.Kernel.Scheduler` correctly aliases elm/core's scheduler.
- The import processing only builds a variable mapping table (`VarTable`). It does NOT check for kernel JS file existence. File existence is only checked by `Build.checkKernelExists` and `Details.crawlKernel`, which are called during module discovery (not during kernel JS parsing). So `import Eco.Kernel.Scheduler` in a kernel JS comment is fine — it maps to the same `_Scheduler_*` symbols without needing a Scheduler.js file.

### ProjectType is not serialized

`ProjectType` is never serialized/deserialized — it is rebuilt from `elm.json` on every build. The `statusEncoder`/`statusDecoder` in `Build.elm` handle the `Status` type (which includes `SKernel`), not `ProjectType`. Adding a `KernelApplication` variant requires no serialization work.

### ProjectType flow

`Details.load` reads `elm.json` → `verifyApp`/`verifyPkg` → creates `ValidApp srcDirs` or `ValidPkg pkg exposedModules`. In `Build.makeEnv`:
- `ValidApp` → `projectType = Parse.Application`, srcDirs from elm.json
- `ValidPkg` → `projectType = Parse.Package pkg`, srcDirs hardcoded to `["src"]`

Using `Package pkg` for the kernel self-compile would lose the custom srcDirs. A new `ProjectType` variant is needed.

### Runner (bin/index.js)

The runner does three things:
1. Creates a mock XHR server via `mock-xmlhttprequest`
2. Routes IO requests to `eco-io-handler.js` (which implements them using Node.js APIs)
3. Loads `guida.js` and runs `Elm.Terminal.Main.init()`

For step 2, the same runner executes guida.js, which then compiles the compiler with kernel IO. The runner path to `guida.js` is currently `require("./guida.js")` (line 30 of `index.js`).

### CLI flag pattern

Guida already supports `--builddir <name>` as an optional flag (`Terminal/Make.elm:556`). The pattern is:
1. Add a `Parser` in `Terminal/Make.elm`
2. Add a field to `FlagsData`
3. Wire through `Chomp.chompNormalFlag` in `Terminal/Main.elm` (line 308)
4. Thread the value through `runHelp` → `runHelpWithScope` → `loadDetailsAndBuild`

### Environment variable pattern

Guida already reads `ECO_HOME` (`Builder/Stuff.elm:329`) and `GUIDA_REGISTRY` (`Builder/Deps/Website.elm:25`) via `Utils.envLookupEnv`.

## Proposed Directory Structure

```
compiler/
├── build-xhr/
│   ├── elm.json            (application: ["../src", "../src-xhr"], deps include elm/http)
│   ├── bin/
│   │   └── guida.js        (step 1 output)
│   └── elm-stuff/          (gitignored)
├── build-kernel/
│   ├── elm.json            (application: ["../src", "../src-kernel"], no elm/http)
│   ├── src-kernel → ../../eco-kernel-cpp/src   (symlink)
│   ├── bin/
│   │   └── eco-boot.js     (step 2 output)
│   └── elm-stuff/          (gitignored)
├── src/                    (unchanged — all compiler source)
├── src-xhr/                (unchanged — XHR IO implementations)
├── tests/                  (unchanged)
├── elm.json                (REMOVED)
├── elm-bootstrap.json      (REMOVED)
├── elm-kernel.json         (REMOVED)
├── elm-application.json    (KEEP for now)
├── bin/                    (runners: index.js, eco-boot-runner.js, eco-io-handler.js)
├── scripts/                (build.sh, replacements.js, etc.)
└── ...
```

## Step-by-step Plan

### Phase A: Kernel Namespace Machinery

This must come first — it goes into the step 1 source so that the guida.js from step 1 can compile kernel modules in step 2.

#### A1. Add `Eco.Kernel.` as a kernel module prefix

In `compiler/src/Compiler/Data/Name.elm`:

```elm
-- Current:
prefixKernel = "Elm.Kernel."
isKernel = String.startsWith prefixKernel

-- New:
prefixKernel = "Elm.Kernel."
prefixEcoKernel = "Eco.Kernel."
isKernel name = String.startsWith prefixKernel name || String.startsWith prefixEcoKernel name
```

`getKernel` needs no change — both prefixes are 11 characters, so `String.dropLeft 11` works for both.

#### A2. Add `eco` to the kernel author whitelist

In `compiler/src/Compiler/Elm/Package.elm`:

```elm
isKernel ( author, _ ) =
    author == elm || author == elmExplorations || author == eco

eco =
    "eco"
```

#### A3. Add `KernelApplication` variant to `ProjectType`

In `compiler/src/Compiler/Parse/Module.elm`:

```elm
type ProjectType
    = Package Pkg.Name
    | Application
    | KernelApplication Pkg.Name

isKernel projectType =
    case projectType of
        Package pkg ->
            Pkg.isKernel pkg
        Application ->
            False
        KernelApplication pkg ->
            Pkg.isKernel pkg

isCore projectType =
    case projectType of
        Package pkg ->
            Pkg.isCore pkg
        Application ->
            False
        KernelApplication _ ->
            False
```

This preserves the application's srcDirs handling while enabling kernel privileges. Every `case` on `ProjectType` throughout the codebase needs a `KernelApplication` branch added. The `fromByteString` calls (Build.elm lines 636, 854, 1850, 2198) pass `projectType` through to parsing — all need to handle the new variant.

#### A4. Add `--kernel-package` CLI flag

In `compiler/src/Terminal/Make.elm`, add to `FlagsData`:

```elm
type alias FlagsData =
    { ...
    , kernelPackage : Maybe Pkg.Name
    }
```

Add parser (following the `buildDir` pattern):
```elm
kernelPackage =
    Parser
        { singular = "kernel package"
        , plural = "kernel packages"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "eco/compiler" ]
        }

parseKernelPackage str =
    case String.split "/" str of
        [ author, name ] -> Just (Pkg.toName author name)
        _ -> Nothing
```

Wire in `Terminal/Main.elm` via `Chomp.chompNormalFlag "kernel-package" ...`.

#### A5. Thread `kernelPackage` through to `Build.makeEnv`

The value flows: `Terminal.Main` → `Make.run` → `Make.runHelp` → `Make.runHelpWithScope` → `Make.loadDetailsAndBuild` → `Build.fromPaths` / `Build.fromExposed` → `Build.makeEnv`.

In `Builder/Build.elm`, `makeEnv` currently takes `key`, `root`, `maybeBuildDir`, `details`, `needsTypedOpt`. Add `maybeKernelPackage : Maybe Pkg.Name`. When constructing `Env` for `ValidApp`:

```elm
Details.ValidApp givenSrcDirs ->
    ...
    Env
        { ...
        , projectType =
            case maybeKernelPackage of
                Nothing -> Parse.Application
                Just pkg -> Parse.KernelApplication pkg
        , ...
        }
```

Update `projectTypeToPkg`:
```elm
projectTypeToPkg projectType =
    case projectType of
        Parse.Package pkg -> pkg
        Parse.Application -> Pkg.dummyName
        Parse.KernelApplication pkg -> pkg
```

#### A6. Fix `checkKernelExists` to search all srcDirs

Currently hardcoded to `"src/"`. Modify `crawlNoLocalPath` to accept srcDirs and search them:

```elm
crawlNoLocalPath name projectType foreigns srcDirs =
    ...
    if Name.isKernel name && Parse.isKernel projectType then
        checkKernelExistsInDirs name srcDirs
    ...

checkKernelExistsInDirs name srcDirs =
    case srcDirs of
        [] ->
            SBadImport Import.NotFound |> Task.succeed
        (AbsoluteSrcDir dir) :: rest ->
            let jsPath = dir ++ "/" ++ ModuleName.toFilePath name ++ ".js"
            in File.exists jsPath
                |> Task.andThen (\exists ->
                    if exists then Task.succeed SKernel
                    else checkKernelExistsInDirs name rest
                )
```

This requires threading `envData.srcDirs` through `crawlFoundPaths` → `crawlNoLocalPath`. The Env is already available at `crawlModule` (line 545), so this is a straightforward parameter addition.

### Phase B: Step 1 (XHR Build) Setup

#### B1. Create `compiler/build-xhr/` directory

Create directory structure:
```
compiler/build-xhr/
├── elm.json
└── bin/       (empty, will receive guida.js)
```

`elm.json` content — same deps as current `compiler/elm.json`, with relative source paths:

```json
{
    "type": "application",
    "source-directories": ["../src", "../src-xhr"],
    "elm-version": "0.19.1",
    "dependencies": { ... same as current ... },
    "test-dependencies": { ... same as current ... }
}
```

#### B2. Update `compiler/CMakeLists.txt` for step 1

Build runs from `build-xhr/` directly (no copy needed):

```cmake
set(BUILD_XHR_DIR "${COMPILER_DIR}/build-xhr")
set(COMPILER_OUTPUT "${BUILD_XHR_DIR}/bin/guida.js")
set(ELM_ENTRY "${COMPILER_DIR}/src/Terminal/Main.elm")

add_custom_command(
    OUTPUT ${COMPILER_OUTPUT}
    COMMAND ${ELM_EXECUTABLE} make --output=${COMPILER_OUTPUT} ${ELM_ENTRY}
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/scripts/replacements.js ${COMPILER_OUTPUT}
    DEPENDS ${NPM_STAMP} ${ELM_SOURCES} ${BUILD_XHR_DIR}/elm.json
    WORKING_DIRECTORY ${BUILD_XHR_DIR}
    COMMENT "Building guida compiler (step 1: XHR)"
)
```

Note: `WORKING_DIRECTORY` is `build-xhr/`, `ELM_ENTRY` and `COMPILER_OUTPUT` use absolute paths. The `elm` binary finds `build-xhr/elm.json` as the project root.

#### B3. Update `compiler/scripts/build.sh`

```bash
cd "$(dirname "$0")/../build-xhr"
elm make --output=bin/guida.js ../src/Terminal/Main.elm
node ../scripts/replacements.js bin/guida.js
```

#### B4. Update runner scripts

Update `compiler/bin/index.js` line 30:
```js
const { Elm } = require("../build-xhr/bin/guida.js");
```

#### B5. Handle `elm-test-rs`

Try:
```bash
cd compiler
npx elm-test-rs --project build-xhr --fuzz 1
```

If `elm-test-rs` expects tests at `build-xhr/tests/`, add a symlink:
```
compiler/build-xhr/tests → ../tests
```

The `build-xhr/elm.json` already includes test-dependencies and `"../src"` covers the test source paths.

### Phase C: Step 2 (Kernel Build) Setup

#### C1. Create `compiler/build-kernel/` directory

```
compiler/build-kernel/
├── elm.json
├── src-kernel → ../../eco-kernel-cpp/src   (symlink to kernel source)
└── bin/       (empty, will receive eco-boot.js)
```

`elm.json` content — same deps minus `elm/http`, with kernel source directory:

```json
{
    "type": "application",
    "source-directories": ["../src", "src-kernel"],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            ... same as current but WITHOUT elm/http ...
        },
        "indirect": { ... }
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
```

The `src-kernel` symlink points to `../../eco-kernel-cpp/src`, making the eco kernel `.elm` and `.js` files available. Note: `"../src"` for the compiler source, `"src-kernel"` for the kernel source (relative to build-kernel/).

#### C2. Add step 2 build script / CMake target

Run from `build-kernel/` directly:

```bash
cd compiler/build-kernel
node ../bin/index.js make \
    --kernel-package eco/compiler \
    --output=bin/eco-boot.js \
    ../src/Terminal/Main.elm
```

The `--kernel-package eco/compiler` flag tells Guida to:
- Set `projectType = KernelApplication ("eco", "compiler")`
- Allow `Eco.Kernel.*` imports in source files
- Look for kernel JS files across all source directories
- Use `("eco", "compiler")` as the module package identity

CMake target:
```cmake
set(BUILD_KERNEL_DIR "${COMPILER_DIR}/build-kernel")
set(ECO_BOOT_OUTPUT "${BUILD_KERNEL_DIR}/bin/eco-boot.js")

add_custom_target(eco-boot
    COMMAND ${NODE_EXECUTABLE} ${COMPILER_DIR}/bin/index.js make
        --kernel-package eco/compiler
        --output=${ECO_BOOT_OUTPUT}
        ${COMPILER_DIR}/src/Terminal/Main.elm
    DEPENDS guida
    WORKING_DIRECTORY ${BUILD_KERNEL_DIR}
    COMMENT "Building eco-boot compiler (step 2: kernel)"
)
```

#### C3. Update `compiler/bin/eco-boot-runner.js`

Point to the new output location:
```js
const { Elm } = require("../build-kernel/bin/eco-boot.js");
```

### Phase D: Cleanup

#### D1. Remove old config files
- Remove `compiler/elm.json`
- Remove `compiler/elm-bootstrap.json`
- Remove `compiler/elm-kernel.json`

#### D2. Update `.gitignore`
```
compiler/build-xhr/elm-stuff/
compiler/build-kernel/elm-stuff/
compiler/build-xhr/bin/
compiler/build-kernel/bin/
```

#### D3. Update CLAUDE.md and build documentation
Update build commands to reflect new structure.

## Questions and Open Issues

### Q1: `elm-test-rs --project` behavior

We need to verify: does `elm-test-rs --project build-xhr` find tests at `build-xhr/tests/` or relative to the current directory? If the former, a `build-xhr/tests → ../tests` symlink is needed. Easy to test empirically.

### Q2: elm/http dependency in kernel build

The XHR build needs `elm/http` (used by `src-xhr/`). The kernel build does NOT — `src-kernel/` uses kernel JS directly. But `src/` (the compiler source) has modules that import `Eco.Http`. In the XHR build, `Eco.Http` comes from `src-xhr/Eco/Http.elm` (which imports `elm/http`). In the kernel build, `Eco.Http` comes from `src-kernel/Eco/Http.elm` (which uses `Eco.Kernel.Http`). Need to verify `src/` itself doesn't directly import `elm/http` modules.

### Q3: All `case` branches on `ProjectType`

Adding `KernelApplication Pkg.Name` to `ProjectType` means every pattern match on `ProjectType` throughout the codebase needs updating. The compiler will flag these as incomplete patterns. Key locations:
- `Parse.Module.isKernel` (line 109)
- `Parse.Module.isCore` (line 93)
- `Parse.Module.checkModule` (line 186 — ports check, line 262)
- `Build.makeEnv` (already handled via `ValidApp`)
- `Build.projectTypeToPkg` (line 1586)

This is mechanical but must be complete. The Elm compiler will catch all missed cases.

### Q4: `node_modules` availability from build dirs

When running `elm make` from `build-xhr/`, the `elm` binary is at `compiler/node_modules/.bin/elm`. The CMakeLists.txt already uses an absolute path for `ELM_EXECUTABLE`, so this is fine. But `scripts/build.sh` uses `elm` from PATH — ensure `node_modules/.bin` is in PATH or use an explicit path.

### Assumptions

- Stock Elm 0.19.1 accepts `../src` in source-directories (tested empirically).
- `ProjectType` is never serialized — adding `KernelApplication` needs no encoder/decoder.
- Each build root gets independent `elm-stuff/` caches.
- The `eco-io-handler.js` script doesn't need changes.
- `elm/http` is needed as a test dependency for the XHR build.
- Kernel JS import comments are purely declarative symbol mappings — no file existence checks.
- The `Eco.Kernel.Scheduler` → `_Scheduler_*` mapping correctly aliases elm/core's scheduler.
