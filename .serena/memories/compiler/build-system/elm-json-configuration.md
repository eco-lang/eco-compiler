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

Three distinct elm.json files exist:

1. **`/work/compiler/elm.json`** (PRIMARY - used by both builds)
   - Modified: Jan 16 14:28
   - source-directories: `["src"]`
   - Has test dependencies: `elm-explorations/test`
   - NO `eco/kernel` dependency
   - Used by: CMake `elm make` command

2. **`/work/compiler/elm-bootstrap.json`** (variant)
   - Modified: Feb 27 10:50
   - source-directories: `["src", "src-xhr"]`
   - NO test dependencies
   - NO `eco/kernel` dependency
   - Status: Not used by build system (created recently, likely experimental)

3. **`/work/compiler/elm-kernel.json`** (variant)
   - Modified: Feb 27 10:50
   - source-directories: `["src"]`
   - NO test dependencies
   - INCLUDES `eco/kernel` dependency (unique difference)
   - Status: Not used by build system (created recently, likely experimental)

### How elm.json is Selected

The Elm compiler (`elm make` command) automatically looks for `elm.json` in the current working directory. Since:
1. CMake runs: `elm make --output=${COMPILER_OUTPUT} ${ELM_ENTRY}` 
2. With: `WORKING_DIRECTORY ${COMPILER_DIR}` (i.e., `/work/compiler/`)
3. The elm command automatically finds `/work/compiler/elm.json`

There is NO special logic to select between the three elm.json files. The build system always uses the default `elm.json`.

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
- **Variant files**: `elm-bootstrap.json` and `elm-kernel.json` are not currently used by the build system
  - Likely experimental/future features for bootstrapping or kernel compilation
  - Created recently (Feb 27) relative to elm.json (Jan 16)
  - No references in build scripts or CMake configuration
