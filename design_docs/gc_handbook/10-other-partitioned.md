# 10. Other Partitioned Schemes

In the previous chapter we looked at generational and other age-based collection schemes. Those algorithms partitioned objects by their age and chose a partition to collect based on some age-related property. Although generational collection is highly effective for a wide range of applications, it does not address all the problems facing the collector. This chapter examines schemes outside the age-based collection framework but still based on partitioning the heap.

---

## 10.1 Large Object Spaces

Large object spaces are one of the most common ways to partition the heap. The definition of "large" can be based on absolute size (e.g., greater than 1024 bytes), size relative to allocator blocks, or size relative to the heap.

Large objects meet several criteria for segregation:
- More expensive to allocate
- More likely to induce fragmentation (internal and external)
- Expensive to copy (space and time)
- Cost of copying may be dominated by updating pointers if the object is a large array of pointers

For these reasons, large object spaces are often managed by collectors that usually do not physically move their objects, although even large objects may need occasional compaction.

### Implementation Approaches

The simplest approach uses a free-list allocator with mark-sweep collection:

```pseudo
allocateLargeObject(size):
    // Search free-list for suitable block
    block ← firstFit(largeFreeList, size)
    if block = null:
        collectLargeObjectSpace()
        block ← firstFit(largeFreeList, size)
    if block = null:
        return null  // Out of memory
    return splitAndAllocate(block, size)
```

Several implementations separate large objects into a small header and a body. The body stays in a non-moving area, but the header is managed with other small objects. This allows generational treatment of the header while the body remains pinned.

Some virtual machines (ExactVM, JRockit, Marmot) allocate large objects directly into the old generation, skipping the nursery. Since large objects are likely to survive for some time, this saves copying them from the young generation.

### Pointer-Free Objects

There are good reasons for segregating typically large objects not directly related to their size. If an object does not contain any pointers, it is unnecessary to scan it. Segregation allows knowledge of whether the object is pointer-free to be derived from its address. If the mark-bit is kept in a side table, the object need not be touched at all. Allocating large bitmaps and strings in their own area can lead to significant performance improvements.

---

## 10.2 The Treadmill Collector

The Treadmill provides some advantages of semispace copying algorithms in a non-moving collector. It is organized as a cyclic, double-linked list of objects partitioned into four segments:
- **Black**: Scanned objects
- **Grey**: Visited but not fully scanned
- **White**: Not yet visited (fromspace)
- **Free**: Available for allocation

Four pointers control the Treadmill:
- `scan`: Start of grey segment (divides grey from black)
- `B` and `T`: Bottom and top of white fromspace
- `free`: Divides free segment from black

```pseudo
treadmillAllocate(size):
    if free = B:
        flip()  // Memory exhausted, start collection
    result ← free
    advance(free)  // clockwise
    snap(result, black)
    return result

flip():
    // Reinterpret black as white
    swap(B, T)
    // Now trace to completion

evacuate(object):
    // "Copy" by moving between list segments
    unsnap(object, white)
    snap(object, grey)

scan():
    while scan ≠ T:
        for each field in Pointers(objectAt(scan)):
            if isWhite(*field):
                evacuate(*field)
        advance(scan)  // anticlockwise (black grows)
```

### Benefits

- Allocation and "copying" are constant time, not dependent on object size
- Snapping simplifies traversal order choices:
  - Snap to end of grey → breadth-first
  - Snap at scan pointer → depth-first
- No physical copying eliminates copy reserve requirement

### Disadvantages

- Per-object overhead of two link pointers
- Must accommodate objects of different sizes (often solved with separate Treadmills per size class)

For large objects, the overhead is less significant since objects are page-aligned anyway.

---

## 10.3 Topological Collectors

### The Train Algorithm (Mature Object Space)

The Train algorithm manages a mature object space outside an age-based scheme by dividing it into fixed-size areas called **cars**, structured into FIFO lists called **trains**. At each collection, a single car is condemned and survivors are copied to other cars.

The key insight: by imposing discipline on destination cars, a garbage cycle will eventually be copied to a train of its own, which can be reclaimed entirely.

```pseudo
trainCollection():
    // 1. Select lowest car c of lowest train t as from-car
    c ← lowestCar(lowestTrain())

    // 2. If no external references to train t, reclaim entire train
    if noRootReferences(train(c)) and emptyRememberedSet(train(c)):
        reclaimTrain(train(c))
        return

    // 3. Copy root-reachable objects to higher train
    for each object in c:
        if reachableFromRoot(object):
            copy(object, newTrainCar())

    // 4. Recursively copy reachable objects
    scanAndCopy(newTrainCar())

    // 5. Move promoted objects to train holding reference
    for each promoted in promotedObjects:
        moveTo(promoted, trainWithReferenceTo(promoted))

    // 6. Process remembered set - move externally referenced
    for each slot in rememberedSet(c):
        object ← *slot
        if inCar(object, c):
            copy(object, trainOfSource(slot))

    // 7. Move remaining reachable to end of current train
    for each object in c:
        if isLive(object):
            copy(object, lastCar(train(c)))

    // 8. Discard from-car
    reclaimCar(c)
```

**Virtues:**
- Incremental: bounds copying per cycle to one car size
- Co-locates objects with those that refer to them
- Requires only unidirectional remembered sets (high to low numbered trains/cars)

**Challenges:**
- Isolating a garbage structure may require O(n^2) cycles
- "Futile" collections can occur when external references flip between objects
- Popular objects induce large remembered sets

### Connectivity-Based Collection

Hirzel et al. observed that object lifetimes are strongly correlated with connectivity:
- Stack-reachable objects tend to be short-lived
- Global-reachable objects tend to live for most of execution
- Objects connected by pointer chains tend to die together

Their connectivity-based model uses a conservative pointer analysis to divide objects into stable partitions forming a DAG. The collector can choose any partition (or set) to collect provided it also collects all predecessor partitions.

**Benefits:**
- No write barriers or remembered sets needed
- Partitions can be reclaimed early (as soon as tracing finishes, white objects are unreachable)
- Popular child partitions can be ignored

---

## 10.4 Thread-Local Garbage Collection

One way to reduce pause times is to perform collection independently for each thread. If objects can only be accessed by a single thread and are stored in their own **thread-local heaplet**, these heaplets can be managed without synchronization.

### Organization

Typically:
- Single shared space for potentially shared objects
- Per-thread heaplets for thread-local objects
- Strict pointer direction rules:
  - Local → local (same thread): OK
  - Local → shared: OK
  - Shared → local: NOT OK
  - Local → local (different thread): NOT OK

```pseudo
threadLocalCollection(thread):
    // Stop only this thread
    suspendThread(thread)

    // Collect thread's heaplet
    roots ← threadRoots(thread)
    for each root in roots:
        if inHeaplet(*root, thread):
            *root ← evacuate(*root)

    // Cheney scan within heaplet
    scan()

    resumeThread(thread)
```

### Static vs Dynamic Segregation

**Static (escape analysis):**
- Compiler determines which objects can escape
- Challenges with dynamic class loading

**Dynamic (write barrier):**
- Detect escapement at runtime
- Set global bit when thread creates reference to object it didn't allocate
- Must propagate to transitive closure

### Erlang Model

Erlang uses immutable data with message-passing concurrency. Each process has its own private heap. Because data is immutable, message passing uses copying semantics and thread-local heaps can be collected independently. Shared binaries are reference counted.

---

## 10.5 Stack Allocation and Region Inference

### Stack Allocation

Allocating objects on the stack rather than the heap:
- Potentially reduces GC frequency
- No tracing or reference counting needed
- Gentler on caches

**Key constraint:** No stack-allocated object can be reachable from an object with longer lifetime.

```pseudo
stackAllocate(size, frame):
    // Check frame has room
    if frame.top + size > frame.limit:
        return heapAllocate(size)  // Fallback

    result ← frame.top
    frame.top ← frame.top + size
    return result

// Write barrier detects escaping references
writeBarrierStack(src, field, dst):
    if isHeap(src) and isStack(dst):
        // Object escaping - copy to heap
        dst ← copyToHeap(dst)
    src[field] ← dst
```

**Scalar replacement** is a related optimization: replacing an object with local variables representing its fields, avoiding allocation entirely.

### Region Inference

Objects are allocated into regions; entire regions are reclaimed when their contents are no longer needed. Region reclamation is constant time.

Decisions about region creation, allocation, and reclamation may be made by:
- The programmer (explicit annotations)
- The compiler (inference)
- The runtime system
- A combination

The Real-Time Specification for Java (RTSJ) provides immortal and scoped regions with strict pointer directionality rules.

---

## 10.6 Hybrid Mark-Sweep/Copying Collectors

### Evacuation vs Allocation Thresholds

Spoonhower et al. characterize collectors by two thresholds:
- **Evacuation threshold**: How much live data to trigger evacuation
- **Allocation threshold**: How much free space to reuse

| Collector | Evacuation | Allocation |
|-----------|------------|------------|
| Mark-sweep | 0% | 100% |
| Semispace copying | 100% | 0% |

### Lang-Dupont Incremental Compaction

Divides heap into k+1 windows, one empty. At collection:
- One window is fromspace, empty window is tospace
- Other windows use mark-sweep
- Evacuate fromspace objects; mark others

```pseudo
langDupontCollection():
    fromWindow ← selectFromWindow()
    toWindow ← emptyWindow

    // Trace heap
    for each root in Roots:
        trace(root)

    // Rotate windows for next collection
    advanceWindows()

trace(ref):
    if isMarked(ref) or isForwarded(ref):
        return
    if inWindow(ref, fromWindow):
        evacuate(ref, toWindow)
    else:
        mark(ref)
    for each field in Pointers(ref):
        trace(*field)
```

The whole heap is compacted in k collections at 1/k space overhead.

### Garbage-First (G1)

A sophisticated incrementally-compacting algorithm designed for soft real-time goals.

**Organization:**
- Heap divided into equal-sized windows
- Thread-local bump-pointer allocation buffers
- Humongous objects (>3/4 window) get their own windows
- Arbitrary windows can be chosen for collection

**Collection:**
1. Concurrent marking (single thread)
2. Use bitmap to select low-liveness windows
3. Parallel evacuation (all mutators stopped)

```pseudo
g1Collection():
    // Concurrent mark phase
    concurrentMark()

    // Select regions for evacuation
    candidates ← selectLowLivenessRegions()

    // Stop the world
    stopAllMutators()

    // Parallel evacuation
    parallelEvacuate(candidates)

    resumeAllMutators()

selectLowLivenessRegions():
    regions ← []
    for each region in heap:
        liveness ← liveBytes(region) / regionSize
        if liveness < EVACUATION_THRESHOLD:
            regions.add(region)
    return sortByLiveness(regions)
```

G1 can operate generationally ("fully young" or "partially young" modes).

### Immix

A mostly mark-sweep collector that eliminates fragmentation by copying when necessary.

**Structure:**
- 32KB blocks divided into 128-byte lines
- Small objects: bump-allocate into free lines
- Medium objects (>line, <large): bump-allocate into empty blocks
- Large objects: separate large object space

```pseudo
immixAllocate(size):
    addr ← sequentialAllocate(currentLines)
    if addr ≠ null:
        return addr

    if size < LINE_SIZE:
        return allocSlowHot(size)
    else:
        return overflowAllocate(size)

allocSlowHot(size):
    lines ← getNextLinesInBlock()
    if lines = null:
        lines ← getNextRecyclableBlock()
    if lines = null:
        lines ← getFreeBlock()
    if lines = null:
        return null  // Out of memory
    return immixAllocate(size)
```

**Mark-region:** Immix marks both objects and lines. A small object may span two lines; the line after any marked sequence is implicitly marked (conservative).

**Opportunistic compaction:** Uses fragmentation statistics from previous collection to decide whether to mark or evacuate each block.

---

## 10.7 Design Considerations

### Routing Decisions

- Size thresholds for large objects
- Type-based routing (pointer-free, code, etc.)
- Thread identity for thread-local allocation
- Escape analysis results

### Remembered Sets

Cross-space pointers must be tracked. Options:
- Per-region remembered sets
- Card tables
- Write barriers with filtering

### Space-Time Trade-offs

- More spaces → finer control but more metadata
- Evacuation vs mark-in-place decisions
- Copy reserve requirements

---

## 10.8 Summary

Beyond simple generational heaps, partitioned schemes tailor collection to object properties:

| Scheme | Purpose | Key Mechanism |
|--------|---------|---------------|
| **Large Object Space** | Handle expensive-to-move objects | Page-aligned allocation, mark-sweep |
| **Treadmill** | Non-moving incremental collection | Linked list color segments |
| **Train** | Bound pause times, collect cycles | Cars in trains, incremental evacuation |
| **Thread-Local** | Reduce synchronization | Per-thread heaplets, escape detection |
| **Regions** | Constant-time reclamation | Bulk deallocation |
| **G1/Immix** | Partial compaction, pause control | Region selection, mark-region |

Design hinges on routing policies, remembered sets, and balancing metadata overhead with pause/throughput goals.
