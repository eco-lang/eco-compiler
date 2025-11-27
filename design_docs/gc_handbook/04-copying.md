# 4. Copying Garbage Collection

Copying collectors evacuate live objects from one memory region (from-space) to another (to-space), leaving behind forwarding pointers. This approach provides automatic compaction, enables extremely fast bump-pointer allocation, and naturally improves cache locality. This chapter covers Cheney's semispace algorithm, traversal strategies, generational copying, and parallel copying techniques.

---

## 4.1 Semispace Copying

The heap is divided into two equal semispaces. Only one is active at a time:

```pseudo
Heap:
    fromSpace: Region
    toSpace: Region
    allocPtr: Address      // Bump pointer in from-space
    scanPtr: Address       // Cheney scan pointer

initialize():
    fromSpace ← Region(HeapStart, HeapMid)
    toSpace ← Region(HeapMid, HeapEnd)
    allocPtr ← fromSpace.start
```

### Allocation

Bump-pointer allocation is extremely fast:

```pseudo
allocate(size):
    aligned ← align(size, ALIGNMENT)
    if allocPtr + aligned > fromSpace.end:
        collect()
        if allocPtr + aligned > fromSpace.end:
            error "Out of memory"

    result ← allocPtr
    allocPtr ← allocPtr + aligned
    return result
```

### Collection

```pseudo
collect():
    // Flip spaces
    swap(fromSpace, toSpace)
    allocPtr ← toSpace.start
    scanPtr ← toSpace.start

    // Evacuate roots
    for each root in Roots:
        if *root ≠ null:
            *root ← evacuate(*root)

    // Cheney scan: process grey objects
    while scanPtr < allocPtr:
        obj ← objectAt(scanPtr)
        for each field in Pointers(obj):
            if *field ≠ null:
                *field ← evacuate(*field)
        scanPtr ← scanPtr + objectSize(obj)

    // fromSpace is now garbage - can be reused next flip
```

---

## 4.2 Cheney's Algorithm

Cheney's algorithm uses the to-space itself as an implicit queue for breadth-first traversal:

```pseudo
// scanPtr divides to-space into:
//   [toSpace.start, scanPtr) - BLACK: fully processed
//   [scanPtr, allocPtr)      - GREY: evacuated but not scanned
//   [allocPtr, toSpace.end)  - available for new evacuations

evacuate(obj):
    if obj = null:
        return null

    // Check if already forwarded
    if isForwarded(obj):
        return forwardingAddress(obj)

    // Copy to to-space
    size ← objectSize(obj)
    newLocation ← allocPtr
    memcpy(newLocation, obj, size)
    allocPtr ← allocPtr + size

    // Install forwarding pointer in from-space
    setForwardingPointer(obj, newLocation)

    return newLocation

isForwarded(obj):
    return obj.header.tag = FORWARDING_TAG

forwardingAddress(obj):
    return obj.header.forwarding

setForwardingPointer(obj, newLoc):
    obj.header.tag ← FORWARDING_TAG
    obj.header.forwarding ← newLoc
```

### Forwarding Pointer Layout

```pseudo
// Original object in from-space before evacuation:
Object:
    header: Header
    field0: Value
    field1: Value
    ...

// After evacuation, from-space object becomes:
ForwardingPointer:
    header: Header { tag = FORWARDING_TAG }
    forwarding: Address  // Points to to-space copy
```

---

## 4.3 Traversal Order

### Breadth-First (Cheney)

The scan/alloc pointer pair implements BFS naturally:

```pseudo
// Siblings evacuated together → good cache locality for wide graphs
// Objects processed in allocation order within to-space

cheneyTraversal():
    while scanPtr < allocPtr:
        obj ← objectAt(scanPtr)
        scanChildren(obj)
        scanPtr ← scanPtr + objectSize(obj)
```

### Depth-First with Explicit Stack

Better for deep graphs, preserves parent-child locality:

```pseudo
dfsEvacuate():
    stack ← []

    // Evacuate roots
    for each root in Roots:
        if *root ≠ null:
            *root ← copyAndPush(*root, stack)

    // Process stack
    while not stack.empty():
        obj ← stack.pop()
        for each field in Pointers(obj):
            if *field ≠ null and not isForwarded(*field):
                *field ← copyAndPush(*field, stack)
            else if *field ≠ null:
                *field ← forwardingAddress(*field)

copyAndPush(obj, stack):
    newLoc ← copyToSpace(obj)
    setForwardingPointer(obj, newLoc)
    stack.push(newLoc)
    return newLoc
```

### Approximately Depth-First

Hybrid approach with bounded stack:

```pseudo
approximatelyDFS():
    // Use small stack for DFS, fall back to Cheney when full
    stack ← BoundedStack(MAX_DEPTH)

    for each root in Roots:
        processWithStack(*root, stack)

    // Cheney scan for overflow
    while scanPtr < allocPtr:
        obj ← objectAt(scanPtr)
        processWithStack(obj, stack)
        scanPtr ← scanPtr + objectSize(obj)

processWithStack(obj, stack):
    for each field in Pointers(obj):
        child ← *field
        if child ≠ null and not isForwarded(child):
            newChild ← evacuate(child)
            *field ← newChild
            if not stack.full():
                stack.push(newChild)
        else if child ≠ null:
            *field ← forwardingAddress(child)

    // Process stack until empty
    while not stack.empty():
        stackObj ← stack.pop()
        processWithStack(stackObj, stack)
```

---

## 4.4 Generational Copying

### Young Generation Structure

```pseudo
YoungGen:
    eden: Region           // New allocations
    survivor0: Region      // First survivor space
    survivor1: Region      // Second survivor space
    fromSurvivor: Region   // Points to current from-space
    toSurvivor: Region     // Points to current to-space

minorGC():
    // Evacuate from eden and fromSurvivor to toSurvivor
    toAllocPtr ← toSurvivor.start

    // Process roots
    for each root in Roots:
        if inYoungGen(*root):
            *root ← minorEvacuate(*root)

    // Process remembered set (old→young references)
    for each card in dirtyCards:
        for each obj in objectsInCard(card):
            for each field in Pointers(obj):
                if inYoungGen(*field):
                    *field ← minorEvacuate(*field)

    // Cheney scan
    scanPtr ← toSurvivor.start
    while scanPtr < toAllocPtr:
        obj ← objectAt(scanPtr)
        for each field in Pointers(obj):
            if inYoungGen(*field):
                *field ← minorEvacuate(*field)
        scanPtr ← scanPtr + objectSize(obj)

    // Clear eden and swap survivors
    eden.allocPtr ← eden.start
    swap(fromSurvivor, toSurvivor)
```

### Promotion to Old Generation

```pseudo
PROMOTION_AGE = 2  // Promote after surviving 2 collections

minorEvacuate(obj):
    if isForwarded(obj):
        return forwardingAddress(obj)

    size ← objectSize(obj)

    // Check age for promotion
    if obj.header.age >= PROMOTION_AGE:
        // Promote to old generation
        newLoc ← oldGenAllocate(size)
        memcpy(newLoc, obj, size)
        newLoc.header.age ← 0  // Reset age in old gen
    else:
        // Copy to survivor space
        newLoc ← toAllocPtr
        memcpy(newLoc, obj, size)
        toAllocPtr ← toAllocPtr + size
        newLoc.header.age ← obj.header.age + 1

    setForwardingPointer(obj, newLoc)
    return newLoc
```

### Remembered Set / Card Table

Track old→young pointers:

```pseudo
CARD_SIZE = 512
cardTable: array[heapSize / CARD_SIZE] of byte

writeBarrier(obj, field, value):
    obj[field] ← value
    if inOldGen(obj) and inYoungGen(value):
        cardIndex ← (addressOf(obj) - heapStart) / CARD_SIZE
        cardTable[cardIndex] ← DIRTY

processRememberedSet():
    for cardIndex from 0 to cardTableSize - 1:
        if cardTable[cardIndex] = DIRTY:
            processCard(cardIndex)
            cardTable[cardIndex] ← CLEAN

processCard(cardIndex):
    cardStart ← heapStart + cardIndex * CARD_SIZE
    cardEnd ← cardStart + CARD_SIZE
    obj ← firstObjectInCard(cardIndex)
    while addressOf(obj) < cardEnd:
        for each field in Pointers(obj):
            if inYoungGen(*field):
                addToRootSet(addressOf(field))
        obj ← nextObject(obj)
```

---

## 4.5 Handling Allocation Failure

### Overflow to Old Generation

When to-space fills during minor GC:

```pseudo
minorEvacuateWithOverflow(obj):
    if isForwarded(obj):
        return forwardingAddress(obj)

    size ← objectSize(obj)

    // Try survivor space
    if toAllocPtr + size <= toSurvivor.end:
        newLoc ← toAllocPtr
        toAllocPtr ← toAllocPtr + size
    else:
        // Overflow: promote directly to old gen
        newLoc ← oldGenAllocate(size)
        if newLoc = null:
            // Must trigger major GC
            triggerMajorGC()
            newLoc ← oldGenAllocate(size)

    memcpy(newLoc, obj, size)
    setForwardingPointer(obj, newLoc)
    return newLoc
```

### Dynamic Survivor Sizing

Adjust survivor space size based on survival rate:

```pseudo
adjustSurvivorSize():
    survivalRate ← bytesSurvived / bytesCollected

    if survivalRate > HIGH_THRESHOLD:
        // Many survivors - increase survivor size
        survivorSize ← min(survivorSize * 2, maxSurvivorSize)
    else if survivalRate < LOW_THRESHOLD:
        // Few survivors - decrease survivor size
        survivorSize ← max(survivorSize / 2, minSurvivorSize)
```

---

## 4.6 Parallel Copying

### Promotion-Local Allocation Buffers (PLABs)

Each GC thread has its own allocation buffer:

```pseudo
PLAB:
    start: Address
    current: Address
    end: Address

allocatePLAB():
    // Atomically claim chunk from to-space
    loop:
        current ← toSpaceAllocPtr
        next ← current + PLAB_SIZE
        if next > toSpace.end:
            return null  // To-space exhausted
        if CompareAndSet(&toSpaceAllocPtr, current, next):
            return PLAB(current, current, next)

plabAllocate(plab, size):
    if plab.current + size > plab.end:
        return null  // PLAB exhausted
    result ← plab.current
    plab.current ← plab.current + size
    return result
```

### Parallel Evacuation with PLABs

```pseudo
parallelCopy():
    // Distribute roots among workers
    rootChunks ← partition(Roots, numWorkers)

    parallel for each worker w:
        w.plab ← allocatePLAB()

        // Evacuate assigned roots
        for each root in rootChunks[w.id]:
            if *root ≠ null and inFromSpace(*root):
                *root ← parallelEvacuate(*root, w)

        // Process grey objects from local work queue
        while obj ← w.workQueue.pop():
            for each field in Pointers(obj):
                if *field ≠ null and inFromSpace(*field):
                    *field ← parallelEvacuate(*field, w)

        // Work stealing when local queue empty
        while not terminationDetected():
            victim ← randomWorker()
            stolen ← victim.workQueue.steal()
            if stolen ≠ null:
                processObject(stolen, w)

parallelEvacuate(obj, worker):
    // Try to claim object for evacuation
    header ← obj.header
    if isForwarded(header):
        return forwardingAddress(header)

    size ← objectSize(obj)

    // Allocate in worker's PLAB
    newLoc ← plabAllocate(worker.plab, size)
    if newLoc = null:
        worker.plab ← allocatePLAB()
        newLoc ← plabAllocate(worker.plab, size)

    // Copy data
    memcpy(newLoc, obj, size)

    // Try to install forwarding pointer (CAS for race)
    forwardHeader ← makeForwardingHeader(newLoc)
    if CompareAndSet(&obj.header, header, forwardHeader):
        // Won race - our copy is canonical
        worker.workQueue.push(newLoc)
        return newLoc
    else:
        // Lost race - reclaim our copy, use winner's
        worker.plab.current ← newLoc  // Rollback
        return forwardingAddress(obj.header)
```

### Work Stealing Deques

```pseudo
WorkDeque:
    array: array[SIZE] of Address
    top: AtomicInt      // Owner pushes/pops here
    bottom: AtomicInt   // Thieves steal from here

push(deque, obj):
    t ← deque.top
    deque.array[t mod SIZE] ← obj
    deque.top ← t + 1

pop(deque):
    t ← deque.top - 1
    deque.top ← t
    b ← deque.bottom
    if t < b:
        deque.top ← b
        return null
    obj ← deque.array[t mod SIZE]
    if t > b:
        return obj
    // Single element - race with steal
    if not CompareAndSet(&deque.bottom, b, b + 1):
        obj ← null  // Lost to thief
    deque.top ← b + 1
    return obj

steal(deque):
    b ← deque.bottom
    t ← deque.top
    if b >= t:
        return null
    obj ← deque.array[b mod SIZE]
    if CompareAndSet(&deque.bottom, b, b + 1):
        return obj
    return null
```

---

## 4.7 Incremental and Concurrent Copying

### Baker's Read Barrier

Ensure mutators only see to-space objects:

```pseudo
bakerReadBarrier(ref):
    if inFromSpace(ref):
        if isForwarded(ref):
            return forwardingAddress(ref)
        else:
            // Evacuate on access
            return evacuate(ref)
    return ref

// All pointer loads go through barrier
Read(obj, field):
    ref ← obj[field]
    return bakerReadBarrier(ref)
```

### Brooks Forwarding Pointer

Each object has an indirection pointer:

```pseudo
// Object layout
Object:
    forwardingPtr: Address  // First word - always points to self or copy
    header: Header
    fields: ...

// Allocation sets self-forwarding
allocate(size):
    obj ← bumpAllocate(size + POINTER_SIZE)
    obj.forwardingPtr ← obj
    return obj

// Read barrier is simple indirection
brooksReadBarrier(ref):
    return ref.forwardingPtr

// Moving an object
moveObject(old, new):
    memcpy(new, old, objectSize(old))
    new.forwardingPtr ← new    // Self-forward
    old.forwardingPtr ← new    // Redirect old to new
```

**Characteristics**:
- Constant-time barrier (single indirection)
- One word overhead per object
- Old copies remain valid until reclaimed

### Self-Healing Pointers

Update stale pointers when encountered:

```pseudo
selfHealingRead(source, offset):
    ref ← source[offset]
    if inFromSpace(ref):
        newRef ← bakerReadBarrier(ref)
        // Try to update source to avoid repeated forwarding
        CompareAndSet(&source[offset], ref, newRef)
        return newRef
    return ref
```

---

## 4.8 Large Object Handling

### Separate Large Object Space

```pseudo
LARGE_OBJECT_THRESHOLD = 8192  // 8KB

allocate(size):
    if size >= LARGE_OBJECT_THRESHOLD:
        return allocateInLOS(size)
    else:
        return allocateInCopyingSpace(size)

// LOS uses mark-sweep, objects don't move
allocateInLOS(size):
    obj ← losAllocator.allocate(size)
    obj.header.space ← LOS
    return obj

// During copying GC, mark but don't copy LOS objects
evacuate(obj):
    if obj.header.space = LOS:
        setMarked(obj)
        return obj  // Don't move
    // Normal evacuation for small objects
    ...
```

### Virtual Memory Tricks for Large Objects

```pseudo
evacuateLargeObject(obj):
    if objectSize(obj) > PAGE_REMAP_THRESHOLD:
        // Remap pages instead of copying
        newLoc ← reserveVirtualMemory(objectSize(obj))
        remapPages(obj, newLoc)
        return newLoc
    else:
        // Normal copy
        return normalEvacuate(obj)
```

---

## 4.9 Locality Optimizations

### Prefetching During Evacuation

```pseudo
evacuateWithPrefetch(obj):
    if isForwarded(obj):
        return forwardingAddress(obj)

    // Prefetch children before copying
    for each field in Pointers(obj):
        child ← *field
        if child ≠ null and inFromSpace(child):
            prefetch(child)

    // Copy
    newLoc ← copyObject(obj)
    setForwardingPointer(obj, newLoc)
    return newLoc
```

### Clustering Related Objects

```pseudo
// Copy objects reachable from same root together
clusteringEvacuate(root):
    cluster ← []
    collectCluster(root, cluster, MAX_CLUSTER_SIZE)

    // Allocate contiguous space for cluster
    totalSize ← sum(objectSize(obj) for obj in cluster)
    clusterStart ← allocPtr
    allocPtr ← allocPtr + totalSize

    // Copy in cluster order
    dest ← clusterStart
    for each obj in cluster:
        memcpy(dest, obj, objectSize(obj))
        setForwardingPointer(obj, dest)
        dest ← dest + objectSize(obj)
```

---

## 4.10 Summary

Copying collection trades space for simplicity and speed:

| Aspect | Characteristic |
|--------|---------------|
| **Space overhead** | 2× for semispace (less for generational) |
| **Allocation** | Bump pointer (fastest possible) |
| **Fragmentation** | None (automatic compaction) |
| **Locality** | Excellent (objects compacted together) |
| **Pause time** | Proportional to live data only |

Key algorithms:

| Algorithm | Traversal | Stack Space | Locality |
|-----------|-----------|-------------|----------|
| **Cheney (BFS)** | Breadth-first | None (implicit) | Sibling clustering |
| **DFS** | Depth-first | O(depth) | Parent-child clustering |
| **Approximate DFS** | Hybrid | Bounded | Balanced |

Generational design:

| Generation | Typical Size | Collector | Survival Rate |
|------------|--------------|-----------|---------------|
| **Eden** | Large | Copying | Very low |
| **Survivor** | Small | Copying | Low |
| **Old** | Large | Mark-sweep/compact | High |

When to use copying:
- Young generation in generational collectors
- When allocation speed is critical
- When low fragmentation is required
- When live data is much smaller than heap

Limitations:
- 2× space overhead for full semispace
- Moving objects requires updating all pointers
- Incompatible with pinned objects (without special handling)
- Large objects usually excluded

