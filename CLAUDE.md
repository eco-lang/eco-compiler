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

## Start up

When Clause Code first starts running:

    1. Familiarize yourself with @design_docs/invariants.csv, @THEORY.md and all child files under @design_docs/theory/.
    2. Update your memories around these files to keep them fresh.

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

Run the tests ONCE, redirecting stdout and stderr to a temporary file:

```
<test command> 2>&1 | tee /tmp/test_output.txt
```

**MANDATORY:** Do NOT run the tests more than once. Use `grep`, `head`, `tail` on
`/tmp/test_output.txt` to extract failure information. If you need to see different
parts of the output, read the file — do NOT re-run the tests.

Compiler front-end tests with elm-test-rs:

```bash
cd compiler
npx elm-test-rs --project build-xhr --fuzz 1
```

Full E2E tests including the backend and runtime:

**Almost always use `--target full`** to avoid consuming stale `.mlir` files. Only use `--target check` if you are certain only C++ code has changed and no `.mlir` regeneration is needed.

```bash
# Default: full rebuild of compiler + run E2E tests (preferred)
cmake --build build --target full

# Only if exclusively C++ changes (no Elm/MLIR changes):
cmake --build build --target check

# To filter and just run a subset of the tests
TEST_FILTER=elm cmake --build build --target full
TEST_FILTER=codegen cmake --build build --target full
```