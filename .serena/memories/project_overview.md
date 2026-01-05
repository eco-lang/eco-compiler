# Project Overview

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

Key file: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` - MLIR backend

### 3. Elm Kernel C++ (`elm-kernel-cpp/`)
C++ implementations of Elm's kernel functions (Basics, String, List, etc.)

### 4. Tests (`test/`)
Property-based tests using RapidCheck:
- Allocator tests (GC correctness)
- Codegen tests (MLIR generation)
- Elm integration tests

## Tech Stack

- **Runtime**: C++20 with CMake, Clang, LLD
- **Compiler**: Elm 0.19.1, Node.js
- **Code generation**: MLIR/LLVM
- **Testing**: RapidCheck (C++ property testing), elm-test, Jest

## Codebase Structure

```
/work
├── runtime/src/allocator/   # C++ GC implementation
├── compiler/src/            # Guida Elm compiler (Elm source)
├── elm-kernel-cpp/          # Elm kernel C++ implementations
├── test/                    # RapidCheck and integration tests
├── design_docs/             # Design documentation
├── build/                   # CMake release build output
├── debug/                   # CMake debug build output
├── CLAUDE.md               # Main project documentation
├── STYLE.md                # C++ style guide
└── CMakeLists.txt          # Root build configuration
```
