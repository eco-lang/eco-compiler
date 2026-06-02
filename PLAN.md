# ECO Project Plan

**Elm Compiler Offline - Native Compilation Backend and Runtime**

## Project Roadmap

- [x] **1. Runtime Foundation** → [§1](#1-runtime-foundation)
  - [x] 1.1 Custom Heap Model → [§1.1](#11-custom-heap-model)
  - [x] 1.2 Garbage Collector → [§1.2](#12-garbage-collector)
    - [x] 1.2.1 Old Generation Algorithm → [§1.2.1](#121-old-generation-algorithm)
    - [x] 1.2.2 LLVM Stack Map Investigation → [§1.2.2](#122-llvm-stack-map-investigation)
    - [x] 1.2.3 LLVM Stack Map Implementation → [§1.2.3](#123-llvm-stack-map-implementation) *(RS4GC migration complete, Apr 22)*
  - [x] 1.3 Process & Thread Model → [§1.3](#13-process--thread-model) *(Platform & Scheduler + MVar runtime complete)*
  - [x] 1.4 Runtime Testing Infrastructure → [§1.4](#14-runtime-testing-infrastructure) *(parallel compilation + stress-elm suite, all tests passing)*

- [ ] **2. Standard Library Porting** → [§2](#2-standard-library-porting)
  - [ ] 2.1 Eco Runtime to Kernel Packages → [§2.1](#21-eco-runtime-to-kernel-packages)
    - [x] 2.1.0 Bytes over Ports Support → [§2.1.0](#210-bytes-over-ports-support)
    - [x] 2.1.1 Audit I/O Implementation → [§2.1.1](#211-audit-io-implementation) *(complete - ops mapped to Eco.* API)*
    - [x] 2.1.2 File System Operations Design → [§2.1.2](#212-file-system-operations-design) *(complete - Eco.File module)*
    - [x] 2.1.3 Network Operations Design → [§2.1.3](#213-network-operations-design) *(deferred - stays on legacy path)*
    - [x] 2.1.4 System Operations Design → [§2.1.4](#214-system-operations-design) *(complete - Eco.Console/Env/Process/Runtime)*
    - [ ] 2.1.5 Kernel Package Implementation & Refactor → [§2.1.5](#215-kernel-package-implementation--refactor) *(eco-kernel-cpp created, XHR IO wired up)*
  - [x] 2.2 Elm Kernel JavaScript Audit → [§2.2](#22-elm-kernel-javascript-audit) *(272 functions cataloged)*
  - [ ] 2.3 Elm Kernel C++ Implementation → [§2.3](#23-elm-kernel-c-implementation) *(core kernels complete, E2E tests passing)*
    - [x] 2.3.1 elm/core Kernel → [§2.3.1](#231-elmcore-kernel) *(complete - Feb 20, 2026)*
    - [x] 2.3.2 elm/json Kernel → [§2.3.2](#232-elmjson-kernel) *(complete - Feb 20, 2026)*
    - [x] 2.3.3 elm/bytes Kernel → [§2.3.3](#233-elmbytes-kernel) *(complete + fusion optimization)*
    - [x] 2.3.4 elm/random Kernel → [§2.3.4](#234-elmrandom-kernel) *(N/A - no kernel code)*
    - [x] 2.3.5 elm/time Kernel → [§2.3.5](#235-elmtime-kernel) *(complete - Feb 20, 2026)*
    - [ ] 2.3.6 Additional Kernel Packages → [§2.3.6](#236-additional-kernel-packages) *(http, regex, debugger complete; browser, parser, virtual-dom N/A for CLI)*
  - [ ] 2.4 I/O Kernel Package C++ Implementation → [§2.4](#24-io-kernel-package-c-implementation)

- [ ] **3. MLIR/LLVM Integration** → [§3](#3-mlirllvm-integration)
  - [x] 3.1 ECO MLIR Dialect → [§3.1](#31-eco-mlir-dialect) *(substantially complete)*
    - [x] 3.1.1 Research & Reference Implementation → [§3.1.1](#311-research--reference-implementation)
    - [x] 3.1.2 Dialect Definition → [§3.1.2](#312-dialect-definition)
    - [x] 3.1.3 Operations → [§3.1.3](#313-operations) *(59+ ops, 53+ lowered, 46+ tests)*
    - [x] 3.1.5 GC Integration Hooks → [§3.1.5](#315-gc-integration-hooks)
    - [ ] 3.1.6 Process Primitives → [§3.1.6](#316-process-primitives)
    - [x] 3.1.7 Test Programs → [§3.1.7](#317-test-programs) *(46+ codegen tests)*
  - [x] 3.2 Lowering Pipeline → [§3.2](#32-lowering-pipeline) *(complete - EcoToLLVM, typed closures, bytes fusion)*
  - [x] 3.3 GC Stack Root Tracing → [§3.3](#33-gc-stack-root-tracing) *(RS4GC + EcoGCPrepare + shadow-stack + allocation groups, Apr 2026)*
  - [ ] 3.4 Multi-target Support → [§3.4](#34-multi-target-support)

- [ ] **4. Compiler Backend** → [§4](#4-compiler-backend)
  - [x] 4.1 Backend Replacement → [§4.1](#41-guida-backend-replacement)
    - [x] 4.1.1 Pluggable Backend Architecture → [§4.1.1](#411-pluggable-backend-architecture)
    - [x] 4.1.2 Global AST Analysis & Monomorphization → [§4.1.2](#412-global-ast-analysis--monomorphization)
    - [x] 4.1.3 Dual Backend Implementation → [§4.1.3](#413-dual-backend-implementation)
    - [x] 4.1.4 Compiler Test Suite → [§4.1.4](#414-compiler-test-suite) *(all tests passing)*
  - [x] 4.2 MLIR Code Generation → [§4.2](#42-mlir-code-generation) *(substantially complete, all tests passing, 21+ resolved issues)*
  - [x] 4.3 Compiler Testing → [§4.3](#43-compiler-testing) *(120+ test files, code coverage tooling, GOPT invariants)*

- [x] **5. Integration & Self-Compilation** → [§5](#5-integration--self-compilation) *(0.1.0 milestone — full binary self-compilation achieved, May 14, 2026)*
  - [ ] 5.1 End-to-End Pipeline → [§5.1](#51-end-to-end-pipeline) *(unified `eco` single-binary compiler ships JIT + AOT through a shared backend; portable static-musl distribution bundle landed; CLI polish outstanding)*
    - [x] 5.1.1 Pipeline Integration → [§5.1.1](#511-pipeline-integration) *(Stage 9 unified `eco` binary — Phases 1–5; JIT and AOT both go through `runEcoBackend` / `EcoBackend`)*
    - [ ] 5.1.2 Command-Line Interface → [§5.1.2](#512-command-line-interface)
    - [x] 5.1.3 Build System & Packaging → [§5.1.3](#513-build-system--packaging) *(Stages A/A.5/B/B.5/C: portable static-musl `eco` distribution bundle)*
    - [x] 5.1.4 Linker Integration & Runtime Libraries → [§5.1.4](#514-linker-integration--runtime-libraries) *(unified `eco` lowers MLIR → ELF and links runtime + kernels; AOT `.o` link-only fast path supported)*
    - [ ] 5.1.5 Debugging Support → [§5.1.5](#515-debugging-support)
  - [x] 5.2 Bootstrap to Native x86 → [§5.2](#52-bootstrap-to-native-x86) *(8-stage bootstrap reaches MLIR fixed point at Stage 8; native ELF matches modulo 3.6 KB of LLVM-side `.strtab` non-determinism)*
  - [x] 5.3 Self-Compilation Milestone → [§5.3](#53-self-compilation-milestone) *(achieved — native compiler self-compiles to bit-identical MLIR)*

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
- Segregated-fits old generation with Big Bag of Pages (BBoP) — see §1.2.1
- Mark-driven live attribution + lazy sweep on the allocation slow path *(Apr 26, 2026)*
- Per-block mark bitmap sidetable (no header-color dependency for sweep liveness) *(Apr 26, 2026)*
- Incremental compaction (implemented, manual trigger only)
- Optional DFS locality optimization for list copying
- Promotion age currently set to 2
- Major GC `0.75/0.50` initiating-occupancy / target-utilization policy *(Apr 24-26, 2026)*

**Deliverables**:
- [x] `allocator.cpp/hpp`: GC implementation
- [x] `gc_stats.hpp`: Telemetry and diagnostics with per-allocation size histograms (nursery + oldgen) *(Apr 26, 2026)*
- [x] Property-based test suite + sustained-pressure GC tests *(Apr 25, 2026 — 19 tests)*

#### 1.2.1 Old Generation Algorithm

**Status**: Complete (rewritten to segregated-fits + BBoP, Apr 25-26, 2026)

Choose and implement an appropriate algorithm for old generation garbage collection.

**Implementation** *(rewritten Apr 25-26, 2026; see `runtime/src/allocator/OldGenSpace.{hpp,cpp}`)*:

The old generation is now a **segregated-fits allocator backed by a Big Bag of Pages (BBoP)**. The initial `initial_old_gen_size` (16 MiB by default) is committed up front and sliced into pages of `alloc_buffer_size` bytes that sit in `unassigned_blocks_` until first use:

- **Small classes** — 32 classes covering 8..256 B in 8-byte steps. On first use a class pulls a page from the bag and slices it into uniform `Tag_Free` cells.
- **Medium classes** — powers of two starting at 512 B, reserved up through 65536 B (8 medium classes). Class count is capped at runtime by `large_object_threshold`.
- **Mid-range (between `large_object_threshold` and `alloc_buffer_size`)** — pulls a page from the bag, installs a single page-spanning `Tag_Free` cell, and uses the larger-cell split path (no fixed-cell slicing).
- **Large objects (≥ `alloc_buffer_size`)** — go through `allocateLargeBlock`, which acquires a dedicated pinned block sized to the object. Large objects in existing blocks are reused before asking the Allocator for a fresh block *(Apr 26, 2026)*.
- **Round-up vs round-down class selection** *(Apr 25, 2026)*: `sizeClass(size)` rounds up at allocation time so a popped cell can always satisfy the request; `freeListClassFor(span)` rounds down at placement time (split tails, sweep coalesces) so cells on `free_lists_[cls]` always have ≥ `classToSize(cls)` bytes — fixing buffer overflows in `tryAllocateBySplittingLarger`.

**GC pipeline** *(Apr 26, 2026 rewrite)*:
- **Major GC trigger** — `shouldTriggerMajorGC()` fires when `allocated_bytes / committed_bytes ≥ major_gc_initiating_occupancy` (default 0.75) **OR** when the global old-gen pressure crosses ~25% of the cap. The global trigger catches workloads that keep per-thread occupancy low because `allocateFromBagPage` burns a fresh page per request *(Apr 26, 2026)*.
- **Mark phase** — incremental marking driven by `MARK_WORK_RATIO`. Liveness is now recorded in per-block bitmaps (1 bit per 8-byte slot) — `mark_bits_` for regular blocks, `large_block_mark_` (single bit) for `is_large` blocks. Headers retain a `color` field for compaction's debug asserts but are no longer load-bearing for sweep liveness *(Apr 26, 2026)*.
- **External roots scanned during mark** *(Apr 25, 2026)*: Scheduler, PlatformRuntime, MVar, and Runtime root scanners are visited so objects rooted only via external state survive a major GC.
- **Mark-driven live attribution + lazy sweep** *(Apr 26, 2026)*: Sweep is no longer a synchronous post-mark cell walk. `live_bytes` is attributed during marking; `transitionToSweeping` clears `free_lists_` *before* reclaim (turning per-block release from O(F) to O(1)); an **all-dead block fast path** releases dead non-large blocks without scanning their cells; an **O(1) page-index** (`page_to_block_index_`) replaces a linear `findBlockContaining` scan; `finishMarkAndSweep` returns with `gc_phase_ = Sweeping` after a 64 KiB initial slice; the rest of the work runs in `SWEEP_WORK_BUDGET`-sized slices on the allocation slow path. Stage 7 major GC: 432 s → 16 s (27× faster).
- **Color reset on every evacuation memcpy** *(Apr 26, 2026)*: nursery promotion, to-space copy, and OldGen compaction all reset `header.color` to White after the memcpy; mark phase also resets at start. Otherwise a stale Black left by an earlier mark would survive the memcpy and cause the next mark to skip the cell as already-processed, with sweep then freeing untraced children.
- **No GC color marking on objects in the nursery** *(Apr 26, 2026)*: Major GC tracks nursery objects in a `nursery_visited_` set instead of writing into the nursery header `color` field. This keeps minor GC's ownership of the nursery header bits clean.
- **Embedded-constant skipping in oldgen marking** *(Apr 24, 2026)*: pointer-shaped slots whose `HPointer.constant != 0` are skipped during marking — embedded constants live outside the heap.
- **Shrink-and-return blocks to the OS** *(Apr 26, 2026)*: post-sweep, surplus blocks below `BUFFER_RETURN_THRESHOLD` are returned to the Allocator's free pool. `decommit_on_oldgen_release` is currently `false` to avoid a stale-pointer-into-decommitted-page corruption (fix in flight; see `bootstrap-stage7-crash-analysis.md`).
- **Heap-base reservation** *(Apr 25, 2026)*: location 0 in the oldgen heap is reserved so a logical `HPointer` of zero is unambiguously "null".
- **Fragmentation monitoring** (`FragmentationStats`) and incremental compaction (still manual trigger only).

**Files modified** *(Apr 24-27, 2026)*: `OldGenSpace.{hpp,cpp}`, `Allocator.{hpp,cpp}`, `AllocatorCommon.hpp`, `ThreadLocalHeap.cpp`, `NurserySpace.cpp`, `GCStats.{hpp,cpp}`. New tests: `OldGenLazySweepTest.{cpp,hpp}`, `OldGenCapacityTest.{cpp,hpp}`, `GCPressureTest.{cpp,hpp}`.

**Plans**: `plans/oldgen-segregated-fits-bbop.md`, `plans/major-gc-75-50-policy.md`, `plans/oldgen-capacity-shrink-and-large-reuse.md`, `plans/gc-mark-driven-live-lazy-sweep.md`, `plans/oldgen-per-block-mark-bitmaps.md`.

**Tasks**:
- [x] Evaluate algorithm options (simple mark-and-sweep vs mark-compact vs other)
- [x] Implement chosen algorithm
- [x] Ensure it is well tested
- [x] Major GC trigger policy (`75/50` initiating-occupancy / target-utilization) *(Apr 24, 2026)*
- [x] Segregated-fits + BBoP rewrite *(Apr 25, 2026)*
- [x] Round-down placement vs round-up allocation class selection *(Apr 25, 2026)*
- [x] External root scanners visited during major-GC mark *(Apr 25, 2026)*
- [x] Sustained-pressure GC test suite (19 tests) *(Apr 25, 2026)*
- [x] Color reset after every evacuation memcpy *(Apr 26, 2026)*
- [x] Mark-driven live + lazy sweep on allocation slow path *(Apr 26, 2026)*
- [x] Per-block mark bitmap sidetable *(Apr 26, 2026)*
- [x] Shrink-and-return surplus blocks *(Apr 26, 2026)*
- [x] Large-object reuse into existing blocks *(Apr 26, 2026)*
- [x] Allocation size histograms in GCStats *(Apr 26, 2026)*
- [ ] Re-enable `decommit_on_oldgen_release` once stale-mark-roots issue is resolved
- [ ] Enable automatic compaction triggering (currently manual only)
- [x] Expand stress test coverage to exercise all heap object types under GC *(Feb 22, 2026)*
- [x] Large object allocation and GC *(Apr 8, 2026)*
- [x] Fixed `getObjectSize()` for Closure *(Apr 11, 2026)*
- [ ] Verify correctness under extended load testing — Stage 7 closure-arity crash reproduced *(Apr 27, 2026)*

**Deliverables**:
- [x] Finalized old generation GC algorithm
- [x] Stress tests covering core object types
- [x] Sustained-pressure GC tests (`GCPressureTest`, 19 tests)
- [x] Lazy-sweep regression tests (`OldGenLazySweepTest`)
- [x] Capacity-shrink + large-reuse tests (`OldGenCapacityTest`)

#### 1.2.2 LLVM Stack Map Investigation

**Status**: Complete

Research LLVM's stack map facilities for precise stack root tracing.

**Tasks**:
- [x] Research LLVM stack map and statepoint APIs
- [x] Document the integration approach

**Deliverables**:
- [x] Research documentation *(see design_docs/llvm_stackmap_integration.md)*

#### 1.2.3 LLVM Stack Map Implementation

**Status**: Complete (Apr 22, 2026)

Implement LLVM stack map integration for precise stack root tracing. This is required for larger, longer-running programs where GC cycles occur with deep call stacks containing heap pointers.

**Background**: Without stack maps, the GC cannot precisely identify heap pointers on the stack, limiting the complexity of programs that can run reliably. Research completed in §1.2.2 documented the integration approach.

**Implementation** *(Mar 26 – Apr 17, 2026)*:

The full GC stack root pipeline is now implemented across compiler, MLIR lowering, and runtime:

- **Phase 1 — Dialect & Compiler**: `eco.safepoint` op redesigned from string attribute to variadic `!eco.value` operands. Compiler tracks live SSA variables (`definedSsaVars`) and emits safepoints before all allocation sites (list, record, tuple, custom type construction).
- **Phase 2 — Statepoint Lowering**: `StatepointConversion.cpp` converts `__eco_safepoint_marker` calls to LLVM `gc.statepoint` intrinsics wrapping the actual allocating/calling function (not a separate nop). Two-phase alloca+mem2reg approach synthesizes correct phi nodes at loop headers for relocated GC roots.
- **Phase 3 — Runtime Integration**: Custom `EcoJIT` engine captures `.llvm_stackmaps` section. `StackMap.cpp` parses LLVM stack map v3 binary format. `ThreadLocalHeap::collectStackRootsFromStackMap()` walks x86-64 frame pointer chain, extracting roots from stack map indirect locations. `StackUnwind.cpp` *(Apr 14)* handles RSP-relative stack map entries that appear even under `-fno-omit-frame-pointer`.
- **Phase 4 — EcoGCPrepare Pass** *(Apr 12-17)*: Lowering pass detects all potentially allocating ops. Attaches live GC roots as explicit operands on allocation ops, `eco.call`, `eco.papExtend`. Uses MLIR `Liveness` analysis unioned with front-end operands; `func.walk()` visits nested regions (`scf.while`/`scf.if`). Adds op's own `!eco.value` operands for multi-statepoint lowering. Excludes embedded constants from root sets. `emitAllocWithSafepoint` receives pre-converted roots from the type-converter adaptor, eliminating races where `!eco.value` types were already erased before liveness.
- **Phase 5 — Fast/Slow Alloc Paths and Allocation Groups** *(Apr 12-16)*: Fast path is nursery bump allocation. Slow path runs allocation inside a GC safepoint. Adjacent fixed-size allocs are coalesced into a single fast/slow/merge CFG: `eco_gc_alloc_region_fast(totalBytes)` + one shared `__eco_safepoint_marker` + `eco_gc_alloc_region_slow`, with members initialized at fixed offsets via `eco_init_*_at` runtime functions. Groups are capped below the 32 KiB large-object threshold and exclude variable-size ops.
- **Phase 6 — GC Root Carrier Interface** *(Apr 13-17)*: `eco.call` and `eco.papExtend` supply GC roots. Safepoint marker emission moved from top of call/PAP lowering to immediately before each final GC-triggering call inside closure dispatch helpers (`emitFastClosureCall`, `emitClosureCall`, `emitInlineClosureCall`, `lowerSegmentationUnknown`, `lowerGenericApply`). Closure wrapper functions (`__closure_wrapper_*`) emit safepoints before target call and every `eco_alloc_*` boxing call.
- **Phase 7 — Shadow Stack and Arg Array Rooting** *(Apr 13-15)*: `RootSet::stack_ranges` — a shadow stack for dynamic arg arrays (alloca'd `uint64_t*` buffers) that static stack maps cannot describe. `eco_apply_closure`, `eco_apply_segmentation_unknown`, `eco_pap_extend`, and `eco_closure_call_saturated` register their combined/unboxed-masked arg arrays via `eco_gc_push_stack_range` before allocating and pop after.
- **Phase 8 — Shared Helper and Closure Re-Resolution** *(Apr 15)*: `emitRootedBoxedArgsArray` helper encapsulates the alloca → zero-init → GC-root → box-and-populate pattern. `buildEvaluatorArgs` takes `closure_hptr` and re-resolves via `hpointerToPtr` before each `values[i]` load — so boxing allocations that trigger GC don't leave the closure pointer stale.
- **Phase 9 — External GC Roots** *(Apr 15)*: `MVar::s_mvars` and `Runtime::s_savedState` registered as external GC root scanners via `Eco_Kernel_{MVar,Runtime}_register_gc_roots` and aggregator `Eco_Kernel_register_all_gc_roots`, invoked after `Allocator::initThread()` in AOT (and weakly in JIT) entries.
- **Phase 10 — Representation Change** *(Apr 17)*: `!eco.value` now lowers to `ptr addrspace(1)` instead of `i64`. `ptrtoint`/`inttoptr` only at heap/global/closure storage boundaries and constant encoding. Constants excluded from GC live root sets; `stripIntToPtr` returns `nullptr` for `inttoptr(ConstantInt)` so constants never become roots. New invariant REP_LLVM_001.
- **Phase 11 — Diagnostics** *(Apr 15-16)*: `ECO_GC_DEBUG` CMake option (default on in Debug) adds nursery ghost-data asserts (`clearToSpaceFreeRegion` zeroes free to-space bytes; `debugAssertValidNurseryPointer` called from `evacuate` and `Allocator::resolve`). `ECO_GC_DEBUG_LIVENESS` enables `EcoGCLivenessAudit` pass. See `guides/gc-diagnostics.md`.
- **Phase 12 — RewriteStatepointsForGC Migration** *(Apr 18-22)*: Bespoke `StatepointConversion` pass replaced with LLVM's upstream `RewriteStatepointsForGC` (RS4GC). New `EcoGCStrategy.cpp` registers `eco-gc` strategy; functions tagged `gc "eco-gc"` get RS4GC-inserted `gc.statepoint`/`gc.relocate` pairs at every non-leaf call, with liveness/base-pointer inference handled upstream. `EcoPtrIntVerify` post-RS4GC verifier enforces the addrspace(1) boundary invariants. LLVM libunwind built into the JIT (per-FDE `.eh_frame` registration, `frame-pointer=all` on emitted functions) so precise unwinding works across JIT-compiled frames. `StackMapRoots` split into its own class owned by `ThreadLocalHeap`. `Allocator` free-list returns nursery blocks from retired `ThreadLocalHeap`s back to the pool (fixes spawn-heavy nursery exhaustion). `eco.shadow_roots` UnitAttr attached by the compiler on `main_$_0` and TCO join blocks for GC-safe tail-recursive frames.

**Tasks**:
- [x] Build a small example program in LLVM using recursion to create stack frames with heap pointers
- [x] Generate LLVM statepoints at GC safepoints in eco.safepoint lowering
- [x] Parse LLVM stack map section in runtime
- [x] Integrate stack map data into the runtime's root scanning during GC
- [x] EcoGCPrepare pass to detect allocating ops and attach GC roots *(Apr 12)*
- [x] Fast/slow allocation paths with allocation coalescing *(Apr 12)*
- [x] GC roots on call/papExtend ops *(Apr 13)*
- [x] Safepoint marker positioning fix (before actual GC-triggering call) *(Apr 13)*
- [x] Shadow stack root ranges for dynamic arg arrays *(Apr 13)*
- [x] Closure wrapper safepoint markers *(Apr 13)*
- [x] MLIR `Liveness` analysis replacing block-local heuristic *(Apr 13)*
- [x] Stack unwinding for RSP-relative stack map locations *(Apr 14)*
- [x] `func.walk()` to visit nested regions *(Apr 14)*
- [x] Arg-array rooting in closure apply/pap_extend/segmentation_unknown *(Apr 15)*
- [x] External GC root scanning for MVar/Runtime statics *(Apr 15)*
- [x] Constant filtering across all four collection points *(Apr 15-17)*
- [x] Allocation group single safepoint lowering *(Apr 16)*
- [x] GC liveness audit pass (ECO_GC_DEBUG_LIVENESS) *(Apr 16)*
- [x] eco.value → ptr addrspace(1) representation change *(Apr 17)*
- [x] RS4GC migration + EcoGCStrategy *(Apr 22)*
- [x] LLVM libunwind integration for JIT *(Apr 19-21)*
- [x] `eco.shadow_roots` attribute + TCO shadow frames *(Apr 18)*
- [x] `StackMapRoots` class split *(Apr 18)*
- [x] Nursery free-list for retired `ThreadLocalHeap`s *(Apr 22)*
- [x] Stress suite to verify stack roots across major GC cycles *(stress-elm library, Apr 20-22)*

**Deliverables**:
- [x] LLVM stack map example/prototype *(safepoint_explicit.mlir)*
- [x] Modified eco.safepoint lowering to emit statepoints *(StatepointConversion.cpp)*
- [x] Runtime stack map parser *(StackMap.cpp/hpp)*
- [x] Integration tests for stack root preservation *(4 safepoint codegen tests)*
- [x] EcoGCPrepare pass *(EcoGCPrepare.cpp)*
- [x] Fast/slow allocation path infrastructure
- [ ] Extended stress tests under concurrent load

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

### 2.1 Eco Runtime to Kernel Packages

**Status**: In Progress (IO Layer Substantially Migrated)

The compiler previously used a runtime library with HTTP URL hacks (`Utils.Impure`) for I/O operations. This is being converted to proper Elm kernel packages via the `eco-kernel-cpp` package, with a three-stage bootstrap pipeline:

1. **Stage 1** (Bootstrap): Stock Elm compiler builds `eco-boot.js` using XHR-based `Eco.*` modules
2. **Stage 2** (Kernel JS): `eco-boot.js` builds `eco-node.js` using `Eco.Kernel.*` directly
3. **Stage 3** (Native): `eco-node.js` builds `eco-native` linked with C++ IO kernel

**Current State** *(Feb 27, 2026)*:
- `eco-kernel-cpp/` package created with Elm API, JS kernel, and C++ kernel implementations
- XHR IO modules created (`compiler/src-xhr/Eco/*.elm`) for bootstrap stage
- All compiler IO operations migrated to `Eco.*` interface — no `Utils.Impure` imports remain in `compiler/src/`
- See `io-refactor.md` for migration report (note: written mid-migration, now complete)

**Deliverables**:
- [x] Elm kernel package definitions (`eco-kernel-cpp/elm.json`)
- [x] API specification via `design_docs/guida-io-ops.csv` (45 operations mapped)
- [x] Refactored compiler fully using new kernel package *(complete - no Impure imports remain)*

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

#### 2.1.1 Audit I/O Implementation

**Status**: Complete (Feb 26, 2026)

Catalog all I/O operations in the compiler and rationalize them into a clean API.

**Tasks**:
- [x] Clone and build Guida compiler *(see design_docs/guida_build_notes.md)*
- [x] Document all native I/O operations currently implemented *(see design_docs/guida-io-operations.md)*
- [x] Rationalize the design to form a well-designed I/O package suitable for any CLI tool written in Elm
- [x] Identify any missing operations needed for general-purpose CLI development *(gaps documented in guida-io-operations.md)*

**Rationalization** *(Feb 26, 2026)*:
- All 45 compiler IO operations mapped from legacy names to clean `Eco.*` API names in `design_docs/guida-io-ops.csv`
- Operations organized into 6 modules: `Eco.File` (21 ops), `Eco.Console` (3 ops), `Eco.Env` (2 ops), `Eco.Process` (5 ops), `Eco.MVar` (4 ops), `Eco.Runtime` (3 ops)
- Legacy compound operations decomposed into atomic primitives (e.g., `dirWithCurrentDirectory` → `setCwd` + bracket pattern)
- New operations added: `readBytes`, `setCwd` (extracted from compound ops)

**Deliverables**:
- [x] Comprehensive list of current I/O operations *(design_docs/guida-io-ops.csv - 45 operations)*
- [x] Rationalized I/O design with clean module structure

#### 2.1.2 File System Operations Design

**Status**: Complete (Feb 26, 2026)

Design a clean API for file system operations.

**Implementation**: The `Eco.File` module provides 21 operations covering all compiler file system needs:

| Category | Operations |
|----------|-----------|
| **Read/Write** | `readString`, `writeString`, `readBytes`, `writeBytes` |
| **Handles** | `open`, `close`, `size` |
| **Locking** | `lock`, `unlock` |
| **Existence** | `fileExists`, `dirExists` |
| **Discovery** | `findExecutable`, `list`, `modificationTime` |
| **Directory** | `getCwd`, `setCwd`, `canonicalize`, `appDataDir`, `createDir` |
| **Removal** | `removeFile`, `removeDir` |

Three implementations exist:
- **XHR** (`compiler/src-xhr/Eco/File.elm`) - 300 lines, for bootstrap stage
- **Kernel Elm** (`eco-kernel-cpp/src/Eco/File.elm`) - calls `Eco.Kernel.File` JS/C++
- **Kernel JS** (`eco-kernel-cpp/src/Eco/Kernel/File.js`) - Node.js `fs` implementation
- **Kernel C++** (`eco-kernel-cpp/src/eco/File.cpp`) - POSIX implementation

**Tasks**:
- [x] Catalog current file operations
- [x] Rationalize into a coherent file system API
- [x] Implement XHR, JS kernel, and C++ kernel variants

**Deliverables**:
- [x] File system API specification (in `Eco.File` module)

#### 2.1.3 Network Operations Design

**Status**: Deferred (stays on legacy path)

Network operations (HTTP proxy, archive downloads, multipart uploads) remain on the legacy `Impure.task` → `Builder/Http.elm` path. These are complex multi-step protocols that don't need to be in the `Eco.*` module interface for the bootstrap pipeline.

**Decision**: Network operations will be addressed when needed for Stage 2/3. The existing `elm/http` kernel (§2.3.6) handles HTTP at the kernel level for native compilation. The compiler's package-fetching operations are specific to the build system and may be handled differently in the native compiler.

**Tasks**:
- [x] Catalog current network operations in compiler (3 ops: fetch, getArchive, upload)
- [x] Decision: keep on legacy path for bootstrap, address later
- [ ] Consider native HTTP client for self-hosted compiler

**Deliverables**:
- [x] Network operations cataloged in `design_docs/guida-io-ops.csv`

#### 2.1.4 System Operations Design

**Status**: Complete (Feb 26, 2026)

Design a clean API for system-level operations.

**Implementation**: System operations are split across four `Eco.*` modules:

| Module | Operations | Description |
|--------|-----------|-------------|
| `Eco.Console` | `write`, `readLine`, `readAll` | Console I/O via handles (stdout/stderr/stdin) |
| `Eco.Env` | `lookup`, `rawArgs` | Environment variables and CLI arguments |
| `Eco.Process` | `exit`, `spawn`, `wait` | Process management and exit codes |
| `Eco.Runtime` | `dirname`, `random`, `saveState` | Runtime utilities |
| `Eco.MVar` | `new`, `read`, `take`, `put` | Concurrency primitives (kernel-only) |

Each has XHR, JS kernel, and C++ kernel implementations.

**Tasks**:
- [x] Catalog current system operations
- [x] Rationalize into coherent module structure
- [x] Implement XHR, JS kernel, and C++ kernel variants

**Deliverables**:
- [x] System operations API specification (in `Eco.*` modules)

#### 2.1.5 Kernel Package Implementation & Refactor

**Status**: In Progress (eco-kernel-cpp created, XHR IO wired up)

Design Elm types for the kernel package and refactor the compiler to use it.

**Implementation** *(Feb 26-27, 2026)*:

The `eco-kernel-cpp/` package has been created as a proper Elm kernel package (`eco/kernel`) with three implementation layers:

```
eco-kernel-cpp/
├── elm.json                     # Package definition (eco/kernel 1.0.0)
├── CMakeLists.txt               # C++ build (6 static libraries)
├── src/
│   ├── Eco/                     # Elm API modules
│   │   ├── File.elm             # File system operations
│   │   ├── Console.elm          # Console I/O
│   │   ├── Env.elm              # Environment variables
│   │   ├── Process.elm          # Process management
│   │   ├── MVar.elm             # Concurrency primitives
│   │   ├── Runtime.elm          # Runtime utilities
│   │   └── Kernel/              # JS kernel implementations
│   │       ├── File.js          # Node.js fs operations
│   │       ├── Console.js       # Node.js console
│   │       ├── Env.js           # Node.js process.env
│   │       ├── Process.js       # Node.js child_process
│   │       ├── MVar.js          # In-memory MVar store
│   │       └── Runtime.js       # Node.js runtime utils
│   └── eco/                     # C++ kernel implementations
│       ├── File.cpp/hpp         # POSIX file operations
│       ├── FileExports.cpp      # C-linkage exports
│       ├── Console.cpp/hpp      # POSIX console I/O
│       ├── ConsoleExports.cpp
│       ├── Env.cpp/hpp          # POSIX environment
│       ├── EnvExports.cpp
│       ├── Process.cpp/hpp      # POSIX process mgmt
│       ├── ProcessExports.cpp
│       ├── MVar.cpp/hpp         # Mutex-based MVars
│       ├── MVarExports.cpp
│       ├── Runtime.cpp/hpp      # Runtime utilities
│       ├── RuntimeExports.cpp
│       ├── KernelExports.h      # All C-linkage declarations
│       └── ExportHelpers.hpp    # Shared export utilities
```

**Bootstrap IO Wiring** *(Feb 27, 2026)*:
- XHR IO modules created (`compiler/src-xhr/Eco/*.elm`) for Stage 1 bootstrap
- `eco-io-handler.js` dispatches JSON requests to Node.js APIs
- `eco-boot-runner.js` runs the bootstrap compiler with both XHR and legacy handlers
- Build configs: `elm-bootstrap.json` (XHR), `elm-kernel.json` (kernel)
- All compiler IO operations migrated to `Eco.*` interface (no `Utils.Impure` imports remain)
- All IO operations now flowing through the new XHR-based `Eco.*` layer
- Registry update caching *(Apr 3, 2026)*: 30-minute check interval for `registry.dat`, `--refresh-registry` flag on `eco make` and `eco install`

**Compiler Migration Status**: Complete — no `Utils.Impure` imports remain in `compiler/src/`. All IO operations route through `Eco.*` modules.

| File | Status |
|------|--------|
| `System/IO.elm` | **Migrated** → `Eco.Console` + `Eco.File` |
| `System/Exit.elm` | **Migrated** → `Eco.Process` |
| `Builder/File.elm` | **Migrated** → `Eco.File` + `Eco.Console` |
| `Terminal/Main.elm` | **Migrated** → `System.Exit` |
| `Utils/Main.elm` | **Migrated** → `Eco.File` + `Eco.Console` + `Eco.Env` + `Eco.Runtime` + `Eco.MVar` |
| `System/Process.elm` | **Migrated** → `Eco.Process` |
| `Builder/Http.elm` | **Migrated** → `Eco.*` |
| `API/Main.elm` | **Migrated** → `Eco.*` |

**Tasks**:
- [x] Design Elm types using Task-based interface
- [x] Ensure API covers all I/O operations the compiler requires
- [ ] Modify compiler to allow kernel code in non-elm/* packages (break the restriction)
- [ ] Enable loading kernel packages from the local file system (not Elm package site)
- [x] Implement the kernel package with JavaScript runtime (`Eco/Kernel/*.js`)
- [x] Implement the kernel package with C++ runtime (`eco/*.cpp`)
- [x] Create XHR variant for bootstrap stage (`src-xhr/Eco/*.elm`)
- [x] Refactor compiler IO to use `Eco.*` interface *(complete - Feb 27, 2026)*
- [x] Remove legacy `Utils.Impure` dependency from compiler *(complete - all compiler/src/ files migrated)*
- [ ] Verify compiler builds and functions with kernel package

**Deliverables**:
- [x] Elm kernel package type definitions (`eco-kernel-cpp/elm.json`)
- [x] JS kernel implementation (`eco-kernel-cpp/src/Eco/Kernel/*.js`)
- [x] C++ kernel implementation (`eco-kernel-cpp/src/eco/*.cpp`)
- [x] XHR bootstrap implementation (`compiler/src-xhr/Eco/*.elm`)
- [x] Bootstrap runner and IO handler (`compiler/bin/eco-boot-runner.js`, `eco-io-handler.js`)
- [x] Build configurations (`elm-bootstrap.json`, `elm-kernel.json`)
- [ ] Modified compiler (kernel package restrictions relaxed)
- [ ] Local kernel package loading support
- [ ] Complete compiler migration off `Utils.Impure`
- [ ] IO refactor report: `io-refactor.md`

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
| `elm/http` | 8 | `HttpExports.cpp` | **Complete** (Feb 20, 2026; rebuilt May 31, 2026) - libcurl, deferred-Task IO, progress streaming |
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

**Http Rebuild** *(May 31, 2026)*:
- `elm/http` + `Eco.Http` reimplemented as a real libcurl kernel running on the single-threaded heap, with a full E2E test suite.
- `Http.track` progress streaming implemented (elm/http) — periodic progress events delivered to the Elm side via the effect manager.
- Native package downloads fixed: send `Content-Length: 0` on empty-body POST/PUT/PATCH (the registry was returning 411); fetch errors propagate as structured `Http.Error`s.
- Accept all libcurl-supported encodings so gzip downloads from the package server work.
- All HTTP test failures in Gate A + B fixed; ties into the deferred-Task pattern (§2.4) so blocking `curl_easy_perform` no longer stalls the scheduler at kernel-call time.

**Tasks**:
- [x] Create stub implementations for all 92 functions
- [x] Add declarations to KernelExports.h
- [x] Add KERNEL_SYM entries for JIT symbol resolution
- [x] Implement Url encoding/decoding (real implementations)
- [ ] Implement Browser primitives (browser-specific, N/A for CLI)
- [x] Implement Http primitives *(Feb 20, 2026 - libcurl/openssl)*
- [ ] Implement elm/file primitives (browser file upload/download, N/A for CLI)
- [ ] Implement VirtualDom primitives (browser-specific, N/A for CLI)
- [ ] Implement Parser primitives
- [x] Implement Regex primitives *(Feb 20, 2026 - srell.hpp)*
- [x] Implement Debugger primitives *(Feb 20, 2026)*

**Deliverables**:
- [x] Stub implementations in `elm-kernel-cpp/src/*/`
- [x] Full Url kernel implementation
- [x] Http, Regex, Debugger implementations *(Feb 20, 2026)*
- [x] E2E tests for http, regex, time, url packages *(test/elm-*/  - Feb 23, 2026)*
- [ ] elm/file (browser upload/download — N/A for CLI), Browser, VirtualDom, Parser implementations

### 2.4 I/O Kernel Package C++ Implementation

**Status**: In Progress (deferred-Task migration complete; structured IO errors plumbed end-to-end)

Implement the I/O kernel packages defined in §2.1 in C++ for linking with the native runtime.

**Background**: This is separate from the standard Elm kernel (§2.3) because it covers the custom I/O operations needed for CLI tools, as designed in §2.1. The C++ implementations live in `eco-kernel-cpp/src/eco/` and are built as static libraries via CMake.

**Current Implementation**:
- 6 C++ modules with C-linkage exports for JIT/native linking
- Built as static libraries: `EcoKernel_File`, `EcoKernel_Console`, `EcoKernel_Env`, `EcoKernel_Process`, `EcoKernel_MVar`, `EcoKernel_Runtime`
- Combined convenience library: `EcoKernel` (INTERFACE target)
- Uses ECO runtime heap model for Elm value interop

**Deferred kernel Task IO via `Task_Binding`** *(May 31, 2026)*: Every C++ symbol that returns an Elm `Task` now performs its IO inside a `Task_Binding` callback rather than at kernel-call time. The scheduler steps bindings and can therefore interleave outstanding IO; blocking syscalls (e.g. `curl_easy_perform`, `waitpid`) park onto an async worker pool and resume the parked closure. Shared helpers live in `runtime/src/platform/TaskBinding.hpp` (sync `makeBinding` and async `makeAsyncBinding`) with Eco-side `succeed*` / `fail*` HPointer wrappers in `eco-kernel-cpp/src/eco/TaskBinding.hpp`. New invariants **KERNEL_TASK_IO_001** and **KERNEL_TASK_IO_002** record the pattern and its rooting discipline. See [Kernel Task Deferral Theory](design_docs/theory/kernel-task-deferral.md) and `plans/defer-eager-kernel-tasks-via-binding.md`.

**Structured IO errors end-to-end** *(May 31, 2026)*: Kernel IO errors are now plumbed as structured Elm error values (with errno, path, and operation context) from the C++ kernels through the scheduler to the final `Exit` boundary, replacing string-stringified error returns. Error handling audited across the Eco kernel API.

**Module Status**:
| Module | Source Files | Status |
|--------|-------------|--------|
| File | `File.cpp/hpp`, `FileExports.cpp` | First pass |
| Console | `Console.cpp/hpp`, `ConsoleExports.cpp` | First pass |
| Env | `Env.cpp/hpp`, `EnvExports.cpp` | First pass |
| Process | `Process.cpp/hpp`, `ProcessExports.cpp` | First pass |
| MVar | `MVar.cpp/hpp`, `MVarExports.cpp` | First pass |
| Runtime | `Runtime.cpp/hpp`, `RuntimeExports.cpp` | First pass |

**Tasks**:
- [x] C++ implementations of file system APIs (§2.1.2) - first pass
- [ ] C++ implementations of network APIs (§2.1.3) - deferred
- [x] C++ implementations of system APIs (§2.1.4) - first pass
- [x] C-linkage exports for JIT symbol resolution (`KernelExports.h`)
- [x] CMake build integration (`eco-kernel-cpp/CMakeLists.txt`)
- [ ] Memory management for foreign objects (file handles, sockets, etc.)
- [ ] Error handling across language boundary
- [ ] Integration with runtime KERNEL_SYM table
- [ ] Test suite for I/O operations

**Deliverables**:
- [x] C++ I/O kernel implementations in `eco-kernel-cpp/src/eco/`
- [x] CMake static library targets
- [ ] Integration with `RuntimeSymbols.cpp` KERNEL_SYM table
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
| **Calls/Closures** | `call`, `papCreate`, `papExtend` | ✅ Lowered + Tested (GC root operands carried directly) |
| **Allocation** | `allocate`, `allocate_ctor`, `allocate_string`, `allocate_closure` | ✅ Lowered + Tested |
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

#### 3.1.5 GC Integration Hooks

**Status**: Complete

Define operations for garbage collection integration.

**Current Implementation**:
- Allocation ops: `eco.allocate`, `eco.allocate_ctor`, `eco.allocate_string`, `eco.allocate_closure` - all lowered to runtime calls, now carry explicit GC root operands *(Apr 2026)*
- **`eco.safepoint` op retired** *(May 19, 2026)*: With the RS4GC migration, GC safepoints are inserted by LLVM at every non-leaf call in a `gc "eco-gc"` function — no front-end marker op is needed. The `eco.safepoint` op was removed and its GC root hints are threaded directly onto the existing `GCRootCarrier` ops (`eco.call`, `eco.papExtend`, and the allocation ops). EcoGCPrepare no longer emits liveness hints — RS4GC recomputes liveness from `ptr addrspace(1)` types.
- GC root operands on `eco.call` and `eco.papExtend` *(Apr 2026)*
- EcoGCPrepare pass: Detects allocating ops and attaches live GC roots as explicit operands *(Apr 2026)*
- Fast/slow allocation paths: Fast bump-pointer, slow path wrapped in `gc.statepoint` by RS4GC *(Apr 2026)*
- Global root registration: `eco.global` lowering generates `__eco_init_globals` constructor that calls `eco_gc_add_root` for each global
- Reference counting placeholders: `eco.incref`, `eco.decref`, etc. - defined but not lowered (for future Perceus)

**Tasks**:
- [x] Allocation operations (nursery via runtime allocator)
- [x] GC safepoint operations (delegated to RS4GC at non-leaf calls)
- [x] Root registration operations (global root auto-registration)
- [x] Explicit GC root operands on allocation ops *(Apr 2026)*
- [x] GC root operands on call/papExtend ops *(Apr 2026)*
- [x] EcoGCPrepare pass for automatic root attachment *(Apr 2026)*
- [x] Fast/slow allocation path splitting *(Apr 2026)*
- [x] Retire `eco.safepoint` op; thread GC hints onto carrier ops directly *(May 19, 2026)*
- [ ] Write barrier operations (not needed - Elm's immutability guarantees no old→young pointers)
- [x] Reference counting operations (Perceus-style reuse) - placeholder definitions

**Deliverables**:
- [x] Reference counting operation definitions *(in Ops.td - placeholders)*
- [x] Allocation operation definitions and lowerings *(EcoToLLVM.cpp)*
- [x] Global root registration code generation
- [x] EcoGCPrepare pass *(EcoGCPrepare.cpp)*
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
- `EcoGCPrepare.cpp`: GC root attachment on allocating ops *(Apr 2026)*
- Pass pipeline: eco → EcoGCPrepare → (verification passes) → EcoToLLVM → LLVM dialect → LLVM IR → StatepointConversion → JIT/native

**Transformations**:
- [x] Pattern matching to control flow (eco.case → switch on tag)
- [x] Closure conversion (papCreate/papExtend → runtime calls)
- [x] Direct closure calls with typed ABI (Feb 12, 2026)
- [x] Heap allocation insertion (construct → allocate + stores)
- [x] GC safepoint insertion (RS4GC inserts `gc.statepoint` at every non-leaf call; `eco.safepoint` op retired May 19, 2026)
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

**Type-Aware Evaluator Args (`_capture_abi`)** *(Apr 15, 2026)*:

- `buildEvaluatorArgs` takes an `EvalParamLayout` giving each slot's type; re-boxes captures to the correct primitive type (`eco_alloc_int`/`_float`/`_char`) instead of always `ElmInt`
- MLIR emitter tracks accumulated arg types across staged calls, emitting a `_capture_abi` attribute on the lowered closure call
- LLVM lowering builds and passes a layout global to the runtime
- `eco_pap_extend` now keeps Char unboxed (consistent with Int/Float)

**CallGenericApply** *(Mar 19, 2026)*:

New safe fallback calling convention for closures where arity cannot be statically determined:

- **CallKind type**: `CallDirectKnownSegmentation | CallDirectFlat | CallGenericApply`
- **Runtime wrappers**: `eco_apply_*` functions in `RuntimeExports.cpp` handle dynamic arity dispatch
- **Staging-agnostic**: Generic apply does not require staging analysis; works as safe fallback
- **Plan**: `plans/generic-apply-staging-agnostic-closures.md`

**Deliverables**:
- [x] Lowering passes in C++ *(Passes/EcoToLLVM.cpp, Passes/RCElimination.cpp)*
- [x] Pass pipeline configuration *(ecoc.cpp)*
- [x] JIT execution support *(EcoRunner.cpp)*
- [x] Testing framework for transformations *(test/codegen/)*
- [ ] Advanced optimizations (inlining, dead code elimination)

### 3.3 GC Stack Root Tracing

**Status**: Substantially Complete (Apr 2026)

Integration between LLVM and the garbage collector for precise stack scanning. This work is tracked jointly with §1.2.3 (LLVM Stack Map Implementation).

**Implementation** *(Mar 26 – Apr 17, 2026)*:
- LLVM statepoint generation wrapping actual allocating/calling functions
- Two-phase alloca+mem2reg statepoint rewriting for correct loop header phi nodes
- EcoGCPrepare pass attaches live GC roots on all potentially allocating ops (uses MLIR `Liveness`, unions with front-end operands, visits nested regions via `func.walk()`)
- Fast/slow allocation paths (bump pointer vs GC safepoint); adjacent fixed-size allocs coalesce into one group with shared safepoint
- GC root carrier interface on `eco.call` and `eco.papExtend`
- Closure wrapper safepoint markers before target call and every boxing site
- `StackRootGuard` RAII helper roots captured HPointers across allocations
- Shadow stack root ranges (`RootSet::stack_ranges`) for dynamic arg arrays
- Runtime stack map v3 parser with x86-64 frame pointer walking + RSP-relative unwinding (`StackUnwind.cpp`)
- External GC root scanning: `RootSet` scanners + `MVar::s_mvars` / `Runtime::s_savedState` registration
- Constants filtered from live root sets (embedded constants, `inttoptr(ConstantInt)`)
- `!eco.value` → `ptr addrspace(1)` representation change (REP_LLVM_001)
- `EcoGCLivenessAudit` pass behind `ECO_GC_DEBUG_LIVENESS`; nursery ghost-data detection behind `ECO_GC_DEBUG`

**Requirements**:
- [x] LLVM stack map generation via statepoints *(Mar 26)*
- [x] Runtime stack root registration *(Mar 26)*
- [x] Safepoint insertion in generated code — initially via `eco.safepoint`, then RS4GC at every non-leaf call *(Apr 18-22)*; `eco.safepoint` op retired *(May 19)*
- [x] EcoGCPrepare automatic root attachment *(Apr 12)*
- [x] Fast/slow allocation paths *(Apr 12)*
- [x] GC roots on call/papExtend operations *(Apr 13)*
- [x] Shadow stack roots for dynamic arg arrays *(Apr 13)*
- [x] RSP-relative stack map unwinding *(Apr 14)*
- [x] Allocation group single safepoint *(Apr 16)*
- [x] External GC roots for kernel global state *(Apr 15)*
- [x] eco.value → ptr addrspace(1) *(Apr 17)*
- [x] Carrier-op-only GC hints; liveness from RS4GC alone *(May 19)*
- [ ] Thread-safe root set management (multi-thread stress testing)

**Deliverables**:
- [x] LLVM stackmap integration *(EcoJIT, StackMap.cpp, StatepointConversion.cpp)*
- [x] Runtime root scanning infrastructure *(ThreadLocalHeap, RootSet, HeapHelpers)*
- [x] EcoGCPrepare pass *(EcoGCPrepare.cpp)*
- [ ] Documentation on GC integration (to be updated)

**See Also**: §1.2.3 for full implementation details and research in `design_docs/llvm_stackmap_integration.md`

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
- `Compiler/Type/PostSolve.elm`: Post-solver that fixes remaining Group B expression types (Str, Chr, Float, Unit) and infers kernel function types
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

**MonoDirect Alternative Monomorphizer** *(Mar 12-16, 2026; removed Mar 31)*:
A solver-driven alternative was explored but removed:
- Used `SolverSnapshot` to query and locally unify types instead of string-based `TypeSubst`
- Tvar fields propagated through `TypedOptimized` IR for linking back to solver state
- **Removed** on Mar 31, 2026 as it was incomplete and blocking refactoring of the production monomorphizer
- Design docs moved to `notes/` for reference: `notes/monodirect_theory.md`, `notes/mono-direct-for-packages.md`
- Classic monomorphizer is the sole production path

**Deliverables**:
- [x] Modified Optimized IR with type annotations (`Compiler/AST/TypedOptimized.elm`)
- [x] Monomorphization pass implementation (`Compiler/Optimize/Mono.elm`)
- [x] MonoDirect solver-driven monomorphizer (`Compiler/MonoDirect/`) *(experimental, Mar 2026)*
- [x] Global AST analysis document
- [x] Decision on DynRecord necessity
- [x] AST modification plan (if needed)

#### 4.1.3 Dual Backend Implementation

**Status**: Complete

Keep JavaScript backend and add MLIR backend with compiler flags to switch between them.

**Implementation**:
- Backend selection via output file extension: `.js` → JavaScript, `.html` → JavaScript+HTML wrapper, `.mlir` → MLIR Mono backend
- Two backend types implemented:
  - `javascriptBackend`: Standard JavaScript code generation (uses untyped `Opt.GlobalGraph`)
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

**GlobalOpt Phase** *(consolidated Feb 5-7, 2026; calling convention fixes Mar 17-19, 2026)*:
```
compiler/src/Compiler/GlobalOpt/
├── MonoGlobalOptimize.elm  # Main optimization pass, ABI alignment
├── MonoInlineSimplify.elm  # Small function inlining
├── MonoTraverse.elm        # Common iterator for code traversal (moved to Monomorphize/)
├── MonoReturnArity.elm     # Return arity tracking
├── CallInfo.elm            # Call information analysis
└── Staging/                # Staged-curried calling convention
    ├── GraphBuilder.elm    # Builds call graph for staging
    ├── Solver.elm          # Solves staging constraints
    ├── Rewriter.elm        # Rewrites calls with staging info
    ├── Types.elm           # Staging type definitions (CallKind added Mar 19)
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

14. **Code Cleanup & elm-review** - ✅ Complete (Feb 25-26)
    - All elm-review issues fixed (auto-fixed + manual fixes)
    - Removed unused code (old test files, redundant modules)
    - elm-format applied across entire codebase
    - Doc fixes for elm-doc generation

15. **Lambda Boundary Normalization** - ✅ Re-enabled (Feb 25)
    - NormalizeLambdaBoundaries phase added back to pipeline
    - All E2E tests pass with the phase enabled
    - Optimize-equivalent test removed (was artificial constraint from early development)

**Resolved Issues** *(fixed Mar 11-19, 2026 — bootstrap push)*:

16. **MErased Removal** - ✅ Complete (Mar 14)
    - Dropped MErased from monomorphized IR; deriving it was too expensive
    - Updated both monomorphizers and all downstream consumers

17. **MonoDirect Solver-Driven Monomorphization** - ✅ First pass (Mar 12-16)
    - New alternative monomorphizer (`Compiler/MonoDirect/`) using HM solver state directly
    - SolverSnapshot captures solver state for local queries and type specialization
    - Tvar fields propagated through TypedOptimized IR for linking back to solver
    - JoinpointFlatten post-pass for MonoDirect closure/case flattening
    - Multiple structural fixes: VarEnv save/restore, curried binop types, erasure removal, accessor handling
    - Design doc: `design_docs/hm-solver-reuse.md`, `design_docs/mono-direct-for-packages.md`

18. **MonoDtPath (Typed Decision Tree Paths)** - ✅ Complete (Mar 16)
    - Decision-tree paths upgraded from untyped `DT.Path` to `MonoDtPath` carrying `MonoType` at each segment
    - MLIR codegen switched to `generateMonoDtPath`, eliminating cross-type guessing (`findSingleCtorUnboxedField` removed)
    - Both monomorphizers extended to specialize `DT.Path → MonoDtPath`

19. **Bootstrap Bug Fixes** - ✅ Fixed (Mar 15-17)
    - String type table ID fix (sentinel -1 → proper ID)
    - Bool (i1) capture boxing through `boxArgsForClosureBoundary` in `generateClosure`
    - SSA variable collision in TailRec fixed
    - ABI boxing bug in Lambdas.elm fixed
    - `eco.eq` for int comparison in patterns
    - SSA placeholder freshness (always allocate fresh vars, removing Dict.get skip)
    - Variable shadowing from function inlining resolved
    - Orphaned SSA vars from nested `generateLet` calls fixed
    - Recursive closure self-capture backpatching (`DenseI64ArrayAttr` vs `ArrayAttr`)
    - `papExtend` verifier fix (check `$cap` fast evaluator, not `$clo` generic clone)
    - Case branch context propagation in TailRec (pendingLambdas, pendingFuncOps, kernelDecls)
    - Never inline tail-recursive functions (prevents non-tail-recursive placement)
    - List head projection type fix for Bool containers
    - Single-ctor unboxed field lookup fix (wrong ctor picked)
    - Case root variable type inference from decider tests in Closure.elm
    - DtRoot/DtPath renaming in inliner and substituteDecider

20. **GlobalOpt Calling Convention Fixes** - ✅ Fixed (Mar 17-18)
    - `sourceArityForCallee` fallback: replaced `countTotalArityFromType` with `firstStageArityFromType`
    - TailDef arity tracking in `annotateDefCalls`
    - Closure capture arity propagation into `env.varSourceArity`
    - Pre-computed CallInfo for wrapper nested calls (both `buildNestedCallsGO` and `Rewriter.buildNestedCalls`)
    - Let-bound function arity propagation fix
    - New GOPT invariant tests (GOPT_011 through GOPT_014)
    - New CGEN_040 violation test case (`ParamArityCases.elm`)

21. **CallGenericApply** - ✅ Implemented (Mar 19)
    - New `CallKind` type: `CallDirectKnownSegmentation | CallDirectFlat | CallGenericApply`
    - Generic apply uses runtime wrappers to avoid over-applying closures where arity mismatch
    - Safe fallback when compiler cannot prove flat or segmented calling is correct
    - Runtime support in `EcoToLLVMRuntime.cpp`, `RuntimeExports.cpp/h`, `Heap.hpp`
    - MLIR ops and lowering updated in `EcoOps.cpp`, `Ops.td`, `EcoPAPSimplify.cpp`, `EcoToLLVMClosures.cpp`
    - Invariants updated in `design_docs/invariants.csv`
    - Plan: `plans/generic-apply-staging-agnostic-closures.md`

**Resolved Issues** *(fixed Mar 27 – Apr 13, 2026 — bootstrap push continued)*:

22. **SSA Variable Leak from Case/If Regions** - ✅ Fixed (Mar 27)
    - `ctxForSiblingRegion` now resets `definedSsaVars` to base context
    - `ctxAfterBranchOp` restores pre-branch state, keeping only case result variables
    - New tests: `CaseSafepointLeakTest.elm`, `IfLetSafepointTest.elm`

23. **GC Safepoint Full Implementation** - ✅ Complete (Mar 26-27)
    - eco.safepoint redesigned from string attribute to variadic `!eco.value` operands
    - Compiler tracks live SSA variables and emits safepoints before allocations
    - StatepointConversion wraps actual allocating calls in `gc.statepoint`
    - Custom EcoJIT captures `.llvm_stackmaps` section, runtime parses v3 format

24. **MLIR Bytecode Format** - ✅ Complete (Mar 24-25)
    - Binary bytecode MLIR format with streaming encoder
    - O(N) Dict-based grouping replacing O(N²) linked-list scan
    - Location/string attribute collision fix (LOC: prefix)

25. **MonoDirect Removal & Int MVarIds** - ✅ Complete (Mar 30-31)
    - MonoDirect experimental monomorphizer removed
    - Type variable String names replaced with Int IDs from monomorphization onward
    - `AssignMVarIds` module for globally unique ID assignment

26. **Solver Root-Backed MVarIds** - ✅ Complete (Apr 4)
    - `SolverRoots` module normalizes solver variables to union-find roots
    - Ensures two type variables sharing the same solver root get the same MVarId
    - schemeRoots field threaded through LocalGraphData and GlobalGraph

27. **Monomorphization Correctness** - ✅ Fixed (Apr 1-11)
    - Scheme freshening with globally unique MVarIds
    - `applySubstWithFreeVars` transitive closure prevents cross-scheme contamination
    - `PendingCall` for deferred nested polymorphic call specialization
    - Per-binding MVarId isolation for cycle members
    - Constructor annotations in scheme cache
    - VarLocal/TrackedVarLocal prefer VarEnv monomorphic type
    - Type alias analysis fixes in `convertCanTypeNameToMVarId`
    - Phantom type var normalization in spec keys
    - Fast path for non-polymorphic functions

28. **Value-Only Recursive Cycles** - ✅ Fixed (Apr 9)
    - Value-only recursive cycles compiled as individual `MonoDefine` nodes instead of single `MonoCycle`
    - `MonoCycle` constructor deleted as dead code

29. **isPureExpr Bugs** - ✅ Fixed (Apr 9)
    - `MonoLet` now checks both body and bound expression for purity
    - `MonoCase` checks Inline expressions inside Decider tree, not just jump-target list

30. **GC Root Safety** - ✅ Fixed (Apr 7-17)
    - `StackRootGuard` RAII helper roots HPointers across allocations
    - Scheduler `pushStack`/`mailboxPushBack` take `HPointer` not `Process*`
    - Shadow stack root ranges (`RootSet::stack_ranges`) for dynamic arg arrays
    - Closure wrapper safepoint markers before target call + each `eco_alloc_*` site
    - `EcoGCPrepare` uses MLIR `Liveness`; `func.walk()` visits nested regions
    - Alloc-group/call-safepoint operand union in `EcoGCPrepare`
    - External GC root scanners for `MVar::s_mvars` and `Runtime::s_savedState`
    - Constants filtered from GC live root sets at all four collection points
    - `stripIntToPtr` returns nullptr for `inttoptr(ConstantInt)`

31. **eco.value → ptr addrspace(1)** - ✅ Complete (Apr 17)
    - `!eco.value` lowers to `ptr addrspace(1)` (GC-managed pointer) instead of `i64`
    - `ptrtoint`/`inttoptr` only at heap/global/closure storage boundaries and constant encoding
    - BF dialect's `BFTypeConverter` unified with `EcoTypeConverter` (all BF runtime LLVM decls use `ptr<1>`)
    - `widenFieldToI64` handles Bool `ptr<1>` constants via `PtrToIntOp` instead of pointer ZExt
    - `widenToI64ForInit` routes through `castToHPtr` so inverse casts cancel in reconcile
    - ADT case bit manipulation lifts `ptr<1>` scrutinee to `i64` via `valueToI64`
    - New invariant REP_LLVM_001; 114 test `.mlir` files updated

32. **Allocation Group Single Safepoint** - ✅ Complete (Apr 16)
    - Adjacent fixed-size alloc ops identified by `EcoGCPrepare` lower to a single fast/slow/merge CFG
    - `eco_gc_alloc_region_fast` / `eco_gc_alloc_region_slow` share one safepoint
    - `eco_init_*_at` runtime functions initialize members at fixed offsets
    - Variable-size ops excluded; group size capped below 32 KiB large-object threshold

33. **Type-Aware buildEvaluatorArgs** - ✅ Fixed (Apr 15)
    - Previously re-boxed all unboxed captures as `ElmInt`; now uses per-slot `EvalParamLayout`
    - MLIR emitter emits `_capture_abi` attribute tracking staged-call arg types
    - LLVM lowering builds layout global passed to runtime
    - `eco_pap_extend` keeps Char unboxed (consistent with Int/Float)

34. **Stack Unwinding for RSP-Relative StackMaps** - ✅ Implemented (Apr 14)
    - `StackUnwind.cpp`/`hpp` interprets LLVM stack maps correctly
    - Covers RSP-relative locations (occur even with `-fno-omit-frame-pointer`)
    - External GC root scanning support added to RootSet
    - EcoGCPrepare attaches live GC roots on allocation ops
    - Fast/slow allocation paths with allocation coalescing
    - eco.call and eco.papExtend supply GC roots

**Current E2E Test Status**:
- Compilation through front-end and back-end to JIT execution working
- All elm-test tests passing
- All E2E tests passing (across elm-core, elm-json, elm-http, elm-regex, elm-time, elm-url packages)
- Parallel test execution with process isolation
- Bootstrap compilation in progress — GC stack root tracing now complete, monomorphization substantially hardened
- ~50+ new E2E test cases added (Apr 2026) covering embedded constants, Maybe/List/Result type mismatches, recursive values

**Deliverables**:
- [x] Code generation modules (11 modules in `Compiler/Generate/MLIR/`)
- [x] MLIR builder utilities (`elm-mlir` package vendored)
- [x] Case/if control flow using SCF dialect
- [x] Indirect call support
- [x] Symbol table management (multiple Elm modules via GlobalGraph)

### 4.3 Compiler Testing

**Status**: Substantially Complete (All Tests Passing)

Comprehensive testing for the compiler backend.

**Implementation** *(Jan 14-19, 2026; enhanced Feb-Mar 2026)*:
- 69+ test files in `compiler/tests/TestLogic/Generate/CodeGen/`
- `Invariants.elm` provides shared verification logic for MLIR AST inspection
- `TestPipeline.elm` consolidates common test pipeline (90+ test files)
- Tests validate CGEN_001 through CGEN_057+ invariants
- Property-based testing with elm-test
- GlobalOpt invariants added (Feb 8, 2026; GOPT_011-014 added Mar 17-18, 2026)
- Code coverage tooling: `compiler/elm-coverage/` with elm-test-rs integration (Mar 17, 2026)
- Coverage-driven test generation plan: `plans/coverage-driven-test-generation.md`

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
| `CmpiPredicateAttr.elm` | CMPI predicate attribute validation *(Mar 17)* |
| `SsaUniqueness.elm` | SSA variable uniqueness across scopes *(Mar 15)* |
| `GlobalOpt/CallInfoCompleteTest.elm` | GOPT_011-014 calling convention invariants *(Mar 17-18)* |

**New SourceIR Test Suites** *(Mar 2026)*:
| Test Module | Description |
|-------------|-------------|
| `BytesFusionCases.elm` | Bytes fusion coverage *(Mar 17)* |
| `BoolCaseCases.elm` | Bool case expression edge cases *(Mar 17)* |
| `ClosureAbiBranchCases.elm` | Closure ABI across case branches *(Mar 17)* |
| `KernelCtorArgCases.elm` | Kernel constructor argument handling *(Mar 17)* |
| `KernelComparisonCases.elm` | Kernel comparison operators *(Mar 17)* |
| `KernelCompositionCases.elm` | Kernel function composition *(Mar 17)* |
| `KernelContextCases.elm` | Kernel context handling *(Mar 17)* |
| `KernelHigherOrderCases.elm` | Kernel higher-order functions *(Mar 17-18)* |
| `KernelIntrinsicCases.elm` | Kernel intrinsic operations *(Mar 17)* |
| `KernelOperatorCases.elm` | Kernel operators *(Mar 17)* |
| `MonoCompoundCases.elm` | Compound monomorphization cases *(Mar 17)* |
| `TailRecLetRecClosureCases.elm` | Tail-rec with let-rec closures *(Mar 14)* |
| `LetDestructFnCases.elm` | Let-bound destructuring with functions *(Mar 13)* |
| `PolyChainCases.elm` | Polymorphic chain cases *(Mar 11)* |
| `ParamArityCases.elm` | Parameter arity validation *(Mar 18)* |
| `AccessorScopingCases.elm` | Accessor type-variable scoping *(Mar 28)* |
| `IfNodeTypeCases.elm` | If-expression node type cases *(Mar 27)* |
| `CaseSafepointLeakCases.elm` | Case branch SSA variable leak detection *(Mar 27)* |
| `IfLetSafepointCases.elm` | If/let safepoint variable leak detection *(Mar 27)* |
| `SpecializeAccessorCases.elm` | Record accessor specialization *(Mar 26)* |
| `SpecializeConstructorCases.elm` | Constructor specialization *(Apr 7)* |
| `TypeAliasCtorCases.elm` | Type alias record constructor annotations *(Apr 11)* |
| `PhantomTypeVarCases.elm` | Phantom type var normalization *(Apr 11)* |

**New Invariant Tests** *(Mar 27 – Apr 2026)*:
| Test Module | Description |
|-------------|-------------|
| `NodeVarConstrained.elm` | TYPE_007: unconstrained node variables detection *(Mar 27)* |
| `PostSolveNodeTypeGrounded.elm` | POST_010: post-PostSolve type grounding *(Mar 28)* |
| `ProjectionHeapLayoutConsistency.elm` | Projection heap layout consistency *(Apr 3)* |
| `MonoVarGlobalArityConsistency.elm` | MONO_027: function/type arity match *(Apr 1)* |

**Removed Tests** *(Feb 26, 2026)*:
- `OptimizeEquivalent.elm` - Removed; was only for parity during early development (typed vs untyped Optimized IR equivalence check)

**E2E Test Suites** *(Feb 23-24, 2026)*:
| Suite | Location | Description |
|-------|----------|-------------|
| elm-core | `test/elm-core/` | Basics, List, String, JsArray, Debug tests |
| elm-json | `test/elm-json/` | Decode + roundtrip tests for all JSON types |
| elm-http | `test/elm-http/` | HTTP header and JSON body tests |
| elm-regex | `test/elm-regex/` | Contains, find, fromString, split tests |
| elm-time | `test/elm-time/` | POSIX time and time parts tests |
| elm-url | `test/elm-url/` | Percent encode/decode and roundtrip tests |

**Bootstrap E2E Test Cases** *(Mar 14-18, 2026; Apr 2026)*:
| Test | Description |
|------|-------------|
| `ClosureCaptureBoolTest.elm` | Bool capture boxing across closure boundary |
| `TailRecBoolCarryTest.elm` | Bool carry through tail recursion |
| `TailRecDeciderSearchTest.elm` | Decider search in tail-recursive context |
| `PapExtendArityTest.elm` | PAP extend arity correctness |
| `PapSaturatePolyPipeMinimalTest.elm` | PAP saturation with polymorphic pipes |
| `CharCasePredicateTest.elm` | Char case with CMPI predicates |
| `LetRecClosureTest.elm` | Recursive closure self-capture |
| `InlineVarCollisionTest.elm` | Variable collision from inlining |
| `CaseFanOutShadowTest.elm` | Case fan-out with shadowed vars |
| `StringEscapeSingleQuoteTest.elm` | String escaping in MLIR |
| `CaseNestedRecordAccessTest.elm` | Nested record access in case |
| `ListAnyBoolTest.elm` / `ListMapBoolTest.elm` | Bool list operations |
| `CaseSingleCtorBoolTest.elm` | Single-ctor Bool unboxing |
| `SingleCtorPair*Test.elm` | 10+ tests for single-ctor pair type combinations |
| `CapturedStagedFuncCallTest.elm` | Captured function with staged calling |
| `DictMapStagedCaptureTest.elm` | Dict.map with staged capture |
| `TypeAliasCtorTest.elm` | Type alias record constructor annotations *(Apr 11)* |
| `PhantomTypeVarTest.elm` | Phantom type var spec key normalization *(Apr 11)* |
| `PureRecursiveValueThunkTest.elm` | Recursive zero-arity value thunks *(Apr 9)* |
| `PureMutualRecursiveValueTest.elm` | Mutual recursive zero-arity values *(Apr 9)* |
| `MaybeMap*Test.elm` | 7 tests for Maybe.map type mismatch scenarios *(Apr 10)* |
| `ListMapTypeMismatchTest.elm` | List.map type mismatch *(Apr 10)* |
| `ResultMapTypeMismatchTest.elm` | Result.map type mismatch *(Apr 10)* |
| `Embedded*Test.elm` | ~27 tests for embedded constant handling (Nil, Nothing, True/False, Unit, EmptyString) *(Apr 9)* |
| `Unbox*Test.elm` | 7 tests for unboxing wrappers around embedded constants *(Apr 9)* |
| `CombinatorListStringTest.elm` | Combinator list string operations *(Apr 5)* |
| `BytesDecoderMutualRecursiveTest.elm` | Mutual recursive bytes decoders *(Apr 9)* |
| `JsonDecoderSelfRecursiveTest.elm` | Self-recursive JSON decoders *(Apr 9)* |

**Specialization Test Suites** *(Feb 25, 2026)*:
| Suite | Description |
|-------|-------------|
| `SpecializePolyTopCases.elm` | Top-level polymorphic function specialization |
| `SpecializePolyLetCases.elm` | Let-bound polymorphic function specialization |

**Deliverables**:
- [x] Test suite infrastructure (`Invariants.elm`, `TestPipeline.elm`)
- [x] Elm test programs (120+ test files, including 15+ new SourceIR suites and 16+ bootstrap E2E tests)
- [x] MLIR AST validation
- [x] Code coverage tooling (`compiler/elm-coverage/`)
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

**Status**: Complete (Stage 9 — Unified `eco` Single-Binary Compiler)

Connect all compiler stages into a working pipeline.

**Current Implementation**:
- A single `eco` binary embeds the Elm frontend, MLIR backend, RS4GC + LLVM lowering, lld linker, and runtime libraries — JIT and AOT both flow through `runEcoBackend` / `EcoBackend`.
- ecoc driver supports multiple emit modes: `-emit=jit`, `-emit=llvm`, `-emit=mlir-llvm`, `-emit=mlir`
- Kernel modules linked as static libraries
- `eco-boot-native` AOT path drives Stages 6–8 of bootstrap; `eco` target depends on bootstrap Stage 8.

**Stage 9 — Unified `eco` Backend** *(May 19 – Jun 1, 2026)*: JIT and AOT lowering pipelines were unified behind a shared backend so the two code paths can never diverge again. Phases:

- **Phases 1 & 2** *(May 19)*: Centralize RS4GC + frame-pointer logic in `EcoBackend`. Previously each driver wired the GC-strategy and `frame-pointer=all` independently.
- **Phase 3** *(May 19)*: Move TargetMachine + DataLayout setup before RS4GC.
- **Phase 3.3** *(May 19)*: Move `opt` + object emission into `runEcoBackend`.
- **Phase 4** *(May 19)*: Route JIT transformers through `runEcoBackend` — the JIT and AOT now share the same lowering callback, just with different sinks (in-process EE vs `.o` file).
- **Phase 5** *(May 19)*: Add AOT E2E test runner + bootstrap gates; default AOT-test parallelism = system core count; ninja clean no longer wipes the AOT E2E shadow tree.
- Stage 9 follow-ups: Force-link `ElmKernel_Utils` in `eco-boot-native`; fix Task-Never type-soundness hole on `Eco.NativeDriver.lowerAndLink`; removed the Stage 9c "binary eco == eco2" self-build check (subsumed by Stage 7/8 MLIR fixed point).
- Plan: `plans/stage9-eco-single-binary.md`. Reports: `design_docs/converge-pipelines.md`, `design_docs/lld-in-eco.md`.

**Tasks**:
- [x] Wire up Guida frontend to MLIR backend
- [x] Connect MLIR lowering passes (EcoToLLVM)
- [x] Integrate LLVM code generation (via MLIR ExecutionEngine)
- [x] JIT execution of compiled Elm programs
- [x] AOT compilation producing standalone native binaries *(eco-boot-native, then unified `eco`)*
- [x] Produce working native binaries from Elm source (without JIT)
- [x] Unify JIT and AOT through `runEcoBackend` / `EcoBackend` *(May 19, 2026)*
- [x] AOT E2E test runner + bootstrap gates *(Phase 5, May 19, 2026)*

**Deliverables**:
- [x] End-to-end JIT compilation working
- [x] Pipeline orchestration code (`ecoc.cpp`, compile scripts)
- [x] AOT native binary generation
- [x] Unified `eco` single-binary compiler

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

**Status**: Substantially Complete (Portable Static-MUSL Distribution Bundle Landed)

Create robust build system and distribution packages.

**Current Implementation** *(Feb 26-27, 2026; static-link pipeline May 24 – Jun 2, 2026)*:
- `eco-kernel-cpp/CMakeLists.txt` integrated into top-level CMake build
- Three-stage bootstrap build configurations:
  - `compiler/elm-bootstrap.json` - Stock Elm compiler → `eco-boot.js` (uses XHR IO)
  - `compiler/elm-kernel.json` - Eco compiler → `eco-node.js` (uses kernel IO)
- Bootstrap entry point: `compiler/bin/eco-boot-runner.js`
- Compiler frontend migrated from npm to pnpm; Elm toolchain (`elm-test-rs`, `elm`) fetched into `build/toolchain/bin/` via CMake *(May 22, 2026)*.

**Static-link pipeline — Stages A → C** *(May 24 – Jun 2, 2026)*: a stack of build modes that progressively eliminate dynamic-library dependencies, culminating in a fully portable distribution:

- **Stage A** *(May 24)*: `-DECO_STATIC=ON` produces an `eco` binary that depends only on glibc + ld-linux (no system libstdc++/libc++ pulled in dynamically).
- **Stage A.5** *(May 25)*: AOT-built binaries also minimal-deps glibc under `-DECO_STATIC=ON`. `EcoBootConfig.h` now emits absolute `.a` paths for the runtime / kernel archives so AOT links see the same archives as the in-tree build.
- **Stage B** *(May 27)*: Static (musl + libc++) `eco` build — toolchain + portability fixes for a fully-static binary independent of the host glibc.
- **Stage B.5** *(May 28)*: AOT-link path for the fully-static MUSL `eco` binary — the AOT-generated executables also link against the musl/libc++ toolchain.
- **Stage C** *(Jun 2)*: Portable static `eco` distribution bundle — ship `eco` + its archives + a minimal kernel-source tree so an end user can compile Elm without a system toolchain.
- Runtime fix: GC heap corruption under static musl — `initStackMapFromSelf` now accepts musl's `dlpi_name="/proc/self/exe"` (musl reports an empty soname for the main executable, where glibc reports the basename).
- Build infrastructure: static MUSL build uses a separate `build-static/` folder (gitignored) so it does not collide with the dev build; section added to bootstrap guide on creating the static binary; build-flags status report (`design_docs/lld-in-eco.md` covers embedding `lld` into the unified binary).

**Tasks**:
- [ ] Evaluate whether CMake is the right tool (needs to invoke Elm compiler and tools outside normal C/C++ toolchain)
- [ ] Consider alternatives or CMake extensions for non-C/C++ tool invocation
- [x] Create Dockerfile encapsulating all build dependencies *(Dockerfile based on Debian Bookworm)*
- [x] Integrate eco-kernel-cpp into CMake build *(Feb 26, 2026)*
- [x] Create bootstrap and kernel build configurations *(Feb 27, 2026)*
- [x] CMake targets for `eco`, bootstrap stages, AOT-link, static-build pipeline
- [x] Build with statically linked libc (musl) for cross-platform Linux distribution *(Stage B, May 27, 2026)*
- [x] Portable static-musl distribution bundle *(Stage C, Jun 2, 2026)*
- [ ] Create Debian package (.deb)
- [ ] Create npm package for Node.js distribution
- [ ] Document build process and dependencies

**Deliverables**:
- [x] Dockerfile for reproducible builds *(Dockerfile, .dockerignore)*
- [x] eco-kernel-cpp CMake integration
- [x] Bootstrap build configurations (`elm-bootstrap.json`, `elm-kernel.json`)
- [x] CMake targets for bootstrap pipeline + AOT E2E shadow tree
- [x] Static Linux binary (musl-linked, Stage B)
- [x] Portable static-musl distribution bundle (Stage C)
- [ ] Debian package
- [ ] npm package
- [ ] Build system documentation

#### 5.1.4 Linker Integration & Runtime Libraries

**Status**: In Progress (Kernel Static Libraries Complete)

Link generated code with ECO runtime and Elm base libraries.

**Current Implementation** *(updated Feb 26, 2026)*:
- Elm kernel modules integrated into CMake build as static libraries (`elm-kernel-cpp/`)
- Eco IO kernel modules integrated as static libraries (`eco-kernel-cpp/`)
- All kernel exports imported into ecoc
- Real kernel implementations linked instead of stub injection
- Elm compiler code added to CMake build
- Two kernel library sets:
  - `elm-kernel-cpp/` - Standard Elm kernel (272 functions across 12 packages)
  - `eco-kernel-cpp/` - Eco IO kernel (6 modules: File, Console, Env, Process, MVar, Runtime)

**Tasks**:
- [x] Create linkable libraries (.a) for kernel operations implemented in C++
- [x] Integrate elm-kernel-cpp modules into CMake build as static libs
- [x] Integrate eco-kernel-cpp modules into CMake build as static libs *(Feb 26, 2026)*
- [x] Unified `eco` binary embeds lld and drives MLIR → ELF + runtime/kernel linking end-to-end *(May 19, 2026)*
- [x] AOT `.o` link-only fast path on `eco-boot-native` (Stage 6 relink 3 m 26 s → 0.6 s) *(May 8, 2026)*
- [ ] Extract elm/core and other ported Elm base libraries into standalone packages
- [ ] Design library discovery and linking as part of eco compilation flow
- [ ] Handle native library dependencies
- [ ] Support dynamic linking options (.so)

**Deliverables**:
- [x] Kernel static libraries (elm-kernel-cpp modules)
- [x] IO kernel static libraries (eco-kernel-cpp modules) *(Feb 26, 2026)*
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

**Status**: **Complete** *(May 14, 2026 — 8-stage bootstrap end-to-end)*

The full 8-stage bootstrap from `guides/bootstrap.md` runs end-to-end:

| Stage | Output | Notes |
|---|---|---|
| 1 | `guida.js` (stock Elm, no `--optimize`) | XHR IO |
| 2 | `eco-boot.js` (self-compile with kernel IO) | |
| 3 + 4 | `eco-boot-2.js` ≡ `eco-boot-3.js` | JS fixed point reached |
| 5 | `eco-compiler.mlir` | First MLIR self-output |
| 6 | native ELF `eco-compiler` (via `eco-boot-native`) | |
| 7 | `eco-compiler-boot.mlir` + native ELF | Native compiler self-compiles |
| 8 | `eco-compiler-boot-2.mlir` ≡ `eco-compiler-boot.mlir` | **MLIR fixed point reached** |

The Stage 7 / Stage 8 MLIR outputs are byte-identical, so the compiler reaches a true fixed point. The two Stage 8 native ELFs are the same size and differ only in ~3.6 KB inside `.strtab` (ASCII hex hash suffixes produced non-deterministically by the LLVM lowering pipeline + lld), not in any code or data the compiler emits.

**Stage 8 determinism** *(May 23, 2026)*: `__eco_str_case_<N>_<i>` symbols are now numbered by a counter rather than by pointer identity, so the symbol names are stable across runs and bootstrap stages.

**Bootstrap ordering & lean test rebuild** *(May 22-23, 2026)*: bootstrap stages are forced to run in their documented order; the `full` target and E2E tests now only need Stage 1 of bootstrap to be present (previously they would consume stale `.mlir` from later stages). The Stage 9c "binary eco == eco2 self-build" check was removed — the Stage 7 / Stage 8 MLIR fixed point already subsumes it.

**Current Progress** *(Mar 11 – May 14, 2026)*:
- Active bootstrap attempt revealed ~20+ codegen and runtime bugs, now fixed (see §4.2 issues 16-31)
- Monomorphizer performance profiling and optimization (TypeSubst UF representation, dict handling efficiency)
- New calling convention (`CallGenericApply`) added as safe fallback for complex call patterns
- Typed decision tree paths (`MonoDtPath`) eliminate cross-type guessing in pattern codegen
- Kernel improvements: Http/Process return types adjusted, MVar parameter fix, List fromArray/toArray identity fix
- Bootstrap documentation updated: `guides/bootstrap.md` (extended to Stage 8)
- **MonoDirect removed** *(Mar 31)*: Incomplete alternative monomorphizer removed to unblock refactoring
- **Int MVarIds** *(Mar 30 – Apr 1)*: Replaced String-based type variable names with Int IDs from monomorphization onward, with `AssignMVarIds` module for global unique ID assignment
- **Solver root-backed MVarIds** *(Apr 4)*: `SolverRoots` module normalizes solver variables to union-find roots after constraint solving; ensures same solver root → same MVarId
- **Monomorphization correctness fixes** *(Apr 1-11)*:
  - Scheme freshening with globally unique MVarIds (no collision with caller substitution)
  - `applySubstWithFreeVars` prevents cross-scheme contamination
  - `PendingCall` variant for deferred specialization of nested polymorphic calls
  - Per-binding MVarId isolation in cycle members
  - Constructor type annotations added to scheme cache
  - VarLocal/TrackedVarLocal prefer VarEnv monomorphic type over re-derivation
  - Type alias analysis fixes (TAlias args/body branch)
  - Phantom type var normalization (surviving MVar → sentinel values in spec keys)
  - Fast path for non-polymorphic functions (skip scheme creation)
- **Memory performance** *(Apr 10-11)*: Deferred callEdges/specHasEffects to post-worklist pass, Dict→Array/BitSet conversions, String→Int ID comparison keys, batched record updates
- **GC stack root tracing complete** *(Apr 11-13)*: See §1.2.3 and §3.3
- **Large object allocation** *(Apr 8)*: First pass at pinned large object allocation and GC
- **Registry caching** *(Apr 3)*: 30-minute check interval for registry.dat, `--refresh-registry` flag
- **Kernel safety fixes** *(Apr 7)*: StackRootGuard RAII helper roots HPointers across allocations, kernel functions fixed to return valid Tasks
- **Runtime fixes**: 64MB default stack size, Env::init for native binary, regex/http pointer safety via side tables
- **GC stack root hardening** *(Apr 13-17)*:
  - Shadow stack root ranges in `RootSet::stack_ranges` — covers dynamic stack arrays (closure arg buffers) that static stack maps cannot describe
  - Closure wrapper functions (`__closure_wrapper_*`) now emit `__eco_safepoint_marker` before the target call and before every `eco_alloc_*` boxing site, tracking loaded arg HPointers as live roots
  - `EcoGCPrepare` switched to MLIR's inter-block `Liveness` analysis (previously block-local heuristic), union with front-end's operands so root sets only grow; `func.walk()` visits nested `scf.while`/`scf.if` regions so in-loop `eco.papExtend`/`eco.call` are covered
  - Safepoint marker positioned immediately before each GC-triggering call inside closure dispatch helpers (`emitFastClosureCall`, `emitClosureCall`, `emitInlineClosureCall`, `lowerSegmentationUnknown`, `lowerGenericApply`) so `StatepointConversion::findTargetCall` latches onto the correct target
  - Arg-array rooting in `eco_apply_closure`, `eco_apply_segmentation_unknown`, `eco_pap_extend`, and `eco_closure_call_saturated` — raw `uint64_t*` buffers registered via `eco_gc_push_stack_range` so GC can evacuate the alloca'd arrays in place
  - Closure pointer re-resolution: `eco_pap_extend` re-resolves `old_closure` from authoritative `closure_hptr` after `Allocator::allocate()`; `buildEvaluatorArgs` takes `closure_hptr` and re-reads via `hpointerToPtr` before each `values[i]` load
  - `EcoGCPrepare` alloc-group/call-safepoint operand union: step 3 unions computed liveness with front-end operands; step 4 (and step 2 for alloc groups) adds the op's own `!eco.value` operands so values dead after the op but needed during multi-statepoint lowering remain tracked
  - External GC root scanning: `MVar::s_mvars` and `Runtime::s_savedState` registered via `Eco_Kernel_{MVar,Runtime}_register_gc_roots` + aggregator `Eco_Kernel_register_all_gc_roots`; invoked after `Allocator::initThread()` in AOT and (weakly) JIT entries
  - Constant filtering: embedded constants (Nil, True, False, Unit, etc.) excluded from GC live root sets in `EcoGCPrepare`; `StatepointConversion::stripIntToPtr` returns `nullptr` for `inttoptr(ConstantInt)` so constants never become GC roots; `ThreadLocalHeap` skips `gc.relocate` on constants
  - `Export::toPtr` hardened: any non-zero constant returns `nullptr`, non-zero padding asserts instead of fabricating a raw pointer
  - GC diagnostics instrumentation wired behind `ECO_GC_DEBUG` CMake option (default on in Debug builds); see `guides/gc-diagnostics.md`
  - GC Liveness audit pass (`ECO_GC_DEBUG_LIVENESS` flag, `EcoGCLivenessAudit.cpp`) — skips `eco.gc_group_member` (covered by leader's root set)
  - Nursery ghost-data clearing: `clearToSpaceFreeRegion()` zeroes all free to-space bytes after each minor GC; `ECO_GC_DEBUG` adds `isInFromSpaceAllocatedRegion`, `isInToSpaceAllocatedRegion`, `debugAssertValidNurseryPointer` asserting no nursery pointer targets unallocated space
  - Closure Cheney-copy fix: now uses `hdr->size` instead of `n_values` (which was wrong)
- **Allocation groups — single safepoint per group** *(Apr 16)*: adjacent fixed-size alloc ops identified by `EcoGCPrepare` now lower to a single fast/slow/merge CFG. Fast path calls `eco_gc_alloc_region_fast(totalBytes)`; on null, the slow path emits one `__eco_safepoint_marker` + `eco_gc_alloc_region_slow`. Each member is initialized at its offset via new `eco_init_*_at` runtime functions that write headers/fields at a pre-allocated pointer and return an HPointer. `EcoGCPrepare` excludes variable-size ops (`AllocateClosureOp`, `AllocateOp`) from groups and caps group size below the 32 KiB large-object threshold. Plan: `plans/allocation-group-single-safepoint.md`.
- **Type-aware `buildEvaluatorArgs`** *(Apr 15)*: previously re-boxed all unboxed closure captures as `ElmInt` regardless of type. Now accepts an `EvalParamLayout` specifying each slot's type, dispatching to `eco_alloc_int`/`_float`/`_char` accordingly. MLIR emitter tracks accumulated arg types across staged calls and emits a `_capture_abi` attribute; LLVM lowering builds and passes a layout global. `eco_pap_extend` paths that previously pre-boxed Char now keep it unboxed (zero-extended to i64), consistent with Int and Float. Correct primitive tags now appear in `Debug.log` output. Shared `emitRootedBoxedArgsArray` helper encapsulates alloca → zero-init → GC-root → box-and-populate, eliminating duplication between `lowerGenericApply` and `lowerSegmentationUnknown`.
- **Full stack unwinding** *(Apr 14)*: `StackUnwind.cpp`/`hpp` implemented to correctly interpret LLVM stack maps that are sometimes RSP-relative rather than RBP-frame relative — required even when compiled with `-fno-omit-frame-pointer`. Plan: `plans/stackmap-unwinder-gc-roots.md`.
- **eco.value → ptr addrspace(1)** *(Apr 17)*: `!eco.value` now lowers to `ptr addrspace(1)` (GC-managed pointer) instead of `i64`. `ptrtoint`/`inttoptr` conversions appear only at heap/global/closure storage boundaries (i64 memory slots) and for embedded-constant encoding. `BFTypeConverter` unified with `EcoTypeConverter`; all BF runtime LLVM decls use `ptr<1>` for HPtr params/returns; `widenFieldToI64` replaces ad-hoc `ZExtOp(i1→i64)` for Bool constants (pointer ZExt would crash). `widenToI64ForInit` routes through `castToHPtr` first so inverse casts cancel in the reconcile pass. ADT case bit manipulation converts `ptr<1>` scrutinee to `i64` via `valueToI64` before `LShr`/`And`. New invariant **REP_LLVM_001**. Plan: `plans/eco-value-to-ptr-addrspace1.md`. 114 test `.mlir` files updated from hardcoded `i64` runtime signatures to `ptr<1>`.
- **RewriteStatepointsForGC analysis** *(Apr 16)*: full analysis of LLVM's pass in `design_docs/rewrite-statepoints-for-gc/{overview,algorithm,invariants,eco-comparison}.md` for reference when evolving `StatepointConversion`.

**Requirements**:
- [x] Compiler backend substantially complete (§4)
- [x] Runtime GC stack root tracing implemented (§1.2.3, §3.3)
- [x] All dependencies needed for self-compile ported (§2) *(remaining stubs — browser, virtual-dom — are not on the compiler's dependency closure)*
- [x] Calling convention edge cases resolved (per-instance kernel ABI, unboxed primitive return ABI)
- [x] Extended stress testing under GC pressure *(see §1.2 GC pressure suite + sustained Stage 7 self-compile workload)*

**Deliverables**:
- [x] Native ECO compiler binary *(`compiler/build-kernel/bin/eco-compiler-boot`)*
- [x] Build instructions *(`guides/bootstrap.md`)*
- [x] Verification tests *(Stage 3+4 JS fixed point, Stage 7+8 MLIR fixed point, Stage 5 MLIR-equivalence runner: 689 / 690 equivalent — the remaining diff is the expected Int-precision case)*

### 5.3 Self-Compilation Milestone

**Status**: **Achieved** *(May 14, 2026)*

Self-compilation: ECO compiles itself through its own native output and the result reproduces itself.

**Success Criteria**:
- [x] ECO compiles its own source code *(Stages 5, 7, 8)*
- [x] Generated binary passes all tests *(elm-test-rs full suite + E2E `cmake --build build --target full`)*
- [x] Binary is reproducible *(MLIR fixed point; native ELF identical modulo `.strtab` non-determinism from LLVM/lld, not from the compiler)*
- [ ] Performance meets baseline requirements *(§6.1 not started — pre-release benchmarking still open)*

**Milestone**: This marks the **0.1.0** release readiness point. Performance benchmarking and release packaging (§6) are the remaining work toward a tagged 0.1 release.

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
- **Node.js**: For bootstrap compiler execution and XHR IO layer
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

**Current Phase**: 0.1.0 Milestone Reached — Unified `eco` Single-Binary Compiler + Portable Static Distribution Bundle
**Last Updated**: 2026-06-02

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

**Changes - Feb 19 to Feb 25, 2026**:

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

**Changes - Jan 21 to Feb 12, 2026**:

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

**Most Recent Changes — May 19 to Jun 2, 2026**:

- **Stage 9 — Unified `eco` Single-Binary Compiler (Phases 1–5)** *(May 19, 2026)*:
  - JIT and AOT lowering pipelines unified behind `runEcoBackend` / `EcoBackend`. Phases 1 & 2 centralize RS4GC + frame-pointer logic; Phase 3 moves TargetMachine + DataLayout setup before RS4GC; Phase 3.3 moves `opt` + object emission into the shared backend; Phase 4 routes JIT transformers through it; Phase 5 adds an AOT E2E test runner + bootstrap gates (parallelism = system core count; ninja clean preserves the AOT shadow tree).
  - Made `eco` target depend on bootstrap Stage 8. Force-link `ElmKernel_Utils` in `eco-boot-native`. Fix Task-Never type-soundness hole on `Eco.NativeDriver.lowerAndLink`. Removed the Stage 9c "binary eco == eco2 self-build" check (subsumed by Stage 7/8 MLIR fixed point).
  - Plan: `plans/stage9-eco-single-binary.md`. Reports: `design_docs/converge-pipelines.md`, `design_docs/lld-in-eco.md`.

- **Static Distribution Pipeline (Stages A → C)** *(May 24 – Jun 2, 2026)*:
  - **Stage A**: `-DECO_STATIC=ON` produces a minimal-glibc-deps `eco` binary. **Stage A.5**: AOT-built binaries also minimal-deps glibc; `EcoBootConfig.h` emits absolute `.a` paths so AOT links see the same archives as the in-tree build.
  - **Stage B**: static (musl + libc++) `eco` build — toolchain + portability fixes. **Stage B.5**: AOT-link path for the fully-static MUSL `eco` binary. **Stage C**: portable static `eco` distribution bundle (Jun 2 — the most recent commit).
  - Runtime fix: `initStackMapFromSelf` now accepts musl's `dlpi_name="/proc/self/exe"` (musl reports an empty soname for the main executable). Without this, the GC stack-map probe missed the main binary under static musl and the bootstrap-stage-7 workload corrupted the heap.
  - Static-MUSL build uses a separate `build-static/` folder (gitignored). Build-flags status report added; section in the bootstrap guide on creating the static binary.

- **Defer Eager Kernel Task IO via `Task_Binding`** *(May 31, 2026)*:
  - Every C++ symbol returning an Elm `Task` in `eco-kernel-cpp/` and `elm-kernel-cpp/` now performs its IO inside a `Task_Binding` callback rather than at kernel-call time. The scheduler can interleave outstanding bindings; blocking syscalls (`curl_easy_perform`, `waitpid`) park onto an async worker pool and resume the parked closure.
  - Shared helpers in `runtime/src/platform/TaskBinding.hpp` (`makeBinding`, `makeAsyncBinding`); Eco-side `succeed*` / `fail*` HPointer wrappers in `eco-kernel-cpp/src/eco/TaskBinding.hpp`.
  - Structured IO errors plumbed end-to-end: kernels return rich error values (errno + path + operation context) which flow through the scheduler to the final `Exit`.
  - Effect-manager setup task built by invoking a saturated closure with a Task-return-type assertion (prevents a class of silent type-soundness holes).
  - New invariants **KERNEL_TASK_IO_001** and **KERNEL_TASK_IO_002**. Plan: `plans/defer-eager-kernel-tasks-via-binding.md`. Theory: [Kernel Task Deferral](design_docs/theory/kernel-task-deferral.md). Error-handling audit on the Eco kernel API.

- **HTTP Kernel Rebuild** *(May 31, 2026)*:
  - elm/http + `Eco.Http` reimplemented as a real libcurl kernel on the single-threaded heap, with a full E2E test suite (HTTP test failures in Gate A + B fixed).
  - `Http.track` progress streaming (periodic progress events via the effect manager).
  - Native package downloads fixed: send `Content-Length: 0` on empty-body POST/PUT/PATCH (registry returned 411); accept all libcurl-supported encodings so gzip downloads from the package server work; fetch errors propagate as structured `Http.Error`s.
  - Package unzip: create missing directories on demand; safe handling of empty-string path; present zip paths in full including the unzip prefix (parity with the JS kernel).

- **`eco.safepoint` Op Retired** *(May 19, 2026)*:
  - With the Apr 22 RS4GC migration, every non-leaf call inside a `gc "eco-gc"` function is wrapped in a `gc.statepoint` by LLVM. The front-end `eco.safepoint` marker op was therefore redundant; it was removed, and its GC root hints are threaded directly onto the existing `GCRootCarrier` ops (`eco.call`, `eco.papExtend`, allocation ops).
  - `EcoGCPrepare` no longer emits liveness hints — RS4GC recomputes liveness from `ptr addrspace(1)` types alone.
  - `EcoUnboxedAggCrossSpec` updated to strip aggregate-typed values from the (now-removed) safepoint op shape during transition; the cleanup also dropped the experimental `-enable-unboxed-agg` pass pipeline.

- **Bytes-Fusion Phase 4+5** *(May 23, 2026)*:
  - Landed phases 4 and 5 of the bytes-fusion roadmap and raised the per-function inliner cap so fused encoder/decoder pipelines can be inlined into their callers. Added an escape hatch for partial fusion when the Elm AST doesn't fully reify to the BF dialect.
  - `elm/bytes` runtime: zero-copy slices, single-copy memcpys, large-object-table (LOT)-aware allocations.
  - Plans: `plans/bytes-fusion-broader-recognition.md`, `plans/bytes-fusion-escape-hatch.md`.

- **Escape-Analysis Groundwork (Phase 1 + Phase 2 scaffolding)** *(May 19-21, 2026)*:
  - **Phase 1**: widened `construct.*` / `make.*` / `eco.call` ops to accept aggregate operands so cross-spec aggregate values can flow through them.
  - **Phase 2 scaffolding** (§9.1): `project.*` ops made nested-aggregate-ready; cross-spec finished the nested-shape DSL use side and fixtures.
  - **Wrapper FCA fix**: eliminated register-form FCA-of-GC-pointer values from wrapper functions — investigation showed RS4GC does not handle heap pointers inside an LLVM `FirstClassAggregate`. Updated plan reflects the outcome.
  - Removed the old `-enable-unboxed-agg` pass pipeline (predecessor experiment retired).
  - Design docs: `design_docs/escape-analysis.md`, `design_docs/escape-analysis-status.md`; plan for moving forward.

- **Compiler Front-End Perf & Telemetry** *(May 20-23, 2026)*:
  - Front-end timing stats added; warm-cache GC cycle fix in `eco-boot-native` so repeated compiles inside one process don't accumulate from-space ghost data.
  - `eco-config.json` for tunable compiler settings (heap parameters, inliner caps, fusion thresholds). Plan: `plans/eco-config-tunable-parameters.md`.
  - Shrunk `.ecot` files via String interning into a per-file string table; dropped redundant unconsumed fields.
  - Wrap Stage 5 / 7a / 7b `.mlir` emits in `/usr/bin/time -v` + new `mlir-timing-report` target (hooked into bootstrap).
  - Skip writing `.eco` / `artifacts.dat` files when emitting MLIR only (and the JS path is symmetric).
  - Adjusted default heap parameters after a sweep over the optimal combinations for the Stage 7 self-compile.

- **Runtime String Perf** *(May 20-22, 2026)*:
  - `runtime/string`: cut allocations + memcpys in string ops.
  - Lowered `string_tiny_slice_limit` from 8 K to 128 — most slices are short, so the previous cap was forcing unnecessary leaf copies.
  - Added a per-thread String-allocation size histogram to `GCStats`, populated from `HeapHelpers::allocString` via a `recordStringAllocOnCurrentThread` hook.

- **Build System Polish** *(May 22 – Jun 2, 2026)*:
  - Compiler frontend migrated from **npm → pnpm**; Elm toolchain (`elm-test-rs`, `elm`) fetched into `build/toolchain/bin/` via CMake.
  - `compiler/CMakeLists.txt`: add `build-kernel/eco-stuff/` to the kernel build's cache search so the per-builddir caches are seen.
  - Set default AOT-test parallelism to system core count; stop `ninja clean` from wiping the AOT E2E shadow tree.

- **Cleanup** *(May 19 – Jun 2, 2026)*:
  - Removed the unboxed-aggregate pass pipeline + `-enable-unboxed-agg` flag (predecessor experiment).
  - Removed printing of LLVM stats.
  - Tidied old design files; updated stale comment; note about unhandled errors.

**Most Recent Changes — Apr 28 to May 14, 2026**:

- **0.1.0 Milestone — Full Binary Self-Compilation** *(May 14, 2026)*:
  - The 8-stage bootstrap from `guides/bootstrap.md` runs end-to-end. Stages 3+4 reach a JS fixed point. Stages 7+8 produce byte-identical MLIR (`eco-compiler-boot.mlir` ≡ `eco-compiler-boot-2.mlir`) — the **native compiler is at a true fixed point at the MLIR level**.
  - The two Stage 8 native ELFs are the same size and differ only in ~3.6 KB inside `.strtab` (ASCII hex hash suffixes produced non-deterministically by the LLVM/lld pipeline). The compiler emits the same code; only downstream toolchain non-determinism remains.

- **Tuple/Record Specialised-Element MonoType Fix** *(May 14, 2026)*:
  - `Compiler/Monomorphize/Specialize.elm` now builds `TOpt.Tuple` / `TOpt.Record` / `TOpt.TrackedRecord` container `MonoType`s from the **already-specialised element expressions** instead of `meta.tipe`. This guarantees the layout bitmap matches SSA slot kinds even when an upstream constraint-flow gap leaves a slot's TVar unbound and `applySubst` falls through its `Nothing` / `CEcoValue` branch. Closes the long-running tuple-slot boxing bug class.
  - 13 `TupleSlotBoxing*Test.elm` variant reproducers added covering Array, Closure, Custom (single/multi-ctor), ListCons, Record (single/multi), and T2/T3 slot positions.

- **MLIR Equivalence Runner (Stage 2 vs Stage 6)** *(May 12-13, 2026)*:
  - New `test/mlir_equivalence_main.cpp` byte-compares the MLIR output of the JS Stage 2 compiler and the native Stage 6 compiler on every E2E test. CMake gains bootstrap targets (`eco-boot-3`, `eco-compiler-mlir`, `eco-compiler`, `eco-compiler-boot`) plus a `bootstrap` aggregate with two fixed-point cmp stamps.
  - Equivalence rate: **689 / 690** tests produce byte-identical MLIR. The remaining one is an expected Int-precision diff.
  - Found and fixed a major correctness bug in the process: `Elm_Kernel_Utils_equal/notEqual` was collapsing every embedded HPointer constant (True/False/Nil/Unit) to `nullptr` via `Export::toPtr`, silently breaking Bool pattern matches and equality comparisons of constructor constants. New invariant **REP_CONSTANT_003** (embedded HPointer constants are type-minimum in `compareUnboxableSlot`, not raw-pointer-equal-to-zero).
  - Other fixes uncovered: Custom-ctor dispatch was loading i16 (not i32) at offset 8 so the 48-bit unboxed bitmap contaminated the discriminator; Patterns.elm Bool-case inversion when reading i1 directly from an HPointer slot; mutual-letrec `cross_edges` corruption from a wrong `consumerIdx` anchor in Expr.elm.

- **Per-Instance Kernel ABI (Phases A–F)** *(May 6-8, 2026)*:
  - Each `Elm_Kernel_*` that was previously a single polymorphic boxed-arg function now has per-type `_Int` / `_Float` / `_Char` variants with typed C++ ABIs. `KernelInstanceKey` / `KernelInstanceAbi` / `deriveKernelInstanceAbi` added.
  - Phase A: instance-key infrastructure. Phase B: `Utils.compare_{Int,Float,Char}`. Phase C: 41 monomorphic variants across `Utils` equality/ordering, `List.cons`, `String.fromNumber`, `Json.wrap`, `JsArray`; 27 new E2E tests. Phase D: typed args plumbed through generic apply (`eco_apply_closure_typed`); `EvalParamLayout::flags`; later folded into `Closure::flags`. Phase E: `eco_apply_closure_typed` becomes canonical end-to-end so wrappers never re-box primitive captures. Phase F: retires `NumberBoxed` mode and the `CLOSURE_FLAG_TYPED_NEWARGS` bit (reclaims 2 bits in `Closure.unboxed`, capping captures at 25).
  - New invariants **CGEN_038** (`KernelDeclInstanceConsistency`), **CGEN_059** / **CGEN_060** (typed-newargs lowering shape).
  - `MonoInlineSimplify` now skips zero-param defines whose body is a bare `MonoVarKernel`, so typed user wrappers survive into MLIR.
  - Plan: `plans/per-instance-kernel-abi.md`. Theory: `design_docs/theory/kernel_abi_theory.md` updated. New design docs: `design_docs/{explicit-meta-structures, kernel-closure-lookthrough, escape-analysis}.md`.

- **Unboxed Primitive Return Values (Phases A–D)** *(May 8-10, 2026)*:
  - Closures returning Int / Float / Char now return them **unboxed** end-to-end through the generic-apply path. Stage 7 boxed `ElmInt` allocations dropped from ~59 M to ~4.7 M (then to ~99.95 % eliminated cumulatively).
  - Steals 2 bits from `Closure.unboxed` (52 → 50) for a `result_kind` byte; capture cap drops 26 → 25.
  - New ops attrs: `_result_kind` / `_result_kinds` on `PapCreate{,Group}` / `PapExtend`. New runtime entries: `eco_apply_closure_eval`, `eco_closure_call_saturated_eval`. `EvalParamLayout` carries a `result_kind` byte. Wrapper return ABI now emits i64 / f64 / i16 directly.
  - Switched 13 higher-order kernels to PAP-aware `eco_apply_closure` entries: `List.map2/3/4/5`, `JsArray.init/map/foldl/foldr`, `String.filter/any/all/foldl/foldr`, `Parser.isSubChar`, `Bytes.decode`, `Time.now`.
  - Plan: `plans/unboxed-primitive-return-values.md`.

- **Builder-Bit Nursery Pinning** *(May 10, 2026)*:
  - New `Header.builder` 1-bit flag (carved from the unused `refcount` field) marks an in-construction object as **fully traced but never promoted and never aged**. Promotion predicate becomes `!pin && !builder && age >= promotion_age`. Forbids old-gen residency (HEAP_BUILDER_001).
  - Five JsArray result-array kernels (`initialize`, `map`, `indexedMap`, etc.) migrated to `allocArrayBuilder` + `BuilderGuard` RAII helper so a minor GC mid-loop can't promote a half-built array and plant a nursery HPointer in an old-gen parent.
  - `THEORY.md` updated; new stress test `ArrayBuilderStress.elm`.

- **Row-Poly Record Narrowing Fix** *(May 10-11, 2026)*:
  - Monomorphize: `applySubst` was silently dropping a `TRecord`'s row-extension MVar when not in subst, leaving an `MRecord` with only the explicit fields and no MVar residue. `MonoRecordAccess` then projected with narrowed field indices. Fix falls back to the RHS mono type when its record shape is wider, and refines `MonoRecordAccess` result type from the structural shape. 11 `RecordNarrow*Test.elm` regression files.

- **Old-Gen GC Robustness & Lazy-Sweep Tuning** *(Apr 30 – May 6, 2026)*:
  - `evaluateMajorGCTrigger` + new `MajorGCTriggerReason` enum; `major_gc_garbage_fraction` (default 0.40) prevents long-running compiles from accumulating hundreds of MB un-swept.
  - Dynamic pressure-aware lazy-sweep budget replaces fixed 1 MiB cap; panic-sweep drains remaining work on `allocateFromBagPage` failure; sweep-on-demand drives lazy sweep until the request is satisfied or the budget hits.
  - Larger 8 KiB-to-LOT objects now check free lists with split-block over 8/16/32 size classes. Per-block free-list threading on OldGen blocks → O(1) free-cell removal on block release. `blockIndexFor` avoids linear scans. Released blocks now clear `large_body_index_` overlapping entries.
  - All heap/alloc parameters moved into runtime-configurable `AllocatorCommon.hpp` + `heap-config.json`.

- **HEAP_026 Large-Object Split-Header** *(May 1-2, 2026)*:
  - Strings and byte buffers > 2 KiB now use a split-header representation: a small `Tag_LargeStringHeader` / `Tag_LargeByteHeader` lives in the nursery and points at a pinned old-gen body. The body is never copied; the header forwards through Cheney evacuation. `alloc::resolveByteBufferBody` / `resolveStringBody` route 39 audited sites through HEAP_026-aware lookup.
  - Added to `design_docs/invariants.csv` as **HEAP_026**.

- **GC Stale-Pointer Audit + EcoBoxedStoreVerify** *(May 7-9, 2026)*:
  - Fixed a minor-GC bug where phase 3 could copy a young child of a promoted parent into to-space and leave it unscanned (now alternates to-space drain with the promoted-objects queue to fixed point).
  - Many kernel helpers rooted by-value HPointer args across allocations (Bytes, JsArray, List, Regex, Http / Time effect managers, Char / String fold closures, Parser.isSubChar, `buildEvaluatorArgs`).
  - New `EcoBoxedStoreVerify` MLIR pass + copy-loop tripwires + post-GC heap-walk extension; gated by `ECO_LOWERING_VALIDATION` / `ECO_HEAP_VALIDATE` CMake options.

- **Stage 7 Self-Compile Performance** *(May 6-9, 2026)*:
  - 1.78× Stage 7 CPU win: per-allocation `clock_gettime` gated behind `ECO_GC_ALLOC_TIMING`, Meyers singleton replaced with namespace-scope global, `getRootSet().reserve(4096)` inlined.
  - `eco-boot-native` accepts `.o` input as a link-only fast path: Stage 6 relink **3 m 26 s → 0.6 s**.
  - New `eco_alloc_with_roots` generic no-rooting fast path for JSON/Bytes/String kernel allocations.
  - `GCStats` now reports per-object-kind allocations, 16B/24B/32B bucket split, per-phase GC timing. New `LoweringStats` subsystem.
  - New intrinsics: `eco.compare → eco.{int,float,char}.cmp_order`; Char eq/ne/lt/le/gt/ge; `Char.toCode` / `fromCode`; `String.fromNumber@Int` / `@Float`; `JsArray` empty / singleton / push / slice / appendN.

- **Stage 7 Final Bootstrap Fixes** *(Apr 28 – May 2, 2026)*:
  - `Time.now` accepts `millisToPosix` and produces a Posix Custom with ctor 0 + unboxed Int.
  - Fix tiny `slice()` / `toStdU16String` rope-DFS to resolve `Tag_StringSlice` through `Tag_LargeStringHeader->body` matching `charAt` — eliminates a 128 K-abuf SIGSEGV in `Compiler.Parse.Variable.chompInnerChars`.
  - Allow split-header large objects to be freed in all old-gen GC states.
  - Stage-7 native-runtime hang fixed: `Builder/Build.elm` `RCached`'s `CachedInterface` MVar initialised with `Unneeded` to unblock `loadInterface` on mixed SChanged + SCached graphs.
  - `Char` / `String_cons` args widened to `uint64+mask`: LLVM `gc.statepoint` was dropping the `i16 zeroext` attribute at AOT call sites, leaking garbage upper bits.

**Most Recent Changes — Apr 23 to Apr 27, 2026**:

- **String Ropes + Slices + Structure Sharing** *(Apr 27, 2026)*:
  - `Tag_StringRope` (concat-tree: `HPointer left`, `HPointer right`, `u32 height`, `u32 leafCount`) and `Tag_StringSlice` (view: `HPointer base`, `u32 offset`, `u32 _padding`) added to the heap. `header.size` is the logical UTF-16 length for all three string forms. New invariant **HEAP_025**.
  - Compiler/MLIR allocations remain leaf-only (`eco_alloc_string*`, `Eco_StringLiteralOp`); ropes and slices are produced exclusively inside `Elm::StringOps` and the kernel `String` module.
  - `append` builds a rope when the total exceeds `FLATTEN_LIMIT` (32 K UTF-16 code units); below that the existing memcpy fast path is unchanged. `slice` over a leaf builds a `Tag_StringSlice` for ranges above `TINY_SLICE_LIMIT`; slice-of-slice collapses to a single slice over the underlying leaf. `concat` over long lists uses `buildBalancedRope` (explicit merge stack — `O(n log n)` shape, no left-leaning `O(n²)`).
  - `charAt` and `toStdU16String` are tag-dispatched: leaves index `chars[]`, slices add `offset`, ropes descend by left subtree length. Both are iterative / use an explicit DFS stack so deep ropes don't blow the C stack.
  - `equal`/`compare` keep the leaf+leaf `memcmp` fast path; mixed shapes flatten under `FLATTEN_LIMIT` then `memcmp`, and fall back to a bounded-memory char walk above the limit.
  - GC integration: nursery evacuation forwards `base` (slice) and `left`/`right` (rope); old-gen mark/fixup updated to match; `getObjectSize` has dedicated arms for the two new tags.
  - Kernel C++ (17 files: `core/{String, Utils, DebugExports}`, `parser/`, `json/`, `bytes/`, `url/`, `http/`, `regex/`, `virtual-dom/`) migrated to `Elm::StringOps::{length, charAt, toStdString, toStdU16String, ensureFlat}` — no direct `s->chars[i]` reads remain. UTF-8 helpers `elm_utf8_width`/`elm_utf8_copy` materialise via `toStdU16String` once.
  - Heuristics constants: `FLATTEN_LIMIT = 32 KiB UTF-16`, `TINY_SLICE_LIMIT = FLATTEN_LIMIT / 4`, `MAX_HEIGHT = 32`, `LEAFCOUNT_LIMIT = 64`, `MIN_LEAF_SIZE = 128`. Rope rebalance is deferred (`maybeFlattenOrRebalance` records the trigger; rotation TODO).
  - Empty-string canonicalisation enforced at every constructor — `len == 0` → `Const_EmptyString`, never a heap allocation.
  - Plan: `plans/string-rope-slice-representation.md`. Theory: [String Rope Representation Theory](design_docs/theory/string_rope_representation_theory.md). New tests: `StringOpsTest.cpp` extensions; regression set `CharThroughFunctionRegressionBTest.elm`, `HeapStringFieldRegressionATest.elm`, `InlineJsonStringParserRegressionCTest.elm`, `ParseLengthSweepRegressionDTest.elm`, `RecordFieldPrimitivesRegressionFTest.elm`, `StateRecordOneOfRegressionGTest.elm`, `StringSourceSweepRegressionETest.elm`.

- **Char Literal Pattern Match Decoding** *(Apr 27, 2026)*:
  - `Compiler/Generate/MLIR/Patterns.elm` now decodes escaped char pattern literals (`'"'`, `'\n'`, etc.) via `decodeChrPatternCode` instead of comparing on the leading backslash byte. New regressions: `CharLiteralPatternMatchMinimalTest.elm`, `CharLiteralPatternMatchVariousTest.elm`.

- **Closure Header Sizing** *(Apr 27, 2026)*:
  - `RuntimeExports.cpp` sets `object.size = max_values` on closure allocations so the header records the closure's full stage arity (rather than the count of args applied so far). Trailing unused capture slots are zeroed; trimming them is a future option. The change ensures `Tag_Closure` marking can iterate `hdr->size` and see all capture slots — fixes a class of GC mis-tracing on stored-but-unapplied captures.
  - Subsequent revert: `object.size` only needs to be large enough to hold the actual args at that stage; the originally proposed full-arity sizing was reverted in commit `9183930` while the underlying GC-mark issue (already fixed independently) is no longer dependent on it.

- **Stack Root Protection in Init/Flags Path** *(Apr 27, 2026)*:
  - `PlatformRuntime.cpp` init/flags path adds `StackRootGuard`s around early-init allocations so initial-state HPointers survive any GC the boot path triggers.

- **Old-Gen Mark-Driven Live + Lazy Sweep** *(Apr 26, 2026)*:
  - Sweep is now driven by mark-time `live_bytes` attribution rather than a synchronous post-mark cell walk
  - O(1) `page_to_block_index_` page-index replaces linear `findBlockContaining` scans
  - All-dead block fast path releases dead non-large blocks without scanning their cells
  - Lazy sweep runs in `SWEEP_WORK_BUDGET`-sized slices on the allocation slow path; `finishMarkAndSweep` returns with `gc_phase_ = Sweeping` after a 64 KiB initial slice
  - `transitionToSweeping` clears `free_lists_` before reclaim, turning per-block release from O(F) to O(1)
  - Stage 7 major GC: 432 s → 16 s (27× faster). New `OldGenLazySweepTest`. Plan: `plans/gc-mark-driven-live-lazy-sweep.md`

- **Per-Block Mark Bitmap Sidetable** *(Apr 26, 2026)*:
  - Liveness recorded in per-block bitmaps (1 bit per 8-byte slot) rather than inspecting object headers
  - `mark_bits_[i]` covers regular blocks; `large_block_mark_[i]` is a single bit for `is_large` blocks
  - Headers retain `color` for compaction's debug asserts but are no longer load-bearing for sweep
  - Plan: `plans/oldgen-per-block-mark-bitmaps.md`

- **Old-Gen Segregated-Fits with Big Bag of Pages** *(Apr 25, 2026)*:
  - Initial old-gen region is precommitted up front and sliced into pages of `alloc_buffer_size`
  - Pages live in `unassigned_blocks_` until first use; small classes (8..256 B step 8) and medium classes (powers of two from 512 B) pull pages from the bag and slice them into uniform `Tag_Free` cells
  - Mid-range allocations (`large_object_threshold`..`alloc_buffer_size`) wrap a single page-spanning cell and split via the larger-cell path; large allocations (`≥ alloc_buffer_size`) get dedicated pinned blocks
  - `freeListClassFor` (round-down placement) added alongside `sizeClass` (round-up allocation lookup) — fixes Stage 7 SEGV in `tryAllocateBySplittingLarger` where medium-class placement parked under-sized cells on classes whose fast path then overflowed them
  - Block uniformity preserved through split residuals and sweep coalesces (size-class blocks are walked by `classToSize(cls)` and must be exactly that size)
  - Mid-class slack handled via `padCellSlack` which writes a `Tag_Free` trailing in the slack at allocation time; `getObjectSize` for `Tag_Array` uses `header.size` (capacity) so sweep stride is correct
  - Plan: `plans/oldgen-segregated-fits-bbop.md`

- **Old-Gen Capacity Shrink and Large-Block Reuse** *(Apr 26, 2026)*:
  - Surplus blocks below `BUFFER_RETURN_THRESHOLD` returned to the Allocator's free pool post-sweep
  - Large-block free list (`free_large_blocks_`) lets `allocateLargeBlock` reuse retired large blocks before asking the Allocator for a fresh one
  - `decommit_on_oldgen_release` defaulted to `false` while debugging stale-pointer-into-decommitted-page corruption
  - Plan: `plans/oldgen-capacity-shrink-and-large-reuse.md`

- **Major GC `0.75/0.50` Trigger Policy** *(Apr 24-26, 2026)*:
  - `shouldTriggerMajorGC` now fires on per-thread `allocated/committed ≥ major_gc_initiating_occupancy` (default 0.75) **OR** at ~25% of the global old-gen cap. Per-thread occupancy alone never crossed 0.75 because `allocateFromBagPage` burns a fresh page per request
  - `major_gc_target_utilization` (default 0.50) drives post-GC committed-capacity grow
  - Initial old-gen size of 16 MiB actually implemented; `DEFAULT_MAX_HEAP_SIZE` raised to 24 GiB (12 GiB old gen + 12 GiB nursery)
  - Plan: `plans/major-gc-75-50-policy.md`

- **GC Color and External-Root Hardening** *(Apr 24-26, 2026)*:
  - Reset `header.color` to White after every evacuation memcpy (nursery promotion, to-space copy, OldGen compaction) and at the start of each mark phase — prevents a stale Black surviving the memcpy and being skipped by the next mark *(Apr 26)*
  - Major GC scans Scheduler / PlatformRuntime / MVar / Runtime external root scanners during the mark phase *(Apr 25)*
  - No GC color marking on objects in the nursery — major GC tracks them in `nursery_visited_` instead of the header *(Apr 26)*
  - Embedded constants (`HPointer.constant != 0`) skipped during oldgen marking *(Apr 24)*
  - Location 0 in the oldgen heap reserved so a logical `HPointer` of zero is unambiguously "null" *(Apr 25)*
  - Allocation size histograms (nursery + oldgen) reported in `GCStats`; `eco-compiler` reports `GCStats` even on signal interrupt *(Apr 26)*

- **Sustained-Pressure GC Test Suite** *(Apr 25, 2026)*:
  - 19 new tests in `GCPressureTest.cpp` covering nursery churn + promotion, oldgen growth and reclamation, cyclic garbage, write-barrier integrity, the full `eco_alloc_*` runtime path (int/float/char/cons/tuple2/tuple3/custom/record/string/closure), size-class churn, large pinned objects, fragmentation/coalescing, occupancy/alloc-failure triggers, randomized rapidcheck workloads, retention sweeps, stack-range roots, and safepoint polling
  - Shared `pressureHeapConfig` (16 KiB pages, 256 KiB nursery, 256 KiB initial oldgen) so each test fires many minor + major GCs in seconds
  - Three runtime fixes surfaced while writing them: `OldGenSpace::allocated_bytes` bumped on every size-class/split/bag-page allocation (was stale between sweeps); `Tag_Closure` marking iterates `hdr->size` instead of `cl->n_values` (so stored-but-unapplied captures survive a major GC); `HeapConfig::validate()` rejects `large_object_threshold > alloc_buffer_size`

- **Stress-Test Library Parameterization** *(Apr 25, 2026)*:
  - All `test/stress-elm/` programs parameterized with `Platform.worker` flags (`-n`/`-m`/`--timeout`)
  - Default sizing tuned to ~10 s per test; isolated test runner for GC stress tests
  - Plan: `plans/stress-test-flags-platform-worker.md`

- **Mutually Recursive Closure SCC Allocation** *(Apr 24, 2026)*:
  - Fix "operand #0 does not dominate this use" failure on mutually recursive let-bound closures by introducing `eco.papCreateGroup`, which atomically allocates the entire SCC in one contiguous region
  - Frontend detects contiguous closure-only SCCs of size ≥ 2 in let-chains and emits one group op instead of per-binding `papCreate`s with forward-referenced placeholders
  - Same-generation, so no write barrier is needed for the cross-sibling capture writes
  - Self-recursion and non-SCC bindings stay on the existing `fixSelfCaptures` path
  - Plan: `plans/pap-create-group-mutual-rec-closures.md`

- **Short-Circuit `&&` and `||`** *(Apr 24, 2026)*:
  - The `Binop` arm of `Compiler/LocalOpt/Typed/Expression.elm` now rewrites `a && b` to `if a then b else False` and `a || b` to `if a then True else b`, so every backend inherits short-circuit semantics from the existing `If` codegen path
  - The strict `eco.bool.and` / `eco.bool.or` intrinsics and the JS `&&` / `||` infix arms remain for first-class uses of `Basics.and` / `Basics.or`
  - Plan: `plans/short-circuit-bool-via-if.md`

- **PlatformRuntime Scratch Promoted to GC-Visible Members** *(Apr 24, 2026)*:
  - Per-batch `FxBatch` and per-manager `Cmd`/`Sub` scratch lifted out of unrooted C++ locals into `PlatformRuntime::activeBatch_` / `effectsScratch_` member fields
  - External root scanner visits them while `dispatchActive_` is set, so GCs triggered during `gatherEffects`, `onEffects`, or `drain()` evacuate every live HPointer in place
  - `dispatchEffects` switched from a manual `cons()` accumulator loop to `alloc::listFromPointers`, fixing a second latent rooting bug where the list head and un-consumed elements were unrooted across cons allocations
  - Plan: `plans/dispatch-effects-gc-visible-scratch.md`

- **Thread-Safe Blocking MVar** *(Apr 24, 2026)*:
  - `eco-kernel-cpp/src/eco/MVar.cpp` reimplemented for thread-safe blocking semantics, exercising `MVarBlockingReadAwaitsPutStress`

- **String Empty-Pattern `inttoptr` Fix** *(Apr 24, 2026)*:
  - In `EcoToLLVMControlFlow.cpp` `CaseOpLowering` (string-case path), the `pattern.empty()` branch was creating the encoded empty-string constant as `i64` and passing it to `Elm_Kernel_Utils_equal`, which expects `(ptr<1>, ptr<1>)`
  - Every other embedded-HPointer constant in the file (e.g. the `True` constant) wraps the `LLVM::ConstantOp` in an `LLVM::IntToPtrOp` to the `ptr addrspace(1)` HPtr type — fix adds the missing `inttoptr`

- **Mutual Let-Rec Many-Captures + Nested Test Coverage** *(Apr 24, 2026)*:
  - `MutualLetRecManyCapturesTest.elm`, `MutualLetRecNestedTest.elm`, `CaseStringEmptyPatternTest.elm` regression tests
  - Bytes-to-tuple GC rooting fix in `BytesExports.cpp`

- **Polymorphic Step-Loop Destructor Fallback** *(Apr 24, 2026 — Bootstrap Stage 6 fix)*:
  - When a polymorphic custom constructor like `Done a` is specialized at `a = Int` but the call site only partially unified `a` (leaving an unresolved MVar on the path), `generate{Destruct,TailRecDestruct}` was deriving `targetType = !eco.value` from the stale path annotation
  - `generateDestruct` and `compileDestructStep` now fall back to the destructor's own `monoType` (which the outer subst pins concretely via return-type unification) when the path's resolved result type still contains an MVar
  - New `PolyStepLoopMultiSpecTest` and `PolyStepLoopMinimalDisagreeTest` regressions

**Most Recent Changes — Apr 18 to Apr 22, 2026**:

- **RewriteStatepointsForGC Migration** (Apr 18-22, 2026):
  - Bespoke `StatepointConversion` pass retired; replaced with LLVM's upstream RS4GC
  - New `EcoGCStrategy.cpp` registers `eco-gc` strategy; all MLIR functions tagged `gc "eco-gc"`
  - RS4GC handles liveness, base-pointer inference, alloca+mem2reg uniformly
  - `EcoPtrIntVerify` post-RS4GC verifier enforces addrspace(1) boundary invariants
  - `eco.shadow_roots` UnitAttr for TCO-safe shadow frames attached by compiler (`main_$_0` + tail join blocks)
  - `StackMapRoots` split into its own class owned by `ThreadLocalHeap`
  - `Allocator` free-list returns retired `ThreadLocalHeap` nursery blocks to the pool (fixes spawn-heavy exhaustion)
  - LLVM libunwind built into JIT with per-FDE `.eh_frame` registration and `frame-pointer=all` on emitted code

- **`eco.value` → `ptr addrspace(1)`** (Apr 17, 2026):
  - Type representation migrated across EcoToLLVM (Heap, Closures, Func, Runtime, ControlFlow, Globals, Types) and BFToLLVM
  - ~114 MLIR tests updated to new lowering
  - Role-specific `ptr<1>↔i64` boundary helpers (heap/global/closure/argsSlot/caseScrutinee/wrapper)
  - New invariant REP_LLVM_001; `stripIntToPtr` excludes constants from GC root sets

- **2-bit Per-Slot Primitive Kind Bitmap** (Apr 20, 2026):
  - Heap/closure slot-kind mask migrated from 1-bit (boxed/unboxed) to 2-bit (boxed / Int / Float / Char)
  - Float and Char now correctly boxed across Record/Custom/Closure/Tuple paths
  - `Heap.hpp` Header.unboxed widened 3→6 bits; new `fieldKind`/`bitmapSetKind` helpers
  - Caps: Custom ≤24 fields, Record ≤32 fields, Closure ≤26 captures
  - Compiler `computeRecordLayout`/`computeCtorLayout`/`computeTupleLayout` emit 2-bit bitmaps; `construct.list` gained a `head_kind` attribute
  - MLIR verifiers enforce per-slot kind ↔ SSA-type match
  - Bytes/String/List kernel masks updated; `Tuple2` mask encoding (`0x4`/`0x5`/`0x6`)

- **CallGenericApply + segmentation_unknown Calling Method** (Apr 19-21, 2026):
  - New calling method alongside flat/segmented dispatch
  - `generateVarKernel` consults `kernelBackendAbiPolicy` on the closure/PAP path for kernels
  - `buildEvaluatorArgs` re-resolves closures by hpointer and preserves unboxed capture kinds across allocating callees
  - Arity propagation into let-bound functions; CGEN_040/CGEN_052 fixes

- **Monomorphization Overhaul** (Apr 18-22, 2026):
  - Type-variable identifiers migrated from `String` names to `Int` IDs starting at Monomorphization
  - `PendingGlobal`: polymorphic globals passed as args deferred until call-site unification
  - `applySubstWithFreeVars` prevents cross-scheme substitution contamination
  - `unifyCallSiteDirect` unifies scheme residual with call's canonical type (recovers row-poly record and scheme-poly tuple bindings)
  - Scheme cache MVarId collision fix; tvar refresh on use
  - MonoDirect implementation removed
  - Fast path for non-polymorphic functions skips SchemeInfo construction
  - New MONO_027 invariant (function/type arity match)

- **PostSolve Overhaul** (Apr 18-21, 2026):
  - New `SolverRoots` module normalises solver variables to union-find roots
  - Alias maps eliminated; root-tvar resolution used directly
  - Structural expressions moved from Group B recovery into solver-derived typing
  - TYPE_007 and POST_010 invariants added
  - `AnnotationsByGlobal` / `SchemeRootsByGlobal` map types introduced

- **Streaming MLIR Bytecode** (Apr 18-20, 2026):
  - Binary bytecode format landed; streaming generation reduces peak memory
  - Location attrs separated from string attrs in encoder's attribute table
  - `MonoRecordUpdate` codegen derives heap layout from actual record type
  - `varMappings`/`definedSsaVars` reset discipline tightened across codegen

- **Stress Test Infrastructure** (Apr 20-22, 2026):
  - New `test/stress-elm/` library for larger/longer-running programs
  - Stress programs exercise Array/Bytes/Dict/Json roundtrips, record-update row-poly, Parser, Process/MVar churn, Spawn fanout, Task.andThen PAP capture, and bootstrap-derived regressions
  - Shared `StressHarness.elm` with CLI `-n`/`-m`/`--timeout` plumbing via `Platform.worker` flags
  - GC histogram printing and stat collation across stress tests
  - Separate `stress-test` binary kept out of the regular `check` cycle

- **Kernel Rooting & MVar/Runtime External Roots** (Apr 18-22, 2026):
  - Dedicated root API for encoded HPointer values in Scheduler/PlatformRuntime
  - `MVar::s_mvars` and `Runtime::s_savedState` registered as external GC root scanners
  - Rooting migrated Phase 1b → Phase 1e (`pushStackRoot` → `pushStackRootRange`)
  - Kernel GC-safety audit across `elm-kernel-cpp/` and `eco-kernel-cpp/`
  - `ListOps` kernel re-reads `Cons*` across GC-triggering callbacks (reverse/foldl/map/filter/...)
  - `Utils::eqHelp`/`cmp` consult `header.unboxed` for unboxed tuples

- **elm/parser Kernel** (Apr 18-20, 2026):
  - Kernel rewritten from first principles; first tests passing; 34-test suite

- **Process & Task E2E + Stress Tests** (Apr 18-19, 2026):
  - SpawnKillHalf, SpawnRecursive, YieldThrashing, TaskAndThenCascade, SpawnFanout, SpawnGCChurn, TaskAndThenPapCapture, TaskSequenceMassive

**Next Steps** *(in priority order)*:
1. **Performance baseline (§6.1)** — benchmark Stage 7 self-compile vs JS bootstrap, runtime micro-benchmarks, GC overhead under stress
2. **Release packaging (§6.2)** — documentation, install scripts, .deb / npm packaging on top of the Stage C static bundle; tag 0.1.0
3. **CLI polish (§5.1.2)** — error messages, `make` flag parity with the JS toolchain
4. **Escape analysis** — finish Phase 2 nested-aggregate readiness and start lifting heap allocation off escape-free constructions
5. **Stress-suite stabilisation** — remaining GC assertions at high iteration counts in `test/stress-elm/`
6. **String rope follow-ups** — actual rope rebalancing (currently only `// TODO`), streaming `equal`/`compare`, streaming UTF-8 encode (Option B), all-ASCII fast-path bit in `ElmStringSlice._padding`

**Active Workstreams**:
1. **Escape analysis** — Phase 1 (widened ops) landed; Phase 2 nested-aggregate scaffolding in progress; wrapper FCA-of-GC-pointer fix made the path RS4GC-safe
2. **Tuple-slot boxing bug class** — root-cause MonoType fix landed *(May 14)*; variant reproducers (Array/Closure/Custom/Record/ListCons/T2/T3) still being verified end-to-end
3. **Old-gen GC hardening** — re-enabling `decommit_on_oldgen_release` once the stale-mark-roots issue is resolved; remaining sweep / pressure-trigger tuning
4. **MLIR equivalence suite** — currently 689 / 690 byte-identical between Stage 2 and Stage 6 outputs; investigating any new diffs as they appear
5. **Bytes-fusion follow-ups** — Phase 4+5 landed; partial-fusion escape hatch is in place but recognition coverage can still be broadened
6. **Compiler pass consolidation** — Monomorphization / PostSolve overhauls (tvar `Int` IDs, `SolverRoots`, `PendingGlobal`, per-instance kernel ABI) stabilising into their final shape
5. **Stress-suite reliability** — driving GC root correctness under sustained allocation pressure; backfilling regressions for every bootstrap-derived bug
