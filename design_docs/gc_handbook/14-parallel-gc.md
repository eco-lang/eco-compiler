# 14. Parallel Garbage Collection

Parallel garbage collection uses multiple threads during stop-the-world collection phases to reduce pause times. While mutators are stopped, collector threads work in parallel to complete marking, sweeping, or copying faster. This chapter covers the algorithms and techniques for parallelizing each phase of collection.

---

## 14.1 Overview of Parallel Collection

Parallel collection differs from concurrent collection:

- **Parallel**: Mutators stopped; multiple GC threads work simultaneously
- **Concurrent**: Mutators run during collection; GC interleaved with mutation

Parallel collection is simpler because there's no need for barriers or atomicity with mutators, but it still requires careful synchronization between GC threads.

### Goals

1. **Minimize pause time** by utilizing all available processors
2. **Maximize throughput** by reducing synchronization overhead
3. **Scale well** with increasing processor count
4. **Balance load** so all threads finish at similar times

---

## 14.2 Parallel Marking

### Basic Parallel Mark

Multiple threads cooperate to trace the object graph:

```pseudo
parallelMark():
    // Initialize: distribute roots among workers
    distributeRoots(Roots, workerQueues)

    // All workers mark in parallel
    parallel for each worker:
        markWorkerLoop()

    // Barrier: ensure all marking complete
    barrier()

markWorkerLoop():
    while true:
        object ← localQueue.pop()
        if object = null:
            object ← globalQueue.steal()
        if object = null:
            if terminationDetected():
                return
            continue

        processObject(object)

processObject(object):
    for each field in pointerFields(object):
        child ← *field
        if child ≠ null and tryMark(child):
            localQueue.push(child)
            if localQueue.size() > THRESHOLD:
                globalQueue.share(localQueue.half())
```

### Work Distribution

**Work packets**: Fixed-size arrays of grey objects. Workers claim packets from a shared pool:

```pseudo
WorkPacket:
    objects: array[PACKET_SIZE]
    count: integer

workPacketLoop():
    localPacket ← new WorkPacket()
    while true:
        // Try local work first
        while localPacket.count > 0:
            obj ← localPacket.pop()
            for each child in pointers(obj):
                if tryMark(child):
                    if localPacket.full():
                        globalPool.put(localPacket)
                        localPacket ← new WorkPacket()
                    localPacket.push(child)

        // Local empty - try to steal
        stolenPacket ← globalPool.steal()
        if stolenPacket = null:
            if attemptTermination():
                break
            continue
        localPacket ← stolenPacket

    // Return any remaining work
    if localPacket.count > 0:
        globalPool.put(localPacket)
```

**Work stealing deques**: Each worker has its own deque. Workers steal from others when idle:

```pseudo
workStealingMark():
    parallel for each worker w:
        while true:
            obj ← w.deque.pop()
            if obj = null:
                // Try stealing from another worker
                victim ← randomWorker()
                obj ← victim.deque.steal()
            if obj = null:
                if terminationDetected():
                    return
                continue

            markAndScan(obj, w.deque)
```

### Marking Atomic Operations

Setting mark bits must be atomic to avoid double-processing:

```pseudo
tryMark(object):
    // Option 1: CAS on header
    loop:
        header ← object.header
        if isMarked(header):
            return false
        if CompareAndSet(&object.header, header, setMark(header)):
            return true

    // Option 2: Bitmap with byte granularity
    byteIndex ← objectIndex(object) / 8
    bitMask ← 1 << (objectIndex(object) mod 8)
    loop:
        byte ← markBitmap[byteIndex]
        if (byte & bitMask) ≠ 0:
            return false
        if CompareAndSet(&markBitmap[byteIndex], byte, byte | bitMask):
            return true
```

---

## 14.3 Parallel Sweeping

### Chunked Sweep

Divide heap into chunks; each worker sweeps independently:

```pseudo
parallelSweep():
    chunks ← divideHeap(CHUNK_SIZE)
    parallel for each chunk in chunks:
        sweepChunk(chunk)

sweepChunk(chunk):
    localFreeList ← null
    cursor ← chunk.start
    while cursor < chunk.end:
        if not isMarked(cursor):
            // Add to local free list
            freeCell(cursor, localFreeList)
        else:
            clearMark(cursor)
        cursor ← cursor + objectSize(cursor)

    // Merge local free list to global
    mergeFreeList(localFreeList)
```

### Lazy Sweeping

Defer sweeping until allocation needs space:

```pseudo
lazySweepAllocate(size):
    // Try fast allocation first
    result ← freeList[sizeClass(size)].pop()
    if result ≠ null:
        return result

    // Sweep chunks until we find enough space
    while true:
        chunk ← getUnsweptChunk()
        if chunk = null:
            return null  // Out of memory

        sweepChunk(chunk)
        result ← freeList[sizeClass(size)].pop()
        if result ≠ null:
            return result
```

### Bitmap-Based Sweeping

Use side bitmaps for faster sweeping:

```pseudo
bitmapSweep(chunk):
    markWord ← markBitmap[chunk.wordIndex]
    allocWord ← allocBitmap[chunk.wordIndex]

    // Free = allocated but not marked
    freeWord ← allocWord & ~markWord

    // Process each free bit
    while freeWord ≠ 0:
        bit ← lowestSetBit(freeWord)
        freeWord ← freeWord & ~bit
        objectAddr ← chunk.start + (bitIndex(bit) * GRANULE_SIZE)
        freeCell(objectAddr)

    // Clear marks for next cycle
    markBitmap[chunk.wordIndex] ← 0
```

---

## 14.4 Parallel Copying Collection

### Basic Parallel Copy

```pseudo
parallelCopy():
    // Each worker has its own promotion/copy buffer (PLAB)
    parallel for each worker w:
        w.plab ← allocatePLAB()

        // Process roots assigned to this worker
        for each root in w.roots:
            if inFromSpace(*root):
                *root ← evacuate(*root, w.plab)

        // Process grey objects
        while obj ← getGreyObject(w):
            for each field in pointerFields(obj):
                if inFromSpace(*field):
                    *field ← evacuate(*field, w.plab)

        // Return unused PLAB space
        returnPLAB(w.plab)
```

### Thread-Local Allocation Buffers (TLABs/PLABs)

To avoid contention on the to-space allocation pointer:

```pseudo
allocatePLAB():
    // Atomic claim from global to-space
    loop:
        current ← toSpacePointer
        next ← current + PLAB_SIZE
        if next > toSpaceLimit:
            return null  // To-space exhausted
        if CompareAndSet(&toSpacePointer, current, next):
            return new PLAB(current, next)

PLAB:
    start: address
    end: address
    bump: address

plabAllocate(plab, size):
    aligned ← align(size)
    if plab.bump + aligned > plab.end:
        return null  // PLAB exhausted
    result ← plab.bump
    plab.bump ← plab.bump + aligned
    return result

returnPLAB(plab):
    // Return unused space to global pool
    unused ← plab.end - plab.bump
    if unused > MIN_RETURN_SIZE:
        returnToGlobalPool(plab.bump, unused)
```

### Parallel Forwarding Pointer Installation

When multiple threads may copy the same object:

```pseudo
evacuate(object, plab):
    // Check if already forwarded
    header ← object.header
    if isForwarded(header):
        return getForwardingAddress(header)

    // Optimistically copy
    size ← objectSize(object)
    newLocation ← plabAllocate(plab, size)
    if newLocation = null:
        plab ← refillPLAB()
        newLocation ← plabAllocate(plab, size)
        if newLocation = null:
            // Handle overflow
            newLocation ← overflowAllocate(size)

    copyObjectData(object, newLocation, size)

    // Try to install forwarding pointer
    forwardHeader ← makeForwardingHeader(newLocation)
    if CompareAndSet(&object.header, header, forwardHeader):
        // We won - our copy is canonical
        return newLocation
    else:
        // Lost race - someone else copied it
        rollbackAllocation(plab, size)
        return getForwardingAddress(object.header)
```

### Grey Object Distribution

Multiple threads need to share the grey set:

```pseudo
// Option 1: Single shared grey queue with stealing
getGreyObject(worker):
    obj ← worker.localGrey.pop()
    if obj ≠ null:
        return obj

    // Steal from shared queue
    obj ← sharedGreyQueue.steal()
    if obj ≠ null:
        return obj

    // Steal from other workers
    victim ← selectVictim(worker)
    return victim.localGrey.steal()

// Option 2: Scanning in to-space (Cheney-style)
parallelCheneyScanning():
    parallel for each worker w:
        // Each worker has a scan range in to-space
        while w.scanPtr < w.scanLimit:
            obj ← objectAt(w.scanPtr)
            for each field in pointerFields(obj):
                if inFromSpace(*field):
                    *field ← evacuate(*field, w.plab)
            w.scanPtr ← w.scanPtr + objectSize(obj)

        // Request more scan range
        claimScanRange(w)
```

---

## 14.5 Parallel Mark-Compact

### Parallel Sliding Compaction

After marking, compact live objects to eliminate fragmentation:

```pseudo
parallelMarkCompact():
    // Phase 1: Parallel mark
    parallelMark()

    // Phase 2: Compute forwarding addresses
    computeForwardingAddresses()

    // Phase 3: Update references
    parallelUpdateReferences()

    // Phase 4: Move objects
    parallelMoveObjects()

computeForwardingAddresses():
    // Sequential: compute prefix sum of live data per region
    offset ← 0
    for each region in heap:
        region.compactStart ← offset
        offset ← offset + region.liveBytes

    // Parallel: compute per-object addresses within regions
    parallel for each region:
        localOffset ← region.compactStart
        for each object in region:
            if isMarked(object):
                object.forwardAddress ← localOffset
                localOffset ← localOffset + objectSize(object)

parallelUpdateReferences():
    parallel for each region:
        for each object in region:
            if isMarked(object):
                for each field in pointerFields(object):
                    target ← *field
                    if target ≠ null:
                        *field ← target.forwardAddress

parallelMoveObjects():
    parallel for each region:
        for each object in region:
            if isMarked(object):
                dest ← object.forwardAddress
                if dest ≠ addressOf(object):
                    moveObject(object, dest)
```

### Region-Based Parallel Compaction

G1-style: select regions for evacuation based on liveness:

```pseudo
regionBasedCompaction():
    // Select regions with low liveness
    candidates ← []
    for each region in heap:
        if region.liveness < EVACUATION_THRESHOLD:
            candidates.add(region)

    // Sort by liveness (lowest first for best yield)
    sort(candidates, byLiveness)

    // Parallel evacuation
    parallel for each region in candidates[0:maxEvacuate]:
        evacuateRegion(region)

evacuateRegion(sourceRegion):
    for each object in sourceRegion:
        if isMarked(object):
            dest ← evacuateToFreeRegion(object)
            installForwardingPointer(object, dest)
```

---

## 14.6 Load Balancing

### Static Partitioning

Divide work evenly at start:

```pseudo
staticPartition(roots, numWorkers):
    partitions ← array[numWorkers]
    for i from 0 to length(roots) - 1:
        partitions[i mod numWorkers].add(roots[i])
    return partitions
```

**Problem:** Work per root varies widely; leads to imbalance.

### Work Stealing

Workers steal from others when idle:

```pseudo
workStealingLoop(worker):
    while not terminated:
        work ← worker.localWork.pop()
        if work = null:
            // Try stealing
            for attempt from 0 to MAX_STEAL_ATTEMPTS:
                victim ← randomWorker()
                work ← victim.localWork.steal()
                if work ≠ null:
                    break
        if work = null:
            if attemptTermination():
                return
            continue

        process(work)
```

### Adaptive Work Sharing

Push work to global pool when local queue grows large:

```pseudo
adaptiveSharing(worker, newWork):
    worker.localWork.push(newWork)

    if worker.localWork.size() > HIGH_WATER_MARK:
        // Share half with global pool
        toShare ← worker.localWork.popHalf()
        globalPool.add(toShare)
```

---

## 14.7 Synchronization Points

### Barriers

Ensure all workers complete a phase before proceeding:

```pseudo
parallelPhases():
    parallelMark()
    barrier()  // All marking complete

    parallelSweep()
    barrier()  // All sweeping complete

// Simple barrier implementation
barrier():
    arrived ← AtomicIncrement(&barrierCount)
    if arrived = numWorkers:
        // Last arrival - release all
        barrierCount ← 0
        releaseAll()
    else:
        waitForRelease()
```

### Phase Transitions

Atomic state transitions for GC phases:

```pseudo
GCState:
    IDLE = 0
    MARKING = 1
    SWEEPING = 2
    COMPACTING = 3

transitionTo(newState):
    loop:
        current ← gcState
        if not validTransition(current, newState):
            return false
        if CompareAndSet(&gcState, current, newState):
            return true
```

---

## 14.8 Remembered Set Processing

Parallel processing of inter-generational pointers:

```pseudo
parallelProcessRememberedSet():
    // Divide card table among workers
    cardsPerWorker ← cardTableSize / numWorkers

    parallel for each worker w:
        startCard ← w.id * cardsPerWorker
        endCard ← startCard + cardsPerWorker

        for cardIndex from startCard to endCard - 1:
            if cardTable[cardIndex] = DIRTY:
                processCard(cardIndex)
                cardTable[cardIndex] ← CLEAN

processCard(cardIndex):
    cardStart ← cardIndex * CARD_SIZE
    cardEnd ← cardStart + CARD_SIZE

    // Scan objects in card
    object ← firstObjectInRange(cardStart)
    while addressOf(object) < cardEnd:
        for each field in pointerFields(object):
            target ← *field
            if inYoungGeneration(target):
                // Add to roots for young collection
                addToRoots(field)
        object ← nextObject(object)
```

---

## 14.9 Summary

Parallel GC reduces stop-the-world pause times by dividing work among multiple threads:

| Technique | Purpose | Key Mechanism |
|-----------|---------|---------------|
| **Work stealing** | Load balancing | Chase-Lev deques |
| **PLABs** | Contention-free allocation | Per-thread buffers |
| **CAS forwarding** | Safe parallel copying | Atomic install, losers rollback |
| **Chunked sweep** | Parallel reclamation | Independent chunk processing |
| **Bitmap marking** | Fast parallel mark | Byte/word-level atomics |
| **Barriers** | Phase synchronization | Atomic counters |

Design principles:
- Minimize synchronization in hot paths
- Use thread-local structures where possible
- Balance work granularity (not too fine, not too coarse)
- Use work stealing for dynamic load balancing
- Atomic operations only where contention expected
