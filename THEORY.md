# THEORY.md

This document captures the essential insights and design rationale for the eco-runtime garbage collector. It is written for an engineer joining the project who wants to quickly build a working understanding of how the system thinks, not just how it works.

For the broader project context, see [PLAN.md](PLAN.md). ECO (Elm Compiler Offline) is a native compilation backend and runtime for Elm, targeting high-performance multi-threaded execution via LLVM. This runtime provides memory management for compiled Elm programs.

## The Core Insight: Elm's Immutability Changes Everything

The single most important thing to understand about eco-runtime is that it exploits **Elm's immutability guarantee** to eliminate the write barrier that normally dominates generational GC complexity.

In a typical generational collector, you need to track when an old-generation object is mutated to point to a young-generation object (an "old-to-young pointer"). This requires a write barrier on every pointer store, plus remembered sets or card tables to scan during minor GC.

Elm values are immutable. Once created, they never change. This means:
- **New objects can only point to older objects** (they can only reference things that already exist)
- **Old-to-young pointers cannot exist** (old objects cannot be modified to point to new things)
- **No write barrier is needed** for generational correctness

This is not a minor optimization - it fundamentally simplifies the GC design. The complexity you do not see in this codebase (card tables, remembered sets, store buffers, barrier code on every write) is the complexity you would normally expect.

## Thread-Local Heaps

Each thread owns a `ThreadLocalHeap` containing its own nursery and old generation. This design eliminates cross-thread synchronization during normal operation:

- **Allocation**: Pure bump-pointer in thread-local nursery, no locks
- **Minor GC**: Operates only on thread-local nursery, no coordination
- **Major GC**: Operates only on thread-local old gen, no coordination

The central `Allocator` singleton manages the unified address space and carves out regions for each thread on initialization. Once a thread has its regions, it operates independently.

```
Thread 1: [Nursery₁] → [OldGen₁]
Thread 2: [Nursery₂] → [OldGen₂]
          ↑                    ↑
          └── carved from unified heap ──┘
```

This is simpler than shared-heap designs that require synchronization on every allocation or during GC. The trade-off is that memory cannot be shared between threads, but Elm's message-passing concurrency model makes this natural.

## Two Generations, Two Algorithms

The GC uses two generations because the "weak generational hypothesis" holds: most Elm values die young. The design pairs each generation with the algorithm best suited to its characteristics.

### Nursery: Region-Based Semi-Space Copying (Cheney's Algorithm)

Young objects live in the nursery, which uses Cheney's copying collector:

1. **Bump-pointer allocation**: Just increment a pointer. O(1), no fragmentation concerns.
2. **Copy survivors to to-space**: Only live objects pay the cost; garbage is free.
3. **Swap spaces**: Old from-space becomes new to-space; memory is implicitly reclaimed.

This is optimal for high-churn, short-lived allocations. The cost of GC is proportional to survivors, not total allocations.

**Two-region design**: The nursery uses two separate address regions (`low_blocks_` and `high_blocks_`) rather than interleaved blocks. One region serves as from-space, the other as to-space, swapping roles after each GC. This enables:

- **O(1) membership checks**: Simple bounds comparison (`ptr >= low_base_ && ptr < low_end_`) instead of O(log n) set lookup
- **Dynamic growth**: When survivors exceed 75% of to-space capacity, both regions grow
- **Unified block sizing**: Same block size as old gen (simpler memory layout)

The key insight: by keeping from-space and to-space in separate address ranges, `isInFromSpace()` becomes a single bounds check cached in member variables (`low_base_`, `low_end_`, `high_base_`, `high_end_`).

### Old Generation: Segregated-Fits + Big Bag of Pages with Mark-Driven Lazy Sweep

Long-lived objects promoted from the nursery live in the old generation. *(Apr 25-26, 2026)* The old gen is a **segregated-fits allocator backed by a Big Bag of Pages (BBoP)** with mark-driven liveness attribution and lazy sweeping on the allocation slow path.

**The Big Bag of Pages**: At init, `initial_old_gen_size` (16 MiB by default) is committed up front and sliced into pages of `alloc_buffer_size` (128 KiB by default). Pages live in `unassigned_blocks_` until first use. Each thread has its own bag; no cross-thread sharing during normal operation.

**Size classes**:
- **Small classes** — 32 classes covering 8..256 B in 8-byte steps.
- **Medium classes** — powers of two starting at 512 B (up through 65536 B). Class count is capped at runtime by `large_object_threshold`.
- **Mid-range** (`large_object_threshold` up to `alloc_buffer_size`) — pulls a page from the bag and installs a single page-spanning `Tag_Free` cell, then splits via the larger-cell path.
- **Large objects** (`≥ alloc_buffer_size`) — go through `allocateLargeBlock` to a dedicated pinned block sized to fit the object. Released large blocks are kept in `free_large_blocks_` and reused before the Allocator hands out a fresh page.

A class pulls a page from the bag on first use and slices it into uniform `Tag_Free` cells. Allocation pops from the class's free list; on miss it tries to split a larger free cell, then falls back to acquiring a new bag page.

**Class-selection asymmetry** *(Apr 25, 2026 — fixes Stage 7 SEGV)*:
- `sizeClass(size)` rounds **up** at allocation time so a popped cell can always satisfy the request.
- `freeListClassFor(span)` rounds **down** at placement time (split tails, sweep coalesces, bag-page tails) so cells on `free_lists_[cls]` always have at least `classToSize(cls)` bytes — the invariant the fast path relies on.

Without the round-down placement, a 352-byte span would land on cls=32 (cellSize=512); the fast path would then hand it out as a 512-byte slot, overflowing on the first store.

**Mark-and-sweep** *(Apr 26, 2026 rewrite)*:
1. **Trigger** — `shouldTriggerMajorGC()` fires when per-thread `allocated/committed ≥ major_gc_initiating_occupancy` (default 0.75) **OR** when the global old-gen pressure crosses ~25% of the cap. The global trigger is needed because `allocateFromBagPage` burns a fresh page per request, so per-thread occupancy alone never crosses 0.75.
2. **Mark** — incremental marking driven by `MARK_WORK_RATIO`. **Liveness is recorded in per-block bitmaps**, not in the header `color` field. `mark_bits_[i]` is a 1-bit-per-8-byte-slot bitmap for regular blocks; `large_block_mark_[i]` is a single live/dead bit for `is_large` blocks. Headers retain `color` for compaction's debug asserts but are no longer load-bearing for sweep liveness. Major GC visits external root scanners (Scheduler, PlatformRuntime, MVar, Runtime) so objects rooted only via external state survive collection. Embedded constants (`HPointer.constant != 0`) are skipped during marking — they live outside the heap.
3. **No nursery color writes during major GC**: nursery objects pushed during major-GC mark are tracked in a `nursery_visited_` set instead of writing into nursery header `color` bits, since minor GC owns those bits.
4. **Mark-driven live attribution + lazy sweep**: `live_bytes` is attributed during marking. `transitionToSweeping` clears `free_lists_` *before* reclaim (turning per-block release from O(F) to O(1)). An **all-dead block fast path** releases dead non-large blocks without scanning their cells. An **O(1) page-index** (`page_to_block_index_`) replaces the old linear `findBlockContaining`. `finishMarkAndSweep` returns with `gc_phase_ = Sweeping` after a 64 KiB initial slice; the rest of the sweep work runs in `SWEEP_WORK_BUDGET`-sized slices on the allocation slow path. (Stage 7 major GC: 432 s → 16 s, 27× faster.)
5. **Color reset after every evacuation memcpy**: nursery promotion, to-space copy, and OldGen compaction each reset `header.color` to White after the memcpy, and the mark phase resets at start. Without this, a stale Black left by an earlier mark would survive the memcpy and cause the next mark to skip the cell as already-processed, with sweep then freeing untraced children.
6. **Shrink-and-return**: post-sweep, surplus blocks below `BUFFER_RETURN_THRESHOLD` are returned to the Allocator's free pool. (`decommit_on_oldgen_release` is currently `false` while debugging stale-pointer-into-decommitted-page corruption — see `bootstrap-stage7-crash-analysis.md`.)
7. **Compaction** — incremental, manual trigger only. Evacuates sparse blocks under a `COMPACTION_WORK_BUDGET` slice budget when fragmentation crosses `UTILIZATION_THRESHOLD`.

**GC phases** (state machine):
```
Idle → Marking → Sweeping (lazy, paced on alloc slow path) → Idle
                    ↓
              (if fragmented)
                    ↓
            Compaction: Evacuating → FixingRefs → Idle
```

Mark-sweep does not require 2x space overhead. Compaction is optional and incremental, spreading the cost across multiple allocation slow-paths.

## Forwarding Pointers

When Cheney's algorithm copies an object, the original location becomes invalid. But other objects might still have pointers to that old location. The solution is a **forwarding pointer**: a special object left at the old location that says "I moved to X".

During minor GC:
1. Object is copied to new location (to-space or old gen)
2. Original location is overwritten with `Tag_Forward` header containing new address
3. Subsequent pointer fixup finds the forward and updates to the new location

The Forward structure repurposes the header word:
```cpp
typedef struct {
    struct {
        u64 tag : 5;              // Tag_Forward
        u64 color : 2;            // (unused for forwards)
        u64 forward_ptr : 40;     // Logical pointer to new location
        u64 unused : 17;
    } header;
} Forward;
```

Key insight: Forwarding pointers are only valid during GC. By the time the mutator resumes, all pointers have been updated to their final locations.

## List Locality Optimization

Elm programs create many linked lists. Standard Cheney's algorithm copies objects in breadth-first order, which can scatter list nodes across memory. The GC uses an optional two-pass copying strategy for Cons cells to improve cache locality:

**Pass 1 - Copy spine contiguously**: Walk the tail chain, copying each Cons cell immediately after the previous one in to-space. This allocates the entire spine contiguously.

**Pass 2 - Evacuate heads**: Walk the copied spine and evacuate each head element (which may be any type).

```
Before GC (scattered):    After GC (contiguous spine):
  [Cons₁] → ... → [Cons₂] → ... → [Cons₃]    [Cons₁][Cons₂][Cons₃] → heads nearby
```

This optimization is controlled by `HeapConfig::use_hybrid_dfs` (enabled by default). The term "hybrid DFS" refers to the depth-first treatment of list tails within an otherwise breadth-first Cheney algorithm.

Benefits:
- Better cache prefetching when traversing lists
- Reduced TLB misses for list-heavy code
- No cost for non-list data structures (they use standard BFS)

## Logical Pointers: 40-bit Offsets

All heap pointers are logical offsets, not raw addresses:

```cpp
typedef struct {
    u64 ptr : 40;       // Offset into heap (8-byte granularity)
    u64 constant : 4;   // Embedded constant tag
    u64 padding : 20;   // Available for future use
} HPointer;
```

The 40-bit offset (with 8-byte alignment) addresses 8TB of heap space. Benefits:

1. **Embedded constants**: Nil, True, False, Unit, Nothing, EmptyString, and EmptyRec are represented by the constant field, not as heap objects. No allocation, no pointer chase.
2. **Compression**: 8-byte pointers instead of native 64-bit addresses.
3. **Relocation-friendly**: Offsets from a base are easier to adjust than raw addresses.

The `fromPointerRaw` and `toPointerRaw` conversions are the only places that touch `heap_base`. All pointer manipulation goes through these.

## Unified Heap: One Address Space, Per-Thread Regions

The allocator reserves a single large address space (1GB by default) via `mmap` without committing physical memory. This space is partitioned:

```
[0 .. heap_reserved/2)      - Old generation regions (carved up per-thread)
[heap_reserved/2 .. end)    - Nursery regions (carved up per-thread)
```

Physical memory is committed on demand:
- Nursery: Blocks committed via `acquireNurseryBlockLow()`/`acquireNurseryBlockHigh()` as threads initialize or grow
- Old gen: Committed via `acquireOldGenRegion()` when a thread initializes, grows as needed

Each thread gets its own regions within these spaces. The Allocator tracks committed ranges and hands out contiguous chunks to each `ThreadLocalHeap`.

**Configuration**: Heap parameters are centralized in `HeapConfig`:
- `nursery_block_count`: Must be even (split between from-space and to-space)
- `alloc_buffer_size`: Size of each block (default 128KB)
- `promotion_age`: GC cycles before promotion (default 2)
- `nursery_gc_threshold`: Occupancy threshold for minor GC trigger (default 90%)
- `use_hybrid_dfs`: Enable list locality optimization (default true)

Configuration is validated on `Allocator::initialize()` to catch invalid combinations early.

**Heap validation**: During major GC, pointers are validated with `isInHeap()` - a simple O(1) bounds check against the reserved address range. This is simpler than checking `isInOldGen() || isInNursery()` and correctly handles all valid heap pointers regardless of which generation they're in.

## Promotion: When Objects Grow Up

Objects are promoted from nursery to old gen after surviving `PROMOTION_AGE` minor GCs (default 2, configurable via `HeapConfig`). The age is tracked in the header:

```cpp
u32 age : 2;      // Survives up to 3 GCs before promotion
u32 pin : 1;      // Prevents relocation (for FFI or debugging)
u32 unboxed : 6;  // 2 bits/slot; per-slot primitive kind (Cons/Tuple/ElmArray)
```

The `unboxed` bitfield encodes a 2-bit primitive kind per slot (00=boxed
HPointer, 01=Int, 10=Float, 11=Char) for `Cons` (1 slot), `Tuple2`/`Tuple3`
(2/3 slots), and `ElmArray` (1 uniform kind). `Custom`, `Record`, and
`DynRecord` carry separate wider bitmaps in their own structures (48, 64,
and 64 bits respectively, all 2-bit-per-slot). See
`design_docs/theory/heap_representation_theory.md` for details.

When `evacuate()` sees an object that has reached promotion age, it allocates in the old gen instead of to-space. Promoted objects are added to a buffer and scanned to update their child pointers, since they may reference other nursery objects that haven't been evacuated yet.

## Execution Model: Thread-Local Stop-the-World

There is no separate collector thread. Each mutator thread runs its own GC on its own heap:

- **Minor GC**: Triggered when nursery occupancy exceeds `nursery_gc_threshold` (default 90%)
- **Major GC**: Triggered when old gen committed bytes exceed a threshold
- **Incremental work**: Marking and compaction can be spread across allocation slow-paths

Each thread's GC is stop-the-world *for that thread only*. Other threads continue executing. This avoids global synchronization while keeping the GC simple.

The `ThreadLocalHeap` coordinates its nursery and old gen:
1. `allocate()` bumps pointer in nursery (fast path)
2. When nursery is exhausted, slow path runs allocation inside a GC safepoint
3. When threshold exceeded, `minorGC()` evacuates survivors
4. Promoted objects go to thread-local old gen
5. When old gen grows large, `majorGC()` marks and sweeps

### Fast and Slow Allocation Paths

*(Apr 2026)* Allocation is split into two paths:

- **Fast path**: Simple nursery bump-pointer increment. No GC interaction. O(1).
- **Slow path**: When nursery space is insufficient, the allocation runs inside a GC safepoint. This allows the GC to collect before retrying.

The `EcoGCPrepare` MLIR pass detects all potentially allocating operations and attaches live GC roots as explicit operands. This ensures the runtime has accurate root information when the slow path triggers GC.

**Allocation groups — single safepoint per group** *(Apr 16, 2026)*: Adjacent fixed-size allocations identified by `EcoGCPrepare` lower to a single fast/slow/merge CFG. The fast path calls `eco_gc_alloc_region_fast(totalBytes)` (a `gc-leaf-function`, never a safepoint); on null the slow path calls `eco_gc_alloc_region_slow(totalBytes)`, which is non-leaf and is therefore wrapped in a `gc.statepoint` by RS4GC. Each member is initialized at its offset via `eco_init_*_at` runtime functions (leaf) that write the header/fields into the reserved region and return the HPointer. Variable-size ops (`AllocateClosureOp`, `AllocateOp`) are excluded from groups; group size is capped below the 32 KiB large-object threshold.

### Stack Root Tracing

Precise GC stack root tracing is implemented via LLVM statepoints, with LLVM's upstream `RewriteStatepointsForGC` (RS4GC) doing the heavy lifting:

1. **EcoGCStrategy** (`runtime/src/codegen/Passes/EcoGCStrategy.cpp`): Registers the `"eco-gc"` strategy with LLVM. `isGCManagedPointer()` returns true for any `ptr addrspace(1)`, and `UseRS4GC = true` drives `RewriteStatepointsForGC`. All non-external Eco functions are tagged `gc "eco-gc"`.
2. **EcoGCPrepare** (MLIR Stage 2): Groups adjacent fixed-size allocations so that one allocation region covers multiple construct ops, and walks MLIR's inter-block `Liveness` analysis to attach live `!eco.value` roots to allocation-group leaders and call-like ops. These operands survive into LLVM IR, but RS4GC does not require them — it recomputes liveness itself.
3. **Leaf annotations**: Runtime helpers that cannot trigger GC (`eco_*_fast`, `eco_store_*`, `eco_init_*_at`, `eco_get_*`, `eco_gc_add_root`, math kernels, etc.) carry `gc-leaf-function` on their LLVM declarations. Non-leaf functions (`eco_alloc_*`, `eco_alloc_*_slow`, `eco_gc_alloc_region_slow`, `eco_apply_closure`, `eco_pap_extend`, `eco_closure_call_saturated`, `eco_clone_array`, `eco_minor_gc`, `eco_major_gc`) are the calls RS4GC treats as safepoints.
4. **RewriteStatepointsForGC** (LLVM function pass, run between MLIR translation and the base optimizer): For every non-leaf call/invoke inside a `gc "eco-gc"` function, RS4GC (a) computes live `ptr addrspace(1)` values via type-based backward dataflow, (b) infers base pointers (trivial here — every HPointer is its own base), (c) wraps the call in `llvm.experimental.gc.statepoint` with a `gc-live` operand bundle, (d) emits `llvm.experimental.gc.relocate` for each live pointer, and (e) rewrites uses via one alloca per live pointer plus `PromoteMemToReg`. The result is clean SSA where every post-safepoint use observes the relocated pointer.
5. **Runtime stack map parsing**: `StackMap.cpp` parses LLVM v3 stack map format; `collectStackRootsFromStackMap()` walks the x86-64 frame pointer chain; `StackUnwind.cpp` handles RSP-relative locations that appear even with `-fno-omit-frame-pointer`.

Because RS4GC identifies GC pointers purely by type (`ptr addrspace(1)`), the front-end/compiler does **not** need to hand-roll liveness: attaching `!eco.value` operands in EcoGCPrepare is belt-and-suspenders, and nothing can "fall through the cracks" because the LLVM type system enforces visibility.

**StackRootGuard**: RAII helper in `HeapHelpers.hpp` that pushes HPointers onto `RootSet::stack_root_ranges` (as 1-element ranges) and restores on destruction. Used by kernel helpers (`allocTask`, `allocProcess`, `cons`, `tuple2`, etc.) to root captured HPointers across allocations that may trigger GC. Stackmap-derived roots live in a separate `StackMapRoots` container owned by `ThreadLocalHeap`, populated only by `collectStackRootsFromStackMap()` and cleared each GC cycle.

**Shadow stack root ranges** *(Apr 13, 2026)*: Closure dispatch helpers (`eco_apply_closure`, `eco_apply_segmentation_unknown`, `eco_pap_extend`, `eco_closure_call_saturated`) alloca `uint64_t*` arg buffers at runtime — a layout static stack maps cannot describe. These buffers are pushed onto `RootSet::stack_ranges` (a "shadow stack") via `eco_gc_push_stack_range` before allocation and popped after. Each range carries an unboxed-bitmap mask so the GC visits only the HPointer slots.

**Closure wrapper safepoints**: Generated `__closure_wrapper_*` functions carry `gc "eco-gc"` like any other Elm function. The target Elm call and every `eco_alloc_*` boxing call inside the wrapper are non-leaf, so `RewriteStatepointsForGC` automatically wraps each in a `gc.statepoint` that captures all live `ptr addrspace(1)` arg HPointers. `eco_resolve_hptr` is a `gc-leaf-function` — it is a non-allocating invariant and therefore never becomes a safepoint.

**Closure pointer re-resolution** *(Apr 15, 2026)*: `buildEvaluatorArgs` takes `closure_hptr` (not raw `Closure*`) and re-resolves via `hpointerToPtr` before each `values[i]` load. `eco_pap_extend` re-resolves `old_closure` from the authoritative `closure_hptr` after `Allocator::allocate()` since GC may have relocated the old closure.

**External GC roots** *(Apr 15, 2026)*: `MVar::s_mvars` and `Runtime::s_savedState` are registered as external root scanners (encode → evacuate → decode each stored HPointer) via `Eco_Kernel_{MVar,Runtime}_register_gc_roots` + aggregator `Eco_Kernel_register_all_gc_roots`, invoked after `Allocator::initThread()` in AOT (and weakly in JIT) entries.

**GC diagnostics** *(Apr 15-16, 2026)*: `ECO_GC_DEBUG` CMake option (default on in Debug builds) adds ghost-data clearing — `clearToSpaceFreeRegion()` zeroes all free to-space bytes after each minor GC, and `debugAssertValidNurseryPointer` fires in `evacuate`/`Allocator::resolve` if a nursery pointer targets unallocated space. `ECO_GC_DEBUG_LIVENESS` enables `EcoGCLivenessAudit`, which audits `EcoGCPrepare`'s root sets against MLIR liveness (skipping `eco.gc_group_member` ops since their liveness is covered by the group leader's root set). See `guides/gc-diagnostics.md`.

### Large Object Allocation

*(Apr 2026)* Objects larger than a nursery block are allocated in a dedicated pinned large-object space within the old generation. Large objects are never copied — they are pinned in place and managed by mark-sweep.

For Elm's typical use case (short-lived web applications with message-passing concurrency), thread-local heaps match the programming model naturally.

## Key Invariants

1. **No old-to-young pointers**: Guaranteed by Elm's immutability. No write barrier needed.

2. **Forwarding pointers are ephemeral**: Only exist during GC. All pointers are resolved before mutator resumes.

3. **Objects are 8-byte aligned**: Enforced by all allocation paths. Required for pointer compression to work.

4. **Headers are always first**: Every heap object starts with an 8-byte Header. Size calculation depends on this.

5. **Constants are never heap-allocated**: Nil, True, False, Unit, Nothing, EmptyString, and EmptyRec are embedded in the pointer representation.

6. **Allocation may trigger GC**: Callers must assume any allocation could move all live objects. Use `StackRootGuard` to root HPointers across allocation calls.

7. **Space membership is O(1)**: Checking if a pointer is in from-space or to-space uses cached bounds (`low_base_`, `low_end_`, etc.) for simple range comparison.

8. **Thread ownership is exclusive**: Each heap region is owned by exactly one thread. No cross-thread pointer sharing (Elm uses message passing).

## Object Layout and Size Calculation

The `getObjectSize()` function must match object layout exactly. This is a common source of bugs. Key points:

- **Fixed-size types**: `ElmInt`, `ElmFloat`, `Tuple2`, etc. have known sizes.
- **Variable-size types**: Use `hdr->size` to store element count (not byte size).
- **Closure special case**: Uses `n_values` field, not header size.
- **Always 8-byte aligned**: `(size + 7) & ~7`

When adding a new type, you must update:
1. `Tag` enum in Heap.hpp
2. Type struct definition
3. `getObjectSize()` switch statement
4. `scanObject()` in NurserySpace.cpp
5. `markChildren()` in OldGenSpace.cpp

## Testing Philosophy

The test suite uses RapidCheck for property-based testing with three core properties:

1. **Preservation**: GC preserves all reachable objects with correct values
2. **Collection**: GC reclaims unreachable objects
3. **Stability**: Multiple GC cycles maintain correctness

Key testing infrastructure:

- `HeapSnapshot`: Captures heap state before/after GC for comparison
- `HeapGraphDesc`: RapidCheck-shrinkable description of a heap graph
- `GraphRoots`: RAII wrapper that auto-unregisters roots on scope exit

When a test fails, RapidCheck provides a reproduction string. Use `--reproduce <string>` to reliably replay the failure for debugging.

## Mental Model: Think in Threads, Generations, and Regions

When reasoning about the GC, think in terms of thread ownership, where objects live, and when they move:

```
Thread initialization:
  Allocator carves out regions → ThreadLocalHeap owns [Nursery] + [OldGen]

Object lifecycle (within one thread):
  allocate() → [Nursery low_blocks (from-space)]
                       |
                       v  (minor GC - threshold exceeded)
                 [Nursery high_blocks (to-space)] or [Old gen]
                       |
                       v  (spaces swap: from_is_low_ flips)
                 [Nursery low_blocks (now to-space)]
                       |
                       v  (next minor GC, if survived PROMOTION_AGE)
                 [Old gen]  (promoted)
```

Old gen objects only die during major GC. They can never move back to nursery.

**Key state variables during GC**:
- `from_is_low_`: Which region is currently from-space (flips after each GC)
- `current_from_idx_`, `alloc_ptr_`: Bump pointer allocation state
- `current_to_idx_`, `copy_ptr_`: Evacuation destination state
- `scan_block_idx_`, `scan_ptr_`: Cheney scan position

The key questions for debugging:
1. Was it correctly evacuated? (forwarding pointer left behind)
2. Were its children correctly updated? (scanObject/markChildren)
3. Was its size calculated correctly? (getObjectSize)
4. Is the pointer in the right region? (isInFromSpace vs isInToSpace)
5. Which thread owns this memory? (check ThreadLocalHeap bounds)

## Future Direction

Several optimizations from PLAN.md §7 have been implemented:

- ✓ **Segregated-fits + BBoP**: 32 small classes (8-256 B) plus medium classes (512 B..65536 B), backed by a Big Bag of Pages *(Apr 25, 2026)*
- ✓ **Mark-driven live + lazy sweep**: live attribution at mark time, sweep paced on the allocation slow path *(Apr 26, 2026)*
- ✓ **Per-block mark bitmap sidetable**: liveness no longer rides in object headers *(Apr 26, 2026)*
- ✓ **Thread-local heaps**: Eliminates cross-thread synchronization
- ✓ **Incremental compaction**: Spreads defragmentation cost over time
- ✓ **List locality optimization**: Contiguous spine copying for better cache behavior

Remaining opportunities:

- **Stack-allocated values**: Escape analysis to avoid heap allocation entirely
- **Reference counting for uniqueness**: Detect refcount==1 to enable safe in-place mutation
- **Concurrent marking**: Mark phase running in parallel with mutator
- **NUMA-aware allocation**: Thread affinity for memory locality on multi-socket systems

The design philosophy is: start simple, prove correctness, then optimize. Complexity is added only when necessary.

---

# Compiler Backend Pipeline

The ECO compiler backend transforms Elm source code into native executables via MLIR and LLVM. This section provides an overview of the compilation pipeline; detailed theory documents for each pass are in [`design_docs/theory/`](design_docs/theory/).

## Pipeline Overview

The compiler backend consists of several phases:

```
Elm Source
    ↓
[Standard Elm Frontend: Parse, Canonicalize, Type Check]
    ↓
┌─────────────────────────────────────────────────────┐
│  ECO Backend Pipeline                               │
│                                                     │
│  PostSolve                                          │
│    - Fix remaining Group B types (Str, Chr, Float)  │
│    - Infer kernel function types                    │
│    ↓                                                │
│  Typed Optimization                                 │
│    - Preserve types through optimization            │
│    - Pattern match compilation                      │
│    ↓                                                │
│  Monomorphization                                   │
│    - Specialize polymorphic functions               │
│    - Compute concrete layouts                       │
│    - Preserve curried type structure (staging-agnostic)
│    ↓                                                │
│  Global Optimization (GlobalOpt)                    │
│    - Canonicalize closure staging (GOPT_001)        │
│    - Normalize case/if ABI (GOPT_003)               │
│    - Compute call staging metadata                  │
│    ↓                                                │
│  MLIR Generation (ECO Dialect)                      │
│    - Generate typed IR                              │
│    - Build type table for debug printing            │
│    ↓                                                │
│  ECO Dialect Lowering (Stage 2)                     │
│    - JoinPoint normalization                        │
│    - Control flow to SCF                            │
│    - RC elimination                                 │
│    - EcoGCPrepare (attach GC roots to alloc ops)    │
│    ↓                                                │
│  LLVM Dialect (Stage 3)                             │
│    - EcoToLLVM lowering                             │
│    - Functions tagged gc "eco-gc"                   │
│    ↓                                                │
│  MLIR → LLVM IR Translation                         │
│    ↓                                                │
│  RewriteStatepointsForGC (LLVM)                     │
│    - gc.statepoint/gc.relocate for every            │
│      non-leaf call in gc "eco-gc" functions         │
│    - Liveness, base inference, alloca+mem2reg       │
│    ↓                                                │
│  LLVM IR → Native Code + stackmap                   │
└─────────────────────────────────────────────────────┘
```

## Key Backend Passes

### PostSolve (Type Fixing)

After type inference, some expressions have incomplete types:

- **Group A expressions**: Most expressions now have solver-owned types, including containers (List, Tuple, Record), lambdas, accessors, let expressions, and all structural expressions *(expanded from Group B to Group A, Mar 28, 2026)*.
- **Group B expressions**: Only scalar literals (String, Char, Float, Unit) remain in Group B — these get synthetic type variables that need structural type computation.
- **Kernel functions**: `VarKernel` references don't have annotations; their types are inferred from usage patterns.

The PostSolve pass walks the AST, computing concrete types and building a `KernelTypeEnv` for typed optimization.

**See**: [PostSolve Theory](design_docs/theory/pass_post_solve_theory.md)

### Typed Optimization

The standard Elm compiler discards types after type checking since JavaScript doesn't need them. ECO's TypedOptimized AST preserves type information on every expression:

```elm
type Expr
    = Bool A.Region Bool Can.Type
    | Int A.Region Int Can.Type
    | Call A.Region Expr (List Expr) Can.Type
    -- Every variant carries Can.Type
```

This enables type-directed code generation and monomorphization.

As part of Typed Optimization, the **NormalizeLambdaBoundaries** pass flattens nested lambda structures by lifting let-bindings and case expressions out of lambda boundaries. This reduces spurious staging boundaries for downstream GlobalOpt.

**Short-circuit `&&`/`||`** *(Apr 24, 2026)*: The `Binop` arm of TypedOptimized rewrites `a && b` to `if a then b else False` and `a || b` to `if a then True else b`, so every backend inherits short-circuit semantics from the existing `If` codegen path. The strict `eco.bool.and` / `eco.bool.or` intrinsics and the JS `&&` / `||` infix arms remain for first-class uses of `Basics.and` / `Basics.or`.

**See**: [Typed Optimization Theory](design_docs/theory/pass_typed_optimization_theory.md), [NormalizeLambdaBoundaries Theory](design_docs/theory/pass_normalize_lambda_boundaries_theory.md)

### Monomorphization

Elm's parametric polymorphism must be resolved for native code. The monomorphizer uses a worklist algorithm to generate specialized versions of polymorphic functions:

```
identity : a -> a
identity x = x

-- With uses: identity 42, identity "hi"
-- Generates:
--   identity<Int> : Int -> Int
--   identity<String> : String -> String
```

Each specialization gets a unique `SpecId`. The pass also computes concrete layouts for records, tuples, and custom types.

**Key concepts**:
- `MonoType`: Monomorphized type (MInt, MFloat, MList MonoType, etc.)
- `SpecKey`: (Global, [MonoType]) identifying a specialization
- `SpecializationRegistry`: Maps SpecKey ↔ SpecId
- `forceCNumberToInt`: Aggressively resolves unresolved `CNumber` type variables to `MInt`, ensuring no `CNumber` survives to codegen
- **Let-bound multi-specialization**: When a polymorphic let-bound function is used at multiple distinct types, the monomorphizer creates separate specialized instances with fresh names (e.g., `identity_0 : Int -> Int`, `identity_1 : String -> String`)
- **Int MVarIds** *(Mar 30 – Apr 1, 2026)*: Type variable names are now Int IDs (not Strings) from monomorphization onward. The `AssignMVarIds` module assigns globally unique Int IDs to all type variables in the TypedOptimized IR at the start of monomorphization.
- **Solver root-backed MVarIds** *(Apr 4, 2026)*: The `SolverRoots` module normalizes solver variables to their union-find roots after constraint solving. `ensureMVarIdForRoot` guarantees that two type variables sharing the same solver root always receive the same MVarId, eliminating spurious specialization divergence caused by aliased type variables.
- **Scheme freshening** *(Apr 1, 2026)*: Every time a callee's type scheme is instantiated, globally unique MVarIds are allocated. This prevents collision between scheme variables and the caller's existing substitution entries.
- **Free-vars-aware substitution** *(Apr 2, 2026)*: `applySubstWithFreeVars` filters substitution to only MVarIds appearing in the canonical type being resolved (plus transitive closure), preventing cross-scheme contamination.
- **PendingCall** *(Apr 5, 2026)*: When a nested Call has a still-polymorphic result type, specialization is deferred by wrapping it in `PendingCall`. The outer callee's expected parameter type is used to refine the substitution before specializing the inner call.
- **Phantom type var normalization** *(Apr 11, 2026)*: Surviving `MVar _ CEcoValue` in specialization keys maps to sentinel values, ensuring fresh MVars from scheme bindings do not create different spec keys for identical specializations.

**Important**: Monomorphization is staging-agnostic. It preserves curried type structure from Elm semantics (e.g., `MFunction [Int] (MFunction [Int] Int)`). All staging and calling-convention decisions are deferred to GlobalOpt.

**See**: [Monomorphization Theory](design_docs/theory/pass_monomorphization_theory.md)

### Global Optimization (GlobalOpt)

After monomorphization, function types are still curried and may have incompatible calling conventions across case branches. GlobalOpt resolves all staging and ABI decisions:

1. **Inline small functions** (Phase 0): `MonoInlineSimplify` inlines small functions to reduce call overhead
2. **Wrap top-level callables** (Phase 0.5): Ensure all function values are closures before staging analysis
3. **Build staging graph** (Phase 1): `Staging.GraphBuilder` constructs a constraint graph connecting producers to slots
4. **Solve staging** (Phase 2): `Staging.Solver` uses union-find with majority voting to choose canonical segmentations
5. **Rewrite with staging** (Phase 3): `Staging.Rewriter` wraps closures with non-canonical staging in eta-expansions
6. **Compute call metadata** (Phase 4): Build `CallInfo` for MLIR codegen

**The Staging Subsystem** (`compiler/src/Compiler/GlobalOpt/Staging/`):
- `Types.elm`: ProducerId, SlotId, Node, StagingGraph types
- `GraphBuilder.elm`: Builds staging constraint graph from MonoGraph
- `Solver.elm`: Union-find solver with majority voting
- `Rewriter.elm`: Applies staging solution via eta-wrapping
- `ProducerInfo.elm`: Computes natural segmentations
- `UnionFind.elm`: Union-find data structure

**Key concepts**:
- `Segmentation`: List of stage arities (e.g., `[2,1]` = take 2 args, return closure taking 1)
- `CallModel`: `FlattenedExternal` (kernels) or `StageCurried` (user-defined)
- `CallInfo`: Pre-computed metadata for each call site
- `CallKind`: `CallDirectKnownSegmentation | CallDirectFlat | CallGenericApply` — determines calling convention
- `segmentation_unknown` *(Mar 30, 2026)*: When compiler cannot statically determine arity, it uses `CallGenericApply` with runtime `eco_apply_*` wrappers for dynamic arity dispatch
- `MonoTraverse`: Common iteration infrastructure for graph traversal (moved to `Monomorphize/`)
- **isPureExpr** *(Apr 9, 2026)*: Fixed to check both body and bound expression in `MonoLet`, and Inline expressions inside Decider trees in `MonoCase`
- **Value-only cycles** *(Apr 9, 2026)*: Zero-arg recursive bindings are now compiled as individual `MonoDefine` nodes instead of a single `MonoCycle` wrapping them in a spurious record

This separation ensures Monomorphization stays simple while GlobalOpt handles all ABI complexity.

**See**: [Global Optimization Theory](design_docs/theory/pass_global_optimization_theory.md), [Staged Currying Theory](design_docs/theory/staged_currying_theory.md)

### MLIR Generation

Converts MonoGraph to MLIR using the ECO dialect.

**Architecture**: The codegen is organized into 11 focused modules under `Compiler/Generate/MLIR/`:
- `Types.elm` - Eco types, MonoType→MlirType conversion
- `Context.elm` - Context, signatures, type registry
- `Ops.elm` - MLIR op builders (eco.*, arith.*, scf.*, func.*)
- `Patterns.elm` - Decision tree path navigation, pattern test generation
- `Expr.elm` - Expression lowering, call ABI (largest module)
- `Functions.elm` - Node generation (define, ctor, extern, cycle)
- `Backend.elm` - Program entry point

**Key responsibilities**:
- **ECO operations**: `eco.construct.list`, `eco.project.record`, `eco.call`, etc.
- **Type table**: `eco.type_table` op with type descriptors for debug printing
- **Closures**: Lambdas hoisted to top-level, captured values tracked
- **Boxing/unboxing**: Primitives (i64, f64, i16) ↔ `eco.value` conversions

**Bytes Fusion Optimization** (`BytesFusion/`): The compiler intercepts `Bytes.encode` and `Bytes.decode` calls and lowers them directly to fused BF dialect operations (cursor-based read/write) instead of going through the interpreter-style kernel:
- `Reify.elm`: Pattern-matches Elm AST to build encoder/decoder node trees
- `Emit.elm`: Emits fused BF dialect ops from reified nodes
- `BFOps.td`: Defines the BF MLIR dialect (alloc, cursor, read/write ops)

**Streaming bytecode emission** *(Apr 18-20, 2026)*: MLIR is emitted directly as MLIR binary bytecode in a streaming fashion rather than materialising a textual string. The bytecode encoder splits its attribute table into separate location and string buckets so location attrs don't inflate the string table. The streaming emitter dramatically reduces peak compiler memory for large programs; bootstrap-scale inputs are now tractable. Text-mode MLIR (`--text-mlir`) is retained for debugging.

**Mutually-recursive closure SCC allocation** *(Apr 24, 2026)*: `eco.papCreateGroup` atomically allocates an entire SCC of mutually recursive let-bound closures in one contiguous region. The Elm frontend detects contiguous closure-only SCCs of size ≥ 2 in let-chains and emits one group op instead of per-binding `papCreate`s with forward-referenced placeholders. Cross-sibling captures are written after all HPointers are known; same-generation, so no write barrier. Self-recursion and non-SCC bindings stay on the existing `fixSelfCaptures` path. This fixes a "operand #0 does not dominate this use" failure observed in mutually-recursive parsers.

**See**: [MLIR Generation Theory](design_docs/theory/pass_mlir_generation_theory.md), [MLIR Bytecode Theory](design_docs/theory/mlir_bytecode_theory.md), [Type Table Theory](design_docs/theory/pass_type_table_theory.md)

### ECO Dialect Lowering

Stage 2 passes transform ECO dialect toward LLVM:

- **EcoGCPrepare** *(Apr 2026)*: Detects all potentially allocating ops and attaches live GC roots as explicit operands. Roots are pre-converted by the type-converter adaptor, eliminating races where `!eco.value` types were already erased to `i64` before liveness analysis.
- **JoinPoint Normalization**: Ensures joinpoints have single entry
- **ECO Control Flow to SCF**: Converts eco.case to scf.if/switch
- **RC Elimination**: Removes reference counting ops (unused in tracing GC)
- **Undefined Function Stubs**: Generates stubs for missing functions
- **CheckEcoClosureCaptures** (verification): Validates closure capture consistency—ensures lambda free variables match closure captures

**See**: [JoinPoint Normalization Theory](design_docs/theory/pass_joinpoint_normalization_theory.md), [ECO Control Flow to SCF Theory](design_docs/theory/pass_eco_control_flow_to_scf_theory.md), [RC Elimination Theory](design_docs/theory/pass_rc_elimination_theory.md), [Undefined Function Theory](design_docs/theory/pass_undefined_function_theory.md)

### EcoToLLVM

Final lowering from ECO dialect to LLVM dialect. As of Feb 2026, the pass underwent significant simplification: all closure calling logic is centralized in `EcoToLLVMClosures.cpp`, and the pass no longer reverse-engineers kernel ABI types (the compiler is the sole ABI arbiter).

- Type conversion: `!eco.value` → `ptr addrspace(1)` (GC-managed pointer; **REP_LLVM_001**, Apr 17, 2026). `ptrtoint`/`inttoptr` conversions appear only at heap/global/closure storage boundaries (i64 memory slots) and for embedded-constant encoding. `BFTypeConverter` is unified with `EcoTypeConverter` so all BF runtime LLVM decls use `ptr<1>` for HPtr params/returns.
- Heap allocation via runtime calls (fast path: nursery bump; slow path: GC safepoint)
- **Allocation groups** *(Apr 16, 2026)*: Adjacent fixed-size alloc ops lower to a single fast/slow/merge CFG using `eco_gc_alloc_region_fast`/`_slow`; members are initialized at fixed offsets via `eco_init_*_at` runtime functions.
- GC roots attached to allocation ops, calls, and papExtend ops by `EcoGCPrepare`, passed through to `emitAllocWithSafepoint`
- Closure creation and invocation (centralized in `EcoToLLVMClosures.cpp`), with shared `emitRootedBoxedArgsArray` for rooted boxed-args construction
- Tagged pointer encoding for embedded constants
- `_capture_abi` attribute drives type-aware `buildEvaluatorArgs` so captured Int/Float/Char are boxed with correct primitive tags (`eco_alloc_int`/`_float`/`_char`), enabling correct `Debug.log` output on primitives
- `widenFieldToI64` handles Bool `ptr<1>` constants via `PtrToIntOp` (pointer ZExt would crash); ADT case bit manipulation lifts `ptr<1>` scrutinee to `i64` via `valueToI64` before `LShr`/`And`
- Kernel calls reflect compiler-declared types without repair
- Safepoint lowering: `eco.safepoint` is erased at LLVM lowering time; the MLIR op is retained only as a front-end marker. RS4GC inserts statepoints directly at every non-leaf call (the real GC-triggering boundary), so no intermediate marker call is needed.
- All non-external functions carry `gc "eco-gc"` attribute; runtime helpers that cannot trigger GC are annotated `gc-leaf-function` so RS4GC skips them

**PAP Wrapper Elimination (Typed Closure Calling)**: The compiler generates direct function calls even when partial application and closures are involved:

- **Homogeneous call path**: When closure structure is statically known, captures are unpacked as direct arguments
- **Heterogeneous call path**: When closure structure varies (e.g., across case branches), the closure pointer is passed
- **ABI cloning** (`AbiCloning.elm`): Functions are cloned into direct and indirect entry points as needed

**Inline papExtend**: The `eco.papExtend` operation is lowered inline (not as a runtime call), enabling LLVM to optimize saturated calls. Float arguments/results require `i64`↔`f64` bitcasts since closures store all values as `i64`.

**See**: [EcoToLLVM Theory](design_docs/theory/pass_eco_to_llvm_theory.md)

### Runtime: Platform & Scheduler

At execution time, the Platform and Scheduler subsystem implements Elm's effect manager architecture. Commands and subscriptions produced by the Elm update cycle are collected into effect bag trees (`Fx_Leaf`/`Fx_Node`/`Fx_Map`), gathered per manager, and dispatched via `onEffects` callbacks. The Scheduler drives a cooperative task-based concurrency model: each process has a root task, a continuation stack, and a mailbox. The `stepProcess` loop interprets the Task ADT (Succeed/Fail/AndThen/OnError/Binding/Receive) to advance processes through their task chains.

**GC safety** *(Apr 2026)*: `pushStack` and `mailboxPushBack` now take `HPointer` (not raw `Process*`) and re-resolve the process pointer after allocation calls that may trigger GC. The currently running Process is registered as a stack root while off the run queue. External GC root scanning is supported in `RootSet`. `StackRootGuard` RAII helper roots captured HPointers across allocations in kernel helpers. *(Apr 24, 2026)* Per-batch `FxBatch` and per-manager scratch lifted out of unrooted C++ locals into `PlatformRuntime::activeBatch_` / `effectsScratch_` member fields, scanned by an external root scanner while `dispatchActive_` is set; `dispatchEffects` builds Elm lists via `alloc::listFromPointers` rather than a manual `cons()` accumulator loop. *(Apr 24, 2026)* `eco-kernel-cpp/src/eco/MVar.cpp` reimplemented for thread-safe blocking semantics.

**See**: [Platform & Scheduler Theory](design_docs/theory/platform_scheduler_theory.md)

## Type Information Flow

A key design principle is **type preservation**: type information flows through the entire pipeline.

```
Can.Type (Canonical)
    ↓ PostSolve fixes incomplete types
Can.Type (complete)
    ↓ Typed Optimization preserves types
TOpt.Expr with Can.Type
    ↓ Monomorphization specializes to concrete types
MonoType (MInt, MFloat, MList MonoType, ...)
    ↓ MLIR Generation maps to MLIR types
MlirType (i64, f64, !eco.value, ...)
    ↓ EcoToLLVM
LLVM types
```

This enables:
- **Unboxing optimization**: Primitives stored inline in containers
- **Type-specific operations**: Different code for Int vs Float arithmetic
- **Debug printing**: Type table provides runtime type introspection

## Kernel Functions

Kernel functions are C++/runtime implementations called from Elm code. They're handled specially:

1. **PostSolve** infers types from aliases and usage
2. **Monomorphization** determines ABI mode (UseSubstitution, PreserveVars, NumberBoxed)
3. **MLIR Generation** checks for intrinsics first, then emits kernel calls with boxing/unboxing
4. **Linking** connects to C++ implementations in the runtime

**Intrinsics**: Many `Basics`, `Bitwise`, `Utils`, and `JsArray` operations are handled by [compiler intrinsics](design_docs/theory/intrinsics_theory.md) that emit direct MLIR operations, bypassing kernel calls entirely. This covers arithmetic (`add`, `sub`, `mul`, `div`), comparisons (`lt`, `le`, `gt`, `ge`), trigonometry (`sin`, `cos`, `tan`), bitwise operations (`and`, `or`, `xor`, `shiftLeftBy`), and typed array access (`JsArray.unsafeGet`, `JsArray.unsafeSet`, `JsArray.length`).

**ABI Modes** (for operations without intrinsics):
- **UseSubstitution**: Monomorphic kernels use typed parameters directly
- **PreserveVars**: Polymorphic kernels use boxed `eco.value` for all type variables
- **NumberBoxed**: Number-polymorphic kernels (`fromNumber`) receive boxed numbers

**Backend ABI Policy**: The compiler's `kernelBackendAbiPolicy` (audited against C++ `KernelExports.h`) determines whether each kernel uses `AllBoxed` (uniform `uint64_t` C++ ABI — List, Utils, JsArray, String.fromNumber, Json.wrap) or `ElmDerived` (typed C++ ABI — Basics, Bitwise, Char, etc.). The compiler is the **sole arbiter** of kernel ABI types (KERN_006); downstream passes (EcoToLLVM) simply reflect the declared types.

**See**: [Intrinsics Theory](design_docs/theory/intrinsics_theory.md), [Kernel ABI Theory](design_docs/theory/kernel_abi_theory.md)

## Detailed Documentation

Each pass and subsystem has comprehensive documentation in [`design_docs/theory/`](design_docs/theory/):

### Compilation Passes

| Document | Description |
|----------|-------------|
| [pass_post_solve_theory.md](design_docs/theory/pass_post_solve_theory.md) | PostSolve type fixing |
| [pass_typed_optimization_theory.md](design_docs/theory/pass_typed_optimization_theory.md) | Type-preserving optimization |
| [pass_normalize_lambda_boundaries_theory.md](design_docs/theory/pass_normalize_lambda_boundaries_theory.md) | Lambda boundary flattening (let/case lifting) |
| [pass_monomorphization_theory.md](design_docs/theory/pass_monomorphization_theory.md) | Polymorphism elimination |
| [pass_global_optimization_theory.md](design_docs/theory/pass_global_optimization_theory.md) | Staging canonicalization and ABI normalization |
| [staged_currying_theory.md](design_docs/theory/staged_currying_theory.md) | Staged currying theory |
| [pass_type_table_theory.md](design_docs/theory/pass_type_table_theory.md) | Runtime type metadata |
| [pass_mlir_generation_theory.md](design_docs/theory/pass_mlir_generation_theory.md) | MLIR code generation |
| [pass_joinpoint_normalization_theory.md](design_docs/theory/pass_joinpoint_normalization_theory.md) | Joinpoint cleanup |
| [pass_eco_control_flow_to_scf_theory.md](design_docs/theory/pass_eco_control_flow_to_scf_theory.md) | Control flow lowering |
| [pass_rc_elimination_theory.md](design_docs/theory/pass_rc_elimination_theory.md) | RC operation removal |
| [pass_undefined_function_theory.md](design_docs/theory/pass_undefined_function_theory.md) | Missing function stubs |
| [pass_eco_to_llvm_theory.md](design_docs/theory/pass_eco_to_llvm_theory.md) | Final LLVM lowering |

### Optimizations and Subsystems

| Document | Description |
|----------|-------------|
| [bytes_fusion_theory.md](design_docs/theory/bytes_fusion_theory.md) | Bytes.encode/decode fusion to BF dialect |
| [typed_closure_calling_theory.md](design_docs/theory/typed_closure_calling_theory.md) | PAP wrapper elimination, ABI cloning |
| [intrinsics_theory.md](design_docs/theory/intrinsics_theory.md) | Direct MLIR lowering for arithmetic/bitwise ops |
| [kernel_abi_theory.md](design_docs/theory/kernel_abi_theory.md) | Kernel function ABI modes and type handling |
| [json_heap_representation_theory.md](design_docs/theory/json_heap_representation_theory.md) | JSON values as heap-resident Custom objects |

### Cross-Cutting Concerns

| Document | Description |
|----------|-------------|
| [heap_representation_theory.md](design_docs/theory/heap_representation_theory.md) | Four representation models, unboxing, layouts |
| [mlir_verification_theory.md](design_docs/theory/mlir_verification_theory.md) | MLIR verifiers and invariant checking |
| [mlir_bytecode_theory.md](design_docs/theory/mlir_bytecode_theory.md) | MLIR bytecode format, streaming encoder |
| [platform_scheduler_theory.md](design_docs/theory/platform_scheduler_theory.md) | Platform effect dispatch, task scheduling, process model |

### Experimental

| Document | Description |
|----------|-------------|
| [monodirect_theory.md](notes/monodirect_theory.md) | Solver-directed monomorphization (removed Mar 31, 2026; kept for reference) |

## Invariant Testing Infrastructure

The compiler backend is validated through a comprehensive invariant testing system that verifies correctness at each compilation phase.

### Invariant Catalog

All compiler invariants are documented in [`design_docs/invariants.csv`](design_docs/invariants.csv), organized by phase:

| Phase | Invariants | Examples |
|-------|------------|----------|
| CANON | CANON_001-006 | Name resolution, unique IDs, no duplicates |
| TYPE | TYPE_001-007 | Constraint generation, unification, occurs check, node variable constraints |
| POST | POST_001-010 | Remaining Group B type fixing, kernel type inference, node type grounding |
| TOPT | TOPT_001-005 | Type carrying, decision trees, annotations preserved |
| MONO | MONO_001-027 | MonoType completeness, layouts, specialization registry, arity consistency |
| GOPT | GOPT_001-014 | Staging canonicalization, call information, closure arity |
| CGEN | CGEN_001-057+ | Boxing rules, SSA consistency, operation attributes, kernel declarations, projection layout consistency |
| REP_LLVM | REP_LLVM_001 | `!eco.value` → `ptr addrspace(1)` in LLVM dialect; conversions only at storage boundaries *(Apr 17, 2026)* |

### MLIR AST Inspection

The test infrastructure inspects the MLIR AST directly in Elm, avoiding MLIR text parsing:

```elm
type alias MlirOp =
    { name : String
    , operands : List String
    , results : List ( String, MlirType )
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    }
```

Shared verification logic in `Compiler/Generate/CodeGen/Invariants.elm` provides:
- `walkAllOps`: Traverse all operations in a module
- `findOpsNamed`: Find operations by name (e.g., "eco.case")
- `getAttr`: Extract typed attributes from operations
- Helpers for checking operand types, result types, and structural properties

### Key Invariants

**CGEN_001 (Boxing)**: MLIR codegen only inserts boxing/unboxing between primitive types and `eco.value`. Mismatches between different primitives (e.g., `i64` vs `f64`) indicate a monomorphization bug.

**CGEN_032 (_operand_types)**: Every operation's `_operand_types` attribute must match the SSA types of its operands. This catches type declaration vs runtime type mismatches.

**CGEN_037 (Case Scrutinee)**: For `case_kind="int"`, the scrutinee must be `i64`; for `case_kind="chr"`, it must be `i16`. The default `eco.value` is only valid for ADT/string matching.

### Test Organization

Tests are in `compiler/tests/Compiler/Generate/CodeGen/`:
- One test file per invariant (e.g., `CaseKindScrutineeTest.elm`)
- Corresponding property module (e.g., `CaseKindScrutinee.elm`)
- `Invariants.elm` provides shared utilities

Tests generate Elm code, compile it through the full pipeline, and verify the resulting `MlirModule` satisfies the invariant.

### The Type Declaration vs Runtime Type Mismatch

A key insight from invariant testing: the primary source of codegen bugs is mismatches between **declared types** (what the code says) and **runtime types** (what values actually are).

| Scenario | Declared | Actual | Result |
|----------|----------|--------|--------|
| Case scrutinee for int patterns | `eco.value` | `i64` | Type mismatch error |
| Heap extraction from ADT | `i64` | `eco.value` | Interpret pointer as int → crash |
| Unbox primitive in wrong context | `eco.value` | `i64` | Interpret int as pointer → crash |

The fix principle: **projection type must match physical storage**, not semantic type. If a field is stored boxed, project as `eco.value` then unbox; if stored unboxed, project as the primitive type then box if needed.
