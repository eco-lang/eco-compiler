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

### Prerequisites

Install [Node Version Manager](https://github.com/nvm-sh/nvm), then:

```bash
nvm use
npm install
```

### Building

```bash
npm run build
```

### Linking for Development

```bash
npm link
```

You should now be able to run `guida --help`.

### Watch Mode

Rebuild automatically when source files change:

```bash
npm run watch
```

### Running Tests

```bash
npm test              # Run all tests
npm run test:jest     # Jest tests only
npm run test:elm      # elm-test only
npm run test:elm-review    # elm-review only
npm run test:elm-format-validate  # Format validation
```

### Formatting

```bash
npm run elm-format
```

### Clear Cache

```bash
rm -rf ~/.guida guida-stuff; npm run build
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
