# Elm.json Configuration in the CMake Build System

## Summary
The compiler build system has ONE primary `elm.json` configuration file that is used by both CMake and npm builds. The other elm.json variant files (elm-bootstrap.json, elm-kernel.json) exist but are NOT currently referenced by the build system.

## Key Findings

### Build Paths

**CMake Build (primary):**
- Located: `/work/CMakeLists.txt` line 47: `add_subdirectory(compiler)`
- Compiler CMake: `/work/compiler/CMakeLists.txt`
- Entry point: `src/Terminal/Main.elm`
- Build command: `elm make --output=bin/guida.js src/Terminal/Main.elm` (line 48)
- Working directory: `${COMPILER_DIR}` (i.e., `/work/compiler/`)
- Config files tracked: `elm.json`, `package.json`, `package-lock.json`, `scripts/build.sh`, `scripts/replacements.js`

**npm Build (alternative):**
- Commands defined in `/work/compiler/package.json`:
  - `npm run build` → runs `npm-run-all --sequential build:*`
  - `npm run build:bin` → `./scripts/build.sh bin`
  - `npm run buildself` → `./scripts/build-self.sh bin`
- Both build scripts ultimately use `elm make` command
- Working directory: `/work/compiler/`

### Elm.json Files in the Repository

**UPDATED 2026-03-25**: Only one elm.json file exists now. The variant files (elm-bootstrap.json, elm-kernel.json) have been removed.

1. **`/work/compiler/elm.json`** (PRIMARY - used by both builds)
   - source-directories: `["src"]`
   - Has test dependencies: `elm-explorations/test`
   - NO `eco/kernel` dependency
   - Used by: CMake `elm make` command

### How elm.json is Selected

The Elm compiler (`elm make` command) automatically looks for `elm.json` in the current working directory. Since:
1. CMake runs: `elm make --output=${COMPILER_OUTPUT} ${ELM_ENTRY}` 
2. With: `WORKING_DIRECTORY ${COMPILER_DIR}` (i.e., `/work/compiler/`)
3. The elm command automatically finds `/work/compiler/elm.json`

The build system always uses the default `elm.json` (the only one that exists).

### Additional Config Files

- **`elm-application.json`**: Defines the "package" metadata for the compiler as if it were published (contains `exposed-modules` list with all compiler modules). Modified: Feb 26 14:15
- **`elm-watch.json`**: Watch mode configuration for development. Simple target mapping. Modified: Dec 18 12:17

### Build Command Flow

1. CMake calls: `${ELM_EXECUTABLE} make --output=${COMPILER_OUTPUT} ${ELM_ENTRY}`
2. Where:
   - ELM_EXECUTABLE = `${COMPILER_DIR}/node_modules/.bin/elm` (found by cmake via `find_program`)
   - COMPILER_OUTPUT = `${COMPILER_DIR}/bin/guida.js`
   - ELM_ENTRY = `${COMPILER_DIR}/src/Terminal/Main.elm`
3. elm command runs in: `${COMPILER_DIR}` (which is `/work/compiler/`)
4. elm automatically reads: `/work/compiler/elm.json`
5. Compilation happens, output written to `bin/guida.js`
6. Node script runs: `node scripts/replacements.js bin/guida.js` for post-processing

### npm Build Script Execution

Both `scripts/build.sh` and `scripts/build-self.sh` follow the same pattern:
- Determine entry point: `src/Terminal/Main.elm` or `src/API/Main.elm`
- Run elm command with entry point
- Execute replacements.js on output

The key difference:
- `build.sh` uses: `elm make --output=$js $elm_entry`
- `build-self.sh` uses: `node bin/index.js make --optimize --output=$js $elm_entry` (uses previously compiled compiler)

### CMake Configuration

**CMakeLists.txt tracked dependencies (lines 23-28):**
```cmake
set(COMPILER_CONFIG_FILES
    "${COMPILER_DIR}/elm.json"              # PRIMARY
    "${COMPILER_DIR}/package.json"
    "${COMPILER_DIR}/package-lock.json"
    "${COMPILER_DIR}/scripts/build.sh"
    "${COMPILER_DIR}/scripts/replacements.js"
)
```

Only `elm.json` is listed (not the variant files).

### Conclusion

- **CMake uses**: `/work/compiler/elm.json` (automatically, no special selection logic)
- **npm uses**: `/work/compiler/elm.json` (automatically)
- **Variant files**: `elm-bootstrap.json` and `elm-kernel.json` have been removed from the repository (as of 2026-03-25)
