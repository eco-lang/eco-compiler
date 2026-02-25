# ECO Project Plan

**Elm Compiler Offline - Native Compilation Backend and Runtime**

## Project Roadmap

- [ ] **1. Runtime Foundation** → [§1](#1-runtime-foundation)
  - [x] 1.1 Custom Heap Model → [§1.1](#11-custom-heap-model)
  - [x] 1.2 Garbage Collector → [§1.2](#12-garbage-collector)
    - [x] 1.2.1 Old Generation Algorithm → [§1.2.1](#121-old-generation-algorithm)
    - [x] 1.2.2 LLVM Stack Map Investigation → [§1.2.2](#122-llvm-stack-map-investigation)
    - [ ] 1.2.3 LLVM Stack Map Implementation → [§1.2.3](#123-llvm-stack-map-implementation)
  - [ ] 1.3 Process & Thread Model → [§1.3](#13-process--thread-model) *(first-pass Platform & Scheduler complete)*
  - [x] 1.4 Runtime Testing Infrastructure → [§1.4](#14-runtime-testing-infrastructure) *(parallel compilation, all tests passing)*

- [ ] **2. Standard Library Porting** → [§2](#2-standard-library-porting)
  - [ ] 2.1 Eco Runtime to Kernel Packages → [§2.1](#21-guida-runtime-to-kernel-packages)
    - [x] 2.1.0 Bytes over Ports Support → [§2.1.0](#210-bytes-over-ports-support)
    - [ ] 2.1.1 Audit I/O Implementation → [§2.1.1](#211-audit-guida-io-implementation) *(audit complete, rationalization pending)*
    - [ ] 2.1.2 File System Operations Design → [§2.1.2](#212-file-system-operations-design)
    - [ ] 2.1.3 Network Operations Design → [§2.1.3](#213-network-operations-design)
    - [ ] 2.1.4 System Operations Design → [§2.1.4](#214-system-operations-design)
    - [ ] 2.1.5 Kernel Package Implementation & Refactor → [§2.1.5](#215-kernel-package-implementation--guida-refactor)
  - [x] 2.2 Elm Kernel JavaScript Audit → [§2.2](#22-elm-kernel-javascript-audit) *(272 functions cataloged)*
  - [ ] 2.3 Elm Kernel C++ Implementation → [§2.3](#23-elm-kernel-c-implementation) *(core kernels complete, E2E tests passing)*
    - [x] 2.3.1 elm/core Kernel → [§2.3.1](#231-elmcore-kernel) *(complete - Feb 20, 2026)*
    - [x] 2.3.2 elm/json Kernel → [§2.3.2](#232-elmjson-kernel) *(complete - Feb 20, 2026)*
    - [x] 2.3.3 elm/bytes Kernel → [§2.3.3](#233-elmbytes-kernel) *(complete + fusion optimization)*
    - [x] 2.3.4 elm/random Kernel → [§2.3.4](#234-elmrandom-kernel) *(N/A - no kernel code)*
    - [x] 2.3.5 elm/time Kernel → [§2.3.5](#235-elmtime-kernel) *(complete - Feb 20, 2026)*
    - [ ] 2.3.6 Additional Kernel Packages → [§2.3.6](#236-additional-kernel-packages) *(http, regex, debugger complete; file, browser, parser pending)*
  - [ ] 2.4 I/O Kernel Package C++ Implementation → [§2.4](#24-io-kernel-package-c-implementation)

- [ ] **3. MLIR/LLVM Integration** → [§3](#3-mlirllvm-integration)
  - [x] 3.1 ECO MLIR Dialect → [§3.1](#31-eco-mlir-dialect) *(substantially complete)*
    - [x] 3.1.1 Research & Reference Implementation → [§3.1.1](#311-research--reference-implementation)
    - [x] 3.1.2 Dialect Definition → [§3.1.2](#312-dialect-definition)
    - [x] 3.1.3 Operations → [§3.1.3](#313-operations) *(59+ ops, 53+ lowered, 46+ tests)*
    - [ ] 3.1.4 Type System → [§3.1.4](#314-type-system)
    - [x] 3.1.5 GC Integration Hooks → [§3.1.5](#315-gc-integration-hooks)
    - [ ] 3.1.6 Process Primitives → [§3.1.6](#316-process-primitives)
    - [x] 3.1.7 Test Programs → [§3.1.7](#317-test-programs) *(46+ codegen tests)*
  - [x] 3.2 Lowering Pipeline → [§3.2](#32-lowering-pipeline) *(complete - EcoToLLVM, typed closures, bytes fusion)*
  - [ ] 3.3 GC Stack Root Tracing → [§3.3](#33-gc-stack-root-tracing)
  - [ ] 3.4 Multi-target Support → [§3.4](#34-multi-target-support)

- [ ] **4. Compiler Backend** → [§4](#4-compiler-backend)
  - [x] 4.1 Backend Replacement → [§4.1](#41-guida-backend-replacement)
    - [x] 4.1.1 Pluggable Backend Architecture → [§4.1.1](#411-pluggable-backend-architecture)
    - [x] 4.1.2 Global AST Analysis & Monomorphization → [§4.1.2](#412-global-ast-analysis--monomorphization)
    - [x] 4.1.3 Dual Backend Implementation → [§4.1.3](#413-dual-backend-implementation)
    - [x] 4.1.4 Compiler Test Suite → [§4.1.4](#414-compiler-test-suite) *(all tests passing)*
  - [x] 4.2 MLIR Code Generation → [§4.2](#42-mlir-code-generation) *(substantially complete, all tests passing)*
  - [x] 4.3 Compiler Testing → [§4.3](#43-compiler-testing) *(substantially complete, all tests passing)*

- [ ] **5. Integration & Self-Compilation** → [§5](#5-integration--self-compilation)
  - [ ] 5.1 End-to-End Pipeline → [§5.1](#51-end-to-end-pipeline) *(JIT pipeline working)*
    - [ ] 5.1.1 Pipeline Integration → [§5.1.1](#511-pipeline-integration) *(JIT complete)*
    - [ ] 5.1.2 Command-Line Interface → [§5.1.2](#512-command-line-interface)
    - [ ] 5.1.3 Build System & Packaging → [§5.1.3](#513-build-system--packaging)
    - [ ] 5.1.4 Linker Integration & Runtime Libraries → [§5.1.4](#514-linker-integration--runtime-libraries) *(kernel static libs complete)*
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
- [x] Expand stress test coverage to exercise all heap object types under GC *(Feb 22, 2026)*
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

**Status**: In Progress (Current Priority)

Implement LLVM stack map integration for precise stack root tracing. This is required for larger, longer-running programs where GC cycles occur with deep call stacks containing heap pointers.

**Background**: Without stack maps, the GC cannot precisely identify heap pointers on the stack, limiting the complexity of programs that can run reliably. Research completed in §1.2.2 documented the integration approach.

**Tasks**:
- [ ] Build a small example program in LLVM using recursion to create stack frames with heap pointers
- [ ] Generate LLVM statepoints at GC safepoints in eco.safepoint lowering
- [ ] Parse LLVM stack map section in runtime
- [ ] Integrate stack map data into the runtime's root scanning during GC
- [ ] Stress test to verify stack roots are preserved correctly across major GC cycles

**Deliverables**:
- [ ] LLVM stack map example/prototype
- [ ] Modified eco.safepoint lowering to emit statepoints
- [ ] Runtime stack map parser
- [ ] Integration tests for stack root preservation

### 1.3 Process & Thread Model

**Status**: In Progress (First-pass Implementation Complete)

Design and implement support for multiple concurrent Elm processes.

**Key Features**:
- Native process abstraction for Elm programs
- Thread management and scheduling
- Disruptor wheels for fast inter-process message passing
- High-performance update loop execution
- Process isolation and memory management

**Current Implementation** *(Feb 20, 2026)*:
- First-pass Platform and Scheduler implementation:
  - `runtime/src/platform/PlatformRuntime.cpp/hpp` - Platform runtime
  - `runtime/src/platform/Scheduler.cpp/hpp` - Task scheduler
- Kernel-side process support:
  - `elm-kernel-cpp/src/core/Platform.cpp/hpp` - Platform kernel
  - `elm-kernel-cpp/src/core/Process.cpp/hpp` - Process kernel
  - `elm-kernel-cpp/src/core/Scheduler.cpp/hpp` - Scheduler kernel
  - `elm-kernel-cpp/src/browser/Browser.cpp/hpp` - Browser runtime adapter
- Effect manager infrastructure:
  - `elm-kernel-cpp/src/EffectManagerRegistry.cpp` - Effect manager registration
  - Time and Http effect managers registered

**Deliverables**:
- [x] Process lifecycle management *(first pass - Feb 20, 2026)*
- [x] Scheduler implementation *(first pass)*
- [ ] Message queue implementation (disruptor pattern)
- [ ] Thread-safe process coordination
- [ ] Process handle storage in heap model

### 1.4 Runtime Testing Infrastructure

**Status**: Substantially Complete

Comprehensive testing for runtime correctness and performance.

**Current Status** *(updated Feb 2026)*:
- Property-based tests using RapidCheck
- Heap snapshot validation
- GC correctness properties (preservation, collection, stability)
- Process isolation for E2E tests
- Parallel test execution for codegen and E2E tests
- System-sensitive parallel build counts
- All tests passing

**Required**:
- [x] Integration tests with compiled code (ElmE2ETest.cpp)
- [x] Process isolation for test stability
- [x] Parallel compilation support
- [ ] Performance benchmarks
- [ ] Stress testing under concurrent load
- [ ] Memory leak detection

**Deliverables**:
- [x] Process-isolated test runner
- [x] Parallel test compilation
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

**Status**: Complete

Audit all kernel JavaScript files in Elm's standard packages to understand what needs to be ported to C++.

**Background**: Elm packages contain kernel JavaScript files (e.g., `Elm/Kernel/List.js`) that implement low-level operations. These must be reimplemented in C++ for native compilation. This audit will create a comprehensive catalog of all kernel functions.

**Packages Audited**:
- `elm/core` - Basics, List, String, Char, Array, Bitwise, Debug, Platform, Process, Scheduler, Utils
- `elm/json` - JSON encoding/decoding primitives
- `elm/bytes` - Binary data handling
- `elm/random` - Random number generation (no kernel - uses elm/core)
- `elm/time` - Time primitives
- `elm/virtual-dom` - Virtual DOM operations
- `elm/browser` - Browser operations (navigation, DOM, events)
- `elm/http` - HTTP client primitives
- `elm/file` - File handling primitives
- `elm/url` - URL encoding/decoding
- `elm/parser` - Parser combinators
- `elm/regex` - Regular expression operations

**Results**:
- **272 core kernel functions** identified across all standard packages
- **113 elm-explorations functions** identified (webgl, linear-algebra, markdown, benchmark) - intentionally not implemented
- Complete function catalog in `design_docs/elm_kernel_functions.csv`

**Tasks**:
- [x] Clone/locate all standard Elm packages
- [x] For each package, catalog all kernel JS files
- [x] For each kernel file, document:
  - [x] All exported functions
  - [x] Function signatures (parameters, return types)
  - [x] Dependencies on other kernel functions
  - [x] Dependencies on browser/Node.js APIs
- [x] Identify which packages are essential for CLI tools vs browser-only
- [x] Prioritize kernel functions by importance for self-hosting Guida

**Deliverables**:
- [x] Kernel function catalog (`design_docs/elm_kernel_functions.csv` - 385 total, 272 core)
- [ ] Dependency graph between kernel modules
- [x] Prioritized implementation order (core packages first, browser packages later)
- [x] Documentation integrated into this section

### 2.3 Elm Kernel C++ Implementation

**Status**: In Progress (Core Kernels Complete, E2E Tests Passing)

Implement Elm kernel functions in C++ using the ECO runtime's heap model.

**Architecture**:
- All kernel functions operate on ECO heap objects (`runtime/src/allocator/Heap.hpp`)
- Functions follow C calling conventions for linkage with MLIR-generated code via JIT
- Memory management uses ECO's garbage collector
- Kernel modules organized in `elm-kernel-cpp/src/` subdirectories by package

**Current Implementation**:
- **272 kernel functions** have C++ declarations in `elm-kernel-cpp/src/KernelExports.h`
- **272 KERNEL_SYM entries** in `runtime/src/codegen/RuntimeSymbols.cpp` for JIT symbol resolution
- **elm/core kernel fully implemented** (Feb 20, 2026) - JsArray, List, Debug, Debugger complete
- **elm/json kernel implemented** (Feb 20, 2026) - using nlohmann/json, heap-resident values (Feb 22)
- **elm/bytes kernel complete** with fusion optimization
- **elm/http kernel implemented** (Feb 20, 2026) - integrated with libcurl and openssl
- **elm/regex kernel implemented** (Feb 20, 2026) - using srell.hpp
- **elm/time kernel implemented** (Feb 20, 2026) - with effect manager
- **elm/url kernel complete** - real implementations
- **Effect managers registered** for Time and Http (Feb 20, 2026)
- Remaining packages (browser, file, virtual-dom, parser, debugger) have stub implementations

**Source Files**:
- `elm-kernel-cpp/src/core/` - BasicsExports.cpp, ListExports.cpp, StringExports.cpp, CharExports.cpp, UtilsExports.cpp, BitwiseExports.cpp, DebugExports.cpp, JsArrayExports.cpp, PlatformExports.cpp, ProcessExports.cpp, SchedulerExports.cpp
- `elm-kernel-cpp/src/json/` - JsonExports.cpp
- `elm-kernel-cpp/src/bytes/` - BytesExports.cpp
- `elm-kernel-cpp/src/time/` - TimeExports.cpp
- `elm-kernel-cpp/src/browser/` - BrowserExports.cpp
- `elm-kernel-cpp/src/http/` - HttpExports.cpp
- `elm-kernel-cpp/src/file/` - FileExports.cpp
- `elm-kernel-cpp/src/url/` - UrlExports.cpp
- `elm-kernel-cpp/src/virtualdom/` - VirtualDomExports.cpp
- `elm-kernel-cpp/src/parser/` - ParserExports.cpp
- `elm-kernel-cpp/src/regex/` - RegexExports.cpp
- `elm-kernel-cpp/src/debugger/` - DebuggerExports.cpp

**Common Patterns**:
- Elm `List` → `Heap::Cons` chains ending in `alloc::listNil()`
- Elm `String` → `Heap::ElmString` (UTF-16 internal, conversion helpers for UTF-8)
- Elm `Int` → Unboxed `i64` or `Heap::Int` as needed
- Elm `Maybe` → `Heap::Custom` with tags for Just/Nothing via `alloc::just(val, is_boxed)`, `alloc::nothing()`
- Elm `Result` → `Heap::Custom` with tags for Ok/Err
- Elm `Array` → `Heap::ElmArray` with `Tag_Array`

**Testing Strategy**:
- Property-based tests comparing C++ output to JavaScript kernel output
- Use RapidCheck generators from existing test infrastructure
- Test each kernel function in isolation before integration

#### 2.3.1 elm/core Kernel

**Status**: Complete (Feb 20, 2026)

Implement the core kernel functions that all Elm programs depend on.

**Implementation Status** (11 modules, 178 functions):
| Module | Functions | Status |
|--------|-----------|--------|
| `Basics` | 30 | **Complete** - arithmetic, comparisons, boolean ops |
| `List` | 9 | **Complete** - cons, fromArray, toArray, map2-5, sortBy, sortWith |
| `String` | 29 | **Complete** - full string operations |
| `Char` | 6 | **Complete** - toCode, fromCode, toUpper, toLower |
| `JsArray` | 14 | **Complete** - with fast array intrinsic ops (Feb 23) |
| `Bitwise` | 7 | **Complete** - and, or, xor, shifts |
| `Debug` | 3 | **Complete** - log, toString |
| `Utils` | 8 | **Complete** - eq, cmp, append, etc. |
| `Scheduler` | 6 | **Complete** - task scheduling primitives |
| `Platform` | 5 | **Complete** - program initialization |
| `Process` | 1 | **Complete** - process primitives |

**Priority Order** (for self-hosting):
1. `Utils` - Fundamental operations used everywhere
2. `Basics` - Arithmetic and comparisons
3. `List` - List operations (heavily used)
4. `String` - String manipulation
5. `Char` - Character handling
6. `Bitwise` - Bit operations
7. `JsArray` - Array operations
8. `Debug` - Debugging support
9. `Scheduler` - Task execution
10. `Platform` - Program runtime
11. `Process` - Process management

**Tasks**:
- [x] Create stub implementations for all 178 functions
- [x] Add declarations to KernelExports.h
- [x] Add KERNEL_SYM entries for JIT symbol resolution
- [x] Implement `UtilsExports.cpp` - eq, cmp, Tuple0/2/3, update, append, chr
- [x] Implement `BasicsExports.cpp` - arithmetic, comparison, boolean ops
- [x] Implement `ListExports.cpp` - cons, head, tail, map, filter, foldl, foldr, etc.
- [x] Implement `StringExports.cpp` - concat, slice, split, etc.
- [x] Implement `CharExports.cpp` - toCode, fromCode, toUpper, toLower
- [x] Implement `BitwiseExports.cpp` - and, or, xor, shiftLeft, shiftRight
- [x] Implement `JsArrayExports.cpp` - get, set, push, slice, etc.
- [x] Implement `DebugExports.cpp` - log, toString
- [x] Implement `SchedulerExports.cpp` - task scheduling primitives
- [x] Implement `PlatformExports.cpp` - program initialization
- [x] Implement `ProcessExports.cpp` - process primitives

**Deliverables**:
- [x] C++ stub implementations in `elm-kernel-cpp/src/core/`
- [x] Header declarations in `elm-kernel-cpp/src/KernelExports.h`
- [x] Real implementations for all functions *(Feb 20, 2026)*
- [x] E2E tests for core kernel modules *(Feb 23, 2026 - see test/elm-core/)*

#### 2.3.2 elm/json Kernel

**Status**: Complete (Feb 20, 2026)

Implement JSON encoding and decoding primitives.

**Implementation Status** (32 functions):
- All 32 functions implemented in `elm-kernel-cpp/src/json/JsonExports.cpp`
- Uses nlohmann/json library (vendored at `elm-kernel-cpp/vendor/nlohmann/json.hpp`)
- JSON values rewritten to heap-resident format (Feb 22, 2026) - avoids foreign pointers on heap
- Roundtrip tests passing (Feb 24, 2026) - encode→decode for all JSON types

**Kernel Functions**:
- Decoders: `decodeInt`, `decodeFloat`, `decodeString`, `decodeBool`, `decodeNull`, `decodeList`, `decodeArray`, `decodeField`, `decodeIndex`, `decodeKeyValuePairs`, `decodeValue`
- Combinators: `map1`-`map8`, `oneOf`, `andThen`, `succeed`, `fail`
- Runners: `run`, `runOnString`
- Encoders: `encodeNull`, `encode`, `wrap`, `emptyArray`, `emptyObject`, `addEntry`, `addField`

**Tasks**:
- [x] Create stub implementations for all 32 functions
- [x] Add declarations to KernelExports.h
- [x] Add KERNEL_SYM entries for JIT symbol resolution
- [x] Implement JSON parser (integrated nlohmann/json library)
- [x] Implement decoder combinators
- [x] Implement encoder functions
- [x] Rewrite to heap-resident JSON values (Feb 22, 2026)

**Deliverables**:
- [x] Full implementations in `elm-kernel-cpp/src/json/JsonExports.cpp`
- [x] Full JSON parsing/serialization
- [x] Roundtrip E2E tests *(test/elm-json/ - Feb 24, 2026)*

#### 2.3.3 elm/bytes Kernel

**Status**: Complete

Implement binary data handling primitives.

**Implementation Status** (26 functions):
- All 26 functions have real implementations in `elm-kernel-cpp/src/bytes/BytesExports.cpp`
- Includes: `decode`, `decodeFailure`, `encode`, `getHostEndianness`, `getStringWidth`, `width`
- Read operations: `read_bytes`, `read_f32`, `read_f64`, `read_i16`, `read_i32`, `read_i8`, `read_string`, `read_u16`, `read_u32`, `read_u8`
- Write operations: `write_bytes`, `write_f32`, `write_f64`, `write_i16`, `write_i32`, `write_i8`, `write_string`, `write_u16`, `write_u32`, `write_u8`

**Bytes Fusion Optimization** *(Feb 11, 2026)*:
- Compiler-side fused encoder/decoder pipeline
- Intercepts `Bytes.encode`/`Bytes.decode` calls and lowers to BF dialect ops
- Cursor-based read/write operations instead of interpreter-style kernel
- BF MLIR dialect defined in `runtime/src/codegen/BF/BFOps.td`
- See `compiler/src/Compiler/Generate/MLIR/BytesFusion/`

**Tasks**:
- [x] Create stub implementations for all 26 functions
- [x] Add declarations to KernelExports.h
- [x] Add KERNEL_SYM entries for JIT symbol resolution
- [x] Implement real byte encoding/decoding
- [x] Handle endianness correctly
- [x] Bytes fusion optimization (compiler-side fused pipeline)

**Deliverables**:
- [x] Real implementations in `elm-kernel-cpp/src/bytes/BytesExports.cpp`
- [x] Bytes fusion optimization
- [ ] Unit tests

#### 2.3.4 elm/random Kernel

**Status**: N/A (No Kernel Code)

Implement random number generation primitives.

**Notes**: The elm/random package does not have kernel JavaScript code. It is implemented entirely in pure Elm using elm/core primitives. No C++ kernel implementation is needed for this package.

**Tasks**:
- [x] Verified: elm/random has no kernel code to port

**Deliverables**:
- N/A

#### 2.3.5 elm/time Kernel

**Status**: Complete (Feb 20, 2026)

Implement time-related primitives.

**Implementation Status** (4 functions):
- All 4 functions implemented in `elm-kernel-cpp/src/time/TimeExports.cpp`
- Time effect manager registered (`elm-kernel-cpp/src/time/TimeEffectManager.cpp`)
- Functions: `getZoneName`, `here`, `now`, `setInterval`

**Kernel Functions**:
- `now` - Get current POSIX time
- `here` - Get current time zone
- `getZoneName` - Get time zone name
- `setInterval` - Set up periodic timer

**Tasks**:
- [x] Create stub implementations for all 4 functions
- [x] Add declarations to KernelExports.h
- [x] Add KERNEL_SYM entries for JIT symbol resolution
- [x] Implement real time functions
- [x] Effect manager for Time subscriptions

**Deliverables**:
- [x] Real implementations in `elm-kernel-cpp/src/time/TimeExports.cpp`
- [x] Time effect manager (`TimeEffectManager.cpp`)
- [x] E2E tests *(test/elm-time/ - Feb 23, 2026)*

#### 2.3.6 Additional Kernel Packages

**Status**: In Progress (Stubs Complete)

Additional kernel packages identified during the audit that also need C++ implementations.

**Package Status**:
| Package | Functions | File | Status |
|---------|-----------|------|--------|
| `elm/browser` | 22 | `BrowserExports.cpp` | Stubs |
| `elm/http` | 8 | `HttpExports.cpp` | **Complete** (Feb 20) - libcurl/openssl |
| `elm/file` | 13 | `FileExports.cpp` | Stubs |
| `elm/url` | 2 | `UrlExports.cpp` | **Complete** |
| `elm/virtual-dom` | 25 | `VirtualDomExports.cpp` | Stubs |
| `elm/parser` | 7 | `ParserExports.cpp` | Stubs |
| `elm/regex` | 7 | `RegexExports.cpp` | **Complete** (Feb 20) - srell.hpp |
| `elm/debugger` | 8 | `DebuggerExports.cpp` | **Complete** (Feb 20) |

**Notable Implementations**:
- `Elm_Kernel_Url_percentEncode` - Full URL encoding implementation
- `Elm_Kernel_Url_percentDecode` - Full URL decoding implementation with UTF-8 support
- Http kernel integrated with libcurl and openssl (Feb 20, 2026)
- Http effect manager registered (`elm-kernel-cpp/src/http/HttpEffectManager.cpp`)
- Regex kernel uses srell.hpp (vendored header-only regex library)
- Debugger kernel complete with `Debugger.cpp/hpp` implementation

**Tasks**:
- [x] Create stub implementations for all 92 functions
- [x] Add declarations to KernelExports.h
- [x] Add KERNEL_SYM entries for JIT symbol resolution
- [x] Implement Url encoding/decoding (real implementations)
- [ ] Implement Browser primitives (most are browser-specific, may be N/A for CLI)
- [x] Implement Http primitives *(Feb 20, 2026 - libcurl/openssl)*
- [ ] Implement File primitives
- [ ] Implement VirtualDom primitives (likely N/A for CLI)
- [ ] Implement Parser primitives
- [x] Implement Regex primitives *(Feb 20, 2026 - srell.hpp)*
- [x] Implement Debugger primitives *(Feb 20, 2026)*

**Deliverables**:
- [x] Stub implementations in `elm-kernel-cpp/src/*/`
- [x] Full Url kernel implementation
- [x] Http, Regex, Debugger implementations *(Feb 20, 2026)*
- [x] E2E tests for http, regex, time, url packages *(test/elm-*/  - Feb 23, 2026)*
- [ ] File, Browser, VirtualDom, Parser implementations

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

**Status**: Substantially Complete

Design and implement a custom MLIR dialect called "eco" for Elm compilation.

**Expertise Required**: MLIR framework knowledge

**Deliverables**:
- [x] `ECODialect.cpp/hpp`: Dialect definition
- [x] Operation definitions (59 ops in Ops.td, 53 lowered to LLVM)
- [x] LLVM lowering pass (EcoToLLVM.cpp - 57 patterns)
- [x] JIT execution engine (EcoRunner)
- [x] Test programs (46 codegen tests)
- [ ] Type system implementation (eco.value used as opaque pointer)
- [ ] Process primitives (§3.1.6)

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

**Status**: Complete

Define custom operations representing Elm semantics.

**Current Implementation** *(runtime/src/codegen/Ops.td - 59 ops defined, 53 lowered to LLVM)*:

| Category | Operations | Status |
|----------|------------|--------|
| **Control Flow** | `case`, `return`, `joinpoint`, `jump`, `crash`, `expect`, `dbg` | ✅ Lowered + Tested |
| **ADT** | `construct`, `project` | ✅ Lowered + Tested |
| **Strings** | `string_literal` | ✅ Lowered + Tested |
| **Calls/Closures** | `call`, `papCreate`, `papExtend` | ✅ Lowered + Tested |
| **Allocation** | `allocate`, `allocate_ctor`, `allocate_string`, `allocate_closure` | ✅ Lowered + Tested |
| **GC** | `safepoint` | ✅ Lowered + Tested |
| **Globals** | `global`, `load_global`, `store_global` | ✅ Lowered + Tested |
| **Boxing** | `box`, `unbox`, `constant` | ✅ Lowered + Tested |
| **Int Arithmetic** | `int.add`, `int.sub`, `int.mul`, `int.div`, `int.modby`, `int.remainderby`, `int.negate`, `int.abs`, `int.pow` | ✅ Lowered + Tested |
| **Float Arithmetic** | `float.add`, `float.sub`, `float.mul`, `float.div`, `float.negate`, `float.abs`, `float.pow`, `float.sqrt` | ✅ Lowered + Tested |
| **Conversions** | `int.toFloat`, `float.round`, `float.floor`, `float.ceiling`, `float.truncate` | ✅ Lowered + Tested |
| **Comparisons** | `int.cmp`, `float.cmp`, `int.min`, `int.max`, `float.min`, `float.max` | ✅ Lowered + Tested |
| **Bitwise** | `int.and`, `int.or`, `int.xor`, `int.complement`, `int.shl`, `int.shr`, `int.shru` | ✅ Lowered + Tested |
| **RC Placeholders** | `incref`, `decref`, `decref_shallow`, `free`, `reset`, `reset_ref` | ⏸️ Intentionally not lowered (for future Perceus) |

**Test Coverage** *(46 codegen tests in test/codegen/)*:
- `arithmetic_*.mlir` - Integer, float, comparison, and bitwise operations
- `box_*.mlir`, `unbox_*.mlir` - Boxing/unboxing roundtrips
- `constant*.mlir` - Embedded constants (Nil, True, False, Unit, etc.)
- `construct_*.mlir` - ADT construction (tuples, lists, custom types)
- `project_fields.mlir` - Field projection
- `string_literal_*.mlir` - String literals including Unicode
- `call_*.mlir`, `pap_*.mlir`, `closure_*.mlir` - Calls and closures
- `case_*.mlir` - Pattern matching
- `joinpoint_loop.mlir` - Joinpoints and loops
- `global_*.mlir` - Global variables and GC root registration
- `crash.mlir`, `expect_*.mlir` - Error handling
- `dbg_all_values.mlir` - Debug output
- `allocate_*.mlir` - Low-level allocation
- `integration_map.mlir`, `map_closure.mlir` - Integration tests

**Tasks**:
- [x] Function definition and application operations
- [x] Pattern matching operations (case, joinpoint/jump)
- [x] Data constructor operations (construct, project)
- [x] String operations (string_literal)
- [x] Closure creation and invocation (papCreate, papExtend, indirect call)
- [x] Allocation operations (allocate, allocate_ctor, allocate_string, allocate_closure)
- [x] Global variable operations (global, load_global, store_global)
- [x] Type conversion operations (box, unbox, constant)
- [x] Integer arithmetic with Elm semantics (div-by-zero → 0, floored modulo)
- [x] Float arithmetic (IEEE 754)
- [x] Comparison operations
- [x] Bitwise operations
- [x] Add parser/printer/builder/verification for all ops
- [x] LLVM lowering patterns for all active ops
- [x] Comprehensive test suite

**Deliverables**:
- [x] Operation definitions in TableGen *(Ops.td - 59 ops)*
- [x] Operation implementation files *(EcoOps.cpp/h)*
- [x] LLVM lowering pass *(Passes/EcoToLLVM.cpp - 57 lowering patterns)*
- [x] Complete operation semantics and verification
- [x] Test suite *(test/codegen/ - 46 tests)*

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

**Status**: Complete

Define operations for garbage collection integration.

**Current Implementation**:
- Allocation ops: `eco.allocate`, `eco.allocate_ctor`, `eco.allocate_string`, `eco.allocate_closure` - all lowered to runtime calls
- GC safepoint: `eco.safepoint` - lowered (currently no-op, ready for stack map integration)
- Global root registration: `eco.global` lowering generates `__eco_init_globals` constructor that calls `eco_gc_add_root` for each global
- Reference counting placeholders: `eco.incref`, `eco.decref`, etc. - defined but not lowered (for future Perceus)

**Tasks**:
- [x] Allocation operations (nursery via runtime allocator)
- [x] GC safepoint operations (placeholder for stack maps)
- [x] Root registration operations (global root auto-registration)
- [ ] Write barrier operations (not needed - Elm's immutability guarantees no old→young pointers)
- [x] Reference counting operations (Perceus-style reuse) - placeholder definitions

**Deliverables**:
- [x] Reference counting operation definitions *(in Ops.td - placeholders)*
- [x] Allocation operation definitions and lowerings *(EcoToLLVM.cpp)*
- [x] Global root registration code generation
- [x] Documentation on GC integration points *(design_docs/eco-lowering.md)*

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

**Status**: Complete

Create small test programs to validate the dialect.

**Current Implementation**:
- 46 `.mlir` test files in `test/codegen/` covering all implemented operations
- Tests use `// RUN:` directives and `// CHECK:` patterns for validation
- In-process test execution via EcoRunner (JIT compilation)
- Subprocess execution for crash tests and IR dump tests
- Test discovery and execution integrated into main test binary

**Tasks**:
- [x] Write small programs directly in ECO MLIR dialect
- [x] Compile through MLIR pipeline to LLVM IR
- [x] Link with ECO runtime and execute (via JIT)
- [x] Validate correctness of generated code (CHECK patterns)
- [x] Create test suite covering all operations and types

**Deliverables**:
- [x] Suite of ECO MLIR test programs *(test/codegen/*.mlir - 46 tests)*
- [x] Test harness for dialect validation *(test/codegen/CodegenTest.hpp)*
- [x] In-process execution engine *(EcoRunner)*
- [x] Documentation of test coverage *(see §3.1.3)*

### 3.2 Lowering Pipeline

**Status**: Substantially Complete

Implement a lowering pipeline that transforms eco dialect to LLVM IR.

**Pipeline Stages**:
1. **High-level eco**: Direct representation of Elm semantics ✅
2. **Lowered eco → LLVM**: EcoToLLVM pass converts eco ops to LLVM dialect ✅
3. **LLVM IR**: Target-independent intermediate representation ✅
4. **JIT Execution**: MLIR ExecutionEngine for in-process execution ✅
5. **Native code**: AOT compilation to x86 (via ecoc -emit=llvm) ✅

**Current Implementation** *(runtime/src/codegen/)*:
- `EcoToLLVM.cpp`: 57+ lowering patterns converting eco ops to LLVM dialect
- `EcoToLLVMClosures.cpp`: Closure/PAP calling with typed ABI support
- `EcoControlFlowToSCF.cpp`: Control flow lowering to SCF dialect
- `EcoPAPSimplify.cpp`: PAP simplification pass
- `CheckEcoClosureCaptures.cpp`: Closure capture verification
- `ecoc.cpp`: Driver supporting `-emit=jit`, `-emit=llvm`, `-emit=mlir-llvm`, `-emit=mlir`
- `EcoRunner.cpp/hpp`: In-process JIT execution engine for tests
- Pass pipeline: eco → (verification passes) → EcoToLLVM → LLVM dialect → LLVM IR → JIT/native

**Transformations**:
- [x] Pattern matching to control flow (eco.case → switch on tag)
- [x] Closure conversion (papCreate/papExtend → runtime calls)
- [x] Direct closure calls with typed ABI (Feb 12, 2026)
- [x] Heap allocation insertion (construct → allocate + stores)
- [x] GC safepoint insertion (eco.safepoint → placeholder for stack maps)
- [x] Bytes fusion (BF dialect for fused byte operations)
- [x] TCO closure bug fixed (Dec 29, 2025) - closures correctly handled in tail-recursive functions
- [x] Tail call optimization - tail recursion with loop state implemented (Feb 2-3, 2026)
- [x] PAP wrapper elimination - complete (Feb 12, 2026)

**PAP Wrapper Elimination** *(Completed Feb 12, 2026)*:

The PAP wrapper elimination optimization has been fully implemented:

- **Direct calls**: Functions can be called directly even when partial application and closures are involved
- **Split call ABI**: For heterogeneous call paths where captured args cannot be known at runtime, a pointer to the entire closure with matching arg encoding is used. For the homogeneous case (most common, fast path), args are passed directly.
- **Typed closure calling**: Closures now carry type information enabling direct primitive ABI calls
- **ABI cloning**: New `AbiCloning.elm` module handles generating appropriate function variants for different calling conventions
- **See**: `plans/typed-closure-calling.md` for full design details

**Centralized Closure ABI** *(Feb 25, 2026)*:

Closure calling knowledge has been centralized:

- **Compiler as sole ABI arbiter**: Compiler determines kernel ABI types; MLIR enforces type-level consistency
- **EcoToLLVM simplified**: No longer reverse-engineers or repairs ABI types—simply reflects them to LLVM
- **Centralized closure calling**: `EcoToLLVMClosures.cpp` and `EcoToLLVMInternal.h` consolidated
- **Dead code removed**: Eliminated redundant ABI inference logic from the lowering pipeline

**Deliverables**:
- [x] Lowering passes in C++ *(Passes/EcoToLLVM.cpp, Passes/RCElimination.cpp)*
- [x] Pass pipeline configuration *(ecoc.cpp)*
- [x] JIT execution support *(EcoRunner.cpp)*
- [x] Testing framework for transformations *(test/codegen/)*
- [ ] Advanced optimizations (inlining, dead code elimination)

### 3.3 GC Stack Root Tracing

**Status**: In Progress (Current Priority)

Integration between LLVM and the garbage collector for precise stack scanning. This work is tracked jointly with §1.2.3 (LLVM Stack Map Implementation).

**Requirements**:
- [ ] LLVM stack map generation via statepoints
- [ ] Runtime stack root registration
- [ ] Safepoint insertion in generated code (eco.safepoint → LLVM statepoint)
- [ ] Thread-safe root set management

**Deliverables**:
- [ ] LLVM stackmap integration
- [ ] Runtime root scanning infrastructure
- [ ] Documentation on GC integration

**See Also**: §1.2.3 for implementation details and research in `design_docs/llvm_stackmap_integration.md`

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

**Status**: Complete *(all subsections 4.1.1-4.1.3 complete, 4.1.4 test suite in progress)*

The Guida compiler (Elm port) has been modified to support MLIR output alongside JavaScript.

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
- `Compiler/AST/TypedOptimized.elm`: Typed AST definitions with full type annotations (every expression carries `Can.Type`)
- `Compiler/AST/Monomorphized.elm`: Monomorphized AST with `MonoType`, layouts, and `SpecializationRegistry`
- `Compiler/Generate/Monomorphize.elm`: Worklist-based monomorphization algorithm (~2500 lines)
- `Compiler/Type/PostSolve.elm`: Post-solver that fixes Group B expression types and infers kernel function types
- `Compiler/Optimize/Typed/Module.elm`: Entry point for type-preserving optimization
- `Builder/Build.elm`: Modified to pass `needsTypedOpt` flag and handle typed compilation for root modules

**Theory Documentation**:
- `design_docs/theory/pass_post_solve_theory.md`: PostSolve pass theory
- `design_docs/theory/pass_typed_optimization_theory.md`: Type-preserving optimization theory
- `design_docs/theory/pass_monomorphization_theory.md`: Monomorphization algorithm theory
- `design_docs/theory/pass_type_table_theory.md`: Runtime type table construction
- `design_docs/theory/pass_mlir_generation_theory.md`: MLIR code generation theory

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

**Status**: Complete (All Tests Passing)

Get existing tests running and expand coverage.

**Implementation** *(enhanced Feb 2026)*:
- C++ test runner that can compile and execute .elm code via JIT
- Elm E2E tests run in parallel with process isolation
- GC stats accumulated across tests
- All tests pass (elm-test and E2E)
- Parallel test compilation with system-sensitive build counts

**Tasks**:
- [x] Get test suite running
- [x] Set up C++ test runner for Elm code
- [x] Implement parallel test execution with process isolation
- [x] Parallel test compilation support
- [x] All tests passing
- [x] Tests pass at higher fuzz levels (`--fuzz 100` working)
- [ ] Expand tests to cover more Elm programs and edge cases

**Deliverables**:
- [x] Working test suite (elm-test and E2E)
- [x] C++ test runner (`test/ElmE2ETest.cpp`, `test/elm/ElmTest.hpp`)
- [x] Parallel compilation (`test/elm-bytes/ElmBytesTest.hpp`)
- [ ] Expanded test coverage

### 4.2 MLIR Code Generation

**Status**: Substantially Complete (All Tests Passing)

Implement code generation from Elm AST to eco MLIR dialect.

**Prerequisites**:
- Type-annotated Optimized IR (§4.1.2) - MLIR code generation requires full type information
- Monomorphization pass (§4.1.2) - polymorphic code must be specialized before MLIR emission

**Code Generation Tasks**:
- [x] Expression translation (basic)
- [x] Pattern matching compilation (case..of, if..then using scf dialect)
- [x] Function definitions
- [x] Closure representation
- [x] Data constructor encoding
- [x] Indirect calls
- [x] Module system (multiple Elm modules combine into GlobalGraph)
- [ ] Foreign function interface

**Architecture** *(modularized Jan 15-19, 2026; enhanced Feb 2026)*:
The MLIR codegen has been refactored from a monolithic 6296-line file into focused modules:
```
compiler/src/Compiler/Generate/MLIR/
├── Types.elm       # Eco types, MonoType→MlirType conversion
├── Context.elm     # Context, signatures, type registry
├── Ops.elm         # MLIR op builders (eco.*, arith.*, scf.*, func.*)
├── Names.elm       # Symbol naming helpers
├── TypeTable.elm   # eco.type_table generation
├── Intrinsics.elm  # Basics/Bitwise kernel intrinsics
├── Patterns.elm    # Path navigation, test generation
├── Expr.elm        # Expression lowering, call ABI (largest)
├── Lambdas.elm     # Lambda/closure processing
├── Functions.elm   # Node/function generation (define, ctor, extern, cycle)
├── TailRec.elm     # Tail recursion with loop state compilation
├── Backend.elm     # Program entry point, module wiring
└── BytesFusion/    # Bytes fusion optimization
    ├── Emit.elm    # Emits fused BF dialect ops
    └── Reify.elm   # Pattern-matches AST to reify encoder/decoder nodes
```

**GlobalOpt Phase** *(consolidated Feb 5-7, 2026)*:
```
compiler/src/Compiler/GlobalOpt/
├── MonoGlobalOptimize.elm  # Main optimization pass, ABI alignment
├── MonoInlineSimplify.elm  # Small function inlining
├── MonoTraverse.elm        # Common iterator for code traversal
├── MonoReturnArity.elm     # Return arity tracking
├── CallInfo.elm            # Call information analysis
└── Staging/                # Staged-curried calling convention
    ├── GraphBuilder.elm    # Builds call graph for staging
    ├── Solver.elm          # Solves staging constraints
    ├── Rewriter.elm        # Rewrites calls with staging info
    ├── Types.elm           # Staging type definitions
    ├── UnionFind.elm       # Union-find for staging
    └── ProducerInfo.elm    # Producer information tracking
```

**Resolved Issues** *(from git log - Dec 2025 to Jan 2026)*:

1. **Bool Constant Codegen** - ✅ Fixed
   - Fix: Using ByteAttr and TypeIntAttr for constant Bool and Char
   - Commit: "Using ByteAttr and TypeIntAttr for constant Bool and Char" (Dec 17, 2025)

2. **Monomorphization Unit Type Bug** - ✅ Fixed
   - Fix: Full rewrite of monomorphizer to address deeper issues
   - Commits: "Full rewrite of monomorphizer" (Dec 18, 2025), guardrails against type variables escaping

3. **Type Variable Resolution** - ✅ Fixed
   - Fix: Kernel type mini-solver to fully deduce VarKernel types
   - Commits: "Post-solver to fill in missing types" (Dec 30, 2025), enhanced detection for `number` and `comparable`

4. **MLIR Type Attribute Inconsistencies** - ✅ Fixed
   - Fix: Calling kernel functions with concrete params not eco.value, fixed SSA type mismatches
   - Commits: Multiple fixes (Jan 4-6, 2026) for eco.value vs primitive types

**Resolved Issues** *(fixed Jan 21 - Feb 12, 2026)*:

5. **Case Scrutinee Type Mismatch** - ✅ Fixed
   - Was: `generateFanOutGeneral` used `Types.ecoValue` for all scrutinees
   - Fixed through staged-curried calling convention and GlobalOpt consolidation

6. **Heap Extraction Type Mismatch** - ✅ Fixed
   - Was: Projections from custom ADTs declared primitive types but returned eco.value
   - Fixed through kernel specialization and unboxed list storage

7. **Tail Recursion Issues** - ✅ Fixed
   - Implemented tail recursion with loop state
   - Joinpoint matching algorithm for stage-curried joinpoints
   - Lambda boundary normalization

**Resolved Issues** *(fixed Feb 23-25, 2026)*:

8. **SSA Value Renaming for Recursive Let Defs** - ✅ Fixed (Feb 23)
   - Inlined self-referential rec let defs required SSA value renaming
   - New test: `LetRecSsaDefinedness.elm`

9. **Array Intrinsic Ops** - ✅ Added (Feb 23)
   - New intrinsic ops for fast array access (`eco.array.get`, `eco.array.set`, etc.)
   - Corrected kernel calling convention to AllBoxed for broken kernels

10. **CGEN_056: papExtend Saturated Result Type** - ✅ Fixed (Feb 24)
    - Added invariant requiring saturating papExtends to follow return type ABI conventions
    - Enables optimization to `eco.call` during lowering
    - Removed compensating `fixCallResultTypes` pass

11. **Polymorphic Let-Bound Functions** - ✅ Fixed (Feb 24-25)
    - Monomorphizing out type variables unless necessary for polymorphic kernels
    - Multiple specialization of let-bound functions at different call sites
    - Added extensive specialization tests

12. **AllBoxed Kernel Return Types** - ✅ Fixed (Feb 25)
    - Fixed call return type for AllBoxed kernels with polymorphic return types

13. **Compiler as Sole ABI Arbiter** - ✅ Refactored (Feb 25)
    - Compiler is now sole arbiter of kernel ABI types
    - MLIR enforces that PAPs and calls match function declarations at the type level
    - EcoToLLVM simply reflects types into LLVM; no longer reverse-engineers or repairs them

**Current E2E Test Status**:
- Compilation through front-end and back-end to JIT execution working
- All elm-test tests passing
- All E2E tests passing (across elm-core, elm-json, elm-http, elm-regex, elm-time, elm-url packages)
- Parallel test execution with process isolation

**Deliverables**:
- [x] Code generation modules (11 modules in `Compiler/Generate/MLIR/`)
- [x] MLIR builder utilities (`elm-mlir` package vendored)
- [x] Case/if control flow using SCF dialect
- [x] Indirect call support
- [x] Symbol table management (multiple Elm modules via GlobalGraph)

### 4.3 Compiler Testing

**Status**: Substantially Complete (All Tests Passing)

Comprehensive testing for the compiler backend.

**Implementation** *(Jan 14-19, 2026; enhanced Feb 2026)*:
- 69+ test files in `compiler/tests/TestLogic/Generate/CodeGen/`
- `Invariants.elm` provides shared verification logic for MLIR AST inspection
- `TestPipeline.elm` consolidates common test pipeline (90+ test files)
- Tests validate CGEN_001 through CGEN_039+ invariants
- Property-based testing with elm-test
- GlobalOpt invariants added (Feb 8, 2026)

**Test Categories**:
- [x] Unit tests for code generation (invariant tests)
- [x] Integration tests (Elm → MLIR → LLVM → native via E2E tests)
- [x] Monomorphization invariant tests
- [x] GlobalOpt invariant tests
- [x] Cross-phase type consistency tests
- [ ] Performance benchmarks
- [ ] Regression test suite

**New Test Infrastructure** *(Feb 2026)*:
| Test Module | Description |
|-------------|-------------|
| `CrossPhase/TypeConsistency.elm` | Type consistency across phases |
| `GlobalOpt/CallInfoComplete.elm` | Call information completeness |
| `GlobalOpt/CaseBranchStaging.elm` | Case branch staging consistency |
| `GlobalOpt/ClosureStageArity.elm` | Closure stage arity validation |
| `Monomorphize/LambdaIdUniqueness.elm` | Lambda ID uniqueness |
| `Monomorphize/MonoFunctionArity.elm` | Function arity consistency |
| `Monomorphize/MonoCtorLayoutIntegrity.elm` | Constructor layout integrity |
| `PapExtendSaturatedResultType.elm` | CGEN_056 - papExtend return type ABI *(Feb 24)* |
| `LetRecSsaDefinedness.elm` | SSA definedness for recursive let bindings *(Feb 23)* |
| `KernelDeclCompleteness.elm` | CGEN_057 - kernel declaration completeness *(Feb 25)* |

**E2E Test Suites** *(Feb 23-24, 2026)*:
| Suite | Location | Description |
|-------|----------|-------------|
| elm-core | `test/elm-core/` | Basics, List, String, JsArray, Debug tests |
| elm-json | `test/elm-json/` | Decode + roundtrip tests for all JSON types |
| elm-http | `test/elm-http/` | HTTP header and JSON body tests |
| elm-regex | `test/elm-regex/` | Contains, find, fromString, split tests |
| elm-time | `test/elm-time/` | POSIX time and time parts tests |
| elm-url | `test/elm-url/` | Percent encode/decode and roundtrip tests |

**Specialization Test Suites** *(Feb 25, 2026)*:
| Suite | Description |
|-------|-------------|
| `SpecializePolyTopCases.elm` | Top-level polymorphic function specialization |
| `SpecializePolyLetCases.elm` | Let-bound polymorphic function specialization |

**Deliverables**:
- [x] Test suite infrastructure (`Invariants.elm`, `TestPipeline.elm`)
- [x] Elm test programs (90+ test files)
- [x] MLIR AST validation
- [x] All tests passing
- [ ] Performance baseline

---

## 5. Integration & Self-Compilation

Bring all components together and achieve self-compilation.

### 5.1 End-to-End Pipeline

**Status**: In Progress (JIT Pipeline Working)

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
- [x] Working compilation pipeline (JIT via ecoc)
- [x] Build scripts (`scripts/compile-elm.sh`)
- [ ] Working `eco` AOT compiler binary
- [ ] Usage documentation

#### 5.1.1 Pipeline Integration

**Status**: In Progress (JIT Pipeline Complete)

Connect all compiler stages into a working pipeline.

**Current Implementation**:
- Compilation through Guida frontend → MLIR backend → JIT execution is working
- Script to run the compiler chain (`scripts/compile-elm.sh`)
- ecoc driver supports multiple emit modes: `-emit=jit`, `-emit=llvm`, `-emit=mlir-llvm`, `-emit=mlir`
- Kernel modules linked as static libraries

**Tasks**:
- [x] Wire up Guida frontend to MLIR backend
- [x] Connect MLIR lowering passes (EcoToLLVM)
- [x] Integrate LLVM code generation (via MLIR ExecutionEngine)
- [x] JIT execution of compiled Elm programs
- [ ] AOT compilation producing standalone native binaries
- [ ] Produce working native binaries from Elm source (without JIT)

**Deliverables**:
- [x] End-to-end JIT compilation working
- [x] Pipeline orchestration code (`ecoc.cpp`, compile scripts)
- [ ] AOT native binary generation

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

**Status**: In Progress (Kernel Static Libraries Complete)

Link generated code with ECO runtime and Elm base libraries.

**Current Implementation** *(from git log - Dec 16, 2025)*:
- Kernel modules integrated into CMake build as static libraries
- All kernel exports imported into ecoc
- Real kernel implementations linked instead of stub injection
- Elm compiler code added to CMake build

**Tasks**:
- [x] Create linkable libraries (.a) for kernel operations implemented in C++
- [x] Integrate kernel modules into CMake build as static libs
- [ ] Extract elm/core and other ported Elm base libraries into standalone packages
- [ ] Design library discovery and linking as part of eco compilation flow
- [ ] Handle native library dependencies
- [ ] Support dynamic linking options (.so)

**Deliverables**:
- [x] Kernel static libraries (elm-kernel-cpp modules)
- [ ] Standalone kernel library packages for distribution
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
- **nlohmann/json**: JSON library for elm/json kernel (vendored)
- **srell.hpp**: Regular expression library for elm/regex kernel (vendored)
- **libcurl**: HTTP client library for elm/http kernel
- **openssl**: TLS support for elm/http kernel

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

**Current Phase**: Stack Map Implementation for GC + Kernel Stabilization
**Last Updated**: 2026-02-25

**Completed**:
- Heap model design (§1.1)
- Full garbage collector implementation (§1.2)
  - Thread-local nursery with Cheney's copying algorithm
  - Old generation with mark-and-sweep, free-list allocation
  - Lazy sweeping and allocation-paced incremental marking
  - Incremental compaction (implemented, manual trigger)
  - Optional DFS locality optimization for list copying
  - GC stress test coverage across all heap object types (Feb 22, 2026)
- Property-based testing infrastructure
- Dockerfile for reproducible builds (§5.1.3)
- LLVM stack map API research (§1.2.2) - see design_docs/llvm_stackmap_integration.md
- Lean/lz MLIR dialect research (§3.1.1) - see design_docs/lean_mlir_research.md
- Guida I/O audit (§2.1.1) - see design_docs/guida-io-operations.md and guida-io-ops.csv
- ECO MLIR dialect definition (§3.1.2) - core infrastructure in runtime/src/codegen/
- **ECO MLIR operations complete (§3.1.3)** - 59 ops defined, 53 lowered to LLVM, 46 tests
- **ECO MLIR lowering pipeline (§3.2)** - EcoToLLVM pass with 57 lowering patterns
- **GC integration hooks (§3.1.5)** - allocation, safepoint, global root registration
- **Test programs (§3.1.7)** - 46 codegen tests with JIT execution via EcoRunner
- Bytes over Ports support (§2.1.0) - enables binary data through Elm ports
- Pluggable backend architecture (§4.1.1) - `CodeGen`, `TypedCodeGen`, `MonoCodeGen` interfaces
- Global AST analysis & monomorphization (§4.1.2) - TypedOptimized AST and Mono pass
- Dual backend implementation (§4.1.3) - JS and MLIR backends with extension-based selection
- **Elm kernel JavaScript audit complete (§2.2)** - 272 core functions cataloged in elm_kernel_functions.csv
- **Elm kernel C++ implementations substantially complete (§2.3)**:
  - 272 kernel functions declared in KernelExports.h
  - 272 KERNEL_SYM entries in RuntimeSymbols.cpp for JIT resolution
  - **elm/core kernel complete** (Feb 20, 2026) - all 178 functions implemented
  - **elm/json kernel complete** (Feb 20, 2026) - nlohmann/json, heap-resident values
  - **elm/bytes kernel complete** - with fusion optimization
  - **elm/http kernel complete** (Feb 20, 2026) - libcurl/openssl integration
  - **elm/regex kernel complete** (Feb 20, 2026) - srell.hpp
  - **elm/time kernel complete** (Feb 20, 2026) - with effect manager
  - **elm/url kernel complete** - full implementations
  - **Debugger kernel complete** (Feb 20, 2026)
  - Remaining stubs: browser, file, virtual-dom, parser
- **Platform & Scheduler first-pass implementation (Feb 20, 2026)** - PlatformRuntime, Scheduler, effect managers
- **PAP Wrapper Elimination (Feb 12, 2026)** - direct calls with typed closure calling
- **Staged-Curried Calling Convention (Feb 9, 2026)** - callsite derivation algorithm complete
- **Bytes Fusion Optimization (Feb 11, 2026)** - compiler-side fused encoder/decoder pipeline
- **GlobalOpt Phase (Feb 5-7, 2026)** - consolidated uncurrying and ABI logic
- **Lambda Boundary Normalization (Feb 4, 2026)** - for uncurrying support
- **Tail Recursion with Loop State (Feb 2-3, 2026)** - joinpoint matching algorithm
- **Parallel Test Compilation (Feb 3, 2026)** - system-sensitive parallel builds
- **Architecture Refactoring (Feb 5-6, 2026)** - removed Guida syntax, clean architecture enforcement
- **All tests passing (Feb 24, 2026)** - elm-test and all E2E test suites pass
- **Fuzz testing at fuzz 100 passing** - `npx elm-test-rs --fuzz 100` working
- **Centralized Closure ABI (Feb 25, 2026)** - compiler as sole ABI arbiter, EcoToLLVM simplified
- **Let-bound Function Specialization (Feb 24-25, 2026)** - multiple specializations at different call sites
- **CGEN_056/057 invariants (Feb 24-25, 2026)** - papExtend result types + kernel decl completeness

**Recent Changes** *(from git log analysis - Feb 19 to Feb 25, 2026)*:

- **Kernel Implementation Sprint** (Feb 20, 2026):
  - Completed elm/core kernel - all 178 functions (JsArray, List, Debug, Debugger, etc.)
  - First-pass Platform & Scheduler implementation
  - Implemented kernels for http (libcurl/openssl), json (nlohmann), regex (srell), time
  - Registered effect managers for Time and Http
  - Cleaned up unused design files

- **Runtime Improvements** (Feb 22, 2026):
  - Array implementation using unboxed bits in heap Header (`Tag_Array`)
  - JSON kernel rewrite to heap-resident values (avoids foreign pointers on heap)
  - Improved GC test coverage across all heap element kinds

- **E2E Test Suite Expansion** (Feb 23, 2026):
  - Comprehensive E2E test suites for elm-core, elm-json, elm-http, elm-regex, elm-time, elm-url
  - Tests for pure functions across all implemented kernels
  - Each package has its own test directory under `test/`

- **Compiler Kernel Integration** (Feb 23, 2026):
  - New intrinsic ops for fast array access
  - Corrected kernel calling convention to AllBoxed for broken kernel functions
  - SSA value renaming for inlined self-referential rec let defs

- **All E2E Tests Passing** (Feb 24, 2026):
  - Fixed all E2E test failures across all package test suites
  - Fixed elm-json roundtrip tests
  - JSON roundtrip tests added for all JSON types (bool, float, int, list, string, nested, etc.)
  - Recorded tech debt arising from e2e test fixes

- **CGEN_056: papExtend Saturated Result Types** (Feb 24, 2026):
  - New invariant requiring saturating papExtends to follow return type ABI conventions
  - Enables optimization to `eco.call` during lowering
  - Removed compensating `fixCallResultTypes` pass

- **Monomorphization Improvements** (Feb 24-25, 2026):
  - Monomorphizing out type variables unless necessary for polymorphic kernel functions
  - Strengthened invariants around monomorphization
  - Multiple specialization of let-bound functions used at different call sites
  - Extensive new specialization tests (`SpecializePolyTopCases.elm`, `SpecializePolyLetCases.elm`)

- **Centralized Closure ABI** (Feb 25, 2026):
  - Compiler made sole arbiter of kernel ABI types
  - MLIR enforces PAPs and calls match function declarations at type level
  - EcoToLLVM simplified: no longer reverse-engineers or repairs ABI types
  - Centralized closure calling knowledge in `EcoToLLVMClosures.cpp`

- **AllBoxed Kernel Return Type Fix** (Feb 25, 2026):
  - Fixed call return type for AllBoxed kernels with polymorphic return types

- **CGEN_057: Kernel Declaration Completeness** (Feb 25, 2026):
  - New test logic ensuring all referenced kernels have declarations
  - `KernelDeclCompleteness.elm` + `KernelDeclCompletenessTest.elm`

- **Array Optimization Design** (Feb 25, 2026):
  - New design outline for array optimization (`design_docs/array-optimisation.md`)

**Previous Changes** *(Jan 21 to Feb 12, 2026)*:

- **PAP Wrapper Elimination Complete** (Feb 12, 2026):
  - Completed elimination of PAP wrappers - all tests pass
  - Direct calls even when partial application and closures are involved
  - Split call ABI for heterogeneous vs homogeneous call paths

- **Staged-Curried Calling Convention** (Feb 9, 2026):
  - Completed callsite derivation algorithm matching all callsites to correct calling convention
  - New modules: `Staging/GraphBuilder.elm`, `Staging/Solver.elm`, `Staging/Rewriter.elm`

- **papExtend Reimplemented as Inline** (Feb 11, 2026):
  - Reimplemented papExtend helper as inline compiled code (same as indirect call)

- **Bytes Fusion Optimization** (Feb 11, 2026):
  - Compiler-side fused encoder/decoder pipeline
  - BF MLIR dialect defined in `BFOps.td`

- **Bytes Kernel C++ Implementations** (Feb 11, 2026):
  - Complete C++ implementations of elm/bytes kernel functions

- **NumberBoxed Kernel ABI** (Feb 10-11, 2026):
  - Introduced NumberBoxed ABI mode for polymorphic number kernels

- **Lambda Closure Capture Fix** (Feb 10, 2026):
  - Fixed closure capture for lambdas with >1 parameter
  - Added `CheckEcoClosureCaptures.cpp` verification pass

- **Kernel Specialization** (Feb 10, 2026):
  - Kernel functions can now specialize to unboxable primitive types

- **GlobalOpt Phase Consolidation** (Feb 5-7, 2026):
  - Major refactoring to consolidate uncurrying and ABI alignment logic

- **Architecture Improvements** (Feb 5-6, 2026):
  - Removed Guida syntax support (rebranded to Eco)
  - Clean architecture dependency enforcement via elm-review

- **Tail Recursion with Loop State** (Feb 2-3, 2026):
  - Implemented tail recursion compilation with loop state
  - Joinpoint matching algorithm for stage-curried joinpoints

- **Float Precision** (Feb 11, 2026):
  - Float-to-string uses shortest round-trip representation

**Next Steps** *(in priority order)*:
1. **LLVM stack map implementation (§1.2.3)** - precise GC root tracing for larger/longer-running programs
2. **Remaining kernel implementations (§2.3)** - file, browser, parser, virtual-dom (lower priority for CLI)
3. **AOT compilation (§5.1.1)** - produce standalone native binaries (currently JIT only)
4. **Array optimization** - design outlined in `design_docs/array-optimisation.md`

**Active Workstreams**:
1. **LLVM stack map implementation (§1.2.3)** - required for GC in larger programs with deep stacks
2. **Compiler correctness stabilization** - new invariants (CGEN_056/057), let-bound specialization
3. **Kernel function testing** - E2E test suites validating kernel implementations
