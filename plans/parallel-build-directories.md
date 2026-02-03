# Plan: Parallel Build Directories for Compiler and E2E Tests

## Overview

Add a `--builddir` command-line option to the compiler `make` command that specifies a subdirectory under the normal `guida-stuff/1.0.0/` build folder. This enables multiple builds to run in parallel without overwriting each other's cache files.

Then update the E2E test runner to use this feature for parallel test compilation.

## Motivation

Currently, when multiple `guida make` commands run simultaneously against the same project (same `elm.json`), they compete for the same cache files in `guida-stuff/1.0.0/`:
- `d.dat` (project details)
- `i.dat` (module interfaces)
- `o.dat` (compiled objects)
- `to.dat` (typed optimized objects)
- `.guidai`, `.guidao`, `.guidato` per-module artifacts

This causes race conditions during parallel E2E test compilation.

## Part 1: Compiler `--builddir` Flag

### 1.1 Add Flag to FlagsData

**File:** `compiler/src/Terminal/Make.elm`

Add `buildDir : Maybe String` to `FlagsData`:

```elm
type alias FlagsData =
    { debug : Bool
    , optimize : Bool
    , withSourceMaps : Bool
    , output : Maybe Output
    , report : Maybe ReportType
    , docs : Maybe String
    , showPackageErrors : Bool
    , buildDir : Maybe String  -- NEW: subdirectory under guida-stuff/1.0.0/
    }
```

### 1.2 Add Flag Parser

**File:** `compiler/src/Terminal/Main.elm`

Add the `--builddir` flag to the `make` command's flag definitions:

```elm
-- In the makeFlags definition, add:
|> Terminal.more (Terminal.flag "builddir" Make.buildDir parseBuildDir)

-- Add parser (in Make.elm):
buildDir : Terminal.Parser String
buildDir =
    Parser
        { singular = "build-directory"
        , plural = "build-directories"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> [ "TestName", "MyBuild" ]
        }

parseBuildDir : String -> Maybe String
parseBuildDir dir =
    -- Validate: no path separators, no special characters
    if String.isEmpty dir then
        Nothing
    else if String.contains "/" dir || String.contains "\\" dir then
        Nothing
    else
        Just dir
```

### 1.3 Modify Build Path Resolution

**File:** `compiler/src/Builder/Stuff.elm`

Add a new function that respects the buildDir:

```elm
{-| Get the stuff directory, optionally with a build subdirectory.
-}
stuffWithBuildDir : String -> Maybe String -> String
stuffWithBuildDir root maybeBuildDir =
    case maybeBuildDir of
        Nothing ->
            stuff root

        Just buildDir ->
            stuff root ++ "/" ++ buildDir
```

### 1.4 Thread buildDir Through the Build System

The `buildDir` needs to be threaded through:

1. **`Terminal/Make.elm`** - Pass `flags.buildDir` to the build functions
2. **`Builder/Build.elm`** - Accept `buildDir` parameter and use `stuffWithBuildDir`
3. **`Builder/Elm/Details.elm`** - Use modified paths for `d.dat`
4. **`Builder/File.elm`** - Use modified paths for `i.dat`, `o.dat`, `to.dat`

Key functions to modify:
- `Build.fromPaths` - accept and thread buildDir
- `Details.loadDetails` / `Details.writeDetails` - use buildDir-aware paths
- `Stuff.toArtifactPath` - needs a buildDir-aware variant

### 1.5 Example Usage

```bash
# Normal build (no change)
node index.js make src/Main.elm --output=main.mlir

# Build to specific subdirectory
node index.js make src/Main.elm --output=main.mlir --builddir=TestBuild

# This would output artifacts to:
# guida-stuff/1.0.0/TestBuild/d.dat
# guida-stuff/1.0.0/TestBuild/i.dat
# guida-stuff/1.0.0/TestBuild/o.dat
# guida-stuff/1.0.0/TestBuild/Main.guidai
# guida-stuff/1.0.0/TestBuild/Main.guidao
# etc.
```

## Part 2: E2E Test Runner Parallel Compilation

### 2.1 Current Two-Phase Approach

The current `ElmTest.hpp` uses a two-phase approach:
- **Phase 1:** Compile all .elm → .mlir sequentially (to avoid race conditions)
- **Phase 2:** Run .mlir tests in parallel

This is inefficient because compilation is single-threaded.

### 2.2 New Two-Phase Approach

1. **Phase 1 (Compile):** Compile tests with `--builddir=<TestName>` for isolation
   - First test compiles alone (populates shared dependency cache in `~/.elm/` or `~/.guida/`)
   - Subsequent tests compile in parallel (up to N workers, default 8)
2. **Phase 2 (Run):** Run .mlir tests in parallel (unchanged)

### 2.3 Implementation Changes

**File:** `test/elm/ElmTest.hpp`

#### 2.3.1 Modify `compileElmToMlir` to accept buildDir

```cpp
inline CompileResult compileElmToMlir(const std::string& elmPath,
                                       const std::string& buildDir) {
    // ... existing code ...

    std::string compileCmd = "cd \"" + elmTestDir + "\" && node \"" + guidaPath +
                             "\" make \"" + elmPath + "\" --output=\"" + result.mlirPath + "\"" +
                             " --builddir=\"" + buildDir + "\"";

    // ... rest of compilation ...
}
```

#### 2.3.2 Add Parallel Compilation Function

```cpp
/**
 * Compile Elm tests with --builddir for isolation.
 * First test compiles alone to populate shared dependency cache.
 * Subsequent tests compile in parallel.
 *
 * @param elmPaths List of .elm file paths to compile
 * @param maxParallel Maximum number of parallel compilations (default 8)
 * @return Vector of CompileResults
 */
inline std::vector<CompileResult> compileElmTestsParallel(
    const std::vector<std::string>& elmPaths,
    size_t maxParallel = 8)
{
    if (elmPaths.empty()) return {};

    std::vector<CompileResult> results;
    results.resize(elmPaths.size());

    // Ensure output directory exists
    ensureMlirDirExists();

    // Compile first test alone (populates shared dependency cache in ~/.elm/)
    std::string firstFile = std::filesystem::path(elmPaths[0]).stem().string();
    std::cout << "Compiling first test (populates dependency cache)..." << std::endl;
    std::cout << "  [1/" << elmPaths.size() << "] " << firstFile << ".elm";

    results[0] = compileElmToMlir(elmPaths[0], firstFile);
    std::cout << (results[0].success ? " ok" : " FAILED") << std::endl;

    if (elmPaths.size() == 1) {
        return results;
    }

    // Compile remaining tests in parallel with unique builddirs
    std::cout << "Compiling " << (elmPaths.size() - 1)
              << " remaining tests in parallel (max " << maxParallel << " workers)..."
              << std::endl;

    std::atomic<size_t> nextIndex{1};
    std::atomic<size_t> completed{1};
    std::mutex outputMutex;

    auto worker = [&]() {
        while (true) {
            size_t idx = nextIndex.fetch_add(1);
            if (idx >= elmPaths.size()) break;

            const std::string& elmPath = elmPaths[idx];
            std::string filename = std::filesystem::path(elmPath).stem().string();
            std::string buildDir = filename;  // Use test name as builddir

            // Check if cached
            std::string mlirPath = getMlirPath(elmPath);
            bool cached = !needsRecompile(elmPath, mlirPath);

            CompileResult result;
            if (cached) {
                result.elmPath = elmPath;
                result.mlirPath = mlirPath;
                result.success = true;
            } else {
                result = compileElmToMlir(elmPath, buildDir);
            }
            results[idx] = result;

            // Thread-safe output
            {
                std::lock_guard<std::mutex> lock(outputMutex);
                size_t done = ++completed;
                std::cout << "  [" << std::setw(3) << done << "/" << elmPaths.size() << "] "
                          << filename << ".elm"
                          << (cached ? " (cached)" : (result.success ? " ok" : " FAILED"))
                          << std::endl;
            }
        }
    };

    // Launch worker threads
    std::vector<std::thread> threads;
    size_t numThreads = std::min(maxParallel, elmPaths.size() - 1);
    for (size_t i = 0; i < numThreads; i++) {
        threads.emplace_back(worker);
    }

    // Wait for all threads
    for (auto& t : threads) {
        t.join();
    }

    // Summary
    size_t compiledCount = 0, failedCount = 0;
    for (const auto& r : results) {
        if (r.success) compiledCount++;
        else failedCount++;
    }

    std::cout << "Compilation complete: " << compiledCount << " succeeded, "
              << failedCount << " failed" << std::endl;

    return results;
}
```

#### 2.3.3 Update `ElmParallelTestSuite::runFiltered`

Replace the call to `compileAllElmTests` with `compileElmTestsParallel`:

```cpp
bool runFiltered(const std::string& filter) const {
    // ... collect tests matching filter ...

    // ================================================================
    // PHASE 0+1: Compile Elm files to MLIR (parallel with isolation)
    // ================================================================
    auto compileResults = compileElmTestsParallel(pathsToRun, 8);  // 8 parallel workers

    // ... rest unchanged (Phase 2: parallel MLIR execution) ...
}
```

### 2.4 Configuration

Add a configurable parallelism level:

```cpp
// In ElmTest.hpp or IsolatedTestRunner.hpp
constexpr size_t MAX_PARALLEL_COMPILES = 8;  // Default parallel compile workers
```

This could also be made a command-line option for the test runner.

## Implementation Order

### Step 1: Compiler Changes

1. **Add `buildDir` field to `FlagsData`** (`Terminal/Make.elm`)
   - Add `buildDir : Maybe String` to the record

2. **Add flag parser** (`Terminal/Main.elm`)
   - Add `--builddir` flag to `makeFlags`
   - Add `parseBuildDir` validation function

3. **Add buildDir-aware path functions** (`Builder/Stuff.elm`)
   - Add `stuffWithBuildDir : String -> Maybe String -> String`
   - Add `toArtifactPathWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String -> String`

4. **Thread `buildDir` through build system**
   - `Build.fromPaths` - accept and pass buildDir
   - `Details.loadDetails` / `writeDetails` - use buildDir-aware paths
   - File operations for `i.dat`, `o.dat`, `to.dat`

5. **Test manually**
   - `node index.js make src/Test.elm --output=Test.mlir --builddir=Foo`
   - Verify artifacts appear in `guida-stuff/1.0.0/Foo/`

### Step 2: Test Runner Changes

1. **Modify `compileElmToMlir`** (`test/elm/ElmTest.hpp`)
   - Accept `buildDir` parameter
   - Always pass `--builddir` to compiler

2. **Add `compileElmTestsParallel` function**
   - First test compiles alone (with builddir)
   - Remaining tests compile in parallel with worker threads

3. **Update `ElmParallelTestSuite::runFiltered`**
   - Replace `compileAllElmTests` with `compileElmTestsParallel`

4. **Test with E2E suite**
   - Run full test suite
   - Verify parallel compilation works
   - Compare results to sequential baseline

## Design Decisions (Clarified)

1. **Shared vs Isolated Dependencies:** Package dependencies from `~/.elm/` or `~/.guida/` are shared. The first test build populates this cache, and subsequent parallel builds read from it. Only project-specific artifacts (`.guidai`, `.guidao`, `.guidato`, `d.dat`, etc.) go in the builddir.

2. **Lock File Handling:** No locks needed. Each builddir is isolated, and the shared dependency cache (`~/.elm/`) is read-only after the first test compiles.

3. **MLIR Output Location:** `--output` paths remain unchanged (absolute or relative to pwd). The `--builddir` only affects the intermediate cache/artifact paths under `guida-stuff/1.0.0/`.

4. **Cache Loading:** The Elm compiler already loads from the main cache naturally. No special handling needed - the builddir is just an additional layer for project-specific artifacts.

5. **First-Test Compilation:** The first test compiles WITH `--builddir` (using its own test name). It still populates the shared dependency cache in `~/.elm/` as a side effect.

### Key Constraints

- The `--builddir` value must be a simple directory name (no path separators, no special chars)
- Parallel test compilation reuses package dependencies from `~/.elm/` (populated by first test)
- 8 parallel workers is the default (configurable)

## Testing Plan

1. **Manual Test:** Verify `--builddir=Foo` creates artifacts in `guida-stuff/1.0.0/Foo/`
2. **Parallel Safety Test:** Run two compilations in parallel with different builddirs, verify no corruption
3. **E2E Test:** Run full elm-bytes test suite with parallel compilation, compare results to sequential
4. **Performance Test:** Measure compilation time before/after parallel changes (expect ~N× speedup where N = worker count)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Increased disk usage | Each builddir duplicates project artifacts | Clean builddirs after test run |
| Memory pressure | Multiple Node.js processes | Limit parallelism (default 8) |
| Partial builddirs on failure | Stale artifacts | Clean on failure or at start of test run |
| First test failure blocks all | No dependency cache | Report clearly, fail fast |
