# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **Eco**, an Elm compiler optimizing and runtime system. It consists of:

1. **Compiler** (`compiler/`): An Elm compiler written in Elm that generates MLIR
2. **Runtime** (`runtime/`): A C++20 code generation backend that lowers the MLIR via LLVM, and a runtime with garbage collection.
3. **Elm Kernel C++** (`elm-kernel-cpp/`): C++ implementations of Elm's kernel functions

## Invariants

**CRITICAL:** Before modifying any codegen, runtime, or representation-related code, ALWAYS read `design_docs/invariants.csv` and verify changes comply with the relevant invariants:

- **REP_*** invariants define the four representation models (ABI, SSA, Heap, Logical) and their boundaries
- **CGEN_*** invariants define MLIR codegen rules
- **HEAP_*** invariants define runtime heap layout and GC rules
- **FORBID_*** invariants define what NOT to do

Key representation rules:
- Only Int, Float, and Char are unboxed in heap fields and closures (NOT Bool)
- Bool is always `!eco.value` in heap/closure storage (True/False are embedded HPointer constants)
- SSA representation, ABI representation, and Heap representation are independent unless explicitly linked by an invariant

## Build Commands

### Initial Setup
```bash
# Configure build (release)
cmake --preset ninja-clang-lld-linux

# Configure build (debug)
cmake --preset ninja-clang-lld-linux-debug
```

### Building
```bash
# Build all targets
cmake --build build

# Build specific target
cmake --build build --target test
cmake --build build --target ecor
```

### Running Tests

Compiler front-end tests with elm-test:

```bash
cd compiler
npx elm-test --fuzz 1
```

Full E2E tests including the backend and runtime:

```bash
# To check after changes to C++ backend:
cmake --build build --target check

# To check after changes to Elm frontend force a full rebuild of the compiler:
cmake --build build --target full

# To filder and just run a subset of the tests
TEST_FILTER=elm cmake --build build --target check
TEST_FILTER=codegen cmake --build build --target check
```