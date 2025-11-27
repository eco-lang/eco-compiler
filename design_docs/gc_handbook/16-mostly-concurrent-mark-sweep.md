# 16. Mostly-Concurrent Mark-Sweep

Mostly-concurrent mark-sweep collectors overlap the marking phase with mutator execution to reduce pause times. By performing the bulk of tracing work concurrently, only brief synchronization pauses are needed at the beginning and end of collection. This chapter covers the algorithms, barriers, and engineering challenges of concurrent marking with non-moving collection.

---

## 16.1 Motivation and Overview

Stop-the-world mark-sweep has pause times proportional to the live data volume. For large heaps, this can mean multi-second pauses. Concurrent mark-sweep addresses this by:

1. Performing most marking while mutators run
2. Using barriers to track mutations during marking
3. Synchronizing only briefly to capture roots and finalize marking

### Algorithm Structure

```
Phase 1: Initial Mark (STW)
  - Stop mutators briefly
  - Scan roots (registers, stacks, globals)
  - Grey all directly reachable objects
  - Resume mutators with write barrier enabled

Phase 2: Concurrent Mark
  - Marker threads trace object graph
  - Mutators continue with barrier recording changes
  - Continues until grey set appears empty

Phase 3: Remark (STW)
  - Stop mutators briefly
  - Process pending barrier buffers
  - Rescan modified roots
  - Complete any remaining marking

Phase 4: Sweep (STW or Concurrent)
  - Reclaim unmarked objects
  - Rebuild free lists
```

---

## 16.2 The Initial Mark Phase

A brief stop-the-world pause to establish the marking wavefront:

```pseudo
initialMark():
    stopAllMutators()

    // Scan roots
    for each thread t:
        scanStack(t)
        scanRegisters(t)

    for each global in globalRoots:
        if isHeapPointer(*global):
            greyObject(*global)

    // Enable barriers
    gcState ← MARKING
    barrierEnabled ← true

    resumeAllMutators()

greyObject(object):
    if markBitmap[object] = UNMARKED:
        markBitmap[object] ← GREY
        greyQueue.push(object)
```

The initial mark pause is typically short—proportional to root set size, not heap size.

---

## 16.3 Write Barriers for Concurrent Marking

Barriers ensure the collector doesn't miss objects that become reachable during concurrent marking.

### Snapshot-at-the-Beginning (SATB) Barrier

Records overwritten references to preserve the initial reachability graph:

```pseudo
satbWriteBarrier(object, field, newValue):
    oldValue ← object[field]
    object[field] ← newValue

    if gcState = MARKING:
        if oldValue ≠ null and not isMarked(oldValue):
            // Log the old value before it's lost
            satbLocalBuffer.push(oldValue)
            if satbLocalBuffer.full():
                flushSATBBuffer()

flushSATBBuffer():
    lock(satbGlobalLock)
    satbGlobalBuffer.append(satbLocalBuffer)
    unlock(satbGlobalLock)
    satbLocalBuffer.clear()
```

**Correctness:** Any object reachable at the start of marking will be found, even if the mutator removes all references to it during marking.

### Incremental Update Barrier

Records new references created from black objects:

```pseudo
incrementalUpdateBarrier(object, field, newValue):
    object[field] ← newValue

    if gcState = MARKING:
        if isBlack(object) and isHeapPointer(newValue):
            if not isMarked(newValue):
                // Shade the new target
                greyObject(newValue)
```

**Trade-off:** May cause more re-marking if objects are modified after being marked black.

### Combining with Generational Barriers

Concurrent collectors often run alongside generational collection:

```pseudo
combinedWriteBarrier(object, field, newValue):
    oldValue ← object[field]
    object[field] ← newValue

    // Generational barrier
    if isOld(object) and isYoung(newValue):
        cardTable[addressOf(object) >> CARD_SHIFT] ← DIRTY

    // Concurrent marking barrier (SATB)
    if gcState = MARKING and oldValue ≠ null:
        if not isMarked(oldValue):
            satbLocalBuffer.push(oldValue)
```

---

## 16.4 Concurrent Marking

Multiple marker threads trace the object graph while mutators run:

```pseudo
concurrentMarkingThread():
    while gcState = MARKING:
        // Get work
        object ← localGreyQueue.pop()
        if object = null:
            object ← stealFromGlobal()
        if object = null:
            if attemptTermination():
                return
            continue

        // Process object
        scanObject(object)

scanObject(object):
    // Mark object black
    markBitmap[object] ← BLACK

    // Grey all children
    for each field in pointerFields(object):
        child ← *field
        if child ≠ null and not isMarked(child):
            if tryMark(child):  // CAS to avoid double-processing
                localGreyQueue.push(child)

    // Share work if local queue is large
    if localGreyQueue.size() > SHARE_THRESHOLD:
        globalGreyQueue.add(localGreyQueue.split())

tryMark(object):
    loop:
        mark ← markBitmap[object]
        if mark ≠ UNMARKED:
            return false
        if CompareAndSet(&markBitmap[object], UNMARKED, GREY):
            return true
```

### Work Balancing

```pseudo
stealFromGlobal():
    // Try global queue first
    packet ← globalGreyQueue.steal()
    if packet ≠ null:
        return packet.pop()

    // Try stealing from other threads
    victim ← randomMarkerThread()
    return victim.localGreyQueue.steal()
```

### Handling Large Objects

Large objects with many pointers can cause work imbalance:

```pseudo
scanLargeObject(object):
    numFields ← pointerFieldCount(object)
    if numFields > LARGE_OBJECT_THRESHOLD:
        // Split into chunks
        for chunk from 0 to numFields by CHUNK_SIZE:
            chunkEnd ← min(chunk + CHUNK_SIZE, numFields)
            greyQueue.push(LargeObjectChunk(object, chunk, chunkEnd))
    else:
        scanObject(object)

scanLargeObjectChunk(chunk):
    for i from chunk.start to chunk.end - 1:
        field ← chunk.object.fields[i]
        if field ≠ null and tryMark(field):
            localGreyQueue.push(field)
```

---

## 16.5 The Remark Phase

A brief stop-the-world pause to complete marking:

```pseudo
remark():
    stopAllMutators()

    // Process SATB buffers
    processSATBBuffers()

    // Rescan roots (may have changed)
    for each thread t:
        rescanStack(t)

    // Process any remaining grey objects
    while not greyQueue.empty():
        object ← greyQueue.pop()
        scanObject(object)

    // Marking complete
    gcState ← SWEEPING

    resumeAllMutators()

processSATBBuffers():
    // Process global buffer
    for each ref in satbGlobalBuffer:
        if not isMarked(ref):
            markObject(ref)
            greyQueue.push(ref)
    satbGlobalBuffer.clear()

    // Flush and process thread-local buffers
    for each thread t:
        flushThreadSATBBuffer(t)
```

### Remark Pause Optimization

Several techniques minimize remark pause time:

**Concurrent precleaning:** Process SATB buffers and dirty cards concurrently before remark:

```pseudo
concurrentPrecleaning():
    while gcState = MARKING:
        // Process any available SATB entries
        if satbGlobalBuffer.size() > PRECLEAN_THRESHOLD:
            processSATBBatch()

        // Process dirty cards
        for each dirtyCard in cardTable:
            if cardTable[dirtyCard] = DIRTY:
                scanCard(dirtyCard)
                cardTable[dirtyCard] ← PRECLEANED

        yield()  // Don't starve mutators
```

**Abortable preclean:** Continue precleaning until remark is triggered:

```pseudo
abortablePrecleaning():
    deadline ← currentTime() + MAX_PRECLEAN_TIME
    while currentTime() < deadline:
        if shouldStartRemark():
            return
        precleanlIteration()
```

---

## 16.6 Sweeping

After marking, sweep reclaims unmarked objects.

### Stop-the-World Sweep

Simple but adds to total pause time:

```pseudo
stopTheWorldSweep():
    for each chunk in heap:
        cursor ← chunk.start
        while cursor < chunk.end:
            if markBitmap[cursor] = UNMARKED:
                addToFreeList(cursor)
            else:
                clearMark(cursor)
            cursor ← cursor + objectSize(cursor)
```

### Concurrent Sweep

Sweep while mutators run, with careful allocation coordination:

```pseudo
concurrentSweep():
    sweepFrontier ← heapStart

    while sweepFrontier < heapEnd:
        chunk ← getChunkAt(sweepFrontier)
        sweepChunk(chunk)
        sweepFrontier ← chunk.end

        yield()  // Let mutators run

concurrentAllocate(size):
    // Only allocate from swept regions
    freeCell ← localFreeList.get(size)
    if freeCell ≠ null:
        return freeCell

    // Wait for sweep to reach a chunk with free space
    while true:
        chunk ← getSweptChunk()
        if chunk = null:
            // Help sweep
            helpSweep()
            continue

        freeCell ← chunk.allocate(size)
        if freeCell ≠ null:
            return freeCell
```

### Lazy Sweep

Defer sweeping until allocation time:

```pseudo
lazySweepAllocate(size):
    // Try immediate allocation
    freeCell ← freeList.get(size)
    if freeCell ≠ null:
        return freeCell

    // Sweep chunks until we find space
    while true:
        chunk ← nextUnsweptChunk()
        if chunk = null:
            triggerGC()
            return null

        sweepChunk(chunk)
        freeCell ← freeList.get(size)
        if freeCell ≠ null:
            return freeCell
```

---

## 16.7 Pacing and Scheduling

Balance GC progress against mutator throughput:

### Allocation-Based Pacing

Do GC work proportional to allocation:

```pseudo
allocateWithPacing(size):
    obj ← allocate(size)

    if gcState = MARKING:
        workToDo ← size * MARKING_RATIO
        doMarkingWork(workToDo)

    return obj

doMarkingWork(amount):
    workDone ← 0
    while workDone < amount and not greyQueue.empty():
        object ← greyQueue.pop()
        scanObject(object)
        workDone ← workDone + objectSize(object)
```

### Time-Based Pacing

Limit GC work per time slice:

```pseudo
concurrentMarkerWithPacing():
    while gcState = MARKING:
        startTime ← currentTime()

        while currentTime() - startTime < GC_TIME_SLICE:
            object ← greyQueue.pop()
            if object = null:
                break
            scanObject(object)

        // Yield to mutators
        sleep(MUTATOR_TIME_SLICE)
```

### Adaptive Pacing

Adjust pace based on heap pressure:

```pseudo
adaptivePacing():
    freeRatio ← freeSpace / heapSize

    if freeRatio < CRITICAL_THRESHOLD:
        // Emergency: aggressive marking
        gcTimeRatio ← 0.9
    else if freeRatio < LOW_THRESHOLD:
        // Increase GC effort
        gcTimeRatio ← min(gcTimeRatio * 1.5, 0.7)
    else if freeRatio > HIGH_THRESHOLD:
        // Decrease GC effort
        gcTimeRatio ← max(gcTimeRatio * 0.8, 0.1)
```

---

## 16.8 Correctness Concerns

### Mark Stack Overflow

The grey queue may overflow for large live sets:

```pseudo
pushWithOverflow(object):
    if greyQueue.full():
        // Mark as overflowed
        overflowBitmap[object] ← true
        overflowOccurred ← true
    else:
        greyQueue.push(object)

handleOverflow():
    if overflowOccurred:
        // Scan heap for overflowed objects
        for each object in heap:
            if overflowBitmap[object]:
                overflowBitmap[object] ← false
                greyQueue.push(object)
        overflowOccurred ← false
```

### Root Mutation During Marking

Roots may change during concurrent marking:

```pseudo
// Thread creates new root during marking
storeToGlobal(globalSlot, value):
    *globalSlot ← value

    if gcState = MARKING:
        // Record the new root
        if not isMarked(value):
            greyObject(value)
```

### Barrier Completeness

All pointer stores must execute the barrier:

```pseudo
// Compiler must ensure barrier on all paths
// Including: array stores, field stores, stack stores, JNI
arrayStore(array, index, value):
    array[index] ← value
    writeBarrier(array, &array[index], value)
```

---

## 16.9 Notable Implementations

### CMS (Concurrent Mark Sweep)

HotSpot's CMS collector:
- Initial mark (STW): scan roots
- Concurrent mark: trace heap
- Concurrent preclean: process dirty cards
- Remark (STW): final marking
- Concurrent sweep: reclaim garbage

### G1 Concurrent Marking

G1 uses concurrent marking for old generation:
- SATB barrier
- Region-based marking
- Concurrent marking threads
- Evacuation based on marking results

---

## 16.10 Summary

Mostly-concurrent mark-sweep trades complexity for reduced pause times:

| Phase | Duration | Work |
|-------|----------|------|
| Initial mark | Short (ms) | Scan roots, grey direct refs |
| Concurrent mark | Long | Trace object graph |
| Remark | Short (ms) | Process buffers, finalize |
| Sweep | Variable | Reclaim unmarked objects |

Key design decisions:
- **Barrier choice**: SATB vs incremental update
- **Sweep timing**: STW vs concurrent vs lazy
- **Pacing strategy**: Allocation-based vs time-based
- **Work distribution**: Work stealing for marker threads

Correct implementation requires:
- Complete barrier coverage
- Handling root mutations
- Mark stack overflow handling
- Proper termination detection
