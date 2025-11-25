# Guida Compiler Build Notes

## Repository

- **URL**: git@github.com:guida-lang/compiler.git
- **Commit**: 922b635435c1459404bf31d1c7e84ef59affde8e
- **Date cloned**: 2025-11-25
- **Version**: 1.0.0-alpha

## Overview

Guida is a functional programming language that builds upon Elm, offering backward compatibility with all existing Elm 0.19.1 projects. The compiler is written in Elm and compiles to JavaScript, using a bootstrap approach where an older version of Guida compiles the new version.

## Prerequisites

- **Node.js**: v25.1.0 (specified in `.nvmrc`)
  - Currently using: v24.5.0 (close enough, works fine)
- **npm**: 11.5.1
- **Guida compiler**: 0.3.0-alpha (installed as dev dependency for bootstrapping)

## Build Steps

1. **Clone the repository**:
   ```bash
   cd /home/rupert/sc/gitlab/eco-runtime/worktrees/med
   git clone git@github.com:guida-lang/compiler.git guida
   cd guida
   ```

2. **Install dependencies**:
   ```bash
   npm install
   ```

   This automatically runs the `prepare` script which builds the compiler.

3. **Build manually** (if needed):
   ```bash
   npm run build
   ```

   This runs two sequential build steps:
   - `build:api` - Compiles `src/API/Main.elm` to `lib/guida.js`
   - `build:bin` - Compiles `src/Terminal/Main.elm` to `bin/guida.js`

## Build Process Details

The build process is defined in `scripts/build.sh` and works as follows:

1. Uses the bootstrapped `guida` compiler (from npm devDependencies) to compile Elm source
2. Compiles with `--optimize` flag for production builds
3. Runs `scripts/replacements.js` for post-processing
4. Minifies output using `uglifyjs` with aggressive optimizations
5. Produces both unminified (`.js`) and minified (`.min.js`) versions

Build outputs:
- **API build**: `lib/guida.js` (4.1MB) → `lib/guida.min.js` (799KB) → 207KB gzipped
- **CLI build**: `bin/guida.js` (4.6MB) → `bin/guida.min.js` (920KB) → 242KB gzipped

The compiler compiles 150 modules for the API and 18 modules for the terminal interface.

## Running the Compiler

```bash
# Show version
node bin/index.js --version

# Show help
node bin/index.js --help

# Compile an Elm file
node bin/index.js make src/Main.elm

# With optimization
node bin/index.js make --optimize src/Main.elm

# REPL
node bin/index.js repl

# Initialize a new project
node bin/index.js init
```

## Directory Structure

### Source Code (`src/`)

- **API/** - Programmatic API entry point
- **Builder/** - Build orchestration, dependency resolution
  - `Builder/Deps/` - Dependency management
  - `Builder/Guida/` - Guida-specific builder logic
  - `Builder/Reporting/` - Build error reporting
- **Codec/** - Encoding/decoding for serialization
  - `Codec/Archive/` - Archive handling
- **Common/** - Shared utilities
  - `Common/Format/` - Code formatting utilities
- **Compiler/** - Core compiler implementation
  - `Compiler/AST/` - Abstract Syntax Tree definitions
  - `Compiler/Canonicalize/` - Name resolution and canonicalization
  - `Compiler/Data/` - Compiler data structures
  - `Compiler/Generate/` - Code generation (to JavaScript)
  - `Compiler/Guida/` - Guida-specific compiler logic
  - `Compiler/Json/` - JSON encoding/decoding for compiler data
  - `Compiler/Nitpick/` - Code quality checks
  - `Compiler/Optimize/` - Optimization passes
  - `Compiler/Parse/` - Parser implementation
  - `Compiler/Reporting/` - Compiler error reporting
  - `Compiler/Type/` - Type inference and checking
- **Control/** - Control flow abstractions (Monad implementations)
- **Data/** - Data structure implementations
- **System/** - System I/O interface (see below)
- **Terminal/** - CLI interface implementation
- **Text/** - Pretty printing utilities
- **Utils/** - General utilities including impure operations bridge

### JavaScript Runtime (`lib/`)

- **lib/index.js** - Node.js runtime implementing native I/O operations
- **lib/index.d.ts** - TypeScript type definitions

### Binary Entry Point (`bin/`)

- **bin/index.js** - CLI entry point wrapper

### Other Directories

- **assets/** - Test assets
- **examples/** - Example Elm/Guida programs
- **libraries/** - Cached Elm packages
- **scripts/** - Build scripts
- **tests/** - Test suite
- **try/** - Browser-based compiler demo

## I/O and Runtime Architecture

Guida uses a clever architecture to handle I/O operations while remaining a pure functional language:

### Elm-Side I/O Interface

Located in `src/System/IO.elm`:
- Defines types: `FilePath`, `Handle`, `IOMode`
- Provides functions like `hPutStr`, `writeString`, `withFile`, `getLine`
- All I/O operations return `Task Never a` types
- Uses `Utils.Impure.task` to create pseudo-HTTP requests

### Impure Bridge

Located in `src/Utils/Impure.elm`:
- Converts I/O operations into HTTP POST requests
- Uses Elm's `Http.task` with mock server URLs
- Request body contains operation parameters
- Response contains operation results
- Creates a pure interface to impure operations

### JavaScript Runtime Implementation

Located in `lib/index.js`:
- Uses `mock-xmlhttprequest` to intercept pseudo-HTTP requests
- Implements 24+ I/O operations as HTTP request handlers
- Operations include:
  - **File I/O**: `read`, `write`, `writeString`, `binaryDecodeFileOrFail`
  - **Directory operations**: `dirDoesFileExist`, `dirDoesDirectoryExist`, `dirListDirectory`, `dirCreateDirectoryIfMissing`, `dirGetModificationTime`, `dirGetCurrentDirectory`, `dirGetAppUserDataDirectory`, `dirCanonicalizePath`
  - **Terminal I/O**: `hPutStr` (handles stdout/stderr based on file descriptor)
  - **File locking**: `lockFile`, `unlockFile`
  - **Environment**: `envLookupEnv`
  - **Archives**: `getArchive` (downloads and unpacks ZIP files)
  - **Concurrency**: `newEmptyMVar`, `readMVar`, `takeMVar`, `putMVar` (MVar implementation for concurrency)
  - **Process**: `getArgs`, `exitWithResponse`

### Key I/O Files

1. **src/System/IO.elm** - High-level I/O interface
2. **src/System/Process.elm** - Process spawning and management
3. **src/System/Exit.elm** - Exit codes
4. **src/Utils/Impure.elm** - Bridge between pure Elm and impure JavaScript
5. **lib/index.js** - Complete JavaScript runtime implementation

## Known Issues

1. **Network dependency**: Building requires network access to download Elm packages from package registries
2. **Package registry availability**: Attempting to compile examples failed because `package.guida-lang.org` was unreachable during testing
3. **Bootstrap dependency**: Building Guida requires a previous version of Guida (circular dependency solved via npm package)

## Testing

```bash
# Run all tests
npm test

# Run specific test suites
npm run test:jest        # JavaScript tests
npm run test:elm         # Elm tests
npm run test:elm-review  # Linter tests
npm run test:eslint      # JavaScript linter
```

## Development Workflow

```bash
# Watch mode (auto-rebuild on changes)
npm run watch

# Format Elm code
npm run elm-format

# Clear all caches and rebuild
rm -rf ~/.guida guida-stuff; npm run build
```

## Notes for ECO Runtime Integration

1. **I/O operations are well-documented**: All native operations are clearly defined in `lib/index.js` with their request/response contracts
2. **Pure functional interface**: The I/O system maintains purity through the Task abstraction
3. **Extensible design**: New I/O operations can be added by:
   - Adding Elm interface in `src/System/IO.elm`
   - Adding handler in `lib/index.js`
4. **Self-hosted**: The compiler is written in Elm/Guida, demonstrating the language's capability for real-world applications
5. **MVar implementation**: Includes concurrency primitives (MVars) that could be useful reference for ECO's concurrency model

## Next Steps

For ECO runtime work (as per PLAN.md §2.1.1):
1. Audit all I/O operations in `lib/index.js` - create comprehensive list
2. Map each operation to C++ implementation requirements
3. Determine which operations need native C++ vs. can use JavaScript interop
4. Design C++ API surface for ECO's I/O system
