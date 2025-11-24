# ECO Project Plan

**Elm Compiler Offline - Native Compilation Backend and Runtime**

## Project Roadmap

- [ ] **1. Runtime Foundation** → [§1](#1-runtime-foundation)
  - [ ] 1.1 Custom Heap Model → [§1.1](#11-custom-heap-model)
  - [ ] 1.2 Garbage Collector → [§1.2](#12-garbage-collector)
  - [ ] 1.3 Process & Thread Model → [§1.3](#13-process--thread-model)
  - [ ] 1.4 Runtime Testing Infrastructure → [§1.4](#14-runtime-testing-infrastructure)

- [ ] **2. Standard Library Porting** → [§2](#2-standard-library-porting)
  - [ ] 2.1 Guida Runtime to Kernel Packages → [§2.1](#21-guida-runtime-to-kernel-packages)
  - [ ] 2.2 Kernel Package C++ Implementation → [§2.2](#22-kernel-package-c-implementation)
  - [ ] 2.3 elm/core Porting → [§2.3](#23-elmcore-porting)

- [ ] **3. MLIR/LLVM Integration** → [§3](#3-mlirllvm-integration)
  - [ ] 3.1 ECO MLIR Dialect → [§3.1](#31-eco-mlir-dialect)
  - [ ] 3.2 Lowering Pipeline → [§3.2](#32-lowering-pipeline)
  - [ ] 3.3 GC Stack Root Tracing → [§3.3](#33-gc-stack-root-tracing)
  - [ ] 3.4 Multi-target Support → [§3.4](#34-multi-target-support)

- [ ] **4. Compiler Backend** → [§4](#4-compiler-backend)
  - [ ] 4.1 Guida Backend Replacement → [§4.1](#41-guida-backend-replacement)
  - [ ] 4.2 MLIR Code Generation → [§4.2](#42-mlir-code-generation)
  - [ ] 4.3 Compiler Testing → [§4.3](#43-compiler-testing)

- [ ] **5. Integration & Self-Compilation** → [§5](#5-integration--self-compilation)
  - [ ] 5.1 End-to-End Pipeline → [§5.1](#51-end-to-end-pipeline)
  - [ ] 5.2 Bootstrap to Native x86 → [§5.2](#52-bootstrap-to-native-x86)
  - [ ] 5.3 Self-Compilation Milestone → [§5.3](#53-self-compilation-milestone)

- [ ] **6. Optimization & Release** → [§6](#6-optimization--release)
  - [ ] 6.1 Performance Testing → [§6.1](#61-performance-testing)
  - [ ] 6.2 Advanced Memory Management → [§6.2](#62-advanced-memory-management)
  - [ ] 6.3 Release Preparation → [§6.3](#63-release-preparation)

---

## Project Overview

**ECO** (Elm Compiler Offline) is a standalone native compilation backend and runtime for the Elm language. Unlike existing Elm implementations targeting JavaScript, ECO compiles Elm code directly to native machine code (x86 initially, with support for other architectures and WebAssembly through LLVM).

### Key Components

- **Compiler Backend**: MLIR-based code generation pipeline replacing Guida's backend
- **Runtime System**: High-performance native runtime with custom heap model and garbage collection
- **Standard Libraries**: C++ implementations of Elm core libraries and kernel packages
- **Multi-process Support**: Native support for concurrent Elm processes with fast message passing

### Design Goals

- Native code generation via LLVM (retargetable to x86, ARM, WebAssembly, etc.)
- High-performance backend execution outside the browser
- Support for multiple concurrent Elm processes
- Fast update loops with disruptor-based message passing
- Custom memory model matching Elm's type system
- Garbage collection with future optimization potential

---

## 1. Runtime Foundation

The runtime provides memory management, garbage collection, and execution support for compiled Elm code.

### 1.1 Custom Heap Model

**Status**: In Progress

Design and implement a heap model that matches Elm's type system requirements.

**Key Features**:
- 40-bit logical pointers for 8TB addressable space
- Unified heap with lazy physical memory commitment
- Unboxed primitives (Int, Float, Char) where possible
- Embedded constants (Nil, True, False, Unit) in pointer representation
- Support for forwarding pointers during GC
- Task and process handle storage

**Deliverables**:
- `heap.hpp`: Object type definitions and layouts
- Memory allocation primitives
- Pointer conversion utilities (logical ↔ physical)

### 1.2 Garbage Collector

**Status**: In Progress

Implement a generational garbage collector as an intermediate solution to de-risk the project. More advanced techniques can be added later.

**Current Implementation**:
- Two-generation design (nursery + old generation)
- Thread-local nursery spaces with Cheney's copying algorithm
- Mark-and-sweep for old generation
- Promotion age currently set to 1

**Integration Requirements**:
- LLVM stack map integration for root tracing (see §3.3)
- Thread-safe coordination across multiple Elm processes
- Support for incremental/concurrent collection

**Future Enhancements**:
- Techniques to reduce garbage generation
- More sophisticated promotion heuristics
- Compaction strategies

**Deliverables**:
- `allocator.cpp/hpp`: GC implementation
- `gc_stats.hpp`: Telemetry and diagnostics
- Property-based test suite

### 1.3 Process & Thread Model

**Status**: Not Started

Design and implement support for multiple concurrent Elm processes.

**Key Features**:
- Native process abstraction for Elm programs
- Thread management and scheduling
- Disruptor wheels for fast inter-process message passing
- High-performance update loop execution
- Process isolation and memory management

**Deliverables**:
- Process lifecycle management
- Message queue implementation (disruptor pattern)
- Thread-safe process coordination
- Process handle storage in heap model

### 1.4 Runtime Testing Infrastructure

**Status**: In Progress

Comprehensive testing for runtime correctness and performance.

**Current Status**:
- Property-based tests using RapidCheck
- Heap snapshot validation
- GC correctness properties (preservation, collection, stability)

**Required**:
- Performance benchmarks
- Stress testing under concurrent load
- Memory leak detection
- Integration tests with compiled code

**Deliverables**:
- Expanded test suite in `test/`
- Benchmarking framework
- Continuous integration setup

---

## 2. Standard Library Porting

Elm's standard libraries must be ported from JavaScript to native C++ implementations.

### 2.1 Guida Runtime to Kernel Packages

**Status**: Not Started

The Guida compiler currently uses a small runtime library with HTTP URL hacks for I/O operations. Convert this to proper Elm kernel packages.

**Tasks**:
- Audit Guida runtime library functionality
- Design kernel package API for I/O operations
  - File system access (read/write)
  - Network operations (HTTP, package fetching)
  - System interaction
- Refactor Guida runtime into Elm kernel packages
- Document kernel package interface

**Deliverables**:
- Elm kernel package definitions
- API specification document

### 2.2 Kernel Package C++ Implementation

**Status**: Not Started

Implement the kernel packages defined in §2.1 in C++ for linking with the native runtime.

**Tasks**:
- C++ implementations of kernel package APIs
- FFI bridge between Elm and C++ runtime
- Memory management for foreign objects
- Error handling across language boundary

**Deliverables**:
- C++ kernel package implementations
- FFI bridge code
- Test suite for kernel packages

### 2.3 elm/core Porting

**Status**: Not Started

Port necessary parts of `elm/core` to C++ implementations.

**Core Modules to Port**:
- `Basics`: Fundamental operations and types
- `List`: List operations
- `String`: String manipulation
- `Char`: Character operations
- `Maybe`, `Result`: Core data types
- `Debug`: Debugging support
- `Platform`: Runtime support

**Deliverables**:
- C++ implementations of core modules
- Test suite for parity with JavaScript version
- Performance benchmarks

---

## 3. MLIR/LLVM Integration

The compilation pipeline uses MLIR for high-level optimization and LLVM for code generation.

### 3.1 ECO MLIR Dialect

**Status**: Not Started

Design and implement a custom MLIR dialect called "eco" for Elm compilation.

**Dialect Features**:
- Operations representing Elm semantics
- Types matching Elm's type system
- Support for Elm's evaluation model
- Garbage collection integration hooks
- Process and message passing primitives

**Expertise Required**: MLIR framework knowledge

**Deliverables**:
- `ECODialect.cpp/hpp`: Dialect definition
- Operation definitions
- Type system implementation
- MLIR dialect documentation

### 3.2 Lowering Pipeline

**Status**: Not Started

Implement a lowering pipeline that transforms eco dialect to LLVM IR.

**Pipeline Stages**:
1. **High-level eco**: Direct representation of Elm semantics
2. **Lowered eco**: Explicit memory management, GC calls
3. **LLVM IR**: Target-independent intermediate representation
4. **Native code**: x86, ARM, WebAssembly, etc.

**Transformations**:
- Pattern matching to control flow
- Closure conversion
- Heap allocation insertion
- GC safepoint insertion
- Tail call optimization

**Deliverables**:
- Lowering passes in C++
- Pass pipeline configuration
- Optimization passes
- Testing framework for transformations

### 3.3 GC Stack Root Tracing

**Status**: Not Started

Integration between LLVM and the garbage collector for precise stack scanning.

**Requirements**:
- LLVM stack map generation
- Runtime stack root registration
- Safepoint insertion in generated code
- Thread-safe root set management

**Deliverables**:
- LLVM stackmap integration
- Runtime root scanning infrastructure
- Documentation on GC integration

### 3.4 Multi-target Support

**Status**: Not Started

Leverage LLVM's retargetability for multiple platforms.

**Initial Target**: x86-64 (Linux)

**Future Targets**:
- ARM64 (Linux, macOS)
- WebAssembly
- Windows (x86-64)

**Deliverables**:
- Target-specific configuration
- Cross-compilation support
- Target-specific runtime adaptations
- Testing on multiple platforms

---

## 4. Compiler Backend

Replace the existing Guida compiler backend with one that generates MLIR.

### 4.1 Guida Backend Replacement

**Status**: Not Started

The Guida compiler (Elm port) needs its backend replaced to output MLIR instead of JavaScript.

**Tasks**:
- Study existing Guida backend architecture
- Design MLIR emission strategy
- Refactor backend to target MLIR eco dialect
- Preserve existing frontend and type checker

**Deliverables**:
- Modified Guida compiler backend
- MLIR emission code
- Documentation on backend architecture

### 4.2 MLIR Code Generation

**Status**: Not Started

Implement code generation from Elm AST to eco MLIR dialect.

**Code Generation Tasks**:
- Expression translation
- Pattern matching compilation
- Function definitions
- Module system
- Foreign function interface
- Closure representation
- Data constructor encoding

**Deliverables**:
- Code generation modules
- MLIR builder utilities
- Symbol table management

### 4.3 Compiler Testing

**Status**: Not Started

Comprehensive testing for the compiler backend.

**Test Categories**:
- Unit tests for code generation
- Integration tests (Elm → MLIR → LLVM → native)
- Correctness tests against reference implementation
- Performance benchmarks
- Regression test suite

**Deliverables**:
- Test suite infrastructure
- Elm test programs
- Expected output validation
- Performance baseline

---

## 5. Integration & Self-Compilation

Bring all components together and achieve self-compilation.

### 5.1 End-to-End Pipeline

**Status**: Not Started

Connect all components into a working compilation pipeline.

**Pipeline**:
```
Elm Source
    ↓
Guida Frontend (parsing, type checking)
    ↓
Modified Backend (MLIR emission)
    ↓
ECO MLIR Dialect
    ↓
Lowering Pipeline
    ↓
LLVM IR
    ↓
LLVM CodeGen
    ↓
Native x86 Binary
    ↓
ECO Runtime (execution)
```

**Integration Tasks**:
- Command-line interface
- Build system integration
- Linker integration
- Debugging support (symbol generation)

**Deliverables**:
- Working `eco` compiler binary
- Build scripts
- Usage documentation

### 5.2 Bootstrap to Native x86

**Status**: Not Started

Compile the Guida compiler itself using ECO to produce a native x86 version.

**Requirements**:
- All dependencies ported (§2)
- Compiler backend complete (§4)
- Runtime stable (§1)

**Deliverables**:
- Native ECO compiler binary
- Build instructions
- Verification tests

### 5.3 Self-Compilation Milestone

**Status**: Not Started

Achieve self-compilation: ECO compiling itself through its own native output.

**Success Criteria**:
- ECO compiles its own source code
- Generated binary passes all tests
- Performance meets baseline requirements
- Binary is reproducible

**Milestone**: This marks the primary project completion point and readiness for initial release.

---

## 6. Optimization & Release

Post-milestone work focused on performance and polish.

### 6.1 Performance Testing

**Status**: Not Started

Comprehensive performance analysis and benchmarking.

**Benchmarks**:
- Compilation speed
- Runtime performance (vs JavaScript backend)
- Memory usage
- GC overhead
- Message passing throughput
- Process creation/switching cost

**Deliverables**:
- Benchmark suite
- Performance reports
- Bottleneck identification

### 6.2 Advanced Memory Management

**Status**: Not Started

Implement advanced techniques to reduce garbage and improve GC performance.

**Potential Techniques**:
- Region-based allocation for known lifetimes
- Arena allocation for short-lived objects
- Escape analysis for stack allocation
- Reference counting for large objects
- Generational tuning and adaptive collection

**Deliverables**:
- Implementation of selected techniques
- Performance comparison studies
- Tuning documentation

### 6.3 Release Preparation

**Status**: Not Started

Prepare ECO for public release.

**Tasks**:
- Documentation (user guide, API reference)
- Installation scripts
- Package management integration plan
- Community engagement (website, announcements)
- Issue tracker setup
- Contributing guidelines

**Deliverables**:
- Release version 1.0
- Documentation site
- Distribution packages

---

## Dependencies

### External Tools & Libraries

- **LLVM**: Version TBD (for code generation)
- **MLIR**: Bundled with LLVM (for IR framework)
- **Guida Compiler**: Elm port of Elm compiler (starting point)
- **C++20 Compiler**: Clang or GCC with C++20 support
- **CMake**: Build system
- **RapidCheck**: Property-based testing (currently in use)

### Critical Path

```
Runtime Foundation (§1)
    ├→ Standard Library Porting (§2)
    └→ MLIR Integration (§3)
            ↓
    Compiler Backend (§4)
            ↓
    Integration (§5)
            ↓
    Optimization (§6)
```

### Risk Areas

1. **MLIR Expertise**: Custom dialect design requires deep MLIR knowledge
2. **GC Integration**: Stack root tracing with LLVM is complex
3. **Self-Compilation**: Bootstrap process may expose edge cases
4. **Performance**: Native performance must justify implementation effort
5. **Library Completeness**: All required stdlib functions must be ported

---

## Success Metrics

### Primary Goal
- **Self-compilation**: ECO successfully compiles itself to native x86

### Secondary Goals
- **Performance**: 2-10x faster than JavaScript backend for typical workloads
- **Memory**: Lower memory usage than Node.js runtime
- **Concurrency**: Native process support with efficient message passing
- **Correctness**: Passes all Elm test suites
- **Stability**: No crashes, memory leaks, or undefined behavior

---

## Project Status

**Current Phase**: Runtime Foundation (§1)
**Last Updated**: 2025-11-24

**Completed**:
- Initial heap model design
- Two-generation garbage collector implementation
- Property-based testing infrastructure

**In Progress**:
- GC refinement and tuning
- Nursery space optimization

**Next Steps**:
- Process & thread model design (§1.3)
- Begin MLIR dialect design (§3.1)
- Audit Guida runtime for kernel package conversion (§2.1)
