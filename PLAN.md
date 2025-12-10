# ECO Project Plan

**Elm Compiler Offline - Native Compilation Backend and Runtime**

## Project Roadmap

- [ ] **1. Runtime Foundation** → [§1](#1-runtime-foundation)
  - [x] 1.1 Custom Heap Model → [§1.1](#11-custom-heap-model)
  - [x] 1.2 Garbage Collector → [§1.2](#12-garbage-collector)
    - [x] 1.2.1 Old Generation Algorithm → [§1.2.1](#121-old-generation-algorithm)
    - [x] 1.2.2 LLVM Stack Map Investigation → [§1.2.2](#122-llvm-stack-map-investigation)
    - [ ] 1.2.3 LLVM Stack Map Implementation → [§1.2.3](#123-llvm-stack-map-implementation)
  - [ ] 1.3 Process & Thread Model → [§1.3](#13-process--thread-model)
  - [ ] 1.4 Runtime Testing Infrastructure → [§1.4](#14-runtime-testing-infrastructure)

- [ ] **2. Standard Library Porting** → [§2](#2-standard-library-porting)
  - [ ] 2.1 Guida Runtime to Kernel Packages → [§2.1](#21-guida-runtime-to-kernel-packages)
    - [x] 2.1.0 Bytes over Ports Support → [§2.1.0](#210-bytes-over-ports-support)
    - [ ] 2.1.1 Audit Guida I/O Implementation → [§2.1.1](#211-audit-guida-io-implementation) *(audit complete, rationalization pending)*
    - [ ] 2.1.2 File System Operations Design → [§2.1.2](#212-file-system-operations-design)
    - [ ] 2.1.3 Network Operations Design → [§2.1.3](#213-network-operations-design)
    - [ ] 2.1.4 System Operations Design → [§2.1.4](#214-system-operations-design)
    - [ ] 2.1.5 Kernel Package Implementation & Guida Refactor → [§2.1.5](#215-kernel-package-implementation--guida-refactor)
  - [ ] 2.2 Elm Kernel JavaScript Audit → [§2.2](#22-elm-kernel-javascript-audit)
  - [ ] 2.3 Elm Kernel C++ Implementation → [§2.3](#23-elm-kernel-c-implementation)
    - [ ] 2.3.1 elm/core Kernel → [§2.3.1](#231-elmcore-kernel)
    - [ ] 2.3.2 elm/json Kernel → [§2.3.2](#232-elmjson-kernel)
    - [ ] 2.3.3 elm/bytes Kernel → [§2.3.3](#233-elmbytes-kernel)
    - [ ] 2.3.4 elm/random Kernel → [§2.3.4](#234-elmrandom-kernel)
    - [ ] 2.3.5 elm/time Kernel → [§2.3.5](#235-elmtime-kernel)
  - [ ] 2.4 I/O Kernel Package C++ Implementation → [§2.4](#24-io-kernel-package-c-implementation)

- [ ] **3. MLIR/LLVM Integration** → [§3](#3-mlirllvm-integration)
  - [ ] 3.1 ECO MLIR Dialect → [§3.1](#31-eco-mlir-dialect)
    - [x] 3.1.1 Research & Reference Implementation → [§3.1.1](#311-research--reference-implementation)
    - [x] 3.1.2 Dialect Definition → [§3.1.2](#312-dialect-definition)
    - [ ] 3.1.3 Operations → [§3.1.3](#313-operations) *(in progress - skeletal ops defined)*
    - [ ] 3.1.4 Type System → [§3.1.4](#314-type-system)
    - [ ] 3.1.5 GC Integration Hooks → [§3.1.5](#315-gc-integration-hooks) *(in progress - refcount ops defined)*
    - [ ] 3.1.6 Process Primitives → [§3.1.6](#316-process-primitives)
    - [ ] 3.1.7 Test Programs → [§3.1.7](#317-test-programs)
  - [ ] 3.2 Lowering Pipeline → [§3.2](#32-lowering-pipeline)
  - [ ] 3.3 GC Stack Root Tracing → [§3.3](#33-gc-stack-root-tracing)
  - [ ] 3.4 Multi-target Support → [§3.4](#34-multi-target-support)

- [ ] **4. Compiler Backend** → [§4](#4-compiler-backend)
  - [ ] 4.1 Guida Backend Replacement → [§4.1](#41-guida-backend-replacement)
    - [x] 4.1.1 Pluggable Backend Architecture → [§4.1.1](#411-pluggable-backend-architecture)
    - [x] 4.1.2 Global AST Analysis & Monomorphization → [§4.1.2](#412-global-ast-analysis--monomorphization)
    - [x] 4.1.3 Dual Backend Implementation → [§4.1.3](#413-dual-backend-implementation)
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

**Status**: Complete

Implement a generational garbage collector as an intermediate solution to de-risk the project. More advanced techniques can be added later (see §7).

**Implementation** (verified from code):
- Two-generation design (nursery + old generation)
- Thread-local nursery spaces with Cheney's copying algorithm
- Mark-and-sweep for old generation with free-list allocation
- Lazy sweeping and allocation-paced incremental marking
- Incremental compaction (implemented, manual trigger only)
- Optional DFS locality optimization for list copying
- Promotion age currently set to 1

**Deliverables**:
- [x] `allocator.cpp/hpp`: GC implementation
- [x] `gc_stats.hpp`: Telemetry and diagnostics
- [x] Property-based test suite

#### 1.2.1 Old Generation Algorithm

**Status**: Complete

Choose and implement an appropriate algorithm for old generation garbage collection.

**Implementation** (verified from `OldGenSpace.cpp`):
- Free-list allocation with 32 size classes (8-256 bytes) - lines 162-204
- New allocations marked Black during marking - lines 174-180, 224-229
- Lazy sweeping state machine (`GCPhase` enum) - lines 540-636
- Allocation-paced incremental marking (`MARK_WORK_RATIO`) - lines 130-160
- Fragmentation monitoring (`FragmentationStats`) - lines 652-678
- Incremental compaction (implemented, not auto-triggered) - lines 680-1104
- Object graph traversal for all Elm types
- GC statistics integration (optional)
- Comprehensive property-based test suite (`test/OldGenSpaceTest.cpp`)

**Tasks**:
- [x] Evaluate algorithm options (simple mark-and-sweep vs mark-compact vs other)
- [x] Implement chosen algorithm
- [x] Ensure it is well tested
- [ ] Enable automatic compaction triggering (currently manual only)
- [ ] Expand stress test coverage to exercise all heap object types under GC
- [ ] Verify correctness under extended load testing

**Deliverables**:
- [x] Finalized old generation GC algorithm
- [x] Stress tests covering core object types

#### 1.2.2 LLVM Stack Map Investigation

**Status**: Complete

Research LLVM's stack map facilities for precise stack root tracing.

**Tasks**:
- [x] Research LLVM stack map and statepoint APIs
- [x] Document the integration approach

**Deliverables**:
- [x] Research documentation *(see design_docs/llvm_stackmap_integration.md)*

#### 1.2.3 LLVM Stack Map Implementation

**Status**: Not Started

Implement LLVM stack map integration for precise stack root tracing.

**Tasks**:
- [ ] Build a small example program in LLVM using recursion to create stack frames with heap pointers
- [ ] Integrate stack map parsing into the runtime's root scanning
- [ ] Stress test to verify stack roots are preserved correctly across major GC cycles

**Deliverables**:
- [ ] LLVM stack map example/prototype
- [ ] Runtime stack map parser
- [ ] Integration tests for stack root preservation

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
- [ ] Process lifecycle management
- [ ] Message queue implementation (disruptor pattern)
- [ ] Thread-safe process coordination
- [ ] Process handle storage in heap model

### 1.4 Runtime Testing Infrastructure

**Status**: In Progress

Comprehensive testing for runtime correctness and performance.

**Current Status**:
- Property-based tests using RapidCheck
- Heap snapshot validation
- GC correctness properties (preservation, collection, stability)

**Required**:
- [ ] Performance benchmarks
- [ ] Stress testing under concurrent load
- [ ] Memory leak detection
- [ ] Integration tests with compiled code

**Deliverables**:
- [ ] Expanded test suite in `test/`
- [ ] Benchmarking framework
- [ ] Continuous integration setup

---

## 2. Standard Library Porting

Elm's standard libraries must be ported from JavaScript to native C++ implementations.

### 2.1 Guida Runtime to Kernel Packages

**Status**: Not Started

The Guida compiler currently uses a small runtime library with HTTP URL hacks for I/O operations. Convert this to proper Elm kernel packages.

**Deliverables**:
- [ ] Elm kernel package definitions
- [ ] API specification document
- [ ] Refactored Guida using new kernel package

#### 2.1.0 Bytes over Ports Support

**Status**: Complete

Enable `Bytes.Bytes` to be sent through Elm ports, allowing binary data interchange between Elm and JavaScript.

**Background**: Standard Elm does not support sending `Bytes` through ports. The elm/json package lacks `Json.Encode.bytes` and `Json.Decode.bytes` functions. This feature is needed for ECO's I/O system to efficiently handle binary data.

**Implementation**:
- Modified `Compiler/Optimize/Port.elm` to generate kernel function references for Bytes encoding/decoding
- Added `_Json_encodeBytes` and `_Json_decodeBytes` JavaScript functions to `Compiler/Generate/JavaScript.elm`
- Functions are injected after kernel code but before module code (order matters for references)

**Technical Details**:
- `_Json_encodeBytes`: Converts Elm's `DataView` (internal Bytes representation) → JavaScript `Uint8Array`
- `_Json_decodeBytes`: Accepts `Uint8Array`, `ArrayBuffer`, or `DataView` → Elm's `DataView`
- Uses `_Json_decodePrim` for decoder infrastructure (consistent with other Json decoders)
- Uses `_Json_wrap` for encoder output (consistent with other Json encoders)

**Files Modified**:
- `compiler/src/Compiler/Optimize/Port.elm`: Added `encodeBytes` and `decodeBytes` helpers using kernel references
- `compiler/src/Compiler/Generate/JavaScript.elm`: Added `bytesForPorts` constant with JS implementations

**Test Program**: `compiler/bop/` contains a working example demonstrating bytes over ports.

**Tasks**:
- [x] Implement `_Json_encodeBytes` function
- [x] Implement `_Json_decodeBytes` function
- [x] Modify Port.elm to reference kernel functions for Bytes type
- [x] Ensure correct code generation order (functions defined before use)
- [x] Test with example program

**Deliverables**:
- [x] Modified Guida compiler with Bytes over Ports support
- [x] Test program (`compiler/bop/`)

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
- [ ] Catalog current file operations in Guida
- [ ] Rationalize into a coherent file system API
- [ ] Operations to include: read, write, append, delete, rename, copy
- [ ] Directory operations: create, list, remove, walk
- [ ] Path handling: join, normalize, resolve, relative paths
- [ ] File metadata: size, timestamps, permissions

**Deliverables**:
- [ ] File system API specification

#### 2.1.3 Network Operations Design

**Status**: Not Started

Design a clean API for network operations.

**Tasks**:
- [ ] Catalog current network operations in Guida (HTTP, package fetching)
- [ ] Rationalize into a coherent network API
- [ ] HTTP client: GET, POST, headers, body handling, streaming
- [ ] Consider connection pooling and timeout handling
- [ ] Package/resource fetching abstraction

**Deliverables**:
- [ ] Network API specification

#### 2.1.4 System Operations Design

**Status**: Not Started

Design a clean API for system-level operations.

**Tasks**:
- [ ] Catalog current system operations in Guida
- [ ] Rationalize into a coherent system API
- [ ] Environment variables: get, set, list
- [ ] Command-line arguments: parsing, access
- [ ] Process execution: spawn, wait, capture output, piping
- [ ] Exit codes and program termination
- [ ] Current working directory operations

**Deliverables**:
- [ ] System operations API specification

#### 2.1.5 Kernel Package Implementation & Guida Refactor

**Status**: Not Started

Design Elm types for the kernel package and refactor Guida to use it.

**Tasks**:
- [ ] Design Elm types using Cmd/Sub or Task with an effects module implementation
- [ ] Ensure API covers all I/O operations Guida requires
- [ ] Modify Guida to allow kernel code in non-elm/* packages (break the restriction)
- [ ] Enable loading kernel packages from the local file system (not Elm package site)
- [ ] Implement the kernel package with JavaScript runtime for current Guida
- [ ] Refactor Guida to use the new kernel package
- [ ] Remove existing I/O system entirely from Guida
- [ ] Verify Guida still builds and functions correctly

**Deliverables**:
- [ ] Elm kernel package type definitions
- [ ] Effects module implementation
- [ ] Modified Guida compiler (kernel package restrictions relaxed)
- [ ] Local kernel package loading support
- [ ] Refactored Guida using new I/O kernel package

### 2.2 Elm Kernel JavaScript Audit

**Status**: Not Started

Audit all kernel JavaScript files in Elm's standard packages to understand what needs to be ported to C++.

**Background**: Elm packages contain kernel JavaScript files (e.g., `Elm/Kernel/List.js`) that implement low-level operations. These must be reimplemented in C++ for native compilation. This audit will create a comprehensive catalog of all kernel functions.

**Packages to Audit**:
- `elm/core` - Basics, List, String, Char, Array, Bitwise, Debug, Platform, Process, Scheduler, Utils
- `elm/json` - JSON encoding/decoding primitives
- `elm/bytes` - Binary data handling
- `elm/random` - Random number generation
- `elm/time` - Time primitives
- `elm/virtual-dom` - (may not be needed for CLI, but audit anyway)
- `elm/browser` - (may not be needed for CLI)
- `elm/http` - HTTP client primitives
- `elm/file` - File handling primitives

**Tasks**:
- [ ] Clone/locate all standard Elm packages
- [ ] For each package, catalog all kernel JS files
- [ ] For each kernel file, document:
  - [ ] All exported functions
  - [ ] Function signatures (parameters, return types)
  - [ ] Dependencies on other kernel functions
  - [ ] Dependencies on browser/Node.js APIs
- [ ] Identify which packages are essential for CLI tools vs browser-only
- [ ] Prioritize kernel functions by importance for self-hosting Guida

**Deliverables**:
- [ ] Kernel function catalog (CSV or similar)
- [ ] Dependency graph between kernel modules
- [ ] Prioritized implementation order
- [ ] Documentation in `design_docs/elm-kernel-audit.md`

### 2.3 Elm Kernel C++ Implementation

**Status**: Not Started

Implement Elm kernel functions in C++ using the ECO runtime's heap model.

**Architecture**:
- All kernel functions operate on ECO heap objects (`runtime/src/allocator/Heap.hpp`)
- Functions follow C++ calling conventions for linkage with MLIR-generated code
- Memory management uses ECO's garbage collector
- Each kernel module becomes a C++ source file in `runtime/src/kernel/`

**Common Patterns**:
- Elm `List` → `Heap::Cons` chains ending in `Heap::Nil`
- Elm `String` → `Heap::String` (UTF-8 encoded)
- Elm `Int` → `Heap::Int` or unboxed where possible
- Elm `Maybe` → `Heap::Custom` with tags for Just/Nothing
- Elm `Result` → `Heap::Custom` with tags for Ok/Err

**Testing Strategy**:
- Property-based tests comparing C++ output to JavaScript kernel output
- Use RapidCheck generators from existing test infrastructure
- Test each kernel function in isolation before integration

#### 2.3.1 elm/core Kernel

**Status**: Not Started

Implement the core kernel functions that all Elm programs depend on.

**Kernel Files**:
- `Basics.js` - Arithmetic, comparison, boolean operations
- `List.js` - List construction, traversal, transformation
- `String.js` - String manipulation, conversion
- `Char.js` - Character operations, Unicode handling
- `Array.js` - Array operations (mutable under the hood)
- `Bitwise.js` - Bitwise integer operations
- `Debug.js` - Debug.log, Debug.toString
- `Utils.js` - Equality, comparison, tuples, update
- `Scheduler.js` - Task scheduling, process management
- `Platform.js` - Program initialization, ports, effects
- `Process.js` - Process spawning, killing

**Priority Order** (for self-hosting):
1. `Utils.js` - Fundamental operations used everywhere
2. `Basics.js` - Arithmetic and comparisons
3. `List.js` - List operations (heavily used)
4. `String.js` - String manipulation
5. `Char.js` - Character handling
6. `Bitwise.js` - Bit operations
7. `Array.js` - Array operations
8. `Debug.js` - Debugging support
9. `Scheduler.js` - Task execution
10. `Platform.js` - Program runtime
11. `Process.js` - Process management

**Tasks**:
- [ ] Implement `Kernel/Utils.cpp` - eq, cmp, Tuple0/2/3, update, append, chr
- [ ] Implement `Kernel/Basics.cpp` - arithmetic, comparison, boolean ops
- [ ] Implement `Kernel/List.cpp` - cons, head, tail, map, filter, foldl, foldr, etc.
- [ ] Implement `Kernel/String.cpp` - concat, slice, split, etc.
- [ ] Implement `Kernel/Char.cpp` - toCode, fromCode, toUpper, toLower
- [ ] Implement `Kernel/Bitwise.cpp` - and, or, xor, shiftLeft, shiftRight
- [ ] Implement `Kernel/Array.cpp` - get, set, push, slice, etc.
- [ ] Implement `Kernel/Debug.cpp` - log, toString
- [ ] Implement `Kernel/Scheduler.cpp` - task scheduling primitives
- [ ] Implement `Kernel/Platform.cpp` - program initialization
- [ ] Implement `Kernel/Process.cpp` - process primitives

**Deliverables**:
- [ ] C++ kernel implementations in `runtime/src/kernel/`
- [ ] Header files declaring kernel function signatures
- [ ] Unit tests for each kernel module

#### 2.3.2 elm/json Kernel

**Status**: Not Started

Implement JSON encoding and decoding primitives.

**Kernel Functions**:
- Decoders: `decodeInt`, `decodeFloat`, `decodeString`, `decodeBool`, `decodeNull`, `decodeList`, `decodeArray`, `decodeField`, `decodeIndex`, `decodeKeyValuePairs`, `decodeMap*`, `decodeOneOf`, `decodeFail`, `decodeSucceed`, `decodeAndThen`
- Encoders: `encodeNull`, `encodeInt`, `encodeFloat`, `encodeString`, `encodeBool`, `encodeList`, `encodeArray`, `encodeObject`
- `encode` - Convert Value to String
- `decodeString` - Parse JSON string
- Bytes support: `encodeBytes`, `decodeBytes` (already added to Guida)

**Tasks**:
- [ ] Implement JSON parser (or integrate existing C++ JSON library)
- [ ] Implement decoder combinators
- [ ] Implement encoder functions
- [ ] Implement `Kernel/Json.cpp`

**Deliverables**:
- [ ] `runtime/src/kernel/Json.cpp`
- [ ] JSON parsing/serialization
- [ ] Unit tests

#### 2.3.3 elm/bytes Kernel

**Status**: Not Started

Implement binary data handling primitives.

**Kernel Functions**:
- `Bytes.width` - Get byte length
- Encoding: `write_i8`, `write_i16`, `write_i32`, `write_f32`, `write_f64`, `write_string`, `write_bytes`
- Decoding: `read_i8`, `read_i16`, `read_i32`, `read_f32`, `read_f64`, `read_string`, `read_bytes`
- Endianness handling (BE/LE)

**Tasks**:
- [ ] Define `Heap::Bytes` representation (or use existing if defined)
- [ ] Implement `Kernel/Bytes.cpp`
- [ ] Handle endianness correctly

**Deliverables**:
- [ ] `runtime/src/kernel/Bytes.cpp`
- [ ] Unit tests

#### 2.3.4 elm/random Kernel

**Status**: Not Started

Implement random number generation primitives.

**Kernel Functions**:
- `initialSeed` - Create seed from integer
- `next` - Generate next random value
- `peel` - Extract value from seed

**Notes**: Elm uses a specific PRNG algorithm (PCG) for reproducibility. Must match exactly.

**Tasks**:
- [ ] Research Elm's exact PRNG algorithm
- [ ] Implement `Kernel/Random.cpp`
- [ ] Verify output matches JavaScript version for same seeds

**Deliverables**:
- [ ] `runtime/src/kernel/Random.cpp`
- [ ] Unit tests with seed verification

#### 2.3.5 elm/time Kernel

**Status**: Not Started

Implement time-related primitives.

**Kernel Functions**:
- `now` - Get current POSIX time
- `here` - Get current time zone
- `getZoneName` - Get time zone name
- Conversion functions for time zones

**Tasks**:
- [ ] Implement `Kernel/Time.cpp`
- [ ] Handle time zone database (may need external dependency)

**Deliverables**:
- [ ] `runtime/src/kernel/Time.cpp`
- [ ] Unit tests

### 2.4 I/O Kernel Package C++ Implementation

**Status**: Not Started

Implement the I/O kernel packages defined in §2.1 in C++ for linking with the native runtime.

**Background**: This is separate from the standard Elm kernel (§2.3) because it covers the custom I/O operations needed for CLI tools, as designed in §2.1.

**Tasks**:
- [ ] C++ implementations of file system APIs (§2.1.2)
- [ ] C++ implementations of network APIs (§2.1.3)
- [ ] C++ implementations of system APIs (§2.1.4)
- [ ] FFI bridge between Elm and C++ runtime
- [ ] Memory management for foreign objects (file handles, sockets, etc.)
- [ ] Error handling across language boundary

**Deliverables**:
- [ ] C++ I/O kernel implementations in `runtime/src/kernel/`
- [ ] FFI bridge code
- [ ] Test suite for I/O operations

---

## 3. MLIR/LLVM Integration

The compilation pipeline uses MLIR for high-level optimization and LLVM for code generation.

### 3.1 ECO MLIR Dialect

**Status**: In Progress

Design and implement a custom MLIR dialect called "eco" for Elm compilation.

**Expertise Required**: MLIR framework knowledge

**Deliverables**:
- [x] `ECODialect.cpp/hpp`: Dialect definition
- [x] Operation definitions (skeletal)
- [ ] Type system implementation
- [ ] MLIR dialect documentation
- [ ] Test programs demonstrating dialect usage

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

**Status**: Complete

Create the core dialect infrastructure.

**Tasks**:
- [x] Define ECO dialect namespace and registration with MLIR framework
- [ ] Set up dialect versioning strategy
- [x] Establish dialect structure and organization
- [x] Configure build system for MLIR integration

**Deliverables**:
- [x] `EcoDialect.cpp/hpp`: Core dialect definition *(runtime/src/codegen/)*
- [x] CMake integration for MLIR *(runtime/src/codegen/CMakeLists.txt)*

#### 3.1.3 Operations

**Status**: In Progress

Define custom operations representing Elm semantics.

**Current Implementation** *(runtime/src/codegen/Ops.td - ~30 ops defined)*:
- Control flow: `eco.func`, `eco.let`, `eco.switch`, `eco.ret`, `eco.joinpoint`, `eco.jump`, `eco.crash`, `eco.expect`, `eco.dbg`
- Values/ADTs: `eco.string_literal`, `eco.struct`, `eco.struct_extract`, `eco.tag_construct`, `eco.tag_get_id`, `eco.tag_extract`, `eco.list_literal`, `eco.empty_list`, `eco.erased.pack`, `eco.erased.unpack`
- Calls: `eco.call`, `eco.call_indirect`, `eco.call_foreign`, `eco.call_lowlevel`, `eco.call_ho`
- Reference counting (Perceus-style): `eco.incref`, `eco.decref`, `eco.decref_shallow`, `eco.free`, `eco.reset`, `eco.reset_ref`

**Tasks**:
- [x] Function definition and application operations
- [x] Pattern matching operations (switch, joinpoint/jump)
- [x] Data constructor operations (tag_construct, tag_get_id, tag_extract)
- [x] Record operations (struct, struct_extract)
- [x] Let bindings and variable references
- [ ] Closure creation and invocation (not yet defined)
- [ ] Add parser/printer/builder/verification for all ops

**Deliverables**:
- [x] Operation definitions in TableGen *(Ops.td)*
- [x] Operation implementation files *(EcoOps.cpp/h)*
- [ ] Complete operation semantics and verification

#### 3.1.4 Type System

**Status**: Not Started

Implement MLIR types matching Elm's type system.

**Tasks**:
- [ ] Primitive types (Int, Float, Char, String, Bool)
- [ ] Function types
- [ ] Algebraic data types (custom types, Maybe, Result, List)
- [ ] Record types
- [ ] Type variables and polymorphism representation

**Deliverables**:
- [ ] Type definitions in TableGen
- [ ] Type implementation files

#### 3.1.5 GC Integration Hooks

**Status**: In Progress

Define operations for garbage collection integration.

**Current Implementation**:
- Reference counting ops defined: `eco.incref`, `eco.decref`, `eco.decref_shallow`, `eco.free`, `eco.reset`, `eco.reset_ref`

**Tasks**:
- [ ] Allocation operations (nursery, old gen)
- [ ] GC safepoint operations
- [ ] Root registration/deregistration operations
- [ ] Write barrier operations (if needed for future concurrent GC)
- [x] Reference counting operations (Perceus-style reuse)

**Deliverables**:
- [x] Reference counting operation definitions *(in Ops.td)*
- [ ] Allocation operation definitions
- [ ] Documentation on GC integration points

#### 3.1.6 Process Primitives

**Status**: Not Started

Define operations for Elm process and task handling.

**Tasks**:
- [ ] Process creation operations
- [ ] Message send/receive operations
- [ ] Task operations
- [ ] Subscription handling

**Deliverables**:
- [ ] Process/task operation definitions

#### 3.1.7 Test Programs

**Status**: Not Started

Create small test programs to validate the dialect.

**Tasks**:
- [ ] Write small programs directly in ECO MLIR dialect
- [ ] Compile through MLIR pipeline to LLVM IR
- [ ] Link with ECO runtime and execute
- [ ] Validate correctness of generated code
- [ ] Create test suite covering all operations and types

**Deliverables**:
- [ ] Suite of ECO MLIR test programs
- [ ] Test harness for dialect validation
- [ ] Documentation of test coverage

### 3.2 Lowering Pipeline

**Status**: Not Started

Implement a lowering pipeline that transforms eco dialect to LLVM IR.

**Pipeline Stages**:
1. **High-level eco**: Direct representation of Elm semantics
2. **Lowered eco**: Explicit memory management, GC calls
3. **LLVM IR**: Target-independent intermediate representation
4. **Native code**: x86, ARM, WebAssembly, etc.

**Transformations**:
- [ ] Pattern matching to control flow
- [ ] Closure conversion
- [ ] Heap allocation insertion
- [ ] GC safepoint insertion
- [ ] Tail call optimization

**Deliverables**:
- [ ] Lowering passes in C++
- [ ] Pass pipeline configuration
- [ ] Optimization passes
- [ ] Testing framework for transformations

### 3.3 GC Stack Root Tracing

**Status**: Not Started

Integration between LLVM and the garbage collector for precise stack scanning.

**Requirements**:
- [ ] LLVM stack map generation
- [ ] Runtime stack root registration
- [ ] Safepoint insertion in generated code
- [ ] Thread-safe root set management

**Deliverables**:
- [ ] LLVM stackmap integration
- [ ] Runtime root scanning infrastructure
- [ ] Documentation on GC integration

### 3.4 Multi-target Support

**Status**: Not Started

Leverage LLVM's retargetability for multiple platforms.

**Initial Targets**: x86-64 (Linux), WebAssembly

**Future Targets**: See §8 (More Compilation Targets)

**Deliverables**:
- [ ] x86-64 Linux target configuration and runtime
- [ ] WebAssembly target with memory model adaptations for WASM linear memory
- [ ] Target-specific testing

---

## 4. Compiler Backend

Replace the existing Guida compiler backend with one that generates MLIR.

### 4.1 Guida Backend Replacement

**Status**: Complete

The Guida compiler (Elm port) needs its backend modified to support MLIR output alongside JavaScript.

**Deliverables**:
- [x] Pluggable backend architecture
- [x] MLIR emission code
- [x] Compiler flags for output mode selection
- [x] Documentation on backend architecture (in PLAN.md sections 4.1.1-4.1.3)

#### 4.1.1 Pluggable Backend Architecture

**Status**: Complete

Ensure the backend can be replaced with alternative implementations.

**Implementation**:
- `CodeGen.elm` defines `CodeGen`, `TypedCodeGen`, and `MonoCodeGen` record types as backend interfaces
- Each backend type specifies required functions (`generate`, `generateForRepl`)
- `Generate.elm` provides `dev`, `debug`, `prod`, `typedDev`, and `monoDev` functions that accept backend as parameter
- JavaScript, MLIR (typed), and MLIR Mono backends all implement these interfaces
- `Terminal/Make.elm` selects appropriate backend based on output file extension (.js, .html, .mlir)

**Tasks**:
- [x] Study existing Guida backend architecture and module structure
- [x] Define a clean API that allows the backend to be "plugged in" to the compiler
- [x] Refactor backend to implement this pluggable interface
- [x] Create working backend implementations (JavaScript, MLIR Typed, MLIR Mono)

**Deliverables**:
- [x] Pluggable backend interface definition (`Compiler/Generate/CodeGen.elm`)
- [x] Refactored JavaScript backend implementing the interface
- [x] MLIR backends implementing the interface

#### 4.1.2 Global AST Analysis & Monomorphization

**Status**: Complete

Analyze the Guida/Elm Global AST and consider necessary changes for native compilation.

**Background**: The Optimized IR (GlobalGraph) currently discards type information since JavaScript code generation doesn't need it. For MLIR/native code generation, full type information must be preserved to generate correctly typed operations and enable monomorphization.

**Implementation**:
- Created parallel TypedOptimized AST (`TOpt.LocalGraph`, `TOpt.GlobalGraph`) that preserves full type information
- `Compile.compileTyped` generates both standard optimized IR and typed IR in a single pass
- Monomorphization pass (`Mono.elm`) specializes polymorphic functions based on concrete types
- Added `needsTypedOpt` flag to compilation environment to trigger typed optimization when targeting MLIR

**Key Files**:
- `Compiler/AST/TypedOptimized.elm`: Typed AST definitions with full type annotations
- `Compiler/Optimize/Mono.elm`: Monomorphization pass implementation
- `Compiler/Type/Occurs.elm`: Type specialization utilities
- `Builder/Build.elm`: Modified to pass `needsTypedOpt` flag and handle typed compilation for root modules

**Tasks**:
- [x] Study the Global AST structure and how it represents Elm programs
- [x] Modify compiler to preserve full type information in Optimized IR
  - [x] Identify where type information is currently discarded
  - [x] Extend Opt.Expr and related types to carry type annotations (via TOpt module)
  - [x] Ensure type information flows through optimization passes
- [x] Design and implement monomorphization pass on GlobalGraph
  - [x] Specialize polymorphic functions into type-specific implementations
  - [x] Focus on Record shape specialization (different record types → different implementations)
  - [x] Handle type variables and constraints
- [x] Evaluate whether DynRecord is needed for native compilation or can be eliminated
- [x] Document AST changes needed for MLIR code generation

**Deliverables**:
- [x] Modified Optimized IR with type annotations (`Compiler/AST/TypedOptimized.elm`)
- [x] Monomorphization pass implementation (`Compiler/Optimize/Mono.elm`)
- [x] Global AST analysis document
- [x] Decision on DynRecord necessity
- [x] AST modification plan (if needed)

#### 4.1.3 Dual Backend Implementation

**Status**: Complete

Keep JavaScript backend and add MLIR backend with compiler flags to switch between them.

**Implementation**:
- Backend selection via output file extension: `.js` → JavaScript, `.html` → JavaScript+HTML wrapper, `.mlir` → MLIR Mono backend
- Three backend types implemented:
  - `javascriptBackend`: Standard JavaScript code generation (uses untyped `Opt.GlobalGraph`)
  - `mlirTypedBackend`: MLIR with type information (uses typed `TOpt.GlobalGraph`)
  - `mlirMonoBackend`: MLIR with monomorphized code (uses monomorphized `Mono.GlobalGraph`)
- `Terminal/Make.elm` routes to appropriate backend based on `--output` extension
- `shouldUseTypedOpt` helper determines if typed optimization is needed based on output type
- Root modules (specified by file path) now correctly generate typed graphs when targeting MLIR

**Key Files**:
- `Compiler/Generate/CodeGen.elm`: Backend interface definitions (`CodeGen`, `TypedCodeGen`, `MonoCodeGen`)
- `Builder/Generate.elm`: Backend implementations and `dev`/`debug`/`prod`/`typedDev`/`monoDev` functions
- `Compiler/Generate/MLIR.elm`: MLIR code generation using typed AST
- `Compiler/Generate/MLIRMono.elm`: MLIR code generation using monomorphized AST
- `Terminal/Make.elm`: Output routing based on file extension

**Tasks**:
- [x] Add compiler flags to choose output mode (JavaScript vs native/MLIR)
- [x] Implement command-line interface for backend selection
- [x] Build out the MLIR-based backend implementation using the pluggable architecture
- [x] Ensure both backends can coexist and be selected at compile time
- [x] Validate JavaScript backend still works correctly after refactoring

**Deliverables**:
- [x] Compiler flags for output mode selection (via `--output` file extension)
- [x] MLIR backend implementation (typed and monomorphized variants)
- [x] Both backends functional and selectable

#### 4.1.4 Compiler Test Suite

**Status**: Not Started

Get existing tests running and expand coverage.

**Tasks**:
- [ ] Get Guida's existing test suite running
- [ ] Verify tests pass with both JavaScript and MLIR backends
- [ ] Expand tests to cover more Elm programs and edge cases
- [ ] Add regression tests for backend-specific behavior
- [ ] Create test programs that exercise all Elm language features

**Deliverables**:
- [ ] Working Guida test suite
- [ ] Expanded test coverage
- [ ] Backend comparison tests

### 4.2 MLIR Code Generation

**Status**: Not Started

Implement code generation from Elm AST to eco MLIR dialect.

**Prerequisites**:
- Type-annotated Optimized IR (§4.1.2) - MLIR code generation requires full type information
- Monomorphization pass (§4.1.2) - polymorphic code must be specialized before MLIR emission

**Code Generation Tasks**:
- [ ] Expression translation
- [ ] Pattern matching compilation
- [ ] Function definitions
- [ ] Module system
- [ ] Foreign function interface
- [ ] Closure representation
- [ ] Data constructor encoding

**Deliverables**:
- [ ] Code generation modules
- [ ] MLIR builder utilities
- [ ] Symbol table management

### 4.3 Compiler Testing

**Status**: Not Started

Comprehensive testing for the compiler backend.

**Test Categories**:
- [ ] Unit tests for code generation
- [ ] Integration tests (Elm → MLIR → LLVM → native)
- [ ] Correctness tests against reference implementation
- [ ] Performance benchmarks
- [ ] Regression test suite

**Deliverables**:
- [ ] Test suite infrastructure
- [ ] Elm test programs
- [ ] Expected output validation
- [ ] Performance baseline

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
- [ ] Working `eco` compiler binary
- [ ] Build scripts and packaging
- [ ] Usage documentation

#### 5.1.1 Pipeline Integration

**Status**: Not Started

Connect all compiler stages into a working pipeline.

**Tasks**:
- [ ] Wire up Guida frontend to MLIR backend
- [ ] Connect MLIR lowering passes
- [ ] Integrate LLVM code generation
- [ ] Produce working native binaries from Elm source

**Deliverables**:
- [ ] End-to-end compilation working
- [ ] Pipeline orchestration code

#### 5.1.2 Command-Line Interface

**Status**: Not Started

Design and implement user-facing CLI for the `eco` compiler.

**Tasks**:
- [ ] Design CLI options and flags
- [ ] Implement argument parsing
- [ ] Support compilation modes (compile, build, run)
- [ ] Error reporting and diagnostics output
- [ ] Verbose/debug output modes

**Deliverables**:
- [ ] `eco` CLI implementation
- [ ] Help text and usage documentation

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
- [ ] Extract elm/core and other ported Elm base libraries into standalone packages
- [ ] Create linkable libraries (.a/.so) for all kernel operations implemented in C/C++
- [ ] Design library discovery and linking as part of eco compilation flow
- [ ] Handle native library dependencies
- [ ] Support static and dynamic linking options

**Deliverables**:
- [ ] Standalone kernel library packages
- [ ] Linker integration in eco compiler
- [ ] Library packaging and distribution

#### 5.1.5 Debugging Support

**Status**: Not Started

Enable debugging of compiled Elm programs.

**Tasks**:
- [ ] Generate DWARF debug symbols
- [ ] Map native code locations back to Elm source
- [ ] Enable stack traces with Elm source locations
- [ ] Integration with GDB/LLDB debuggers
- [ ] Consider source map generation for additional tooling

**Deliverables**:
- [ ] Debug symbol generation
- [ ] Source location mapping
- [ ] Debugger integration documentation

### 5.2 Bootstrap to Native x86

**Status**: Not Started

Compile the Guida compiler itself using ECO to produce a native x86 version.

**Requirements**:
- [ ] All dependencies ported (§2)
- [ ] Compiler backend complete (§4)
- [ ] Runtime stable (§1)

**Deliverables**:
- [ ] Native ECO compiler binary
- [ ] Build instructions
- [ ] Verification tests

### 5.3 Self-Compilation Milestone

**Status**: Not Started

Achieve self-compilation: ECO compiling itself through its own native output.

**Success Criteria**:
- [ ] ECO compiles its own source code
- [ ] Generated binary passes all tests
- [ ] Performance meets baseline requirements
- [ ] Binary is reproducible

**Milestone**: This marks the primary project completion point and readiness for initial release.

---

## 6. Optimization & Release

Post-milestone work focused on performance and polish.

### 6.1 Performance Testing

**Status**: Not Started

Comprehensive performance analysis and benchmarking.

**Benchmarks**:
- [ ] Compilation speed
- [ ] Runtime performance (vs JavaScript backend)
- [ ] Memory usage
- [ ] GC overhead
- [ ] Message passing throughput
- [ ] Process creation/switching cost

**Deliverables**:
- [ ] Benchmark suite
- [ ] Performance reports
- [ ] Bottleneck identification

### 6.2 Release Preparation

**Status**: Not Started

Prepare ECO for public release.

**Tasks**:
- [ ] Documentation (user guide, API reference)
- [ ] Installation scripts
- [ ] Package management integration plan
- [ ] Community engagement (website, announcements)
- [ ] Issue tracker setup
- [ ] Contributing guidelines

**Deliverables**:
- [ ] Release version 1.0
- [ ] Documentation site
- [ ] Distribution packages

---

## 7. Advanced Garbage Collection

Advanced GC techniques to reduce garbage generation and improve performance. These are post-milestone optimizations building on the foundational GC in §1.2.

### 7.1 Fixed-Size Object Spaces

**Status**: Not Started

Implement segregated allocation spaces for fixed-size objects that don't require compaction.

**Rationale**: Objects of known, fixed sizes can be allocated from dedicated pools, eliminating fragmentation and the need for compaction. Free slots can be tracked with bitmaps or free lists.

**Tasks**:
- [ ] Identify common fixed-size object classes (e.g., Cons cells, Tuple2, small closures)
- [ ] Implement segregated free-list allocators for each size class
- [ ] Integrate with existing GC for collection
- [ ] Benchmark allocation/deallocation performance

**Deliverables**:
- [ ] Size-segregated allocation pools
- [ ] Integration with mark-and-sweep collection
- [ ] Performance comparison with general allocator

### 7.2 Stack-Allocated Values

**Status**: Not Started

Enable unboxed values and small objects to be allocated directly on the program stack.

**Rationale**: Values that don't escape their scope can live on the stack, avoiding heap allocation entirely. This requires escape analysis at compile time.

**Tasks**:
- [ ] Define criteria for stack-allocatable values (size limits, escape analysis results)
- [ ] Implement compiler support for escape analysis (coordinate with §4)
- [ ] Generate code that allocates qualifying values on stack
- [ ] Ensure GC correctly handles mixed stack/heap object graphs

**Deliverables**:
- [ ] Escape analysis pass in compiler
- [ ] Stack allocation code generation
- [ ] Verification tests for correctness

### 7.3 Reference Counting & Uniqueness

**Status**: Not Started

Use reference counting to detect unique references (refcount == 1) enabling safe in-place mutation.

**Rationale**: Elm's immutability is a semantic guarantee, but if an object has exactly one reference, mutating it in place is observationally equivalent to creating a new copy. This can dramatically reduce allocation for operations like list building or record updates.

**Tasks**:
- [ ] Implement reference count tracking in object headers
- [ ] Detect refcount == 1 at runtime to enable mutation
- [ ] Identify operations that benefit from uniqueness (e.g., `List.map`, record update)
- [ ] Ensure correctness: mutation only when truly unique
- [ ] Measure allocation reduction in benchmarks

**Deliverables**:
- [ ] Reference counting infrastructure
- [ ] Uniqueness-based mutation optimization
- [ ] Benchmark suite showing allocation savings

### 7.4 Lock-Free Optimization

**Status**: Not Started

Replace mutex-based synchronization with lock-free algorithms where beneficial to reduce contention.

**Rationale**: Lock-free algorithms can reduce contention in highly concurrent scenarios, improving throughput when many threads are allocating simultaneously. This is an optimization that can be pursued once the basic GC is stable.

**Tasks**:
- [ ] Profile current mutex contention points
- [ ] Identify candidates for lock-free replacement using CAS operations
- [ ] Implement lock-free alternatives for high-contention paths
- [ ] Add performance metrics to stress test programs
- [ ] Target: 8 threads running at ~800% CPU utilization to demonstrate low contention
- [ ] Benchmark before/after to validate improvements

**Deliverables**:
- [ ] Lock-free data structures for GC coordination
- [ ] Performance metrics and benchmarks
- [ ] Contention analysis report

---

## 8. More Compilation Targets

Additional platform targets beyond the initial x86-64 Linux and WebAssembly support.

### 8.1 ARM64 Support

**Status**: Not Started

Support ARM64 architecture on Linux and macOS.

**Tasks**:
- [ ] ARM64 Linux target configuration
- [ ] ARM64 macOS target configuration
- [ ] Platform-specific runtime adaptations (calling conventions, atomics)
- [ ] Testing on ARM64 hardware

**Deliverables**:
- [ ] ARM64 target support
- [ ] Platform-specific runtime code
- [ ] Test suite validation on ARM64

### 8.2 Windows Support

**Status**: Not Started

Support x86-64 Windows platform.

**Tasks**:
- [ ] Windows target configuration
- [ ] Platform-specific I/O implementation (Windows APIs vs POSIX)
- [ ] Threading adaptations (Windows threads vs pthreads)
- [ ] Build system support for MSVC/MinGW

**Deliverables**:
- [ ] Windows x86-64 target support
- [ ] Windows-specific runtime code
- [ ] Windows build and test infrastructure

### 8.3 Cross-Compilation Infrastructure

**Status**: Not Started

Build system support for cross-compilation to all targets.

**Tasks**:
- [ ] CMake toolchain files for each target
- [ ] CI/CD pipelines for cross-platform builds
- [ ] Target-specific testing infrastructure (emulators, remote testing)
- [ ] Distribution packaging for each platform

**Deliverables**:
- [ ] Cross-compilation toolchain configurations
- [ ] Multi-platform CI/CD setup
- [ ] Platform-specific distribution packages

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

**Current Phase**: Compiler Backend Complete, MLIR Code Generation Ready
**Last Updated**: 2025-12-10

**Completed**:
- Heap model design (§1.1)
- Full garbage collector implementation (§1.2)
  - Thread-local nursery with Cheney's copying algorithm
  - Old generation with mark-and-sweep, free-list allocation
  - Lazy sweeping and allocation-paced incremental marking
  - Incremental compaction (implemented, manual trigger)
  - Optional DFS locality optimization for list copying
- Property-based testing infrastructure
- Dockerfile for reproducible builds (§5.1.3)
- LLVM stack map API research (§1.2.2) - see design_docs/llvm_stackmap_integration.md
- Lean/lz MLIR dialect research (§3.1.1) - see design_docs/lean_mlir_research.md
- Guida I/O audit (§2.1.1) - see design_docs/guida-io-operations.md and guida-io-ops.csv
- ECO MLIR dialect definition (§3.1.2) - core infrastructure in runtime/src/codegen/
- ECO MLIR operations skeleton (§3.1.3) - ~30 ops defined in Ops.td
- Bytes over Ports support (§2.1.0) - enables binary data through Elm ports
- Pluggable backend architecture (§4.1.1) - `CodeGen`, `TypedCodeGen`, `MonoCodeGen` interfaces
- Global AST analysis & monomorphization (§4.1.2) - TypedOptimized AST and Mono pass
- Dual backend implementation (§4.1.3) - JS and MLIR backends with extension-based selection

**Recent Changes**:
- Completed compiler backend refactoring (§4.1)
  - Implemented pluggable backend architecture with three backend types
  - Created TypedOptimized AST (`TOpt.LocalGraph`, `TOpt.GlobalGraph`) preserving full type info
  - Implemented monomorphization pass (`Compiler/Optimize/Mono.elm`)
  - Added MLIR code generation backends (typed and monomorphized variants)
  - Fixed root module typed compilation for MLIR output
  - Backend selection via output file extension (`.js`, `.html`, `.mlir`)
- Modified `Builder/Build.elm` to support typed optimization in root modules
  - Extended `RootResult` and `Root` types to include typed graphs
  - Added `needsTypedOpt` flag to compilation environment
  - `compileOutside` now uses `Compile.compileTyped` when targeting MLIR
- Modified `Builder/Generate.elm` to include root typed graphs in monomorphized output
  - Added `addRootTypedGraph` helper function
  - Fixed `monoDev` to properly collect typed graphs from all roots
- MLIR compilation now works for example programs (Hello.elm, Buttons.elm, Clock.elm, Numbers.elm)

**Next Steps**:
- Complete ECO MLIR operations (§3.1.3) - add closure ops, parser/printer/verification
- ECO MLIR type system (§3.1.4)
- Connect MLIR output to LLVM lowering pipeline (§3.2)
- LLVM stack map implementation (§1.2.3)
- Rationalize Guida I/O design (§2.1.1)
- Elm kernel JavaScript audit (§2.2) - catalog all kernel functions for C++ porting
- Elm kernel C++ implementation (§2.3) - independent workstream for native runtime

**Active Workstreams**:
1. MLIR lowering pipeline (§3.2) - connect Guida MLIR output to LLVM
2. Guida I/O refactoring (§2.1) - kernel package design
3. Elm kernel C++ porting (§2.2, §2.3) - can run in parallel with above
