# GC Implementation Cheatsheet

A practical guide for choosing and implementing garbage collection strategies based on your runtime's requirements.

---

## Quick Reference: The Four Fundamental Approaches

| Algorithm | Reclamation | Fragmentation | Space Overhead | Best For |
|-----------|-------------|---------------|----------------|----------|
| **Mark-Sweep** | Batch (tracing) | Yes | Low (mark bits) | Old generation, conservative GC |
| **Mark-Compact** | Batch (tracing) | No | Low | Full-heap collection, defragmentation |
| **Copying** | Batch (tracing) | No | High (2× semispace) | Young generation, fast allocation |
| **Reference Counting** | Immediate | Yes | Medium (count field) | Prompt reclamation, non-moving |

---

## Choosing a Strategy by Runtime Type

### Functional Programming Languages (Elm, Haskell, OCaml, Erlang)

**Characteristics**: Immutable data, high allocation rate, short-lived objects, no mutation of old objects.

**Recommended approach**: Generational copying with mark-sweep/compact old generation.

**Key optimizations**:
- **No write barriers needed** for old→young tracking (immutability guarantees no such pointers)
- **Aggressive nursery sizing** (4-16MB) since allocation is the primary operation
- **Single survivor space** or direct promotion (objects rarely survive multiple collections)
- **Bump-pointer allocation** in nursery for maximum speed
- **Consider Cheney copying** with BFS for list-heavy workloads (siblings clustered)

**What to avoid**: Reference counting (high allocation rate makes barrier cost prohibitive), complex remembered sets (not needed with immutability).

---

### Object-Oriented Languages (Java, C#, Python, Ruby)

**Characteristics**: Mutable objects, complex object graphs, variable lifetimes, potential for cycles.

**Recommended approach**: Generational with card-table write barriers.

**Key optimizations**:
- **Card table** (512-byte cards) for tracking old→young pointers
- **Multiple survivor spaces** (eden + 2 survivors) with age-based promotion
- **Promotion age of 2-4** to avoid promoting short-lived but not instant-death objects
- **Mark-compact for old generation** to handle fragmentation from long-running applications
- **Consider G1/region-based** for large heaps with latency requirements

**What to avoid**: Pure copying for old generation (2× space overhead at scale), ignoring cycles in any RC component.

---

### Database Systems and Caches

**Characteristics**: Large working sets, variable object sizes, long-lived data, latency-sensitive queries.

**Recommended approach**: Region-based collection (G1-style) or mark-sweep with incremental compaction.

**Key optimizations**:
- **Region-based heap** (1-32MB regions) for partial collection
- **Concurrent marking** with SATB barriers to minimize pause times
- **Incremental compaction** of sparse regions during low-activity periods
- **Large object space** (LOS) with mark-sweep for buffers and result sets
- **Lazy sweeping** to amortize reclamation cost

**What to avoid**: Full-heap stop-the-world collection (unacceptable latency), pure copying (memory overhead).

---

### Real-Time and Embedded Systems

**Characteristics**: Strict latency bounds, limited memory, predictable behavior required.

**Recommended approach**: Incremental mark-sweep or work-based collection.

**Key optimizations**:
- **Work-based scheduling**: Tax allocation with proportional GC work
- **Bounded mark stack** with overflow to bitmap
- **Arraylets/oblets** for large objects (fixed-size fragments)
- **Slack-based collection** during idle periods
- **Time-based quanta** with guaranteed minimum mutator utilization (MMU)

**What to avoid**: Unbounded pauses, cascade deletions in RC, large copy operations.

---

### Systems Programming (Rust-style arenas, game engines)

**Characteristics**: Manual control desired, arena/pool allocation, deterministic destruction.

**Recommended approach**: Region-based allocation with bulk deallocation, or hybrid manual+GC.

**Key optimizations**:
- **Arena allocation** with mass free (no per-object overhead)
- **Pool allocation** for fixed-size objects
- **Optional tracing** for cycle detection only
- **Explicit pinning** for FFI interop
- **Conservative stack scanning** if needed

**What to avoid**: Per-object GC overhead when bulk deallocation suffices.

---

### Scripting and Dynamic Languages (JavaScript, Lua)

**Characteristics**: Dynamic typing, closures, prototype chains, interactive use.

**Recommended approach**: Generational with incremental marking.

**Key optimizations**:
- **Incremental marking** to keep pauses under 10ms for interactive feel
- **Hidden class/shape tracking** for efficient object scanning
- **Weak references** for caches and memoization tables
- **Ephemeron support** for weak key→value relationships
- **Concurrent sweep** to further reduce pauses

**What to avoid**: Long stop-the-world pauses (breaks interactive feel), ignoring closure environments in root scanning.

---

## Critical Implementation Details

### Write Barriers

| Barrier Type | Use Case | Cost | Implementation |
|--------------|----------|------|----------------|
| **Card marking** | Generational (old→young) | Very low | `cardTable[addr >> 9] = DIRTY` |
| **Remembered set** | Region-based (cross-region) | Low | Hash set per region |
| **SATB** | Concurrent marking | Medium | Buffer deleted references |
| **Incremental update** | Concurrent marking | Medium | Grey new targets from black sources |

**Rule of thumb**: Start with unconditional card marking. Add filtering only if profiling shows barrier overhead > 2%.

### Allocation Fast Path

The allocation fast path must be as fast as possible:

```
allocate(size):
    aligned = align(size, 8)
    if bump + aligned > limit:
        return slowPath(size)
    result = bump
    bump += aligned
    return result
```

Target: 3-5 instructions for the fast path. Use thread-local allocation buffers (TLABs) to avoid synchronization.

### Root Scanning

Sources of roots (must scan all):
- Thread stacks and registers
- Global/static variables
- JNI/FFI handles
- Finalizer queues
- Weak reference tables

**Conservative vs precise**: Conservative treats anything that looks like a pointer as one (safe but can't move objects). Precise requires compiler cooperation (stack maps, register maps) but enables copying.

### Object Layout for GC

Minimum header should include:
- Type/class pointer (for scanning)
- Mark bit or color (2 bits)
- Forwarding state (1 bit or full word when forwarded)
- Optional: age (for generational), hash code, lock state

**Alignment**: 8-byte minimum (allows 3 tag bits in pointers). 16-byte for SIMD-heavy workloads.

---

## Tuning Parameters

### Nursery/Young Generation

| Parameter | Low Value Effect | High Value Effect | Starting Point |
|-----------|------------------|-------------------|----------------|
| **Size** | Frequent minor GC | Longer minor pauses | 1-4MB per thread |
| **Promotion age** | Early promotion, old-gen pressure | Objects linger, survivor overflow | 2 |
| **Survivor ratio** | More eden, overflow risk | Wasted survivor space | 8:1:1 (eden:s0:s1) |

### Old Generation

| Parameter | Low Value Effect | High Value Effect | Starting Point |
|-----------|------------------|-------------------|----------------|
| **Heap size** | Frequent major GC | Long major pauses, memory waste | 2-4× live set |
| **Compaction threshold** | Frequent compaction | Fragmentation accumulates | 70% occupancy |
| **Region size** | Fine-grained collection | Overhead per region | 1-4MB |

### Concurrent Collection

| Parameter | Low Value Effect | High Value Effect | Starting Point |
|-----------|------------------|-------------------|----------------|
| **Marking threads** | Slow marking | Diminishing returns, contention | cores/4 |
| **SATB buffer size** | Frequent flushes | Memory overhead | 256-1024 entries |
| **Initiating occupancy** | Early start (safe) | Risk of allocation stall | 45% |

---

## Common Pitfalls

1. **Floating garbage**: SATB preserves objects deleted during marking until next cycle. Not a leak, but increases memory usage.

2. **Premature promotion**: Objects promoted too early fill old generation. Increase promotion age or survivor space.

3. **Card table scanning cost**: If old generation is large with many dirty cards, consider filtering barriers or switching to remembered sets.

4. **Concurrent mode failure**: If allocation outpaces concurrent collection, falls back to STW. Start collection earlier or increase heap.

5. **Fragmentation death spiral**: Mark-sweep with high allocation rate of varied sizes leads to fragmentation. Add periodic compaction.

6. **Finalization delays**: Objects with finalizers survive an extra cycle. Minimize finalizer use; prefer weak references with cleanup.

7. **Large object allocation**: Large objects in main heap cause fragmentation. Use separate LOS with page-aligned allocation.

8. **Stack overflow in marking**: Deep object graphs overflow mark stack. Use iterative marking with overflow bitmap fallback.

---

## Quick Decision Tree

```
START
  │
  ├─► Need immediate reclamation? ──► Reference Counting + cycle backup
  │
  ├─► Latency critical (<10ms)? ──► Concurrent/Incremental + region-based
  │
  ├─► Memory constrained? ──► Mark-Sweep (no copy reserve needed)
  │
  ├─► High allocation rate? ──► Generational with copying nursery
  │
  ├─► Long-running server? ──► G1-style with compacting old gen
  │
  └─► Simple embedded? ──► Mark-Sweep with lazy sweeping
```

---

## Performance Targets

| Metric | Acceptable | Good | Excellent |
|--------|------------|------|-----------|
| **Minor GC pause** | <50ms | <10ms | <1ms |
| **Major GC pause** | <500ms | <100ms | <10ms (incremental) |
| **Allocation throughput** | 100MB/s | 500MB/s | 1GB+/s |
| **GC overhead** | <10% | <5% | <2% |
| **Memory efficiency** | 50% utilization | 70% utilization | 85%+ utilization |

---

## Further Reading

- **Chapters 2-5**: Core algorithms (mark-sweep, compact, copying, RC)
- **Chapter 9**: Generational collection deep dive
- **Chapters 14-18**: Parallel and concurrent techniques
- **Chapter 19**: Real-time and bounded-latency approaches

