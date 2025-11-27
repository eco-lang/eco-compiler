# 2. Mark-Sweep Garbage Collection

Mark-sweep is the foundational tracing collector algorithm, developed by McCarthy in 1960 for Lisp. It operates in two phases: first tracing the object graph from roots to identify live objects (marking), then scanning the entire heap to reclaim unmarked objects (sweeping). This chapter covers the core algorithm, the tricolor abstraction, bitmap marking, lazy sweeping, and cache-conscious optimizations.

---

## 2.1 The Core Algorithm

Mark-sweep is an indirect collection algorithm. Rather than detecting garbage directly, it identifies all live objects and concludes that everything else must be garbage.

### Basic Structure

```pseudo
// Allocation triggers collection when heap is full
New():
    ref ← allocate()
    if ref = null:
        collect()
        ref ← allocate()
        if ref = null:
            error "Out of memory"
    return ref

atomic collect():
    markFromRoots()
    sweep(HeapStart, HeapEnd)
```

### Marking Phase

The marker traverses the object graph starting from roots:

```pseudo
markFromRoots():
    initialize(worklist)
    for each fld in Roots:
        ref ← *fld
        if ref ≠ null and not isMarked(ref):
            setMarked(ref)
            add(worklist, ref)
    mark()

mark():
    while not isEmpty(worklist):
        ref ← remove(worklist)
        for each fld in Pointers(ref):
            child ← *fld
            if child ≠ null and not isMarked(child):
                setMarked(child)
                add(worklist, child)
```

### Sweeping Phase

The sweeper reclaims unmarked objects:

```pseudo
sweep(start, end):
    scan ← start
    while scan < end:
        if isMarked(scan):
            unsetMarked(scan)
        else:
            free(scan)
        scan ← nextObject(scan)
```

### Complexity

- **Mark phase**: O(L) where L is the size of live data
- **Sweep phase**: O(H) where H is the heap size
- **Space**: O(D) for the mark stack, where D is maximum graph depth

---

## 2.2 The Tricolor Abstraction

The tricolor abstraction provides a framework for reasoning about collector correctness:

```pseudo
Colors:
    WHITE = unvisited (candidate garbage)
    GREY  = discovered but not yet scanned
    BLACK = scanned and all children identified
```

### Color Transitions

```pseudo
// Initial state: all objects WHITE

// When first discovered
greyObject(obj):
    if color(obj) = WHITE:
        color(obj) ← GREY
        add(worklist, obj)

// When scanned
blackenObject(obj):
    for each child in children(obj):
        greyObject(child)
    color(obj) ← BLACK
```

### The Strong Tricolor Invariant

**Invariant**: No black object points directly to a white object.

This ensures that any white object reachable from the roots must be reachable through a grey object. If this invariant is maintained, the collector will not miss any live objects.

### Wavefront Model

The grey objects form a "wavefront" separating black (processed) from white (unprocessed) objects. Marking progresses by advancing this wavefront until no grey objects remain.

---

## 2.3 Mark Bit Storage

### In-Header Mark Bits

Store mark bits in object headers:

```pseudo
isMarked(obj):
    return (obj.header & MARK_BIT) ≠ 0

setMarked(obj):
    obj.header ← obj.header | MARK_BIT

unsetMarked(obj):
    obj.header ← obj.header & ~MARK_BIT
```

**Advantages**: Simple, no extra data structures
**Disadvantages**: Modifies objects, cache traffic

### Bitmap Marking

Store marks in a separate bitmap:

```pseudo
ALIGNMENT = 8  // Minimum object alignment
markBitmap: array[(HeapEnd - HeapStart) / ALIGNMENT] of bit

bitIndex(obj):
    return (addressOf(obj) - HeapStart) / ALIGNMENT

isMarked(obj):
    return markBitmap[bitIndex(obj)] = 1

setMarked(obj):
    markBitmap[bitIndex(obj)] ← 1

clearAllMarks():
    memset(markBitmap, 0, sizeof(markBitmap))
```

**Advantages**:
- Compact representation (1 bit per possible object)
- Cache-friendly for sweeping (dense bit scanning)
- Safe for conservative collectors (doesn't modify objects)
- Allows testing multiple objects at once (word operations)

**Disadvantages**:
- Extra memory for bitmap
- Additional indirection to test marks

### Byte Maps for Parallel Marking

Single bits cause race conditions in parallel marking. Use bytes instead:

```pseudo
markByteMap: array[(HeapEnd - HeapStart) / ALIGNMENT] of byte

setMarked(obj):
    // Idempotent - no race condition
    markByteMap[bitIndex(obj)] ← 1
```

---

## 2.4 The Mark Stack

### Basic Stack Implementation

```pseudo
MarkStack:
    entries: array[MAX_DEPTH] of Address
    top: int

push(stack, obj):
    if stack.top >= MAX_DEPTH:
        handleOverflow(obj)
    else:
        stack.entries[stack.top] ← obj
        stack.top ← stack.top + 1

pop(stack):
    if stack.top = 0:
        return null
    stack.top ← stack.top - 1
    return stack.entries[stack.top]
```

### Overflow Handling

When the stack overflows, use an overflow bitmap:

```pseudo
overflowed: boolean
overflowBitmap: array[...] of bit

handleOverflow(obj):
    overflowed ← true
    overflowBitmap[bitIndex(obj)] ← 1

processOverflow():
    if not overflowed:
        return

    overflowed ← false
    for each obj in heap:
        if overflowBitmap[bitIndex(obj)] = 1:
            overflowBitmap[bitIndex(obj)] ← 0
            if not allChildrenMarked(obj):
                push(markStack, obj)

// After main mark loop completes
while overflowed:
    processOverflow()
    mark()
```

### Linear Bitmap Scan (Printezis/Detlefs)

Avoid stack overflow by scanning the bitmap linearly:

```pseudo
markWithBitmapScan():
    cur ← nextMarkedInBitmap(HeapStart)
    while cur < HeapEnd:
        add(worklist, cur)
        markStep(cur)
        cur ← nextMarkedInBitmap(cur)

markStep(start):
    while not isEmpty(worklist):
        ref ← remove(worklist)
        for each fld in Pointers(ref):
            child ← *fld
            if child ≠ null and not isMarked(child):
                setMarked(child)
                if child < start:
                    add(worklist, child)  // Behind wavefront
                // Else: will be found by linear scan
```

---

## 2.5 Lazy Sweeping

Defer sweeping until allocation time to reduce pause times:

```pseudo
LazySweeperState:
    sweepCursor: Address
    reclaimList: List<Block>

collect():
    markFromRoots()
    // Don't sweep now - add blocks to reclaim list
    for each block in Blocks:
        if not anyMarked(block):
            returnToBlockAllocator(block)
        else:
            add(reclaimList, block)

allocate(size):
    result ← freeList[sizeClass(size)].pop()
    if result ≠ null:
        return result

    // Sweep incrementally until we find space
    lazySweep(size)
    return freeList[sizeClass(size)].pop()

lazySweep(size):
    while true:
        block ← nextBlock(reclaimList, size)
        if block = null:
            break

        sweep(block.start, block.end)
        if spaceFound(block, size):
            return

    // No space found - get fresh block or trigger GC
    allocateFreshBlock(size)
```

### Block-Level Marking

Track whether any object in a block is marked:

```pseudo
blockMarked: array[numBlocks] of byte

setMarked(obj):
    markBitmap[bitIndex(obj)] ← 1
    blockMarked[blockIndex(obj)] ← 1  // Also mark block

// In collect()
for each block in Blocks:
    if blockMarked[blockIndex(block)] = 0:
        // Entire block is garbage
        returnToBlockAllocator(block)
    else:
        add(reclaimList, block)
        blockMarked[blockIndex(block)] ← 0  // Reset for next cycle
```

---

## 2.6 Cache-Conscious Marking

### FIFO Prefetch Buffer

Insert a FIFO queue between stack operations to enable prefetching:

```pseudo
MarkWorklist:
    stack: MarkStack
    fifo: CircularBuffer[PREFETCH_DISTANCE]

add(worklist, item):
    push(worklist.stack, item)

remove(worklist):
    addr ← pop(worklist.stack)
    if addr = null:
        return removeLast(worklist.fifo)

    prefetch(addr)
    prepend(worklist.fifo, addr)
    return removeLast(worklist.fifo)
```

The prefetch distance (FIFO size) determines how far ahead objects are fetched. Typical values: 8-32 entries.

### Edge Marking vs Node Marking

Traditional marking adds each node once. Edge marking adds children unconditionally:

```pseudo
// Node marking (traditional)
markNode():
    while not isEmpty(worklist):
        obj ← remove(worklist)
        for each fld in Pointers(obj):
            child ← *fld
            if child ≠ null and not isMarked(child):
                setMarked(child)
                add(worklist, child)

// Edge marking (better cache behavior)
markEdge():
    while not isEmpty(worklist):
        obj ← remove(worklist)
        if not isMarked(obj):
            setMarked(obj)
            for each fld in Pointers(obj):
                child ← *fld
                if child ≠ null:
                    add(worklist, child)  // Unconditional
```

Edge marking has more worklist entries but better cache behavior because `isMarked` and `Pointers` operate on the same (prefetched) object.

### Prefetch on Grey

Prefetch object contents when adding to worklist:

```pseudo
greyAndPrefetch(obj):
    if not isMarked(obj):
        setMarked(obj)
        prefetch(obj)  // Fetch first cache line
        add(worklist, obj)
```

---

## 2.7 Parallel Mark-Sweep

### Work Stealing for Marking

```pseudo
parallelMark():
    // Initialize: distribute roots among workers
    for each worker w:
        w.localQueue ← empty
    distributeRoots(Roots, workers)

    // Mark in parallel
    parallel for each worker w:
        markWorkerLoop(w)

markWorkerLoop(worker):
    while true:
        obj ← worker.localQueue.pop()
        if obj = null:
            obj ← globalQueue.steal()
        if obj = null:
            victim ← randomWorker()
            obj ← victim.localQueue.steal()
        if obj = null:
            if terminationDetected():
                return
            continue

        scanObject(obj, worker)

scanObject(obj, worker):
    for each child in children(obj):
        if child ≠ null and tryMark(child):
            worker.localQueue.push(child)
            if worker.localQueue.size() > SHARE_THRESHOLD:
                globalQueue.add(worker.localQueue.split())
```

### Atomic Mark Bit Setting

```pseudo
tryMark(obj):
    loop:
        byte ← markByteMap[bitIndex(obj)]
        if byte ≠ 0:
            return false  // Already marked
        if CompareAndSet(&markByteMap[bitIndex(obj)], 0, 1):
            return true
```

### Parallel Sweeping

```pseudo
parallelSweep():
    chunks ← divideHeap(CHUNK_SIZE)
    parallel for each chunk in chunks:
        sweepChunk(chunk)

sweepChunk(chunk):
    localFreeList ← empty
    cursor ← chunk.start
    while cursor < chunk.end:
        if not isMarked(cursor):
            addToFreeList(localFreeList, cursor)
        else:
            unsetMarked(cursor)
        cursor ← nextObject(cursor)

    mergeFreeList(globalFreeList, localFreeList)
```

---

## 2.8 Incremental and Concurrent Marking

### Write Barriers for Concurrent Marking

To maintain the tricolor invariant while mutators run:

**Dijkstra Barrier (Incremental Update)**:
```pseudo
dijkstraWriteBarrier(obj, field, newValue):
    obj[field] ← newValue
    if gcState = MARKING:
        if isBlack(obj) and isWhite(newValue):
            shade(newValue)  // Grey the new target
```

**SATB Barrier (Snapshot-at-Beginning)**:
```pseudo
satbWriteBarrier(obj, field, newValue):
    oldValue ← obj[field]
    obj[field] ← newValue
    if gcState = MARKING:
        if oldValue ≠ null and not isMarked(oldValue):
            satbBuffer.push(oldValue)
```

### Concurrent Sweep

Sweep can run concurrently with mutators since garbage objects are not accessible:

```pseudo
concurrentSweep():
    sweepFrontier ← HeapStart
    while sweepFrontier < HeapEnd:
        chunk ← getChunkAt(sweepFrontier)
        sweepChunk(chunk)
        sweepFrontier ← chunk.end
        yield()  // Allow mutator progress

// Allocator must only use swept regions
allocate(size):
    while freeList.empty():
        if sweepFrontier >= HeapEnd:
            return null
        helpSweep()  // Mutator helps sweep
    return freeList.pop(size)
```

---

## 2.9 Free List Management

### Segregated Free Lists

Organize free cells by size class:

```pseudo
NUM_SIZE_CLASSES = 64
freeLists: array[NUM_SIZE_CLASSES] of FreeList

sizeClass(size):
    if size <= 128:
        return size / 8
    else:
        return 16 + log2(size - 128)

allocate(size):
    class ← sizeClass(size)
    cell ← freeLists[class].pop()
    if cell ≠ null:
        return cell
    return allocateSlow(size)
```

### Coalescing Adjacent Free Cells

```pseudo
free(obj):
    size ← objectSize(obj)
    prev ← previousObject(obj)
    next ← nextObject(obj)

    // Coalesce with previous
    if prev ≠ null and isFree(prev):
        removeFromFreeList(prev)
        obj ← prev
        size ← size + objectSize(prev)

    // Coalesce with next
    if next ≠ null and isFree(next):
        removeFromFreeList(next)
        size ← size + objectSize(next)

    addToFreeList(obj, size)
```

---

## 2.10 Heap Parsability

The sweeper must be able to find each object in the heap:

### Using Object Size Fields

```pseudo
nextObject(obj):
    return obj + objectSize(obj) + alignmentPadding(obj)

objectSize(obj):
    return obj.header.size  // Or from type descriptor
```

### Using Block Structure

```pseudo
// All objects in a block have the same size
nextObjectInBlock(obj, block):
    next ← obj + block.cellSize
    if next >= block.end:
        return null
    return next
```

### Crossing Maps for Large Objects

```pseudo
// Map from card → offset to object start
crossingMap: array[numCards] of int

firstObjectInCard(cardIndex):
    offset ← crossingMap[cardIndex]
    if offset >= 0:
        return cardStart(cardIndex) + offset
    else:
        // Object spans from previous card
        return firstObjectInCard(cardIndex + offset)
```

---

## 2.11 Summary

Mark-sweep is the foundational non-moving collector:

| Aspect | Characteristic |
|--------|---------------|
| **Space overhead** | Low (mark bits only) |
| **Allocation** | Free-list based |
| **Fragmentation** | Yes (not compacting) |
| **Pause time** | Proportional to live + heap size |
| **Mutator overhead** | None (STW) or barrier (concurrent) |

Key optimizations:

| Technique | Benefit |
|-----------|---------|
| **Bitmap marking** | Cache-friendly sweeping, safe for conservative GC |
| **Lazy sweeping** | Amortizes sweep cost, reduces pause |
| **FIFO prefetch** | Hides memory latency in mark phase |
| **Edge marking** | Better cache utilization |
| **Parallel marking** | Reduces pause via multiple threads |

When to use mark-sweep:
- Old generation in generational collectors
- Conservative/uncooperative environments
- Memory-constrained systems (no copy reserve)
- When objects cannot move (FFI, pinning)

Limitations:
- Fragmentation accumulates over time
- Sweep cost proportional to entire heap
- May need periodic compaction

