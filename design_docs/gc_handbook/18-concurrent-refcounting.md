# 18. Concurrent Reference Counting

Concurrent reference counting aims to maintain prompt reclamation while reducing the overhead of synchronization on every pointer update. This chapter covers buffering techniques, concurrent cycle collection, and hybrid approaches combining reference counting with tracing.

---

## 18.1 The Challenge of Concurrent Reference Counting

Reference counting has attractive properties:
- Prompt reclamation when reference count reaches zero
- Incremental: work distributed across mutations
- No tracing pause required (for acyclic structures)

However, naively implemented, concurrent RC faces challenges:
- Every pointer update requires atomic operations
- Reference count updates from multiple threads must synchronize
- Cascade deletions can cause unbounded pauses
- Cyclic garbage cannot be reclaimed

---

## 18.2 Buffered Reference Counting

### Basic Buffering

Defer increment and decrement operations to reduce synchronization:

```pseudo
// Thread-local buffers
incBuffer: ThreadLocal<Buffer>
decBuffer: ThreadLocal<Buffer>

increment(object):
    incBuffer.push(object)
    if incBuffer.full():
        flushIncBuffer()

decrement(object):
    decBuffer.push(object)
    if decBuffer.full():
        flushDecBuffer()

flushIncBuffer():
    lock(rcLock)
    for each object in incBuffer:
        object.refCount ← object.refCount + 1
    unlock(rcLock)
    incBuffer.clear()

flushDecBuffer():
    lock(rcLock)
    for each object in decBuffer:
        object.refCount ← object.refCount - 1
        if object.refCount = 0:
            scheduleReclamation(object)
    unlock(rcLock)
    decBuffer.clear()
```

### Coalesced Reference Counting

Eliminate redundant updates to the same object:

```pseudo
// Track net change per object
deltaMap: ThreadLocal<HashMap<Object, int>>

writeBarrier(oldRef, newRef):
    if oldRef ≠ null:
        deltaMap[oldRef] ← deltaMap.getOrDefault(oldRef, 0) - 1
    if newRef ≠ null:
        deltaMap[newRef] ← deltaMap.getOrDefault(newRef, 0) + 1

    if deltaMap.size() > THRESHOLD:
        flushDeltas()

flushDeltas():
    lock(rcLock)
    for each (object, delta) in deltaMap:
        object.refCount ← object.refCount + delta
        if object.refCount = 0:
            scheduleReclamation(object)
    unlock(rcLock)
    deltaMap.clear()
```

**Benefit:** Multiple inc/dec to the same object coalesce to a single update.

### Deferred Reference Counting

Ignore stack references; periodically reconcile:

```pseudo
// Only count heap references
heapWriteBarrier(src, field, newValue):
    oldValue ← src[field]
    src[field] ← newValue

    decrement(oldValue)
    increment(newValue)

// Periodic reconciliation
reconcile():
    stopAllMutators()

    // Decrement for all objects only reachable from stacks
    for each object with refCount = 0:
        if not reachableFromStack(object):
            reclaim(object)

    resumeAllMutators()
```

**Trade-off:** Objects may float between reconciliations if only stack-referenced.

---

## 18.3 Lock-Free Reference Counting

### Atomic Increment/Decrement

Use atomic operations for ref count updates:

```pseudo
atomicIncrement(object):
    AtomicAdd(&object.refCount, 1)

atomicDecrement(object):
    oldCount ← AtomicAdd(&object.refCount, -1)
    if oldCount = 1:  // Was 1, now 0
        scheduleReclamation(object)
```

### Split Reference Counts

Separate counts for local vs global references:

```pseudo
Object:
    localCount: int     // Thread-local count (no sync needed)
    globalCount: int    // Shared count (atomic)

threadLocalIncrement(object, thread):
    if object.owningThread = thread:
        object.localCount ← object.localCount + 1
    else:
        AtomicAdd(&object.globalCount, 1)

mergeOnMigration(object):
    // When object escapes to another thread
    AtomicAdd(&object.globalCount, object.localCount)
    object.localCount ← 0
```

### Biased Reference Counting

Bias count operations toward the creating thread:

```pseudo
Object:
    biasedThread: Thread
    localCount: int
    sharedCount: atomic int

biasedIncrement(object, currentThread):
    if object.biasedThread = currentThread:
        // Fast path: no synchronization
        object.localCount ← object.localCount + 1
    else:
        // Slow path: atomic
        AtomicAdd(&object.sharedCount, 1)
```

---

## 18.4 Handling Cascade Deletions

When a reference count reaches zero, decrementing children can cause a cascade:

```pseudo
// Naive approach - unbounded recursion
reclaim(object):
    for each field in pointerFields(object):
        child ← *field
        if child ≠ null:
            decrement(child)
            if child.refCount = 0:
                reclaim(child)  // Recursive!
    free(object)
```

### Work List Approach

Avoid deep recursion with explicit work list:

```pseudo
scheduleReclamation(object):
    reclaimQueue.push(object)

processReclamations():
    while not reclaimQueue.empty():
        object ← reclaimQueue.pop()
        for each field in pointerFields(object):
            child ← *field
            if child ≠ null:
                decrement(child)
        free(object)
```

### Lazy Reclamation

Limit work per allocation:

```pseudo
allocateWithReclamation(size):
    // Do some reclamation work
    for i from 1 to WORK_UNITS:
        if reclaimQueue.empty():
            break
        processOneReclamation()

    return allocate(size)

processOneReclamation():
    object ← reclaimQueue.pop()
    // Process one level only
    for each field in pointerFields(object):
        child ← *field
        if child ≠ null:
            atomicDecrement(child)  // May schedule more
    free(object)
```

---

## 18.5 Cycle Collection

Reference counting cannot reclaim cyclic garbage. Solutions combine RC with cycle detection.

### Trial Deletion (Bobrow's Algorithm)

Suspect objects are those whose count reaches zero then increases:

```pseudo
suspectSet: Set<Object>

decrement(object):
    oldCount ← AtomicAdd(&object.refCount, -1)
    if oldCount = 1:
        reclaim(object)
    else if object in suspectSet:
        // Count increased from zero - may be cycle
        scheduleCycleDetection()
```

### Concurrent Cycle Collection

Background cycle detection using trial deletion:

```pseudo
cycleCollector():
    while true:
        // Wait for suspects
        waitForSuspects()

        // Phase 1: Mark red (trial decrement)
        for each suspect in suspects:
            markRed(suspect)

        // Phase 2: Scan (increment reachable from outside)
        for each suspect in suspects:
            scan(suspect)

        // Phase 3: Collect (free remaining red objects)
        for each suspect in suspects:
            if color(suspect) = RED:
                collectCycle(suspect)

markRed(object):
    if color(object) ≠ RED:
        color(object) ← RED
        for each child in children(object):
            object.trialCount ← object.trialCount - 1

scan(object):
    if color(object) = RED:
        if object.trialCount > 0:
            // Externally reachable
            scanGreen(object)
        else:
            // Still potentially cyclic garbage
            for each child in children(object):
                scan(child)

scanGreen(object):
    color(object) ← GREEN
    for each child in children(object):
        child.trialCount ← child.trialCount + 1
        if color(child) = RED:
            scanGreen(child)

collectCycle(object):
    if color(object) = RED:
        color(object) ← FREED
        for each child in children(object):
            collectCycle(child)
        free(object)
```

### Synchronization Challenges

Concurrent cycle collection must handle:
- Mutator modifications during marking
- Ensuring consistent snapshot

```pseudo
safeCycleCollection():
    // Use SATB-style barrier during cycle marking
    cycleMarkingActive ← true

    // Mark phase with barrier protection
    markCycleCandidates()

    // Brief synchronization to get consistent state
    synchronizeWithMutators()

    // Complete cycle collection
    collectConfirmedCycles()

    cycleMarkingActive ← false

cycleSATBBarrier(object, field, newValue):
    oldValue ← object[field]
    object[field] ← newValue

    if cycleMarkingActive and oldValue ≠ null:
        // Record deletion for cycle collector
        cycleBuffer.push(oldValue)
```

---

## 18.6 Sliding Views

Maintain two reference counts: a stable count and a delta:

```pseudo
Object:
    stableCount: int   // Stable reference count
    deltaCount: int    // Accumulated changes

// Mutator updates delta
concurrentIncrement(object):
    AtomicAdd(&object.deltaCount, 1)

concurrentDecrement(object):
    AtomicAdd(&object.deltaCount, -1)

// Collector periodically reconciles
reconcileView():
    for each object in heap:
        delta ← AtomicExchange(&object.deltaCount, 0)
        object.stableCount ← object.stableCount + delta
        if object.stableCount = 0:
            scheduleReclamation(object)
```

**Benefit:** Collector can work with stable counts without blocking mutators.

---

## 18.7 Hybrid Tracing/RC

Combine reference counting with tracing for cycle collection:

### Ulterior Reference Counting

Use tracing for young objects, RC for old:

```pseudo
// Young objects: tracing (copying) collection
// Old objects: reference counting

writeBarrier(src, field, newValue):
    oldValue ← src[field]
    src[field] ← newValue

    // Generational barrier
    if isOld(src) and isYoung(newValue):
        recordOldToYoung(src, field)

    // RC barrier for old→old references
    if isOld(src) and isOld(newValue):
        if oldValue ≠ null and isOld(oldValue):
            decrement(oldValue)
        if newValue ≠ null:
            increment(newValue)
```

### Age-Oriented RC

Objects start with tracing; promoted objects use RC:

```pseudo
promote(object):
    // Initialize reference count from current references
    count ← 0
    for each reference to object:
        if isOld(referenceSource):
            count ← count + 1
    object.refCount ← count

    // Add to old generation
    addToOldGen(object)
```

---

## 18.8 Performance Considerations

### Buffer Sizing

- **Larger buffers**: More coalescing, less synchronization, delayed reclamation
- **Smaller buffers**: More synchronization, faster reclamation

```pseudo
BUFFER_SIZE = 1024  // Typical: 256-4096 entries

adaptiveBufferSize():
    // Adjust based on contention
    if highContention():
        bufferSize ← bufferSize * 2
    else if lowContention() and bufferSize > MIN_SIZE:
        bufferSize ← bufferSize / 2
```

### False Sharing

Avoid cache line contention on reference counts:

```pseudo
// Pad reference count to cache line
Object:
    refCount: int
    padding: byte[CACHE_LINE_SIZE - sizeof(int)]
    header: ...

// Or use separate count table
countTable: array[heapSize / objectAlignment] of int
getRefCount(object):
    index ← (addressOf(object) - heapStart) / ALIGNMENT
    return countTable[index]
```

### Batch Processing

Process buffers in batches for better cache behavior:

```pseudo
processBatch(buffer):
    // Sort by address for sequential access
    sort(buffer, byAddress)

    for each object in buffer:
        updateRefCount(object)
```

---

## 18.9 Correctness Guarantees

### Safety

Reference counts must never go negative, and objects must not be freed while referenced:

```pseudo
safeDecrement(object):
    loop:
        count ← object.refCount
        if count ≤ 0:
            error("Invalid count")
        if CompareAndSet(&object.refCount, count, count - 1):
            return count - 1
```

### Liveness

Garbage must eventually be collected:
- Acyclic garbage: collected when count reaches zero
- Cyclic garbage: collected by periodic cycle detection

```pseudo
ensureLiveness():
    // Periodic cycle collection
    if timeSinceLastCycleCollection > CYCLE_INTERVAL:
        runCycleCollection()

    // Or trigger on heap pressure
    if heapUsage > CYCLE_THRESHOLD:
        runCycleCollection()
```

---

## 18.10 Summary

Concurrent reference counting balances prompt reclamation against synchronization overhead:

| Technique | Trade-off |
|-----------|-----------|
| **Buffering** | Reduced sync, delayed reclamation |
| **Coalescing** | Fewer updates, memory for tracking |
| **Deferred RC** | Simpler barriers, reconciliation pause |
| **Lock-free** | No locks, atomic overhead |
| **Biased** | Fast thread-local, slow cross-thread |
| **Sliding views** | Concurrent collector, delayed reclamation |

Cycle collection strategies:
- Trial deletion (Bobrow) for background cycle detection
- SATB barriers for concurrent cycle marking
- Hybrid with tracing for young generation

Key design points:
- Buffer sizes affect latency vs throughput
- False sharing can severely impact performance
- Cascade deletions need work limiting
- Cycle collection adds complexity but is necessary
