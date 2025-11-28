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

## Two Generations, Two Algorithms

The GC uses two generations because the "weak generational hypothesis" holds: most Elm values die young. The design pairs each generation with the algorithm best suited to its characteristics.

### Nursery: Block-Based Semi-Space Copying (Cheney's Algorithm)

Young objects live in the nursery, which uses Cheney's copying collector:

1. **Bump-pointer allocation**: Just increment a pointer. O(1), no fragmentation concerns.
2. **Copy survivors to to-space**: Only live objects pay the cost; garbage is free.
3. **Swap spaces**: Old from-space becomes new to-space; memory is implicitly reclaimed.

This is optimal for high-churn, short-lived allocations. The cost of GC is proportional to survivors, not total allocations.

**Block-based design**: Rather than two contiguous semi-spaces, the nursery uses AllocBuffer-sized blocks organized into two sets (`from_blocks_` and `to_blocks_`). This enables:

- **Dynamic growth**: When survivors exceed 75% of to-space capacity, both spaces grow by 50%
- **Unified block management**: Same block size as old gen AllocBuffers (simpler memory layout)
- **On-demand acquisition**: Blocks are acquired from the Allocator as needed

The trade-off: `isInFromSpace()` requires O(log n) lookup via `std::set::upper_bound()` rather than O(1) pointer comparison. This is acceptable because the check only happens during GC (once per pointer), not on the allocation fast path.

### Old Generation: Mark-and-Sweep

Long-lived objects promoted from the nursery live in the old generation, which uses mark-and-sweep:

1. **Mark**: Trace from roots, marking reachable objects (tri-color: white/grey/black).
2. **Sweep**: Walk all objects; unreachable (white) objects are garbage.

Mark-sweep does not require 2x space overhead. The current implementation is non-compacting.

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

1. **Embedded constants**: Nil, True, False, Unit are represented by the constant field, not as heap objects. No allocation, no pointer chase.
2. **Compression**: 8-byte pointers instead of native 64-bit addresses.
3. **Relocation-friendly**: Offsets from a base are easier to adjust than raw addresses.

The `fromPointerRaw` and `toPointerRaw` conversions are the only places that touch `heap_base`. All pointer manipulation goes through these.

## Unified Heap: One Address Space, Two Regions

The allocator reserves a single large address space (1GB by default) via `mmap` without committing physical memory. This space is partitioned:

```
[0 .. heap_reserved/2)      - Old generation
[heap_reserved/2 .. end)    - Nursery blocks
```

Physical memory is committed on demand:
- Nursery: Blocks committed via `acquireNurseryBlock()` as the nursery initializes or grows
- Old gen: Committed in AllocBuffer-sized chunks as objects are promoted

This lazy commitment means the runtime reserves address space but only uses physical memory for actual allocations.

**Configuration**: The nursery is sized via `nursery_block_count` (must be even, split between from-space and to-space). Total nursery size = `nursery_block_count * alloc_buffer_size`.

**Heap validation**: During major GC, pointers are validated with `isInHeap()` - a simple O(1) bounds check against the reserved address range. This is simpler than checking `isInOldGen() || isInNursery()` and correctly handles all valid heap pointers regardless of which generation they're in.

## Promotion: When Objects Grow Up

Objects are promoted from nursery to old gen after surviving `PROMOTION_AGE` minor GCs (currently 1). The age is tracked in the header:

```cpp
u32 age : 2;  // Survives up to 3 GCs before promotion
```

When `evacuate()` sees an object that has reached promotion age, it allocates in the old gen instead of to-space. Promoted objects are added to a buffer and scanned to update their child pointers, since they may reference other nursery objects that haven't been evacuated yet.

## Execution Model: Mutator Runs GC

There is no separate collector thread. Each mutator thread runs its own GC:

- **Minor GC**: Triggered when nursery allocation fails (all from-space blocks exhausted)
- **Major GC**: Triggered when old gen committed bytes exceed a threshold

This stop-the-world approach is simple and avoids synchronization complexity. The mutator pauses, runs GC, then resumes. For Elm's typical use case (short-lived web applications), this is sufficient.

## Key Invariants

1. **No old-to-young pointers**: Guaranteed by Elm's immutability. No write barrier needed.

2. **Forwarding pointers are ephemeral**: Only exist during GC. All pointers are resolved before mutator resumes.

3. **Objects are 8-byte aligned**: Enforced by all allocation paths. Required for pointer compression to work.

4. **Headers are always first**: Every heap object starts with an 8-byte Header. Size calculation depends on this.

5. **Constants are never heap-allocated**: Nil, True, False, Unit are embedded in the pointer representation.

6. **Allocation may trigger GC**: Callers must assume any allocation could move all live objects.

7. **Block membership is O(log n)**: Checking if a pointer is in from-space or to-space uses `std::set::upper_bound()`. This only matters during GC, not allocation.

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

## Mental Model: Think in Generations and Blocks

When reasoning about the GC, think in terms of where objects live and when they move:

```
Allocation  -->  [Nursery from-space blocks]
                       |
                       v  (minor GC - blocks exhausted)
                 [Nursery to-space blocks] or [Old gen]
                       |
                       v  (spaces swap)
                 [Nursery from-space blocks]  (now has survivors)
                       |
                       v  (next minor GC, if survived enough)
                 [Old gen]  (promoted)
```

Old gen objects only die during major GC. They can never move back to nursery.

**Block iteration during GC**: The nursery maintains iterators (`current_from_it_`, `current_to_it_`) to track which block is currently active for allocation and copying. Cheney's algorithm advances through to-space blocks as it copies survivors.

The key questions for debugging:
1. Was it correctly evacuated? (forwarding pointer left behind)
2. Were its children correctly updated? (scanObject/markChildren)
3. Was its size calculated correctly? (getObjectSize)
4. Is the pointer in the right block set? (isInFromSpace vs isInToSpace)

## Future Direction

The current GC is a foundation. PLAN.md §7 describes advanced techniques to pursue later:

- **Fixed-size object spaces**: Segregated pools for common sizes (Cons cells, tuples)
- **Stack-allocated values**: Escape analysis to avoid heap allocation entirely
- **Reference counting for uniqueness**: Detect refcount==1 to enable safe in-place mutation
- **Lock-free coordination**: Reduce contention in multi-threaded scenarios

The design philosophy is: start simple, prove correctness, then optimize. Complexity is added only when necessary.
