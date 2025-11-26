# ECO Project Plan

**Elm Compiler Offline - Native Compilation Backend and Runtime**

## Project Roadmap

- [ ] **1. Runtime Foundation** → [§1](#1-runtime-foundation)
  - [x] 1.1 Custom Heap Model → [§1.1](#11-custom-heap-model)
  - [ ] 1.2 Garbage Collector → [§1.2](#12-garbage-collector)
    - [ ] 1.2.1 Old Generation Algorithm → [§1.2.1](#121-old-generation-algorithm)
    - [x] 1.2.2 LLVM Stack Map Investigation → [§1.2.2](#122-llvm-stack-map-investigation)
    - [ ] 1.2.3 LLVM Stack Map Implementation → [§1.2.3](#123-llvm-stack-map-implementation)
  - [ ] 1.3 Process & Thread Model → [§1.3](#13-process--thread-model)
  - [ ] 1.4 Runtime Testing Infrastructure → [§1.4](#14-runtime-testing-infrastructure)

- [ ] **2. Standard Library Porting** → [§2](#2-standard-library-porting)
  - [ ] 2.1 Guida Runtime to Kernel Packages → [§2.1](#21-guida-runtime-to-kernel-packages)
    - [ ] 2.1.1 Audit Guida I/O Implementation → [§2.1.1](#211-audit-guida-io-implementation) *(audit complete, rationalization pending)*
    - [ ] 2.1.2 File System Operations Design → [§2.1.2](#212-file-system-operations-design)
    - [ ] 2.1.3 Network Operations Design → [§2.1.3](#213-network-operations-design)
    - [ ] 2.1.4 System Operations Design → [§2.1.4](#214-system-operations-design)
    - [ ] 2.1.5 Kernel Package Implementation & Guida Refactor → [§2.1.5](#215-kernel-package-implementation--guida-refactor)
  - [ ] 2.2 Kernel Package C++ Implementation → [§2.2](#22-kernel-package-c-implementation)
  - [ ] 2.3 elm/core Porting → [§2.3](#23-elmcore-porting)

- [ ] **3. MLIR/LLVM Integration** → [§3](#3-mlirllvm-integration)
  - [ ] 3.1 ECO MLIR Dialect → [§3.1](#31-eco-mlir-dialect)
    - [x] 3.1.1 Research & Reference Implementation → [§3.1.1](#311-research--reference-implementation)
    - [ ] 3.1.2 Dialect Definition → [§3.1.2](#312-dialect-definition)
    - [ ] 3.1.3 Operations → [§3.1.3](#313-operations)
    - [ ] 3.1.4 Type System → [§3.1.4](#314-type-system)
    - [ ] 3.1.5 GC Integration Hooks → [§3.1.5](#315-gc-integration-hooks)
    - [ ] 3.1.6 Process Primitives → [§3.1.6](#316-process-primitives)
    - [ ] 3.1.7 Test Programs → [§3.1.7](#317-test-programs)
  - [ ] 3.2 Lowering Pipeline → [§3.2](#32-lowering-pipeline)
  - [ ] 3.3 GC Stack Root Tracing → [§3.3](#33-gc-stack-root-tracing)
  - [ ] 3.4 Multi-target Support → [§3.4](#34-multi-target-support)

- [ ] **4. Compiler Backend** → [§4](#4-compiler-backend)
  - [ ] 4.1 Guida Backend Replacement → [§4.1](#41-guida-backend-replacement)
    - [ ] 4.1.1 Pluggable Backend Architecture → [§4.1.1](#411-pluggable-backend-architecture)
    - [ ] 4.1.2 Global AST Analysis & Monomorphization → [§4.1.2](#412-global-ast-analysis--monomorphization)
    - [ ] 4.1.3 Dual Backend Implementation → [§4.1.3](#413-dual-backend-implementation)
    - [ ] 4.1.4 Compiler Test Suite → [§4.1.4](#414-compiler-test-suite)
  - [ ] 4.2 MLIR Code Generation → [§4.2](#42-mlir-code-generation)
  - [ ] 4.3 Compiler Testing → [§4.3](#43-compiler-testing)

- [ ] **5. Integration & Self-Compilation** → [§5](#5-integration--self-compilation)
  - [ ] 5.1 End-to-End Pipeline → [§5.1](#51-end-to-end-pipeline)
    - [ ] 5.1.1 Pipeline Integration → [§5.1.1](#511-pipeline-integration)
    - [ ] 5.1.2 Command-Line Interface → [§5.1.2](#512-command-line-interface)
    - [ ] 5.1.3 Build System & Packaging → [§5.1.3](#513-build-system--packaging)
    - [ ] 5.1.4 Linker Integration & Runtime Libraries → [§5.1.4](#514-linker-integration--runtime-libraries)
    - [ ] 5.1.5 Debugging Support → [§5.1.5](#515-debugging-support)
  - [ ] 5.2 Bootstrap to Native x86 → [§5.2](#52-bootstrap-to-native-x86)
  - [ ] 5.3 Self-Compilation Milestone → [§5.3](#53-self-compilation-milestone)

- [ ] **6. Optimization & Release** → [§6](#6-optimization--release)
  - [ ] 6.1 Performance Testing → [§6.1](#61-performance-testing)
  - [ ] 6.2 Release Preparation → [§6.2](#62-release-preparation)

- [ ] **7. Advanced Garbage Collection** → [§7](#7-advanced-garbage-collection)
  - [ ] 7.1 Fixed-Size Object Spaces → [§7.1](#71-fixed-size-object-spaces)
  - [ ] 7.2 Stack-Allocated Values → [§7.2](#72-stack-allocated-values)
  - [ ] 7.3 Reference Counting & Uniqueness → [§7.3](#73-reference-counting--uniqueness)
  - [ ] 7.4 Lock-Free Optimization → [§7.4](#74-lock-free-optimization)

- [ ] **8. More Compilation Targets** → [§8](#8-more-compilation-targets)
  - [ ] 8.1 ARM64 Support → [§8.1](#81-arm64-support)
  - [ ] 8.2 Windows Support → [§8.2](#82-windows-support)
  - [ ] 8.3 Cross-Compilation Infrastructure → [§8.3](#83-cross-compilation-infrastructure)

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

**Status**: Complete

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

Implement a generational garbage collector as an intermediate solution to de-risk the project. More advanced techniques can be added later (see §7).

**Current Implementation**:
- Two-generation design (nursery + old generation)
- Thread-local nursery spaces with Cheney's copying algorithm
- Mark-and-sweep for old generation
- Promotion age currently set to 1

**Deliverables**:
- `allocator.cpp/hpp`: GC implementation
- `gc_stats.hpp`: Telemetry and diagnostics
- Property-based test suite

#### 1.2.1 Old Generation Algorithm

**Status**: Not Started

Choose and implement an appropriate algorithm for old generation garbage collection.

**Background**: The current implementation has a mark-and-sweep algorithm, but the choice of algorithm and its implementation details need to be finalized. A simple stop-the-world mark-and-sweep may be sufficient for initial implementation, with concurrent collection deferred to advanced GC work (see §7.4).

**Tasks**:
- Evaluate algorithm options (simple mark-and-sweep vs mark-compact vs other)
- Implement chosen algorithm with stop-the-world collection
- Ensure thread safety during collection phase
- Expand stress test coverage to exercise all heap object types under GC
- Verify correctness under multi-threaded allocation patterns

**Deliverables**:
- Finalized old generation GC algorithm
- Thread-safe implementation
- Stress tests covering all object types

#### 1.2.2 LLVM Stack Map Integration

**Status**: Research Complete

Integrate with LLVM's stack map facilities for precise stack root tracing.

**Tasks**:
- [x] Research LLVM stack map and statepoint APIs *(see design_docs/llvm_stackmap_integration.md)*
- [ ] Build a small example program in LLVM using recursion to create stack frames with heap pointers
- [ ] Integrate stack map parsing into the runtime's root scanning
- [ ] Stress test to verify stack roots are preserved correctly across major GC cycles
- [x] Document the integration approach *(see design_docs/llvm_stackmap_integration.md)*

**Deliverables**:
- [ ] LLVM stack map example/prototype
- [ ] Runtime stack map parser
- [ ] Integration tests for stack root preservation

#### 1.2.3 Lock-Free Optimization

**Status**: Not Started

Replace mutex-based synchronization with lock-free algorithms where beneficial to reduce contention.

**Tasks**:
- Profile current mutex contention points
- Identify candidates for lock-free replacement using CAS operations
- Implement lock-free alternatives for high-contention paths
- Add performance metrics to stress test programs
- Target: 8 threads running at ~800% CPU utilization to demonstrate low contention
- Benchmark before/after to validate improvements

**Deliverables**:
- Lock-free data structures for GC coordination
- Performance metrics and benchmarks
- Contention analysis report

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

**Deliverables**:
- Elm kernel package definitions
- API specification document
- Refactored Guida using new kernel package

#### 2.1.1 Audit Guida I/O Implementation

**Status**: In Progress (audit complete, rationalization pending)

Check out and build the Guida compiler. Catalog all operations in its native I/O implementation.

**Tasks**:
- [x] Clone and build Guida compiler *(see design_docs/guida_build_notes.md)*
- [x] Document all native I/O operations currently implemented *(see design_docs/guida-io-operations.md)*
- [ ] Rationalize the design to form a well-designed I/O package suitable for any CLI tool written in Elm, not just Guida
- [x] Identify any missing operations needed for general-purpose CLI development *(gaps documented in guida-io-operations.md)*

**Deliverables**:
- [x] Comprehensive list of current I/O operations *(design_docs/guida-io-ops.csv - 37 operations)*
- [ ] Rationalized I/O design document

#### 2.1.2 File System Operations Design

**Status**: Not Started

Design a clean API for file system operations.

**Tasks**:
- Catalog current file operations in Guida
- Rationalize into a coherent file system API
- Operations to include: read, write, append, delete, rename, copy
- Directory operations: create, list, remove, walk
- Path handling: join, normalize, resolve, relative paths
- File metadata: size, timestamps, permissions

**Deliverables**:
- File system API specification

#### 2.1.3 Network Operations Design

**Status**: Not Started

Design a clean API for network operations.

**Tasks**:
- Catalog current network operations in Guida (HTTP, package fetching)
- Rationalize into a coherent network API
- HTTP client: GET, POST, headers, body handling, streaming
- Consider connection pooling and timeout handling
- Package/resource fetching abstraction

**Deliverables**:
- Network API specification

#### 2.1.4 System Operations Design

**Status**: Not Started

Design a clean API for system-level operations.

**Tasks**:
- Catalog current system operations in Guida
- Rationalize into a coherent system API
- Environment variables: get, set, list
- Command-line arguments: parsing, access
- Process execution: spawn, wait, capture output, piping
- Exit codes and program termination
- Current working directory operations

**Deliverables**:
- System operations API specification

#### 2.1.5 Kernel Package Implementation & Guida Refactor

**Status**: Not Started

Design Elm types for the kernel package and refactor Guida to use it.

**Tasks**:
- Design Elm types using Cmd/Sub or Task with an effects module implementation
- Ensure API covers all I/O operations Guida requires
- Modify Guida to allow kernel code in non-elm/* packages (break the restriction)
- Enable loading kernel packages from the local file system (not Elm package site)
- Implement the kernel package with JavaScript runtime for current Guida
- Refactor Guida to use the new kernel package
- Remove existing I/O system entirely from Guida
- Verify Guida still builds and functions correctly

**Deliverables**:
- Elm kernel package type definitions
- Effects module implementation
- Modified Guida compiler (kernel package restrictions relaxed)
- Local kernel package loading support
- Refactored Guida using new I/O kernel package

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

**Expertise Required**: MLIR framework knowledge

**Deliverables**:
- `ECODialect.cpp/hpp`: Dialect definition
- Operation definitions
- Type system implementation
- MLIR dialect documentation
- Test programs demonstrating dialect usage

#### 3.1.1 Research & Reference Implementation

**Status**: Complete

Study existing MLIR implementations for functional languages as reference.

**Tasks**:
- [x] Check out and build the Lean MLIR branch as a working example of compiling a functional language through MLIR *(lean/ and lz/ cloned)*
- [x] Study Lean's dialect design, lowering passes, and runtime integration *(see design_docs/lean_mlir_research.md)*
- [ ] Find and review academic papers on MLIR dialects for reference counting and garbage reduction
- [x] Document relevant patterns and techniques applicable to ECO *(see design_docs/lean_mlir_research.md)*

**Deliverables**:
- [x] Working Lean MLIR build for reference *(lz/ - hask-opt tool)*
- [ ] Summary of relevant papers and techniques
- [x] Design notes for ECO dialect based on findings *(design_docs/lean_mlir_research.md - 1400+ lines)*

#### 3.1.2 Dialect Definition

**Status**: Not Started

Create the core dialect infrastructure.

**Tasks**:
- Define ECO dialect namespace and registration with MLIR framework
- Set up dialect versioning strategy
- Establish dialect structure and organization
- Configure build system for MLIR integration

**Deliverables**:
- `ECODialect.cpp/hpp`: Core dialect definition
- CMake integration for MLIR

#### 3.1.3 Operations

**Status**: Not Started

Define custom operations representing Elm semantics.

**Tasks**:
- Function definition and application operations
- Pattern matching operations
- Data constructor operations (algebraic data types)
- Record operations (creation, field access, update)
- Let bindings and variable references
- Closure creation and invocation

**Deliverables**:
- Operation definitions in TableGen
- Operation implementation files

#### 3.1.4 Type System

**Status**: Not Started

Implement MLIR types matching Elm's type system.

**Tasks**:
- Primitive types (Int, Float, Char, String, Bool)
- Function types
- Algebraic data types (custom types, Maybe, Result, List)
- Record types
- Type variables and polymorphism representation

**Deliverables**:
- Type definitions in TableGen
- Type implementation files

#### 3.1.5 GC Integration Hooks

**Status**: Not Started

Define operations for garbage collection integration.

**Tasks**:
- Allocation operations (nursery, old gen)
- GC safepoint operations
- Root registration/deregistration operations
- Write barrier operations (if needed for future concurrent GC)

**Deliverables**:
- GC-related operation definitions
- Documentation on GC integration points

#### 3.1.6 Process Primitives

**Status**: Not Started

Define operations for Elm process and task handling.

**Tasks**:
- Process creation operations
- Message send/receive operations
- Task operations
- Subscription handling

**Deliverables**:
- Process/task operation definitions

#### 3.1.7 Test Programs

**Status**: Not Started

Create small test programs to validate the dialect.

**Tasks**:
- Write small programs directly in ECO MLIR dialect
- Compile through MLIR pipeline to LLVM IR
- Link with ECO runtime and execute
- Validate correctness of generated code
- Create test suite covering all operations and types

**Deliverables**:
- Suite of ECO MLIR test programs
- Test harness for dialect validation
- Documentation of test coverage

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

**Initial Targets**: x86-64 (Linux), WebAssembly

**Future Targets**: See §8 (More Compilation Targets)

**Deliverables**:
- x86-64 Linux target configuration and runtime
- WebAssembly target with memory model adaptations for WASM linear memory
- Target-specific testing

---

## 4. Compiler Backend

Replace the existing Guida compiler backend with one that generates MLIR.

### 4.1 Guida Backend Replacement

**Status**: Not Started

The Guida compiler (Elm port) needs its backend modified to support MLIR output alongside JavaScript.

**Deliverables**:
- Pluggable backend architecture
- MLIR emission code
- Compiler flags for output mode selection
- Documentation on backend architecture

#### 4.1.1 Pluggable Backend Architecture

**Status**: Not Started

Ensure the backend can be replaced with alternative implementations.

**Tasks**:
- Study existing Guida backend architecture and module structure
- Define a clean API that allows the backend to be "plugged in" to the compiler
- Refactor backend to implement this pluggable interface
- Create a dummy backend implementation for testing the architecture
- Make a light pass on the dummy implementation to output debug statements showing rough compilation structure (a to-do list for the real code generator)

**Deliverables**:
- Pluggable backend interface definition
- Refactored JavaScript backend implementing the interface
- Dummy backend with debug output
- Documentation on backend plugin architecture

#### 4.1.2 Global AST Analysis & Monomorphization

**Status**: Not Started

Analyze the Guida/Elm Global AST and consider necessary changes for native compilation.

**Tasks**:
- Study the Global AST structure and how it represents Elm programs
- Design monomorphization pass to specialize polymorphic functions into type-specific implementations
- Focus on Record shape specialization (different record types → different implementations)
- Evaluate whether DynRecord is needed for native compilation or can be eliminated
- Document AST changes needed for MLIR code generation

**Deliverables**:
- Global AST analysis document
- Monomorphization pass design
- Decision on DynRecord necessity
- AST modification plan (if needed)

#### 4.1.3 Dual Backend Implementation

**Status**: Not Started

Keep JavaScript backend and add MLIR backend with compiler flags to switch between them.

**Tasks**:
- Add compiler flags to choose output mode (JavaScript vs native/MLIR)
- Implement command-line interface for backend selection
- Build out the MLIR-based backend implementation using the pluggable architecture
- Ensure both backends can coexist and be selected at compile time
- Validate JavaScript backend still works correctly after refactoring

**Deliverables**:
- Compiler flags for output mode selection (`--target=js`, `--target=native`)
- MLIR backend implementation
- Both backends functional and selectable

#### 4.1.4 Compiler Test Suite

**Status**: Not Started

Get existing tests running and expand coverage.

**Tasks**:
- Get Guida's existing test suite running
- Verify tests pass with both JavaScript and MLIR backends
- Expand tests to cover more Elm programs and edge cases
- Add regression tests for backend-specific behavior
- Create test programs that exercise all Elm language features

**Deliverables**:
- Working Guida test suite
- Expanded test coverage
- Backend comparison tests

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

**Deliverables**:
- Working `eco` compiler binary
- Build scripts and packaging
- Usage documentation

#### 5.1.1 Pipeline Integration

**Status**: Not Started

Connect all compiler stages into a working pipeline.

**Tasks**:
- Wire up Guida frontend to MLIR backend
- Connect MLIR lowering passes
- Integrate LLVM code generation
- Produce working native binaries from Elm source

**Deliverables**:
- End-to-end compilation working
- Pipeline orchestration code

#### 5.1.2 Command-Line Interface

**Status**: Not Started

Design and implement user-facing CLI for the `eco` compiler.

**Tasks**:
- Design CLI options and flags
- Implement argument parsing
- Support compilation modes (compile, build, run)
- Error reporting and diagnostics output
- Verbose/debug output modes

**Deliverables**:
- `eco` CLI implementation
- Help text and usage documentation

#### 5.1.3 Build System & Packaging

**Status**: In Progress

Create robust build system and distribution packages.

**Tasks**:
- [ ] Evaluate whether CMake is the right tool (needs to invoke Elm compiler and tools outside normal C/C++ toolchain)
- [ ] Consider alternatives or CMake extensions for non-C/C++ tool invocation
- [x] Create Dockerfile encapsulating all build dependencies *(Dockerfile based on Debian Bookworm)*
- [ ] Build on Arch Linux with statically linked libc (musl) for cross-platform Linux distribution
- [ ] Create Debian package (.deb)
- [ ] Create npm package for Node.js distribution
- [ ] Document build process and dependencies

**Deliverables**:
- [x] Dockerfile for reproducible builds *(Dockerfile, .dockerignore)*
- [ ] Static Linux binary (musl-linked)
- [ ] Debian package
- [ ] npm package
- [ ] Build system documentation

#### 5.1.4 Linker Integration & Runtime Libraries

**Status**: Not Started

Link generated code with ECO runtime and Elm base libraries.

**Tasks**:
- Extract elm/core and other ported Elm base libraries into standalone packages
- Create linkable libraries (.a/.so) for all kernel operations implemented in C/C++
- Design library discovery and linking as part of eco compilation flow
- Handle native library dependencies
- Support static and dynamic linking options

**Deliverables**:
- Standalone kernel library packages
- Linker integration in eco compiler
- Library packaging and distribution

#### 5.1.5 Debugging Support

**Status**: Not Started

Enable debugging of compiled Elm programs.

**Tasks**:
- Generate DWARF debug symbols
- Map native code locations back to Elm source
- Enable stack traces with Elm source locations
- Integration with GDB/LLDB debuggers
- Consider source map generation for additional tooling

**Deliverables**:
- Debug symbol generation
- Source location mapping
- Debugger integration documentation

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

### 6.2 Release Preparation

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

## 7. Advanced Garbage Collection

Advanced GC techniques to reduce garbage generation and improve performance. These are post-milestone optimizations building on the foundational GC in §1.2.

### 7.1 Fixed-Size Object Spaces

**Status**: Not Started

Implement segregated allocation spaces for fixed-size objects that don't require compaction.

**Rationale**: Objects of known, fixed sizes can be allocated from dedicated pools, eliminating fragmentation and the need for compaction. Free slots can be tracked with bitmaps or free lists.

**Tasks**:
- Identify common fixed-size object classes (e.g., Cons cells, Tuple2, small closures)
- Implement segregated free-list allocators for each size class
- Integrate with existing GC for collection
- Benchmark allocation/deallocation performance

**Deliverables**:
- Size-segregated allocation pools
- Integration with mark-and-sweep collection
- Performance comparison with general allocator

### 7.2 Stack-Allocated Values

**Status**: Not Started

Enable unboxed values and small objects to be allocated directly on the program stack.

**Rationale**: Values that don't escape their scope can live on the stack, avoiding heap allocation entirely. This requires escape analysis at compile time.

**Tasks**:
- Define criteria for stack-allocatable values (size limits, escape analysis results)
- Implement compiler support for escape analysis (coordinate with §4)
- Generate code that allocates qualifying values on stack
- Ensure GC correctly handles mixed stack/heap object graphs

**Deliverables**:
- Escape analysis pass in compiler
- Stack allocation code generation
- Verification tests for correctness

### 7.3 Reference Counting & Uniqueness

**Status**: Not Started

Use reference counting to detect unique references (refcount == 1) enabling safe in-place mutation.

**Rationale**: Elm's immutability is a semantic guarantee, but if an object has exactly one reference, mutating it in place is observationally equivalent to creating a new copy. This can dramatically reduce allocation for operations like list building or record updates.

**Tasks**:
- Implement reference count tracking in object headers
- Detect refcount == 1 at runtime to enable mutation
- Identify operations that benefit from uniqueness (e.g., `List.map`, record update)
- Ensure correctness: mutation only when truly unique
- Measure allocation reduction in benchmarks

**Deliverables**:
- Reference counting infrastructure
- Uniqueness-based mutation optimization
- Benchmark suite showing allocation savings

---

## 8. More Compilation Targets

Additional platform targets beyond the initial x86-64 Linux and WebAssembly support.

### 8.1 ARM64 Support

**Status**: Not Started

Support ARM64 architecture on Linux and macOS.

**Tasks**:
- ARM64 Linux target configuration
- ARM64 macOS target configuration
- Platform-specific runtime adaptations (calling conventions, atomics)
- Testing on ARM64 hardware

**Deliverables**:
- ARM64 target support
- Platform-specific runtime code
- Test suite validation on ARM64

### 8.2 Windows Support

**Status**: Not Started

Support x86-64 Windows platform.

**Tasks**:
- Windows target configuration
- Platform-specific I/O implementation (Windows APIs vs POSIX)
- Threading adaptations (Windows threads vs pthreads)
- Build system support for MSVC/MinGW

**Deliverables**:
- Windows x86-64 target support
- Windows-specific runtime code
- Windows build and test infrastructure

### 8.3 Cross-Compilation Infrastructure

**Status**: Not Started

Build system support for cross-compilation to all targets.

**Tasks**:
- CMake toolchain files for each target
- CI/CD pipelines for cross-platform builds
- Target-specific testing infrastructure (emulators, remote testing)
- Distribution packaging for each platform

**Deliverables**:
- Cross-compilation toolchain configurations
- Multi-platform CI/CD setup
- Platform-specific distribution packages

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
    Optimization & Release (§6)
            ↓
    Advanced GC (§7) [post-release]
            ↓
    More Targets (§8) [post-release]
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

**Current Phase**: Runtime Foundation (§1) + Research
**Last Updated**: 2025-11-26

**Completed**:
- Initial heap model design
- Two-generation garbage collector implementation
- Property-based testing infrastructure
- Dockerfile for reproducible builds (§5.1.3)
- LLVM stack map API research (§1.2.2) - see design_docs/llvm_stackmap_integration.md
- Lean/lz MLIR dialect research (§3.1.1) - see design_docs/lean_mlir_research.md
- Guida I/O audit (§2.1.1) - see design_docs/guida-io-operations.md and guida-io-ops.csv

**In Progress**:
- GC refinement and tuning
- Nursery space optimization

**Next Steps**:
- Process & thread model design (§1.3)
- Begin ECO MLIR dialect definition (§3.1.2)
- Design file system operations API (§2.1.2)
