# Project Overview (refreshed 2026-02-19)

## Purpose

**eco-runtime** is a generational garbage collector runtime for Elm, with an accompanying Elm-to-MLIR compiler. The project aims to compile Elm to native code via LLVM/MLIR.

## Components

### 1. Runtime (`runtime/`)
A C++20 garbage collector implementation with:
- **Two-generation GC**: Nursery (minor) and old generation (major) collection
- **Thread-local nurseries**: 4MB semi-space copying collectors per thread using Cheney's algorithm
- **Old generation**: Mark-and-sweep with free-list allocation
- **Logical pointers**: 40-bit offsets into unified heap (8TB address space)
- **No write barriers**: Elm's immutability guarantees no old→young pointers

Key files in `runtime/src/allocator/`:
- `Allocator.cpp` - Main GC coordinator
- `NurserySpace.cpp` - Minor GC (Cheney's algorithm)
- `OldGenSpace.cpp` - Major GC (mark-sweep)
- `Heap.hpp` - Object layouts (Int, Float, String, List, Custom, Record, Closure, etc.)

### 2. Compiler (`compiler/`)
**Guida** - An Elm compiler written in Elm that generates MLIR:
- Compiles Elm 0.19.1 code to MLIR
- Performs monomorphization (removes polymorphism)
- Generates code for the eco-runtime GC

Key files:
- `compiler/src/Compiler/Generate/MLIR/` - MLIR backend modules
- `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` - Direct MLIR lowering for Basics/Bitwise ops

### 3. Elm Kernel C++ (`elm-kernel-cpp/`)
C++ implementations of Elm's kernel functions (Basics, String, List, etc.)

### 4. Tests (`test/`)
Property-based tests using RapidCheck:
- Allocator tests (GC correctness)
- Codegen tests (MLIR generation)
- Elm integration tests

## Key Files for Understanding

**Must Read at Startup (per CLAUDE.md):**
- `design_docs/invariants.csv` - All compiler invariants (REP_*, CGEN_*, HEAP_*, MONO_*, etc.)
- `THEORY.md` - GC theory + compiler pipeline overview
- `design_docs/theory/` - Detailed pass documentation

## Tech Stack

- **Runtime**: C++20 with CMake
- **Compiler**: Elm (compiled with guida)
- **IR**: MLIR with custom ECO dialect
- **Build**: cmake presets (ninja-clang-lld-linux)

## Build Commands

```bash
# Setup
cmake --preset ninja-clang-lld-linux

# Build all
cmake --build build

# Run E2E tests (C++ backend)
cmake --build build --target check

# Run Elm frontend tests
cd compiler && npx elm-test-rs --fuzz 1

# Full rebuild (Elm + C++)
cmake --build build --target full

# Filter tests
TEST_FILTER=elm cmake --build build --target check
```

## Memory Layout (Heap.hpp)

All heap objects are 8-byte aligned with Header first:
- Header: 8 bytes (tag:5, color:2, age:2, epoch:2, pin:1, size:32)
- Specific structs: ElmInt, ElmFloat, ElmChar, String, Cons, Tuple2, Tuple3, Record, Custom, Closure

## HPointer Encoding

```
Bits 0-39:  Heap offset (40 bits)
Bits 40-43: Constant field (0=heap, 1-15=embedded constant)
Bits 44-63: Reserved
```

Embedded constants: Unit(1), True(3), False(4), Nil(5), EmptyString(7)