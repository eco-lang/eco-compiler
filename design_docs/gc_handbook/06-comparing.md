# 6. Comparing Garbage Collectors

Comparing garbage collectors requires understanding that no single collector is "best" for all situations. This chapter examines the criteria by which algorithms are assessed, the strengths and weaknesses of different approaches in different circumstances, and presents the remarkable unified theory that reveals deep similarities between tracing and reference counting.

---

## 6.1 The Impossibility of a Universal Best Collector

It is common to ask: which is the best garbage collector to use? However, the temptation to provide a simple answer must be resisted. First, what does "best" mean? Do we want the collector that provides the best throughput, or the shortest pause times? Is space utilization important? Or is a compromise combining these desirable properties required?

Second, even if a single metric is chosen, the ranking of different collectors varies between applications. In a study of twenty Java benchmarks and six different collectors, Fitzgerald and Tarditi [2000] found that for each collector there was at least one benchmark that would have been at least 15% faster with a more appropriate collector. Furthermore, programs tend to run faster given larger heaps, but the relative performance of collectors varies according to the amount of heap space available. To complicate matters further, excessively large heaps may disperse temporally related objects, leading to worsened locality that can slow down applications.

---

## 6.2 Throughput

The first item on many users' wish lists is overall application throughput. This might be the primary goal for a batch application or for a web server where pauses might be tolerable or obscured by network delays. Although it is important that garbage collection be performed quickly, employing a faster collector does not necessarily mean that a computation will execute faster.

In a well-configured system, garbage collection should account for only a small fraction of overall execution time. If the price for faster collection is a larger tax on mutator operations, then the application's execution time may become longer rather than shorter. The cost to the mutator may be explicit or implicit:

- **Explicit costs**: Read and write barrier actions, such as those that reference counting requires
- **Implicit costs**: A copying collector may rearrange objects in a way that affects cache behavior adversely, or a reference count decrement may touch a cold object

It is essential to avoid synchronization wherever possible. Reference count modifications must be synchronized to avoid missing updates, but deferred and coalesced reference counting can eliminate much of these synchronization costs.

### Algorithmic Complexity

For mark-sweep collection, we must include the cost of both tracing (mark) and sweep phases, whereas copying collection depends only on tracing. Tracing requires visiting every live object; sweeping requires visiting every object (live and dead). It is tempting to assume that mark-sweep must therefore be more expensive than copying, but the number of instructions executed to visit an object for mark-sweep tracing is fewer than for copying tracing.

Locality plays a significant role. Prefetching techniques can hide cache misses, but it remains an open question whether such techniques can be applied to copying collection without losing the benefits of depth-first copying for mutator locality. In either tracing collector, the cost of chasing pointers is likely to dominate. If marking is combined with lazy sweeping, we obtain greatest benefit in the same circumstances that copying performs best: when the proportion of live data in the heap is small.

---

## 6.3 Pause Time

The extent to which garbage collection interrupts program execution is critical for many users. Low pause times are important not only for interactive applications but also for transaction processors where delays cause backlogs to build up.

The tracing collectors considered so far have all been stop-the-world: all mutator threads must halt before the collector runs to completion. Garbage collection pause times in early systems were legendary, but even on modern hardware, stop-the-world collectors may pause very large applications for over a second.

The immediate attraction of reference counting is that it should avoid such pauses, distributing memory management costs throughout the program. However, this benefit is not realized in high-performance reference counting systems:

1. Removing the last reference to a large pointer structure leads to recursive reference count modifications and freeing of components
2. Deferred and coalesced reference counting, the most effective performance improvements, reintroduce a stop-the-world pause to reconcile reference counts and reclaim garbage objects

As we shall see in the unified theory section, high-performance reference counting and tracing schemes are not so different as they might first appear.

---

## 6.4 Space

Memory footprint is important if there are tight physical constraints on memory, if applications are very large, or to allow applications to scale well. All garbage collection algorithms incur space overheads from several factors:

### Per-Object Overhead

Algorithms may pay a per-object penalty, for example for reference count fields.

### Copy Reserve

Semispace copying collectors need additional heap space for a copy reserve. To be safe, this needs to be as large as the volume of data currently allocated, unless a fallback mechanism is used (for example, mark-compact collection).

### Fragmentation

Non-moving collectors face the problem of fragmentation, reducing the amount of heap usable to the application.

### Metadata Space

Tracing collectors may require marking stacks, mark bitmaps, or other auxiliary data structures. Any non-compacting memory manager, including explicit managers, uses space for their own data structures such as segregated free-lists.

### Headroom for Garbage

If a tracing or deferred reference counting collector is not to thrash by collecting too frequently, it requires sufficient room for garbage in the heap. Systems are typically configured to use a heap 30% to 200-300% larger than the minimum required by the program. Hertz and Berger [2005] suggest that a garbage-collected heap three to six times larger than that required by explicitly managed heaps is needed to achieve comparable application performance.

### The Advantage of Prompt Reclamation

Simple reference counting frees objects as soon as they become unlinked from the graph of live objects. Apart from preventing accumulation of garbage, this offers potential benefits:
- Space is likely to be reused shortly after being freed, improving cache performance
- The compiler may detect when an object becomes free and reuse it immediately, without recycling through the memory manager

### Completeness and Promptness

It is desirable for collectors to be not only complete (reclaiming all dead objects eventually) but also prompt (reclaiming all dead objects at each collection cycle). Basic tracing collectors achieve this by tracing all live objects at every collection. However, modern high-performance collectors typically trade immediacy for performance, allowing some garbage to float from one collection to the next. Reference counting faces the additional problem of being incomplete—specifically, unable to reclaim cyclic garbage structures without recourse to tracing.

---

## 6.5 Implementation

Garbage collection algorithms are difficult to implement correctly, and concurrent algorithms notoriously so. The interface between the collector and the compiler is critical. Errors made by the collector often manifest long afterwards (maybe many collections later), typically when a mutator attempts to follow a reference that is no longer valid.

### Moving vs Non-Moving Collectors

The task facing copying and compacting collectors is more complex than for non-moving collectors. A moving collector must identify every root and update the reference accordingly, whereas a non-moving collector need only identify at least one reference to each live object, and never needs to change the value of a pointer.

Conservative collectors can reclaim memory without accurate knowledge of mutator stack or object layouts. Instead they make intelligent (but safe) guesses about whether a value really is a reference. Because non-moving collectors do not update references, the risk of misidentifying a value as a heap pointer is confined to introducing a space leak: the value itself will not be corrupted.

### Reference Counting Trade-offs

Reference counting is tightly coupled to the mutator. The advantages are that it can be implemented in a library, making it possible for the programmer to decide selectively which objects should be managed by reference counting and which should be managed explicitly. The disadvantages are that this coupling introduces processing overheads and that all reference count manipulations must be correct.

### Performance-Critical Code

The performance of any modern language that makes heavy use of dynamically allocated data is heavily dependent on the memory manager. Critical actions typically include allocation, mutator updates including barriers, and the garbage collector's inner loops. Wherever possible, code sequences for these critical actions need to be inlined, but this must be done carefully to avoid exploding generated code size.

If the processor's instruction cache is sufficiently large and the code expansion is sufficiently small (less than 30%), this blowup may have negligible effect on performance. Otherwise, it is necessary to distinguish the common case which needs to be small enough to inline (the "fast path") while calling out to a procedure for the less common "slow path."

---

## 6.6 Adaptive Systems

Commercial systems often offer the user a choice of garbage collectors, each with many tuning options. The tuning levers tend not to be independent of one another. Several approaches to adaptation have been suggested:

### Dynamic Collector Switching

Some systems adapt dynamically by switching collectors at runtime according to heap size available. This either requires offline profiling runs to annotate programs with the best collector/heap-size combination, or switching based on comparing current space usage with maximum heap available.

### Machine Learning

Machine learning techniques can predict the best collector from static properties of the program, requiring only a single training run.

### Ergonomic Tuning

Some collectors attempt to tune performance against user-supplied throughput and maximum pause time goals, adjusting the size of spaces within the heap accordingly.

### Practical Advice

The best advice for developers is: know your application. Measure its behavior and the size and lifetime distributions of the objects it uses. Then experiment with the different collector configurations on offer. Unfortunately, this needs to be done with real data sets. Synthetic and toy benchmarks are likely to mislead.

---

## 6.7 A Unified Theory of Garbage Collection

Bacon et al [2004] show that tracing and reference counting collectors share remarkable similarities. Their abstract framework allows expressing a wide variety of collectors in a way that highlights precisely where they are similar and where they differ.

### Abstract Garbage Collection

Garbage collection can be expressed as a fixed-point computation that assigns reference counts ρ(n) to nodes n ∈ Nodes. Reference counts include contributions from the root set and incoming edges from nodes with non-zero reference counts:

```
∀ref ∈ Nodes:
  ρ(ref) = |{fld ∈ Roots : *fld = ref}|
         + |{fld ∈ Pointers(n) : n ∈ Nodes ∧ ρ(n) > 0 ∧ *fld = ref}|
```

Having assigned reference counts, nodes with a non-zero count are retained and the rest should be reclaimed. Reference counts need not be precise but may simply be a safe approximation of the true value.

### Abstract Tracing Collection

```pseudo
collectTracing():
    rootsTracing(W)
    scanTracing(W)
    sweepTracing()

scanTracing(W):
    while not isEmpty(W):
        src ← remove(W)
        ρ(src) ← ρ(src) + 1        // shade src
        if ρ(src) = 1:             // src was white, now grey
            for each fld in Pointers(src):
                ref ← *fld
                if ref ≠ null:
                    W ← W + [ref]

sweepTracing():
    for each node in Nodes:
        if ρ(node) = 0:            // node is white
            free(node)
        else:                      // node is black
            ρ(node) ← 0            // reset node to white

rootsTracing(R):
    for each fld in Roots:
        ref ← *fld
        if ref ≠ null:
            R ← R + [ref]
```

Tracing collection starts with reference counts of all nodes being zero. Collection proceeds by tracing the object graph to discover all nodes reachable from the roots. The `scanTracing` procedure increments the reference count of each node each time it is encountered. When a reachable node is discovered for the first time (when ρ(src) is set to 1), the collector recurses through all its out-edges by adding child nodes to the work list W.

A practical implementation can use a single-bit value for each node's reference count (a mark-bit rather than a full-sized reference count) to record whether the node has already been visited. The mark-bit is thus a coarse approximation of the true reference count.

### Abstract Reference Counting Collection

```pseudo
collectCounting(I, D):
    applyIncrements(I)
    scanCounting(D)
    sweepCounting()

scanCounting(W):
    while not isEmpty(W):
        src ← remove(W)
        ρ(src) ← ρ(src) - 1
        if ρ(src) = 0:
            for each fld in Pointers(src):
                ref ← *fld
                if ref ≠ null:
                    W ← W + [ref]

sweepCounting():
    for each node in Nodes:
        if ρ(node) = 0:
            free(node)

Write(src, i, dst):
    inc(dst)
    dec(src[i])
    src[i] ← dst

inc(ref):
    if ref ≠ null:
        I ← I + [ref]

dec(ref):
    if ref ≠ null:
        D ← D + [ref]

applyIncrements(I):
    while not isEmpty(I):
        ref ← remove(I)
        ρ(ref) ← ρ(ref) + 1
```

Reference counting operations are buffered by the mutator's `inc` and `dec` procedures rather than performed immediately. This buffering technique is very practical for multithreaded applications. The collector performs deferred increments with `applyIncrements` and deferred decrements with `scanCounting`.

### The Deep Similarity

The tracing and reference counting algorithms are identical but for minor differences:

1. Each has a scan procedure: `scanTracing` uses reference count **increments** whereas `scanCounting` uses **decrements**
2. In both cases the recursion condition checks for a zero reference count
3. Each has a sweep procedure that frees the space occupied by garbage nodes

The outline structures of both algorithms are identical. Deferred reference counting, which defers counting references from the roots, is similarly captured by this framework.

### Fixed Points and Cycles

Computing reference counts is tricky when it comes to cycles in the object graph. Consider a simple isolated cycle where A points to B and B points to A, with no external references. There are two fixed-point solutions:

- **Least fixed-point**: ρ(A) = ρ(B) = 0 (both are garbage)
- **Greatest fixed-point**: ρ(A) = ρ(B) = 1 (both appear live)

Tracing collectors compute the **least fixed-point**, whereas reference counting collectors compute the **greatest fixed-point**, which is why they cannot (by themselves) reclaim cyclic garbage. The difference between these two solutions is precisely the set of objects reachable only from garbage cycles.

Reference counting algorithms can use partial tracing to reclaim garbage cycles by starting from the greatest fixed-point solution and contracting the set of unreclaimed objects to the least fixed-point solution.

---

## 6.8 Guidelines for Choosing Collectors

Based on the analysis above, here are guidelines for choosing collectors:

| Collector Type | Best When |
|---------------|-----------|
| **Copying/Generational** | Most objects die young; space is available; moving objects is acceptable |
| **Mark-Sweep** | Space is tight; moving is not possible or acceptable |
| **Mark-Compact** | Fragmentation hurts performance; willing to accept higher pause times |
| **Concurrent** | Latency is critical; barrier overhead is acceptable; precise barriers can be implemented |
| **Reference Counting / Hybrids** | Prompt reclamation needed; non-moving is required; add tracing for cycles |
| **Region/Immix/G1-style** | Want partial compaction; need regional control of pauses |

---

## 6.9 Summary

Comparing collectors hinges on workload characteristics, constraints (latency vs throughput vs space), and implementation complexity. Metrics must include pause time distributions, throughput impact, and memory overhead. Adaptive strategies can tune parameters dynamically, but require careful implementation to avoid oscillation.

The unified theory reveals that tracing and reference counting are duals: tracing computes the least fixed-point of reachability (identifying all live objects from roots), while reference counting computes the greatest fixed-point (identifying objects with non-zero counts). High-performance implementations of both converge toward similar structures with buffering and batch processing.

No single collector wins universally. Design is a choice of trade-offs informed by measurements on representative workloads.
