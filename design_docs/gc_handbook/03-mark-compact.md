# 3. Mark-Compact Garbage Collection

Mark-compact collectors extend mark-sweep by adding a compaction phase that relocates live objects to eliminate fragmentation. After marking, objects are moved to form a contiguous block at one end of the heap, leaving all free space at the other end. This chapter covers the main compaction algorithms (two-finger, Lisp2, and sliding), forwarding pointer management, and region-based partial compaction.

---

## 3.1 Motivation and Structure

Mark-sweep leaves "holes" in the heap where dead objects resided. Over time, these holes cause:
- **External fragmentation**: Many small free spaces that can't satisfy large allocations
- **Poor locality**: Live objects scattered across memory
- **Allocation overhead**: Complex free-list management

Mark-compact addresses these by relocating live objects:

```pseudo
markCompact():
    // Phase 1: Mark (same as mark-sweep)
    markFromRoots()

    // Phase 2: Compute forwarding addresses
    computeLocations()

    // Phase 3: Update references
    updateReferences()

    // Phase 4: Relocate objects
    relocate()
```

**Trade-offs**:
- **Pros**: No fragmentation, bump allocation, good locality
- **Cons**: Multiple heap passes, must update all pointers, longer pauses

---

## 3.2 Two-Finger Compaction (Edwards)

The simplest compaction algorithm uses two pointers that converge from opposite ends:

```pseudo
twoFingerCompact():
    // Phase 1: Mark (standard)
    markFromRoots()

    // Phase 2: Move objects
    free ← HeapStart      // Points to first gap
    scan ← HeapEnd        // Points to last object

    while free < scan:
        // Find first unmarked object (gap) from bottom
        while free < scan and isMarked(free):
            free ← free + objectSize(free)

        // Find last marked object from top
        while scan > free and not isMarked(objectBefore(scan)):
            scan ← objectBefore(scan)

        if free >= scan:
            break

        // Move object from scan to free
        src ← objectBefore(scan)
        size ← objectSize(src)
        memcpy(free, src, size)
        setForwardingPointer(src, free)
        unsetMarked(free)
        free ← free + size
        scan ← src

    newHeapTop ← free

    // Phase 3: Update all references
    updateReferences(HeapStart, newHeapTop)
```

### Updating References

```pseudo
updateReferences(start, end):
    // Update roots
    for each root in Roots:
        if *root ≠ null:
            *root ← forwardingAddress(*root)

    // Update object fields
    cursor ← start
    while cursor < end:
        for each field in Pointers(cursor):
            old ← *field
            if old ≠ null:
                *field ← forwardingAddress(old)
        cursor ← cursor + objectSize(cursor)
```

**Characteristics**:
- Simple implementation
- Single pass for relocation
- Arbitrary object ordering (destroys allocation locality)
- Requires uniform object sizes for efficient operation

---

## 3.3 Lisp2 Compaction (Threaded)

The Lisp2 algorithm uses pointer threading to avoid extra space for forwarding addresses:

```pseudo
lisp2Compact():
    // Phase 1: Mark
    markFromRoots()

    // Phase 2: Compute forwarding addresses and thread pointers
    dest ← HeapStart
    cursor ← HeapStart
    while cursor < HeapEnd:
        if isMarked(cursor):
            forwardAddress[cursor] ← dest
            threadReferences(cursor)
            dest ← dest + objectSize(cursor)
        cursor ← cursor + objectSize(cursor)

    newTop ← dest

    // Phase 3: Update threaded references and move objects
    cursor ← HeapStart
    dest ← HeapStart
    while cursor < HeapEnd:
        if isMarked(cursor):
            unthread(cursor)
            if cursor ≠ dest:
                memcpy(dest, cursor, objectSize(cursor))
            unsetMarked(dest)
            dest ← dest + objectSize(cursor)
        cursor ← cursor + objectSize(cursor)
```

### Pointer Threading

Replace pointers with a linked list through the objects they reference:

```pseudo
threadReferences(obj):
    for each field in Pointers(obj):
        target ← *field
        if target ≠ null and isMarked(target):
            // Thread: store field's address in target, point field to target's old first threaded pointer
            oldThread ← target.header.thread
            target.header.thread ← addressOf(field)
            *field ← oldThread

unthread(obj):
    thread ← obj.header.thread
    newAddr ← forwardAddress[obj]
    while thread ≠ null:
        next ← *thread
        *thread ← newAddr  // Update to point to new location
        thread ← next
    obj.header.thread ← null
```

**Characteristics**:
- No extra space for forwarding addresses
- Complex implementation
- Requires header space for threading
- Good for memory-constrained systems

---

## 3.4 Sliding Compaction (LISP 1.5)

Sliding compaction preserves allocation order by moving objects toward the heap start:

```pseudo
slidingCompact():
    // Phase 1: Mark
    markFromRoots()

    // Phase 2: Compute forwarding addresses (prefix sum)
    dest ← HeapStart
    cursor ← HeapStart
    while cursor < HeapEnd:
        size ← objectSize(cursor)
        if isMarked(cursor):
            setForwardingAddress(cursor, dest)
            dest ← dest + size
        cursor ← cursor + size
    newTop ← dest

    // Phase 3: Update references
    updateAllReferences()

    // Phase 4: Relocate objects
    cursor ← HeapStart
    while cursor < HeapEnd:
        size ← objectSize(cursor)
        if isMarked(cursor):
            destAddr ← forwardingAddress(cursor)
            if destAddr ≠ cursor:
                memmove(destAddr, cursor, size)
            unsetMarked(destAddr)
        cursor ← cursor + size

    heapTop ← newTop
```

### Forwarding Address Storage

Options for storing forwarding addresses:

**In object header**:
```pseudo
setForwardingAddress(obj, dest):
    obj.header.forwarding ← dest

forwardingAddress(obj):
    return obj.header.forwarding
```

**In side table**:
```pseudo
forwardingTable: HashMap<Address, Address>

setForwardingAddress(obj, dest):
    forwardingTable[obj] ← dest

forwardingAddress(obj):
    return forwardingTable[obj]
```

**Computed from bitmap**:
```pseudo
// Use bitmap to recompute offset
forwardingAddress(obj):
    // Count live bytes before obj
    liveBytes ← 0
    cursor ← HeapStart
    while cursor < obj:
        if isMarked(cursor):
            liveBytes ← liveBytes + objectSize(cursor)
        cursor ← cursor + objectSize(cursor)
    return HeapStart + liveBytes
```

**Characteristics**:
- Preserves allocation order (good locality)
- Requires multiple heap passes
- Must handle overlapping source/destination

---

## 3.5 Break Table Compaction (Haddon-Waite)

Avoid storing per-object forwarding addresses by recording only the "breaks" where gaps occur:

```pseudo
BreakEntry:
    oldAddress: Address
    newAddress: Address

buildBreakTable():
    breaks ← []
    dest ← HeapStart
    cursor ← HeapStart

    while cursor < HeapEnd:
        size ← objectSize(cursor)
        if isMarked(cursor):
            if dest ≠ cursor:
                // Gap: record break
                breaks.add(BreakEntry(cursor, dest))
            dest ← dest + size
        cursor ← cursor + size

    return breaks

forwardingAddress(obj, breaks):
    // Binary search for break before obj
    entry ← binarySearchFloor(breaks, obj.oldAddress)
    if entry = null:
        return obj  // No break before - unmoved
    offset ← obj - entry.oldAddress
    return entry.newAddress + offset
```

**Characteristics**:
- Space proportional to number of gaps, not objects
- O(log n) lookup per reference
- Good when few large gaps

---

## 3.6 One-Pass Algorithms

Combine reference updating with relocation:

```pseudo
onePassCompact():
    markFromRoots()

    // Compute forwarding addresses
    computeForwardingAddresses()

    // Single pass: copy and update simultaneously
    dest ← HeapStart
    cursor ← HeapStart
    while cursor < HeapEnd:
        if isMarked(cursor):
            size ← objectSize(cursor)

            // Copy object
            if cursor ≠ dest:
                memcpy(dest, cursor, size)

            // Update fields in the copy
            for each field in Pointers(dest):
                old ← *field
                if old ≠ null:
                    *field ← forwardingAddress(old)

            unsetMarked(dest)
            dest ← dest + size
        cursor ← cursor + objectSize(cursor)

    // Update roots
    updateRoots()
    heapTop ← dest
```

**Requirement**: Forwarding addresses must be computed before relocation begins, or destinations must not overlap sources (sliding downward satisfies this).

---

## 3.7 Handling Large and Pinned Objects

### Large Object Space (LOS)

Exclude large objects from compaction:

```pseudo
allocate(size):
    if size > LARGE_OBJECT_THRESHOLD:
        return allocateInLOS(size)
    else:
        return allocateInCompactedSpace(size)

compact():
    // Only compact regular space, not LOS
    markFromRoots()
    compactRegularSpace()
    sweepLOS()  // Use mark-sweep for large objects
```

### Pinned Objects

Objects that cannot move (FFI references, etc.):

```pseudo
computeForwardingWithPins():
    dest ← HeapStart
    cursor ← HeapStart

    while cursor < HeapEnd:
        size ← objectSize(cursor)
        if isMarked(cursor):
            if isPinned(cursor):
                // Pinned: leave in place
                if dest < cursor:
                    // Fill gap before pinned object
                    addToFreeList(dest, cursor - dest)
                setForwardingAddress(cursor, cursor)
                dest ← cursor + size
            else:
                setForwardingAddress(cursor, dest)
                dest ← dest + size
        cursor ← cursor + size
```

---

## 3.8 Parallel Compaction

### Region-Based Parallel Compaction

Divide heap into regions for parallel processing:

```pseudo
parallelCompact():
    // Phase 1: Parallel mark
    parallelMark()

    // Phase 2: Compute per-region live bytes
    parallel for each region r:
        r.liveBytes ← countLiveBytes(r)

    // Phase 3: Sequential prefix sum (quick)
    offset ← 0
    for each region r:
        r.destStart ← offset
        offset ← offset + r.liveBytes

    // Phase 4: Parallel compute per-object forwarding
    parallel for each region r:
        dest ← r.destStart
        for each obj in r:
            if isMarked(obj):
                setForwardingAddress(obj, dest)
                dest ← dest + objectSize(obj)

    // Phase 5: Parallel update references
    parallel for each region r:
        for each obj in r:
            if isMarked(obj):
                updateObjectReferences(obj)

    // Phase 6: Parallel relocate
    parallel for each region r:
        relocateRegion(r)
```

### Handling Cross-Region Dependencies

Objects may move to different regions than their source:

```pseudo
relocateRegion(sourceRegion):
    for each obj in sourceRegion:
        if isMarked(obj):
            dest ← forwardingAddress(obj)
            destRegion ← regionOf(dest)

            // May need synchronization if dest in different region
            if destRegion ≠ sourceRegion:
                lock(destRegion)
                memcpy(dest, obj, objectSize(obj))
                unlock(destRegion)
            else:
                memcpy(dest, obj, objectSize(obj))
```

---

## 3.9 Incremental Compaction

Break compaction into smaller steps to reduce pause times:

### Region-Based Incremental Compaction (G1/Immix Style)

```pseudo
incrementalCompact():
    // Select regions to evacuate (based on liveness)
    evacuationSet ← selectLowLivenessRegions()

    for each region r in evacuationSet:
        evacuateRegion(r)
        yield()  // Allow mutator progress

evacuateRegion(region):
    for each obj in region:
        if isMarked(obj):
            dest ← allocateInDenseRegion(objectSize(obj))
            memcpy(dest, obj, objectSize(obj))
            setForwardingAddress(obj, dest)

    // Update references (needs read barrier during incremental)
    updateReferencesToEvacuatedObjects(region)
    freeRegion(region)
```

### Read Barriers for Incremental Compaction

```pseudo
// Brooks-style forwarding pointer in each object
readBarrier(obj):
    return obj.forwardingPointer

// Or check if in evacuated region
readBarrier(obj):
    if inEvacuatedRegion(obj):
        return forwardingAddress(obj)
    return obj
```

---

## 3.10 Memory Ordering and Correctness

### Copy-Then-Update Ordering

Ensure copy is visible before forwarding pointer:

```pseudo
relocateWithOrdering(obj, dest):
    // Copy object data
    memcpy(dest, obj, objectSize(obj))

    // Memory barrier: ensure copy visible
    writeBarrier()

    // Now install forwarding pointer
    setForwardingAddress(obj, dest)
```

### Handling Overlapping Regions

When destination overlaps source (common in sliding):

```pseudo
safeRelocate(obj, dest):
    size ← objectSize(obj)
    if dest < obj:
        // Moving down: safe to copy forward
        memcpy(dest, obj, size)
    else if dest > obj:
        // Moving up: copy backward to avoid overwrite
        memmove(dest, obj, size)  // memmove handles overlap
    // else: dest = obj, no copy needed
```

---

## 3.11 Interior Pointers

Handle pointers into the middle of objects:

```pseudo
updateInteriorPointer(fieldAddr):
    ptr ← *fieldAddr
    base ← findObjectBase(ptr)
    offset ← ptr - base
    newBase ← forwardingAddress(base)
    *fieldAddr ← newBase + offset

findObjectBase(interiorPtr):
    // Use crossing map or object table
    card ← cardOf(interiorPtr)
    objStart ← firstObjectInCard(card)
    while objStart + objectSize(objStart) <= interiorPtr:
        objStart ← objStart + objectSize(objStart)
    return objStart
```

---

## 3.12 Comparison of Compaction Algorithms

| Algorithm | Passes | Extra Space | Order Preserved | Complexity |
|-----------|--------|-------------|-----------------|------------|
| **Two-Finger** | 2 | Forwarding table | No | Simple |
| **Lisp2 (Threaded)** | 2 | Header thread field | Yes | Complex |
| **Sliding** | 3-4 | Forwarding in header | Yes | Moderate |
| **Break Table** | 3 | O(gaps) | Yes | Moderate |
| **One-Pass** | 2 | Forwarding table | Yes | Moderate |

---

## 3.13 Summary

Mark-compact eliminates fragmentation at the cost of additional passes:

| Phase | Purpose | Cost |
|-------|---------|------|
| **Mark** | Identify live objects | O(L) |
| **Compute** | Calculate forwarding addresses | O(H) |
| **Update** | Fix all pointers | O(L × refs) |
| **Relocate** | Move objects | O(L) |

Key design choices:

| Aspect | Options |
|--------|---------|
| **Forwarding storage** | Header, side table, computed, threaded |
| **Order** | Preserved (sliding) vs arbitrary (two-finger) |
| **Large objects** | Separate LOS, exclude from compaction |
| **Parallelism** | Region-based with prefix sums |
| **Incrementality** | Region evacuation with barriers |

When to use mark-compact:
- When fragmentation is problematic
- When allocation locality matters
- As fallback for mark-sweep when fragmentation threshold exceeded
- For full-heap collection in generational systems

Compared to copying:
- Uses less space (no copy reserve)
- More complex pointer updates
- Suitable for old generation where copying's 2× overhead is prohibitive

