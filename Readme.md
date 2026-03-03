# Eco

A native compiler and runtime for the [Elm](https://elm-lang.org/) programming language.

Eco compiles Elm to native x86 binaries via MLIR and LLVM. The compiler is written in Elm.

## Status

**Working today:**

- Elm source code compiles through: Elm → IR → custom MLIR dialect (`eco`) → LLVM (AOT and JIT execution)
- Full program optimisation and monomorphisation pass
- Bytes fusion DSL compilation (a dedicated MLIR dialect compiling `Bytes.Encode`/`Bytes.Decode` pipelines into fused loops)
- 144 MLIR operations across the `eco` and `bf` (bytes fusion) dialects, with lowering to LLVM
- C++ implementations of Elm kernel packages: core, json, bytes, time, http, regex, url, parser, file, browser, virtual-dom
- Generational garbage collector exploiting Elm's immutability (no write barrier needed)
- Extensive test coverage: 466 codegen/E2E test programs, 87 compiler test suites (~8,000 fuzz iterations), property-based GC tests

**In progress towards 0.1.0:**

- Bootstrapping (the compiler compiles itself to native code)
- Kernel I/O integration for building larger programs
- Scheduler and effects runtime correctness for real applications
- GC stack root tracing via LLVM stack maps (required for long-running programs)

## 0.1.0 Criteria

The initial release establishing the foundation of the Eco compiler toolchain.

- [ ] Forked from [Guida](https://github.com/guida-lang/compiler) compiler port
- [x] MLIR `eco` dialect established, compilation via LLVM to x86 binaries
- [x] Standard library scaffolding (core, json, bytes, http, regex, url, parser, time)
- [x] Bytes fusion DSL compilation
- [x] Full program optimisation and monomorphisation pass
- [x] Extensive test suite confirming compiler correctness
- [x] Generational garbage collector
- [ ] Self-compilation (bootstrapping in progress)
- [ ] GC stack root tracing for long-running programs
- [ ] Scheduler correctness for effect managers
- [ ] Linux only

## Architecture

```
  Elm source
      │
      ▼
┌──────────┐   compiler/     Elm compiler written in Elm
│  Parse &  │                 (forked from Guida)
│ Typecheck │
└────┬─────┘
     │  Typed AST
     ▼
┌──────────┐   compiler/src/Compiler/Generate/MLIR/
│  MLIR    │                 Monomorphisation, optimisation,
│  Codegen │                 bytes fusion, code generation
└────┬─────┘
     │  eco dialect MLIR
     ▼
┌──────────┐   runtime/src/codegen/
│  LLVM    │                 EcoToLLVM lowering passes
│ Lowering │
└────┬─────┘
     │  LLVM IR
     ▼
┌──────────┐
│  Native  │   x86 binary (AOT) or JIT execution
│  Code    │
└──────────┘
     │
     ▼
┌──────────┐   runtime/src/allocator/
│ Runtime  │                 GC, heap, process scheduling
│          │   elm-kernel-cpp/
│          │                 C++ kernel implementations
└──────────┘
```

### Key directories

| Directory | Contents |
|-----------|----------|
| `compiler/` | Elm compiler (written in Elm) with MLIR backend |
| `runtime/` | C++20 runtime: MLIR dialect, LLVM lowering, GC, heap |
| `elm-kernel-cpp/` | C++ implementations of Elm kernel packages |
| `eco-kernel-cpp/` | Eco-specific kernel extensions (console, file, env, process) |
| `test/` | Codegen tests, E2E tests, property-based GC tests |
| `design_docs/` | Invariants, theory documentation, design decisions |

## Building

### Prerequisites

**Docker (recommended):**

```bash
docker build -t eco-build .
docker run --rm -v "$PWD":/work eco-build
```

**Debian/Ubuntu host:**

```bash
sudo apt install clang lld ninja-build cmake ccache
```

### Configure and build

```bash
# Release
cmake --preset ninja-clang-lld-linux
cmake --build build

# Debug
cmake --preset ninja-clang-lld-linux-debug
cmake --build build
```

### Running tests

```bash
# Incremental build + run all tests
cmake --build build --target check

# Full clean rebuild + tests (use after compiler changes)
cmake --build build --target full

# Filter tests by name
TEST_FILTER=elm cmake --build build --target check
TEST_FILTER=String cmake --build build --target run-tests

# Compiler frontend tests
cd compiler && npx elm-test-rs --fuzz 1
```

### Build targets

| Target | Description |
|--------|-------------|
| `check` | Incremental build + run tests |
| `run-tests` | Run tests only (no build) |
| `rebuild` | Clean + rebuild (no tests) |
| `full` | Clean + rebuild + run tests |

### Running the test binary directly

```bash
./build/test/test                    # Run all tests
./build/test/test --filter elm       # Filter by name
./build/test/test -n 1000           # Run 1000 tests
./build/test/test --seed 42          # Reproducible run
./build/test/test --max-size 500     # Higher complexity tests
```

## Docker development

```bash
# Build image
docker build -t eco-build .

# Interactive session with persistent home directory
docker volume create eco-dev-home
docker run -it --rm -v "$PWD":/work -v eco-dev-home:/home/dev eco-build bash

# One-shot build + test
docker run --rm -v "$PWD":/work eco-build bash -c \
  "cmake --preset ninja-clang-lld-linux && cmake --build build --target check"
```

## Acknowledgements

The Eco compiler frontend is forked from [Guida](https://github.com/guida-lang/compiler), an Elm compiler port. Guida is itself a port of the original [Elm compiler](https://github.com/elm/compiler) by Evan Czaplicki.
