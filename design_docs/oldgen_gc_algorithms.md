# GC Algorithms in OldGenSpace.cpp - Analysis Report

## Overview

The `OldGenSpace.cpp` file implements the old generation (mature object space) for the Elm runtime's garbage collector. This document analyzes all GC algorithms employed and compares them with alternatives, focusing on **ultra-short pause times**, **avoiding stop-the-world pauses**, and **maintaining good throughput**.

---

## Algorithms Implemented

1. **Tri-Color Mark-and-Sweep** (Incremental)
2. **Free-List Allocation with Size Classes** (Segregated Fits)
3. **Lazy Sweeping**
4. **Incremental Compaction** (Evacuation-Based)
5. **Bump-Pointer Allocation**

---

## 1. Tri-Color Mark-and-Sweep (Incremental)

**Location in code:** `runtime/src/OldGenSpace.cpp:278-478`

### Implementation Details

The code uses a classic tri-color marking scheme:
- **White** - Not yet discovered (potential garbage)
- **Grey** - Discovered but children not processed
- **Black** - Fully processed (survives collection)

### Key Functions
- `startMark()` (line 279): Initializes marking, pushes roots onto mark stack
- `incrementalMark()` (line 313): Processes `work_units` objects at a time
- `markChildren()` (line 354): Type-specific child traversal

### Pseudo Code
```pseudo
markPhase():
    for each obj in Heap: obj.color ← WHITE
    greySet ← emptyQueue()

    for each rootRef in Roots:
        if obj ≠ null and obj.color = WHITE:
            obj.color ← GREY
            enqueue(greySet, obj)

    while not isEmpty(greySet):
        obj ← dequeue(greySet)
        for each childRef in obj.fields:
            if child.color = WHITE:
                child.color ← GREY
                enqueue(greySet, child)
        obj.color ← BLACK
```

### Alternatives Comparison

| Strategy | Pause Time | Pause Predictability | Throughput | Barrier Type | Floating Garbage | Complexity |
|----------|-----------|---------------------|------------|--------------|------------------|------------|
| **STW Mark** | HIGH | Poor (∝ live set) | BEST | None | None | Low |
| **Incremental Mark** (current) | MEDIUM | Better (work-bounded) | Good | None | None | Medium |
| **SATB Concurrent** | LOW | Good | Medium | Write barrier | Yes | High |
| **Incremental-Update Concurrent** | LOW | Good | Medium | Write barrier | Less | High |
| **Read-Barrier Concurrent** (ZGC/Shenandoah) | LOWEST | Excellent | Lower | Read barrier | None | Very High |

---

## 2. Free-List Allocation with Size Classes

**Location in code:** `runtime/src/OldGenSpace.cpp:126-208, 486-534`

### Implementation Details

The code uses 64 size classes (`NUM_SIZE_CLASSES`) with segregated free lists:
```cpp
static constexpr size_t NUM_SIZE_CLASSES = 64;
FreeCell* free_lists_[NUM_SIZE_CLASSES];
```

### Pseudo Code
```pseudo
allocate(size):
    size ← align(size)
    cls ← sizeClass(size)

    block ← remove(freeLists[cls])
    if block ≠ null:
        return block

    return allocateSlow(cls)  // Get fresh block or sweep

addToFreeList(obj, size):
    cls ← sizeClass(size)
    push(freeLists[cls], obj)
```

### Alternatives Comparison

| Strategy | Allocation Speed | Fragmentation | GC Integration | Lock Contention |
|----------|-----------------|---------------|----------------|-----------------|
| **Bump Pointer** | FASTEST | None in buffer | Requires compaction | Low (per-buffer) |
| **Segregated Free-list** (current) | Fast (O(1)) | Internal only | Works with mark-sweep | Low (per-class) |
| **Single Free-list** | Slow (O(n)) | External | Works with mark-sweep | High |
| **Buddy Allocator** | Medium | Power-of-two rounding | Any | Medium |
| **TLAB + Bump Pointer** | FASTEST + no contention | None | Requires compaction | None (thread-local) |

---

## 3. Lazy Sweeping

**Location in code:** `runtime/src/OldGenSpace.cpp:540-636`

### Implementation Details

Instead of sweeping the entire heap at once, sweeping is deferred and performed incrementally during allocation:
- `transitionToSweeping()` (line 540): Prepares lazy sweep state
- `lazySweep()` (line 570): Sweeps bounded amount to find free space

### Pseudo Code
```pseudo
lazySweep(target_class, work_budget):
    work_done ← 0

    while work_done < work_budget and sweeping:
        if sweep_cursor = null:
            if sweep_buffer_index >= buffers.size:
                complete_sweeping()
                return
            sweep_cursor ← buffers[sweep_buffer_index].start

        while sweep_cursor < buffer.end and work_done < budget:
            if object.color = BLACK:
                object.color ← WHITE  // Reset for next cycle
            else:
                addToFreeList(object)  // Dead object
            sweep_cursor += object_size
            work_done += object_size
```

### Alternatives Comparison

| Strategy | Pause Contribution | Pause Predictability | Throughput | Space Overhead | Implementation |
|----------|-------------------|---------------------|------------|----------------|----------------|
| **Eager STW** | HIGH (adds to GC pause) | Poor | Good | Low | Simple |
| **Lazy Sweep** (current) | LOW (amortized) | Medium | Good | Medium (unswept garbage) | Medium |
| **Concurrent Sweep** | NONE | Excellent | Medium | Medium | Complex |

---

## 4. Incremental Compaction (Evacuation-Based)

**Location in code:** `runtime/src/OldGenSpace.cpp:680-1104`

### Implementation Details

Three-phase compaction to reduce fragmentation:
1. **Select evacuation set** - Choose buffers with most garbage
2. **Evacuate** - Copy live objects to new locations, install forwarding pointers
3. **Fix references** - Update all pointers to forwarded objects

### Key Functions
- `scheduleCompaction()` (line 687): Initiates compaction when utilization < threshold
- `selectEvacuationSet()` (line 712): Selects buffers with >30% garbage
- `evacuateSlice()` (line 791): Copies objects incrementally
- `installForwardingPointer()` (line 882): Uses `Tag_Forward` header
- `fixReferencesSlice()` (line 920): Updates pointers in non-evacuated objects
- `freeEvacuatedBuffers()` (line 1084): Reclaims fully evacuated buffers

### Pseudo Code
```pseudo
incrementalCompact():
    markFromRoots()
    evacuationSet ← selectLowLivenessRegions()

    for each region in evacuationSet:
        evacuateRegion(region)
        yield_to_mutators()

evacuateRegion(region):
    for each obj in region:
        if isMarked(obj):
            dest ← allocateInDenseRegion(obj.size)
            memcpy(dest, obj, obj.size)
            setForwardingPointer(obj, dest)

    updateReferencesToEvacuatedObjects(region)
    freeRegion(region)
```

### Alternatives Comparison

| Strategy | Fragmentation | Pause Time | Pause Scales With | Space Overhead | Throughput |
|----------|---------------|-----------|-------------------|----------------|------------|
| **No Compaction** | HIGH over time | NONE | N/A | Minimal | Best until fragmentation hurts |
| **STW Full Compact** | Eliminated | VERY HIGH | Heap size | Low | Lower during compaction |
| **Incremental Compact** (current) | Low | MEDIUM | Evacuation set | Copy reserve | Good |
| **Concurrent Copying** (ZGC-style) | None | LOWEST | Near-constant | Copy reserve + metadata | Lower (barrier overhead) |

---

## 5. Bump-Pointer Allocation

**Location in code:** `runtime/src/OldGenSpace.cpp:210-272`

### Implementation Details

Fast O(1) allocation by incrementing a pointer within an `AllocBuffer`. Used as fallback when free list is empty.

### Pseudo Code
```pseudo
bump_alloc(size):
    size ← align(size)
    new_ptr ← alloc_ptr + size
    if new_ptr > buffer.end:
        acquire_new_buffer()
        return bump_alloc(size)

    result ← alloc_ptr
    alloc_ptr ← new_ptr
    return result
```

---

## Comprehensive Comparison Tables

### Table 1: Current OldGenSpace Algorithms vs Alternatives

| Algorithm | Current Implementation | Max Pause | Pause Scales With | Throughput | Barrier Cost | STW Phases |
|-----------|----------------------|-----------|-------------------|------------|--------------|------------|
| **Tri-color Mark-Sweep** | Incremental marking (allocation-paced) | Medium | Live objects in mark stack | Good | None | Mark phase only |
| **Free-list + Size Classes** | 64 size classes | N/A (allocation) | N/A | Excellent | None | N/A |
| **Lazy Sweeping** | On-demand during allocation | Low | Sweep work budget | Good | None | None |
| **Incremental Compaction** | Region-based evacuation | Medium | Evacuation set size | Good | None | Evacuation + fixup |
| **Bump-pointer Allocation** | Fallback in AllocBuffers | N/A | N/A | Excellent | None | N/A |

### Table 2: Major Algorithm Families vs Pause Time and Throughput

| Family | STW Phases | Typical Max Pause | Mutator Overhead | Throughput | Notes |
|--------|-----------|-------------------|------------------|------------|-------|
| **STW Mark-Sweep** | Whole collection | High; ∝ live+heap | None | High | Simple, long pauses |
| **STW Mark-Compact** | Whole collection | Very high | None | Lower on large heaps | Eliminates fragmentation |
| **STW Copying** | Whole condemned space | Medium-high | None | High in nursery | 2× copy reserve |
| **Generational (STW old)** | Minor: young; Major: full | Minor short; majors long | Write barriers | High if young dominates | Classic JVM |
| **Mostly-concurrent Mark-Sweep** | Short initial/remark | Short (ms-scale) | SATB/incremental barriers | Slightly reduced | CMS-style |
| **Region-based incr. compaction** | STW evacuations of selected regions | Tunable; bounded | Write barriers + metadata | Good | G1/Immix style |
| **Mostly-concurrent Copying** | Very short STW (roots/flips) | Lowest; near-constant | Read barriers on all accesses | Lower (barrier tax) | ZGC/Shenandoah/C4 |
| **Real-time incremental** | Very small bounded quanta | Bounded ~µs-ms | Per-allocation taxes + barriers | Trades for predictability | Hard real-time |

### Table 3: Marking/Barrier Variants vs Latency & Throughput

| Variant | Barriers | Pause Characteristics | Throughput Impact | Typical Use |
|---------|----------|-----------------------|-------------------|-------------|
| **STW Mark** | None | Long pauses ∝ live set | Best (no barrier tax) | Classic mark-sweep/compact |
| **SATB** | Write barrier logging old values | Short initial/remark; main work concurrent | Moderate overhead | CMS, G1 concurrent marking |
| **Incremental update** | Write barrier greying new targets | Similar to SATB; possibly more re-mark | Similar medium overhead | Alternative concurrent mark |
| **Concurrent copying (read barriers)** | Read barriers on most accesses | Lowest pauses; copying mostly concurrent | High steady-state cost | ZGC, Shenandoah, C4 |
| **Real-time incremental** | Barriers + per-allocation work tax | Bounded micro-pauses | Sacrifices throughput for predictability | Hard real-time runtimes |

### Table 4: Complete Collector Designs Comparison

| Collector Type | Typical Max Pause | Throughput | Barrier Cost | Complexity | Best For |
|---------------|-------------------|------------|--------------|------------|----------|
| **STW Generational** | 100ms - 1s+ | BEST | Minimal (card table) | Low | Batch workloads |
| **CMS-style** | 10-50ms | Good | SATB write barriers | Medium | Server with moderate latency |
| **G1-style** (similar to current) | 10-200ms (tunable) | Good | SATB + remembered sets | Medium-High | General purpose |
| **Immix-style** | 10-100ms | Good | Minimal | Medium | Memory-intensive apps |
| **ZGC/Shenandoah** | <10ms (heap-independent) | Lower | Read barriers on ALL loads | Very High | Ultra-low latency |
| **Real-time (Metronome)** | <1ms (bounded) | LOWEST | High (work tax + barriers) | Very High | Hard real-time |

---

## Specific Trade-offs for Elm/OldGenSpace

Given Elm's **immutability** (no old→young pointers, no write barriers needed):

| Design Choice | Pros for Elm | Cons | Pause Impact |
|---------------|--------------|------|--------------|
| **No write barriers** | Excellent throughput, simple | Can't do SATB concurrent marking easily | Limits concurrency options |
| **Incremental marking** (current) | Spreads work across allocations | Still has STW transitions | Medium pauses |
| **Lazy sweep** (current) | Good latency | Unpredictable allocation time | Low pauses |
| **Buffer-based compaction** (current) | Bounded work per pause | Requires forwarding pointers | Medium pauses |
| **Concurrent marking** (potential) | Lower pauses | Need snapshot mechanism | Low pauses |
| **Read barriers** (potential) | Lowest pauses | Significant overhead on all reads | Lowest pauses |

---

## Path to Ultra-Short Pauses

### Current OldGenSpace Design (G1-like):
- **Pause profile**: Medium (bounded by evacuation set and mark stack)
- **Throughput**: Good
- **Barrier overhead**: None

### Options to Reduce Pauses Further:

| Option | Pause Reduction | Throughput Cost | Implementation Effort |
|--------|----------------|-----------------|----------------------|
| **Smaller evacuation sets** | 20-30% | Minimal | Low |
| **Finer-grained incremental marking** | 20-30% | Minimal | Low |
| **Concurrent sweep thread** | 10-20% | Low | Medium |
| **SATB concurrent marking** | 50-70% | 5-10% | High |
| **Read-barrier concurrent copying** | 80-90% | 15-25% | Very High |

### Recommended Path for Elm Runtime:

1. **Short-term** (current design is good):
   - Tune `COMPACTION_WORK_BUDGET` and `MARK_WORK_RATIO` for desired pause bounds
   - Ensure evacuation set selection limits live bytes moved

2. **Medium-term** (if pauses still too high):
   - Add concurrent sweep thread
   - Consider SATB-style snapshot for concurrent marking

3. **Long-term** (if sub-10ms required):
   - Investigate read-barrier concurrent copying (ZGC-style)
   - Note: Elm's immutability doesn't help here since read barriers are needed regardless

---

## Key Design Decisions in Current Implementation

1. **Allocation-paced marking** (line 132-160): Marking work is spread across allocations using `MARK_WORK_RATIO` to avoid long pauses.

2. **New objects during GC are Black** (line 175-180, 224-230): Objects allocated during marking/sweeping are immediately marked Black to ensure they survive the current cycle.

3. **Buffer metadata tracking** (line 503-506): Per-buffer `live_bytes` and `garbage_bytes` enable informed compaction decisions.

4. **Utilization threshold** for compaction (line 677): `UTILIZATION_THRESHOLD` triggers compaction when heap becomes too fragmented.

---

## References

- GC Handbook (Jones, Hosking, Moss)
- ZGC: A Scalable Low-Latency Garbage Collector (Liden, Karlsson)
- Shenandoah: An open-source concurrent compacting garbage collector for OpenJDK
- The Garbage Collection Handbook: The Art of Automatic Memory Management
