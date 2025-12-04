# THEORY.md

This document captures the essential insights and design rationale for the eco-runtime garbage collector. It is written for an engineer joining the project who wants to quickly build a working understanding of how the system thinks, not just how it works.

For the broader project context, see PLAN.md. ECO (Elm Compiler Offline) is a native compilation backend and runtime for Elm, targeting high-performance multi-threaded execution via LLVM. This runtime provides memory management for compiled Elm programs.

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

### Old Generation: Mark-Sweep with Lazy Sweeping and Incremental Compaction

Long-lived objects promoted from the nursery live in the old generation, which uses mark-and-sweep with several optimizations:

1. **Mark**: Trace from roots, marking reachable objects (tri-color: white/grey/black).
2. **Lazy Sweep**: Instead of sweeping all objects immediately, sweep on-demand when allocation needs free space.
3. **Segregated Free Lists**: 32 size classes (8-256 bytes in 8-byte increments) for fast small-object allocation.
4. **Incremental Compaction**: When fragmentation exceeds a threshold, evacuate sparse blocks incrementally.

**Allocation strategy**:
- Small objects (≤256 bytes): Check segregated free list first, fall back to bump allocation
- Large objects: Bump allocation from current block
- When current block exhausted: Trigger lazy sweep to reclaim memory, or acquire new block

**GC phases** (state machine):
```
Idle → Marking → Sweeping → Idle
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
- `promotion_age`: GC cycles before promotion (default 1)
- `nursery_gc_threshold`: Occupancy threshold for minor GC trigger (default 90%)
- `use_hybrid_dfs`: Enable list locality optimization (default true)

Configuration is validated on `Allocator::initialize()` to catch invalid combinations early.

**Heap validation**: During major GC, pointers are validated with `isInHeap()` - a simple O(1) bounds check against the reserved address range. This is simpler than checking `isInOldGen() || isInNursery()` and correctly handles all valid heap pointers regardless of which generation they're in.

## Promotion: When Objects Grow Up

Objects are promoted from nursery to old gen after surviving `PROMOTION_AGE` minor GCs (default 1, configurable via `HeapConfig`). The age is tracked in the header:

```cpp
u32 age : 2;    // Survives up to 3 GCs before promotion
u32 epoch : 2;  // GC epoch when last marked (for incremental marking)
u32 pin : 1;    // Prevents relocation (for FFI or debugging)
```

When `evacuate()` sees an object that has reached promotion age, it allocates in the old gen instead of to-space. Promoted objects are added to a buffer and scanned to update their child pointers, since they may reference other nursery objects that haven't been evacuated yet.

## Execution Model: Thread-Local Stop-the-World

There is no separate collector thread. Each mutator thread runs its own GC on its own heap:

- **Minor GC**: Triggered when nursery occupancy exceeds `nursery_gc_threshold` (default 90%)
- **Major GC**: Triggered when old gen committed bytes exceed a threshold
- **Incremental work**: Marking and compaction can be spread across allocation slow-paths

Each thread's GC is stop-the-world *for that thread only*. Other threads continue executing. This avoids global synchronization while keeping the GC simple.

The `ThreadLocalHeap` coordinates its nursery and old gen:
1. `allocate()` bumps pointer in nursery
2. When threshold exceeded, `minorGC()` evacuates survivors
3. Promoted objects go to thread-local old gen
4. When old gen grows large, `majorGC()` marks and sweeps

For Elm's typical use case (short-lived web applications with message-passing concurrency), thread-local heaps match the programming model naturally.

## Key Invariants

1. **No old-to-young pointers**: Guaranteed by Elm's immutability. No write barrier needed.

2. **Forwarding pointers are ephemeral**: Only exist during GC. All pointers are resolved before mutator resumes.

3. **Objects are 8-byte aligned**: Enforced by all allocation paths. Required for pointer compression to work.

4. **Headers are always first**: Every heap object starts with an 8-byte Header. Size calculation depends on this.

5. **Constants are never heap-allocated**: Nil, True, False, Unit, Nothing, EmptyString, and EmptyRec are embedded in the pointer representation.

6. **Allocation may trigger GC**: Callers must assume any allocation could move all live objects.

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

- ✓ **Segregated free lists**: 32 size classes for small objects (8-256 bytes)
- ✓ **Thread-local heaps**: Eliminates cross-thread synchronization
- ✓ **Incremental compaction**: Spreads defragmentation cost over time
- ✓ **List locality optimization**: Contiguous spine copying for better cache behavior

Remaining opportunities:

- **Stack-allocated values**: Escape analysis to avoid heap allocation entirely
- **Reference counting for uniqueness**: Detect refcount==1 to enable safe in-place mutation
- **Concurrent marking**: Mark phase running in parallel with mutator
- **NUMA-aware allocation**: Thread affinity for memory locality on multi-socket systems

The design philosophy is: start simple, prove correctness, then optimize. Complexity is added only when necessary.
