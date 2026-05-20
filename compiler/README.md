# Eco Compiler

Eco is a new compiler for the Elm language, designed for native compilation via LLVM.

The front-end is written in Elm itself and is self-compiling. A new back-end has been developed using MLIR to define a custom "eco" dialect. The front-end compiles Elm source code to "eco", and the back-end lowers "eco" to LLVM, reaching many compilation targets including x86, ARM, and WebAssembly.

## Lineage

The Eco compiler forked from the [Guida compiler](https://github.com/guida-lang/compiler) written by Décio Ferreira. The Guida compiler was itself forked from the original [Elm compiler](https://github.com/elm/compiler) in Haskell written by Evan Czaplicki.

## Architecture

The compiler transforms Elm source code through six major phases:

```
Source Code (.elm files)
       │
       ▼
┌─────────────────┐
│   1. PARSE      │  Text → Source AST
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 2. CANONICALIZE │  Source AST → Canonical AST
└────────┬────────┘  (Name resolution, scope checking)
         │
         ▼
┌─────────────────┐
│ 3. TYPE CHECK   │  Canonical AST → Typed Canonical AST
└────────┬────────┘  (Constraint generation + solving)
         │
         ▼
┌─────────────────┐
│   4. NITPICK    │  Verify exhaustiveness, check Debug usage
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  5. OPTIMIZE    │  Canonical AST → Optimized AST
└────────┬────────┘  (Case compilation, inlining, DCE)
         │
         ▼
┌─────────────────┐
│  6. GENERATE    │  Optimized AST → Target Code
└─────────────────┘  (JavaScript or MLIR)
```

The key insight enabling aggressive optimizations is Elm's purity guarantee: no side effects, immutable data, and referential transparency. This means inlining is always safe, dead code elimination is straightforward, and monomorphization is viable for native compilation.

For detailed compiler internals, see [THEORY.md](THEORY.md).

## Backends

### JavaScript Backend

Generates ES5-compatible JavaScript with optional source maps, suitable for browser and Node.js environments. This maintains compatibility with the existing Elm ecosystem.

### MLIR Backend (Eco Dialect)

For native compilation, the MLIR backend:
1. **Monomorphizes** all polymorphic code, specializing generic functions to concrete types
2. **Computes memory layouts** for all data types
3. **Emits typed MLIR operations** in the eco dialect
4. **Lowers to LLVM IR** for final code generation

This enables compilation to native executables for x86, ARM, WebAssembly, and other LLVM-supported targets.

## Development

The compiler is built and tested via the top-level CMake build. The
sections below describe the compiler-frontend-only workflow; for the
full system (runtime, codegen, kernel libs, E2E tests) see the
[top-level Readme.md](../Readme.md).

### Prerequisites

- Node.js (any LTS) with `corepack` (ships with Node ≥ 16.9)
- CMake + Ninja + clang (per the top-level build)

`pnpm` is enabled on demand by corepack — no global install needed.
The Elm toolchain (`elm`, `elm-format`, `elm-test-rs`) is **not** a
project dependency; CMake fetches the binaries directly from upstream
with pinned SHAs into `build/toolchain/bin/` — see
`compiler/cmake/toolchain.cmake`.

Install the Node-side runtime libraries (`adm-zip`, `tmp`, `which`,
etc., needed by `bin/index.js`):

```bash
cd compiler
corepack enable pnpm
pnpm install --frozen-lockfile
```

`compiler/.npmrc` disables npm/pnpm lifecycle scripts
(`ignore-scripts=true`) — pnpm prints what it skipped, which is expected.
The vendored `elm-coverage/` subtree opts back in via its own `.npmrc`
because it depends on a binwrap install step.

### Building the compiler

```bash
cmake --build build --target guida        # Stage 1: stock elm → guida.js
cmake --build build --target eco-boot     # Stage 2: guida.js self-compiles → eco-boot.js
cmake --build build --target bootstrap    # Stages 3–8: native bootstrap chain
```

Outputs land under `build/compiler/build-{xhr,kernel}/bin/`.

### Watch Mode

Rebuild the Stage 1 JS output whenever `src/**/*.elm` changes:

```bash
cd compiler && pnpm run watch
```

This calls the CMake-fetched `elm` binary directly via the
`onchange` dev dependency.

### Running Tests

The Elm-side compiler frontend tests run via `elm-test-rs`:

```bash
cmake --build build --target elm-tests
```

To filter or change fuzz count, invoke the binary directly:

```bash
PATH="$PWD/../build/toolchain/bin:$PATH" \
    ../build/toolchain/bin/elm-test-rs \
        --project ../build/compiler/build-xhr \
        --fuzz 1
```

`elm-test-rs` discovers `elm` via `PATH`, so prepend the toolchain dir.

### Formatting

```bash
build/toolchain/bin/elm-format compiler/src --yes
```

### Clear Cache

```bash
rm -rf ~/.guida build/compiler
cmake --build build --target guida
```

## Examples

```bash
cd examples
guida make --debug src/Hello.elm
open index.html
```

## Directory Structure

```
src/Compiler/
├── AST/                  # AST definitions for each phase
│   ├── Source.elm        # Parse output
│   ├── Canonical.elm     # Canonicalized
│   ├── Optimized.elm     # Optimized (untyped)
│   ├── TypedOptimized.elm  # Optimized (typed)
│   └── Monomorphized.elm # Fully specialized (for MLIR)
├── Parse/                # Parsing phase
├── Canonicalize/         # Canonicalization phase
├── Type/                 # Type checking phase
├── Nitpick/              # Post-typecheck verification
├── Optimize/             # Optimization phase
├── Generate/             # Code generation phase
│   ├── JavaScript/       # JS backend
│   └── CodeGen/          # MLIR backend
├── Reporting/            # Error reporting
└── Data/                 # Internal data structures
```

## References

- Initial transpilation from Haskell to Elm based on [Elm compiler v0.19.1](https://github.com/elm/compiler/releases/tag/0.19.1) (commit [c9aefb6](https://github.com/elm/compiler/commit/c9aefb6230f5e0bda03205ab0499f6e4af924495))
- Terminal logic implementation based on [elm-posix](https://github.com/albertdahlin/elm-posix)
- [MLIR documentation](https://mlir.llvm.org/)
