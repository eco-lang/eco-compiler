# 15. Barriers for Garbage Collection

Barriers are code sequences that execute during read or write operations to maintain garbage collector invariants. They enable generational collection by tracking inter-generational pointers and enable concurrent collection by maintaining the tricolor invariant while mutators modify the heap. This chapter covers the design, implementation, and trade-offs of various barrier types.

---

## 15.1 Why Barriers Are Necessary

### For Generational Collection

Young generation collection requires knowing which old-generation objects point into the young generation. Without scanning the entire old generation (which would defeat the purpose of generational collection), we need barriers to record these pointers as they're created.

### For Concurrent Collection

When mutators run concurrently with the collector, pointer modifications can cause the collector to miss live objects. Barriers maintain invariants that ensure safety.

**The Lost Object Problem:**

```
Initial state: A (black) → B (white)
Mutator:
1. C.field ← B    // C is black, B now reachable from C
2. A.field ← null // A no longer points to B

Collector: Scans A (already black), never sees B
Result: B is incorrectly collected as garbage
```

---

## 15.2 Write Barriers

Write barriers execute when the mutator stores a pointer value into memory.

### Unconditional Card Marking

The simplest and most common write barrier for generational collection:

```pseudo
writeBarrier(object, field, value):
    object[field] ← value
    cardTable[addressOf(object) >> CARD_SHIFT] ← DIRTY
```

**Properties:**
- Very fast: no conditionals, single store
- May re-dirty already dirty cards (harmless)
- Works for any store, not just pointer stores

### Conditional Card Marking

Avoid re-dirtying clean cards:

```pseudo
writeBarrierConditional(object, field, value):
    object[field] ← value
    cardIndex ← addressOf(object) >> CARD_SHIFT
    if cardTable[cardIndex] ≠ DIRTY:
        cardTable[cardIndex] ← DIRTY
```

**Trade-off:** Additional branch vs. fewer redundant stores.

### Filtering Write Barriers

Skip barrier when unnecessary:

```pseudo
writeBarrierFiltered(object, field, value):
    object[field] ← value

    // Skip if storing null
    if value = null:
        return

    // Skip if not cross-generational
    if not isOld(object) or not isYoung(value):
        return

    recordInRememberedSet(field)
```

### Store Buffer Barrier

Record updated locations in a buffer for later processing:

```pseudo
writeBarrierStoreBuffer(object, field, value):
    object[field] ← value

    if isOld(object):
        localBuffer.push(addressOf(object[field]))
        if localBuffer.full():
            flushToGlobalBuffer(localBuffer)
```

**Advantages:**
- Precise: records exact location
- Batched processing
- Thread-local for low contention

---

## 15.3 Write Barriers for Concurrent Collection

### Dijkstra's Incremental Update Barrier

Prevents creating black→white edges by shading new targets grey:

```pseudo
dijkstraBarrier(object, field, value):
    object[field] ← value

    if gcState = MARKING:
        if isBlack(object) and isWhite(value):
            shade(value)  // Make grey, add to work list
```

**Invariant maintained:** Strong tricolor invariant (no black→white edges).

**Drawback:** May shade objects unnecessarily if they would have been shaded anyway via another path.

### Steele's Incremental Update Barrier

Variant that shades the source object grey instead:

```pseudo
steeleBarrier(object, field, value):
    object[field] ← value

    if gcState = MARKING:
        if isBlack(object) and isWhite(value):
            shade(object)  // Rescan object
```

**Property:** May rescan objects multiple times but simpler reasoning.

### Snapshot-at-the-Beginning (SATB) Barrier

Preserves the object graph as it existed at the start of marking:

```pseudo
satbBarrier(object, field, value):
    oldValue ← object[field]
    object[field] ← value

    if gcState = MARKING:
        if oldValue ≠ null and not isMarked(oldValue):
            satbBuffer.push(oldValue)
```

**Key insight:** Any object reachable at the start of marking will be retained, regardless of subsequent mutations.

**Invariant maintained:** Weak tricolor invariant (if black→white exists, grey→white path exists from snapshot).

**Advantages:**
- Clean termination: once grey set empty, collection complete
- No floating garbage from mutations during collection
- Only logs deletions, not insertions

**Disadvantages:**
- Must load old value before storing new (extra memory access)
- Objects allocated during marking need special handling

### SATB Buffer Processing

```pseudo
processSATBBuffers():
    for each thread t:
        buffer ← t.satbBuffer
        while not buffer.empty():
            ref ← buffer.pop()
            if not isMarked(ref):
                mark(ref)
                greySet.add(ref)
```

---

## 15.4 Read Barriers

Read barriers execute when the mutator loads a pointer from memory. They're more expensive than write barriers since reads are much more frequent, but necessary for some concurrent copying algorithms.

### Brooks Forwarding Pointer Barrier

Each object has an indirection pointer; reads follow it:

```pseudo
// Object layout includes forwarding pointer as first field
// Initially points to itself

brooksReadBarrier(ref):
    return ref.forwardingPointer

// When object is moved
moveObject(old, new):
    copy(old, new)
    new.forwardingPointer ← new
    old.forwardingPointer ← new  // Redirect old to new
```

**Properties:**
- Constant-time forwarding
- One extra indirection per read
- Old copies stay valid until compaction

### Baker's To-Space Invariant Barrier

Ensures mutators only see to-space copies:

```pseudo
bakerReadBarrier(ref):
    if inFromSpace(ref):
        // Evacuate on access
        if isForwarded(ref):
            return getForwardingAddress(ref)
        else:
            newRef ← evacuate(ref)
            return newRef
    return ref
```

**Invariant:** Mutators only access to-space objects.

**Cost:** Every pointer load requires space check.

### Conditional Read Barrier

Execute barrier only during collection:

```pseudo
conditionalReadBarrier(ref):
    if gcState = COLLECTING:
        return fullReadBarrier(ref)
    return ref
```

### Self-Healing Reads

Update the source of a read when forwarded:

```pseudo
selfHealingRead(source, fieldOffset):
    ref ← source[fieldOffset]
    if inFromSpace(ref):
        newRef ← evacuate(ref)
        // Try to update source to avoid repeated forwarding
        CompareAndSet(&source[fieldOffset], ref, newRef)
        return newRef
    return ref
```

---

## 15.5 Barrier Implementation Techniques

### Inlining

Place barrier code directly at each access site:

```pseudo
// Generated code for: x.field = y
store [x + fieldOffset], y
movq rax, [x + fieldOffset]
shrq rax, CARD_SHIFT
movb [cardTable + rax], DIRTY
```

**Pros:** Fast (no call overhead)
**Cons:** Code size increase

### Out-of-Line Calls

Call a barrier function:

```pseudo
// Generated code for: x.field = y
store [x + fieldOffset], y
call writeBarrier(x, fieldOffset, y)
```

**Pros:** Smaller code
**Cons:** Call overhead, register spilling

### Hybrid Approach

Inline fast path, call slow path:

```pseudo
// Generated code
store [x + fieldOffset], y
movq rax, [x + fieldOffset]
shrq rax, CARD_SHIFT
cmpb [cardTable + rax], DIRTY
jne slowPath
continue:
    ...

slowPath:
    call writeBarrierSlow(x, fieldOffset, y)
    jmp continue
```

### Page Protection Barriers

Use hardware memory protection to trigger barriers:

```pseudo
// Protect from-space pages
protectPages(fromSpace, READ_PROTECT)

// On access, trap handler evacuates
trapHandler(address):
    object ← findObject(address)
    newObject ← evacuate(object)
    unprotectPage(pageOf(address))
    // Return to retry access
```

**Pros:** Zero overhead when barrier not needed
**Cons:** High cost per trap, OS involvement

---

## 15.6 Card Tables

### Design Parameters

```pseudo
CARD_SIZE = 512 bytes  // Typical: 128-1024 bytes
CARD_SHIFT = 9         // log2(CARD_SIZE)

cardTable: array[heapSize / CARD_SIZE] of byte
```

**Trade-offs:**
- Smaller cards → more precise, larger table, more dirty cards
- Larger cards → less precise, smaller table, fewer writes

### Card States

```pseudo
CLEAN = 0     // No interesting pointers
DIRTY = 1     // Contains pointer to young gen (must scan)
SCANNED = 2   // Dirty but already processed this cycle
```

### Scanning Dirty Cards

```pseudo
scanDirtyCards():
    for cardIndex from 0 to cardTableSize - 1:
        if cardTable[cardIndex] = DIRTY:
            scanCard(cardIndex)
            cardTable[cardIndex] ← CLEAN

scanCard(cardIndex):
    start ← cardIndex << CARD_SHIFT
    end ← start + CARD_SIZE

    // Find first object in card
    object ← firstObjectStartingBefore(start)
    while addressOf(object) < end:
        for each field in pointerFields(object):
            target ← *field
            if inYoungGeneration(target):
                processYoungRef(field, target)
        object ← nextObject(object)
```

### Crossing Map

Helps find the first object in a card:

```pseudo
// crossingMap[i] = offset from card start to last object starting in card i
// or negative if object from previous card spans into this one

firstObjectInCard(cardIndex):
    offset ← crossingMap[cardIndex]
    if offset >= 0:
        return cardStart(cardIndex) + offset
    else:
        // Object spans from previous card
        return firstObjectInCard(cardIndex + offset)
```

---

## 15.7 Remembered Sets

Fine-grained alternative to card tables:

### Hash Set

```pseudo
rememberedSet: HashSet<Address>

writeBarrierRemSet(object, field, value):
    object[field] ← value
    if isOld(object) and isYoung(value):
        rememberedSet.add(addressOf(field))

processRememberedSet():
    for each fieldAddr in rememberedSet:
        target ← *fieldAddr
        if inYoungGeneration(target):
            processYoungRef(fieldAddr, target)
    rememberedSet.clear()
```

### Per-Region Remembered Sets (G1 Style)

```pseudo
// Each region has its own remembered set of references from other regions
Region:
    rememberedSet: HashSet<CardIndex>

writeBarrierG1(object, field, value):
    object[field] ← value
    sourceRegion ← regionOf(object)
    targetRegion ← regionOf(value)

    if sourceRegion ≠ targetRegion:
        // Record cross-region reference
        cardIndex ← addressOf(field) >> CARD_SHIFT
        targetRegion.rememberedSet.add(cardIndex)
```

---

## 15.8 Barrier Filtering and Optimization

### Null Check Elimination

```pseudo
writeBarrierOptimized(object, field, value):
    object[field] ← value
    if value = null:
        return  // Null can't be young pointer
    // Continue with barrier
```

### Loop Hoisting

```pseudo
// Before optimization
for i from 0 to n-1:
    array[i] ← value
    barrier(array, i)

// After optimization (barrier at end)
for i from 0 to n-1:
    array[i] ← value
barrier(array)  // One barrier for entire array
```

### Batching

```pseudo
writeBarrierBatched(object, field, value):
    object[field] ← value
    localBatch.add(field)
    if localBatch.size() >= BATCH_SIZE:
        processBatch(localBatch)
        localBatch.clear()
```

### Redundant Barrier Elimination

Compiler optimization to remove barriers where provably unnecessary:

```pseudo
// x.f = a
// x.f = b  // Barrier for first store is redundant
writeBarrier(x, f, a)  // Can be eliminated
x.f = a
writeBarrier(x, f, b)
x.f = b
```

---

## 15.9 Barrier Correctness

### Memory Ordering

Barriers must be correctly ordered with the actual write:

```pseudo
// WRONG - barrier before write
cardTable[card] ← DIRTY
object[field] ← value    // GC might miss this

// CORRECT - write before barrier
object[field] ← value
releaseFence()           // Ensure write visible
cardTable[card] ← DIRTY  // Now safe to dirty card
```

### Atomicity Requirements

For concurrent collectors, barrier and write may need to be atomic:

```pseudo
// Potential race with concurrent collector
object[field] ← value    // Collector sees old value
// Context switch to collector
// Collector marks based on old value
satbBuffer.push(old)     // Too late!

// Solution: Use atomic or ensure ordering
atomic:
    oldValue ← object[field]
    object[field] ← value
    if gcState = MARKING:
        satbBuffer.push(oldValue)
```

---

## 15.10 Comparing Barrier Strategies

| Barrier Type | Use Case | Cost | Precision |
|-------------|----------|------|-----------|
| **Card marking** | Generational | Very low | Coarse (card granularity) |
| **Store buffer** | Generational | Low | Precise |
| **Incremental update** | Concurrent mark | Medium | Precise |
| **SATB** | Concurrent mark | Medium | Precise |
| **Brooks forwarding** | Concurrent copy | High (every read) | N/A |
| **Baker to-space** | Concurrent copy | High (every read) | N/A |

---

## 15.11 Summary

Barriers are essential infrastructure for modern garbage collectors:

| Purpose | Barrier Type | Mechanism |
|---------|-------------|-----------|
| **Track old→young** | Card marking | Dirty byte per card |
| **Track old→young** | Store buffer | Log modified locations |
| **Concurrent mark** | Incremental update | Shade new target grey |
| **Concurrent mark** | SATB | Log overwritten value |
| **Concurrent copy** | Read barrier | Evacuate on access |
| **Concurrent copy** | Self-healing | Update stale pointers |

Design considerations:
- Write barriers preferred (writes less frequent than reads)
- Inline fast path, call slow path
- Filter nulls and same-generation writes
- Balance precision against overhead
- Ensure correct memory ordering
- Consider interaction with compiler optimizations
