# 5. Reference Counting

Reference counting is a direct collection method that maintains a count of incoming references to each object. When an object's count reaches zero, it is immediately reclaimed. Unlike tracing collectors, RC identifies garbage directly from the object itself, without graph traversal. This chapter covers the core algorithm, deferred and coalesced RC, cycle collection, and hybrid approaches combining RC with tracing.

---

## 5.1 The Core Algorithm

Each object maintains a reference count that tracks how many pointers refer to it:

```pseudo
Object:
    header: Header
    refCount: int      // Number of incoming references
    fields: ...

// Pointer assignment updates counts
Write(obj, field, newValue):
    oldValue ← obj[field]
    obj[field] ← newValue
    if newValue ≠ null:
        increment(newValue)
    if oldValue ≠ null:
        decrement(oldValue)

increment(obj):
    obj.refCount ← obj.refCount + 1

decrement(obj):
    obj.refCount ← obj.refCount - 1
    if obj.refCount = 0:
        reclaim(obj)

reclaim(obj):
    for each field in Pointers(obj):
        child ← *field
        if child ≠ null:
            decrement(child)  // May cascade
    free(obj)
```

### Allocation

```pseudo
New(size):
    obj ← allocate(size)
    obj.refCount ← 1  // Initial reference from assignment target
    return obj
```

### Properties

**Advantages**:
- **Prompt reclamation**: Objects freed immediately when unreachable
- **Incremental**: Work distributed across mutations
- **Predictable**: No stop-the-world pauses (mostly)
- **Local**: Garbage identified from object alone

**Disadvantages**:
- **Cycles**: Cannot reclaim cyclic garbage
- **Overhead**: Every pointer store requires count updates
- **Cache pollution**: Count updates touch scattered memory
- **Space**: Count field in each object

---

## 5.2 Deferred Reference Counting

Reduce overhead by buffering decrements and processing them later:

```pseudo
ThreadLocal:
    decrementBuffer: Buffer
    incrementBuffer: Buffer

Write(obj, field, newValue):
    oldValue ← obj[field]
    obj[field] ← newValue

    if newValue ≠ null:
        incrementBuffer.push(newValue)
    if oldValue ≠ null:
        decrementBuffer.push(oldValue)

    if decrementBuffer.full():
        processBuffers()

processBuffers():
    // Process increments first (for safety)
    for each obj in incrementBuffer:
        obj.refCount ← obj.refCount + 1
    incrementBuffer.clear()

    // Then decrements
    for each obj in decrementBuffer:
        obj.refCount ← obj.refCount - 1
        if obj.refCount = 0:
            reclaim(obj)
    decrementBuffer.clear()
```

### Zero Count Table (ZCT)

Track objects that reached zero count but weren't immediately reclaimed:

```pseudo
ZCT: Set<Object>

deferredDecrement(obj):
    obj.refCount ← obj.refCount - 1
    if obj.refCount = 0:
        ZCT.add(obj)

processZCT():
    while not ZCT.empty():
        obj ← ZCT.remove()
        if obj.refCount = 0:  // Still zero
            for each field in Pointers(obj):
                child ← *field
                if child ≠ null:
                    deferredDecrement(child)
            free(obj)
```

---

## 5.3 Coalesced Reference Counting

Eliminate redundant updates to the same object:

```pseudo
ThreadLocal:
    deltaMap: HashMap<Object, int>  // Net change per object

Write(obj, field, newValue):
    oldValue ← obj[field]
    obj[field] ← newValue

    if oldValue ≠ null:
        deltaMap[oldValue] ← deltaMap.getOrDefault(oldValue, 0) - 1
    if newValue ≠ null:
        deltaMap[newValue] ← deltaMap.getOrDefault(newValue, 0) + 1

    if deltaMap.size() > COALESCE_THRESHOLD:
        flushDeltas()

flushDeltas():
    for each (obj, delta) in deltaMap:
        obj.refCount ← obj.refCount + delta
        if obj.refCount = 0:
            reclaim(obj)
        else if obj.refCount < 0:
            error "Negative reference count"
    deltaMap.clear()
```

**Benefit**: Multiple inc/dec to same object become single atomic update.

**Example**:
```pseudo
// Without coalescing: 6 count operations
x.a = y  // inc(y)
x.a = z  // dec(y), inc(z)
x.a = y  // dec(z), inc(y)

// With coalescing: 0 net operations to y, 0 to z
// deltaMap: {y: 0, z: 0} → no actual count changes
```

---

## 5.4 Cycle Collection

Reference counting cannot reclaim cyclic garbage. Solutions combine RC with cycle detection.

### The Problem

```pseudo
// Create cycle
a.next = b
b.next = a

// Remove external references
root = null

// Now: a.refCount = 1 (from b), b.refCount = 1 (from a)
// Both unreachable but counts never reach zero
```

### Trial Deletion (Bobrow's Algorithm)

Test whether suspected cycles can be collected:

```pseudo
CycleCandidate:
    object: Object
    color: Color  // WHITE, GREY, BLACK, PURPLE

collectCycles():
    // Phase 1: Mark roots (objects with external refs)
    for each obj in candidates:
        if obj.refCount > 0:
            markGrey(obj)

    // Phase 2: Scan and identify garbage
    for each obj in candidates:
        if obj.color = GREY:
            scan(obj)

    // Phase 3: Collect white objects
    for each obj in candidates:
        if obj.color = WHITE:
            collectWhite(obj)

markGrey(obj):
    if obj.color ≠ GREY:
        obj.color ← GREY
        for each child in children(obj):
            child.trialRefCount ← child.trialRefCount - 1
            markGrey(child)

scan(obj):
    if obj.color = GREY:
        if obj.trialRefCount > 0:
            // Has external references - not garbage
            scanBlack(obj)
        else:
            obj.color ← WHITE
            for each child in children(obj):
                scan(child)

scanBlack(obj):
    obj.color ← BLACK
    for each child in children(obj):
        child.trialRefCount ← child.trialRefCount + 1
        if child.color ≠ BLACK:
            scanBlack(child)

collectWhite(obj):
    if obj.color = WHITE:
        obj.color ← BLACK
        for each child in children(obj):
            collectWhite(child)
        free(obj)
```

### Synchronous Cycle Collection

Trigger cycle collection periodically or when candidates accumulate:

```pseudo
decrement(obj):
    obj.refCount ← obj.refCount - 1
    if obj.refCount = 0:
        reclaim(obj)
    else:
        // Potential cycle root - add to candidates
        if obj.color ≠ PURPLE:
            obj.color ← PURPLE
            candidates.add(obj)

    if candidates.size() > CYCLE_THRESHOLD:
        collectCycles()
```

### Bacon-Rajan Cycle Collection

More efficient algorithm with fewer traversals:

```pseudo
Colors:
    BLACK = in use
    GREY  = possible cycle member
    WHITE = garbage
    PURPLE = possible cycle root

possibleRoot(obj):
    if obj.color ≠ PURPLE:
        obj.color ← PURPLE
        if not obj.buffered:
            obj.buffered ← true
            roots.add(obj)

markRoots():
    newRoots ← []
    for each obj in roots:
        if obj.color = PURPLE and obj.refCount > 0:
            markGrey(obj)
            newRoots.add(obj)
        else:
            obj.buffered ← false
            if obj.color = BLACK and obj.refCount = 0:
                free(obj)
    roots ← newRoots

scanRoots():
    for each obj in roots:
        scan(obj)

collectRoots():
    for each obj in roots:
        obj.buffered ← false
        collectWhite(obj)
    roots.clear()

collectCycles():
    markRoots()
    scanRoots()
    collectRoots()
```

---

## 5.5 Limited-Field Reference Counts

Reduce space by limiting count width:

```pseudo
MAX_COUNT = 127  // 7 bits
STICKY_BIT = 128

increment(obj):
    if obj.refCount < MAX_COUNT:
        obj.refCount ← obj.refCount + 1
    else:
        obj.refCount ← obj.refCount | STICKY_BIT  // Saturate

decrement(obj):
    if (obj.refCount & STICKY_BIT) = 0:
        obj.refCount ← obj.refCount - 1
        if obj.refCount = 0:
            reclaim(obj)
    // Else: sticky - need backup tracing to collect
```

### Overflow Table

Handle overflow counts separately:

```pseudo
overflowTable: HashMap<Object, int>

increment(obj):
    if obj.refCount < MAX_COUNT:
        obj.refCount ← obj.refCount + 1
    else if obj.refCount = MAX_COUNT:
        obj.refCount ← OVERFLOW_MARKER
        overflowTable[obj] ← MAX_COUNT + 1
    else:
        overflowTable[obj] ← overflowTable[obj] + 1

decrement(obj):
    if obj.refCount < MAX_COUNT:
        obj.refCount ← obj.refCount - 1
        if obj.refCount = 0:
            reclaim(obj)
    else:
        count ← overflowTable[obj] - 1
        if count = MAX_COUNT:
            overflowTable.remove(obj)
            obj.refCount ← MAX_COUNT
        else:
            overflowTable[obj] ← count
```

---

## 5.6 Concurrent Reference Counting

### Atomic Reference Counting

Use atomic operations for thread safety:

```pseudo
atomicIncrement(obj):
    AtomicAdd(&obj.refCount, 1)

atomicDecrement(obj):
    oldCount ← AtomicAdd(&obj.refCount, -1)
    if oldCount = 1:  // Was 1, now 0
        scheduleReclamation(obj)
```

### Per-Thread Buffers

Reduce contention with thread-local buffering:

```pseudo
ThreadLocal:
    localBuffer: Buffer

increment(obj):
    localBuffer.push(IncrementEntry(obj))
    if localBuffer.full():
        flushBuffer()

decrement(obj):
    localBuffer.push(DecrementEntry(obj))
    if localBuffer.full():
        flushBuffer()

flushBuffer():
    // Sort by object address for cache efficiency
    sort(localBuffer, byObjectAddress)

    for each entry in localBuffer:
        if entry.isIncrement:
            AtomicAdd(&entry.obj.refCount, 1)
        else:
            oldCount ← AtomicAdd(&entry.obj.refCount, -1)
            if oldCount = 1:
                scheduleReclamation(entry.obj)

    localBuffer.clear()
```

### Biased Reference Counting

Optimize for creating thread:

```pseudo
Object:
    ownerThread: Thread
    localCount: int      // No sync needed for owner
    sharedCount: AtomicInt

increment(obj):
    if currentThread() = obj.ownerThread:
        obj.localCount ← obj.localCount + 1
    else:
        AtomicAdd(&obj.sharedCount, 1)

decrement(obj):
    if currentThread() = obj.ownerThread:
        obj.localCount ← obj.localCount - 1
        if obj.localCount + obj.sharedCount = 0:
            reclaim(obj)
    else:
        oldShared ← AtomicAdd(&obj.sharedCount, -1)
        // Must coordinate with owner for final reclamation
```

---

## 5.7 Handling Cascade Deletions

Reclaiming an object may trigger cascading decrements:

### Iterative Reclamation

Avoid deep recursion:

```pseudo
reclaim(obj):
    workList ← [obj]
    while not workList.empty():
        current ← workList.pop()
        for each field in Pointers(current):
            child ← *field
            if child ≠ null:
                child.refCount ← child.refCount - 1
                if child.refCount = 0:
                    workList.push(child)
        free(current)
```

### Lazy Reclamation

Limit work per allocation:

```pseudo
reclaimQueue: Queue<Object>

scheduleReclamation(obj):
    reclaimQueue.push(obj)

allocate(size):
    // Do some reclamation work
    for i from 0 to WORK_UNITS:
        if reclaimQueue.empty():
            break
        processOneReclamation()

    return doAllocate(size)

processOneReclamation():
    obj ← reclaimQueue.pop()
    for each field in Pointers(obj):
        child ← *field
        if child ≠ null:
            child.refCount ← child.refCount - 1
            if child.refCount = 0:
                reclaimQueue.push(child)
    free(obj)
```

---

## 5.8 Hybrid RC + Tracing

Combine RC's promptness with tracing's cycle handling:

### Ulterior Reference Counting

RC for old generation, tracing for young:

```pseudo
// Young generation: tracing (copying) collector
// Old generation: reference counting

writeBarrier(obj, field, newValue):
    oldValue ← obj[field]
    obj[field] ← newValue

    // Generational barrier
    if inOldGen(obj) and inYoungGen(newValue):
        recordOldToYoung(obj, field)

    // RC barrier for old→old references
    if inOldGen(obj):
        if oldValue ≠ null and inOldGen(oldValue):
            decrement(oldValue)
        if newValue ≠ null and inOldGen(newValue):
            increment(newValue)
```

### Periodic Backup Tracing

Use tracing to collect cycles:

```pseudo
// Normal operation: reference counting
// Periodically: full tracing to find cycles

periodicCollection():
    if timeSinceLastTrace() > TRACE_INTERVAL:
        // Pause and trace to find cycles
        markFromRoots()
        sweepUnmarked()  // Includes cyclic garbage
    else:
        // Normal RC operation
        processRCBuffers()
```

### Trial Deletion with Backup

Fall back to tracing if cycle detection fails:

```pseudo
collectCycles():
    candidates ← getCycleCandidates()
    trialDelete(candidates)

    // If candidates remain after trial deletion
    if candidates.size() > TRACE_THRESHOLD:
        // Use backup tracing
        markFromRoots()
        for each obj in candidates:
            if not isMarked(obj):
                free(obj)
```

---

## 5.9 Sliding Views Reference Counting

Maintain stable and delta counts for concurrent operation:

```pseudo
Object:
    stableCount: int     // Base reference count
    deltaCount: AtomicInt // Accumulated changes

// Mutator updates delta
concurrentIncrement(obj):
    AtomicAdd(&obj.deltaCount, 1)

concurrentDecrement(obj):
    AtomicAdd(&obj.deltaCount, -1)

// Collector reconciles periodically
reconcile():
    for each obj in heap:
        delta ← AtomicExchange(&obj.deltaCount, 0)
        obj.stableCount ← obj.stableCount + delta
        if obj.stableCount = 0:
            scheduleReclamation(obj)
```

**Benefit**: Collector works with stable counts, mutators update deltas concurrently.

---

## 5.10 Performance Engineering

### Avoiding Barrier Overhead

Filter unnecessary updates:

```pseudo
optimizedWrite(obj, field, newValue):
    oldValue ← obj[field]

    // Skip if no change
    if oldValue = newValue:
        obj[field] ← newValue
        return

    // Skip null
    if newValue ≠ null:
        increment(newValue)
    if oldValue ≠ null:
        decrement(oldValue)

    obj[field] ← newValue
```

### Initialization Without RC

Bulk initialization skips intermediate states:

```pseudo
// Instead of:
obj.field1 = a  // inc(a)
obj.field2 = b  // inc(b)
obj.field3 = c  // inc(c)

// Use:
initializeObject(obj, [a, b, c]):
    obj.field1 ← a
    obj.field2 ← b
    obj.field3 ← c
    increment(a)
    increment(b)
    increment(c)
```

### Cache-Conscious Counts

Place counts to reduce cache pressure:

```pseudo
// Option 1: Count in header (co-located with object)
Object:
    header: Header { tag, refCount, ... }
    fields: ...

// Option 2: Separate count table (better for dense scanning)
countTable: array[maxObjects] of int
getCount(obj) = countTable[objectIndex(obj)]
```

---

## 5.11 Summary

Reference counting provides immediate reclamation at the cost of per-write overhead:

| Aspect | Characteristic |
|--------|---------------|
| **Reclamation** | Immediate when count hits zero |
| **Cycles** | Cannot collect (need backup) |
| **Overhead** | Per-pointer-write updates |
| **Pauses** | Small (cascade can be bounded) |
| **Space** | Count field per object |

Optimization techniques:

| Technique | Benefit | Trade-off |
|-----------|---------|-----------|
| **Deferred RC** | Reduced barrier cost | Delayed reclamation |
| **Coalesced RC** | Eliminated redundant updates | Memory for delta map |
| **Biased RC** | Fast for creating thread | Complex cross-thread |
| **Limited counts** | Smaller headers | Sticky bits or overflow table |

Cycle collection:

| Approach | Complexity | Completeness |
|----------|------------|--------------|
| **Trial deletion** | O(cycle size) | May miss some |
| **Backup tracing** | O(live set) | Complete |
| **Hybrid** | Variable | Complete |

When to use RC:
- Prompt reclamation required (real-time, low latency)
- Objects cannot move (FFI, shared memory)
- Mostly acyclic data structures
- As component in hybrid collector

When to avoid RC:
- High mutation rate (barrier overhead dominates)
- Many cycles (need frequent backup tracing)
- Simple generational collector suffices

