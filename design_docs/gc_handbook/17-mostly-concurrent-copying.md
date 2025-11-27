# 17. Mostly-Concurrent Copying Collection

Concurrent copying collectors relocate objects while mutators continue executing. This is more challenging than concurrent marking because mutators may access objects mid-copy, requiring sophisticated barriers to maintain consistency. This chapter covers the algorithms, barriers, and invariants needed for concurrent object relocation.

---

## 17.1 The Challenge of Concurrent Copying

In stop-the-world copying, the collector has exclusive access to the heap. Concurrent copying must handle:

1. **Mutator reads from-space**: May see partially copied or stale data
2. **Mutator writes to from-space**: Updates may be lost if object moves
3. **Pointer comparisons**: Same object may have two addresses
4. **Memory ordering**: Copies must be visible before forwarding

The goal is to ensure mutators always see a consistent view of objects, typically the to-space copy.

---

## 17.2 Read Barriers

### Baker's To-Space Invariant

The **to-space invariant** guarantees mutators only access to-space copies:

```pseudo
bakerReadBarrier(ref):
    if inFromSpace(ref):
        // Ensure object is in to-space
        if isForwarded(ref):
            return getForwardingAddress(ref)
        else:
            return evacuate(ref)
    return ref

evacuate(object):
    // Allocate to-space copy
    size ← objectSize(object)
    newLocation ← toSpaceAlloc(size)

    // Copy data
    copyObjectData(object, newLocation, size)

    // Install forwarding pointer atomically
    if CompareAndSet(&object.forwardingWord, null, newLocation):
        return newLocation
    else:
        // Lost race - another thread evacuated
        rollbackAllocation(size)
        return object.forwardingWord
```

**Properties:**
- Mutators always see to-space copies
- Every pointer dereference requires barrier check
- Objects evacuated on demand

### Incremental Evacuation

Rather than evacuating entire objects on access, scan and evacuate incrementally:

```pseudo
incrementalReadBarrier(ref):
    if inFromSpace(ref):
        ref ← ensureForwarded(ref)
    return ref

ensureForwarded(object):
    header ← object.header
    if isForwarded(header):
        return getForwardingAddress(header)

    // Object not yet forwarded - evacuate
    return evacuateObject(object)
```

### Load Barrier Placement

The barrier must execute on every pointer load:

```pseudo
// Field load
loadField(object, offset):
    ref ← object[offset]
    return readBarrier(ref)

// Array element load
loadArrayElement(array, index):
    ref ← array[index]
    return readBarrier(ref)

// Stack/register access (compiler-generated)
// Barrier on entry to safe points
```

---

## 17.3 Brooks Forwarding Pointers

Each object contains a forwarding pointer (typically the first word). Objects initially forward to themselves:

```pseudo
// Object layout
Object:
    forwardingPointer: Address  // First word
    header: Header
    fields: ...

// Allocation sets self-forwarding
allocateObject(size):
    obj ← bump(size + FORWARD_PTR_SIZE)
    obj.forwardingPointer ← obj  // Self-forwarding
    return obj

// Read barrier is simple indirection
brooksReadBarrier(ref):
    return ref.forwardingPointer

// Moving an object
moveObject(old, new):
    copy(old, new, objectSize(old))
    new.forwardingPointer ← new   // Self-forward
    old.forwardingPointer ← new   // Redirect old to new
```

**Advantages:**
- Constant-time barrier (single indirection)
- No conditional branches in common case
- Old copies remain valid

**Disadvantages:**
- One word overhead per object
- Extra memory access per read

### Compressing Brooks Pointers

Reduce overhead by embedding forwarding in header when not moved:

```pseudo
compressedBrooksRead(ref):
    header ← ref.header
    if isForwarded(header):
        return extractForwardAddress(header)
    return ref  // Not moved
```

---

## 17.4 Write Barriers for Concurrent Copying

Mutator writes must go to the to-space copy to avoid lost updates.

### Write-Through to To-Space

All writes go to the to-space copy:

```pseudo
copyingWriteBarrier(object, offset, value):
    toSpaceObj ← readBarrier(object)
    toSpaceObj[offset] ← value
```

### Write Logging

Log writes for replay to to-space copy:

```pseudo
loggedWriteBarrier(object, offset, value):
    object[offset] ← value

    if inFromSpace(object):
        writeLog.push(WriteEntry(object, offset, value))

// Collector processes log
processWriteLog():
    for each entry in writeLog:
        toSpaceObj ← getForwardingAddress(entry.object)
        toSpaceObj[entry.offset] ← entry.value
```

### Combined Read-Write Barriers

```pseudo
readWriteBarrier(object, offset, value):
    // Ensure we have to-space reference
    toSpaceObj ← object.forwardingPointer

    // Write to to-space copy
    toSpaceObj[offset] ← value

    // Also update from-space if collector not done
    if inFromSpace(object) and object ≠ toSpaceObj:
        object[offset] ← value
```

---

## 17.5 Maintaining Pointer Equality

With two copies of each object, pointer comparison is problematic:

```pseudo
// Wrong: compares addresses directly
equals(a, b):
    return a = b

// Correct: compare canonical (to-space) addresses
safeEquals(a, b):
    return readBarrier(a) = readBarrier(b)
```

### Self-Healing

Update stale pointers when encountered:

```pseudo
selfHealingRead(source, offset):
    ref ← source[offset]
    if inFromSpace(ref):
        newRef ← readBarrier(ref)
        // Try to update source to avoid repeated forwarding
        CompareAndSet(&source[offset], ref, newRef)
        return newRef
    return ref
```

Self-healing amortizes barrier cost by fixing stale pointers.

---

## 17.6 The Sapphire Algorithm

A phased concurrent copying algorithm with precise barrier requirements per phase:

### Phase 1: Mark

Concurrent marking to identify live objects:

```pseudo
sapphireMarkPhase():
    gcPhase ← MARKING
    concurrentMark()  // Standard concurrent marking
    gcPhase ← MARKED
```

### Phase 2: Flip

Atomically switch the meaning of spaces:

```pseudo
sapphireFlip():
    // Brief STW to flip spaces
    stopAllMutators()
    swap(fromSpace, toSpace)
    gcPhase ← COPYING
    resumeAllMutators()
```

### Phase 3: Copy

Concurrent copying with read barriers:

```pseudo
sapphireCopyPhase():
    // Evacuate all live objects
    while not allEvacuated():
        object ← getNextLiveObject()
        evacuate(object)

    gcPhase ← DONE
```

### Phase Barriers

Different barriers for each phase:

```pseudo
sapphireReadBarrier(ref):
    switch gcPhase:
        case MARKING:
            // No barrier needed (objects don't move yet)
            return ref
        case COPYING:
            // Must ensure to-space copy
            return ensureForwarded(ref)
        case DONE:
            // All objects in to-space
            return ref

sapphireWriteBarrier(object, offset, value):
    switch gcPhase:
        case MARKING:
            // SATB barrier for marking
            satbBarrier(object, offset, value)
        case COPYING:
            // Write to to-space copy
            writeThrough(object, offset, value)
        case DONE:
            // Normal write
            object[offset] ← value
```

---

## 17.7 Concurrent Copying for Generational GC

### Young Generation: Usually STW

Young generation collections are typically stop-the-world because:
- Young gen is small → short pauses
- High allocation rate → frequent collections
- Read barrier overhead would hurt throughput

### Old Generation: Concurrent Options

Concurrent copying in old generation:

```pseudo
concurrentOldGenCopy():
    // Mark live objects (concurrent)
    concurrentMark()

    // Select regions for evacuation
    evacuationSet ← selectLowLivenessRegions()

    // Evacuate concurrently with read barriers
    for each region in evacuationSet:
        evacuateRegion(region)

    // Update references (may need STW)
    updateReferences()
```

### Card Table Interaction

Concurrent copying must handle inter-generational pointers:

```pseudo
generationalCopyingBarrier(object, offset, value):
    toSpaceObj ← ensureForwarded(object)

    // Write to to-space copy
    toSpaceObj[offset] ← value

    // Generational barrier
    if isOld(toSpaceObj) and isYoung(value):
        dirtyCard(toSpaceObj)
```

---

## 17.8 Termination and Correctness

### Termination Condition

Collection complete when:
1. All live objects evacuated
2. All references updated to to-space
3. Write log processed

```pseudo
checkTermination():
    // All live objects copied?
    if not allLiveObjectsEvacuated():
        return false

    // All references fixed?
    if pendingReferenceUpdates():
        return false

    // Write log empty?
    if not writeLog.empty():
        processWriteLog()
        return false

    return true
```

### Invariants

**To-space invariant:** Every pointer dereferenced by the mutator yields a to-space address.

**Forwarding completeness:** Every from-space object reachable at the start of copying eventually has a forwarding pointer.

**Write consistency:** Every write by the mutator is reflected in the to-space copy.

---

## 17.9 Memory Ordering

### Copy-Then-Forward

The copy must be visible before the forwarding pointer:

```pseudo
evacuateWithOrdering(object):
    newLocation ← allocate(objectSize(object))

    // Copy object data
    copyObjectData(object, newLocation)

    // Release fence: copy visible before forwarding
    releaseFence()

    // Install forwarding pointer
    if CompareAndSet(&object.forwardingWord, null, newLocation):
        return newLocation
    else:
        rollback(newLocation)
        return object.forwardingWord
```

### Read Barrier Ordering

```pseudo
readBarrierWithOrdering(ref):
    forwardingPtr ← ref.forwardingWord
    if forwardingPtr ≠ ref:
        // Acquire fence: see copy before accessing fields
        acquireFence()
        return forwardingPtr
    return ref
```

---

## 17.10 Implementation Considerations

### Barrier Elision

Compiler can elide barriers in certain cases:

```pseudo
// Back-to-back loads from same object
x ← obj.field1  // Barrier here
y ← obj.field2  // Can skip barrier (obj already forwarded)

// Loop over object fields
for i from 0 to n-1:
    // Only barrier on first iteration
    process(obj.fields[i])
```

### Large Object Handling

Large objects may use virtual memory tricks:

```pseudo
evacuateLargeObject(object):
    if objectSize(object) > LARGE_THRESHOLD:
        // Remap pages instead of copying
        newLocation ← reserveVirtualSpace(objectSize(object))
        remapPages(object, newLocation)
        installForwarding(object, newLocation)
    else:
        normalEvacuate(object)
```

### Treadmill for Large Objects

Non-copying collection within concurrent framework:

```pseudo
treadmillBarrier(ref):
    // No evacuation needed for treadmill objects
    // Just ensure marked
    if not isMarked(ref):
        mark(ref)
    return ref
```

---

## 17.11 Notable Systems

### Azul C4

Pauseless concurrent copying:
- Read barrier ("Loaded Value Barrier")
- Self-healing
- No stop-the-world phases for steady state

### Shenandoah

Concurrent copying for OpenJDK:
- Brooks-style forwarding
- Load and store barriers
- Concurrent evacuation and update

### ZGC

Concurrent copying with colored pointers:
- Metadata in pointer bits
- Load barrier only
- Region-based

---

## 17.12 Summary

Concurrent copying requires barriers to maintain consistency:

| Technique | Barrier Type | Trade-off |
|-----------|-------------|-----------|
| Baker's | Read (evacuate on access) | High barrier cost, simple model |
| Brooks | Read (indirection) | Per-object overhead, constant barrier |
| Sapphire | Phased read/write | Complex phases, lower overhead |
| Self-healing | Read + CAS write | Amortized cost, extra CAS |

Design considerations:
- Read barrier overhead is significant (every load)
- Write barriers ensure to-space gets updates
- Self-healing reduces repeated barrier cost
- Memory ordering crucial for correctness
- Large objects may need special handling

Concurrent copying achieves the lowest pause times but at the cost of steady-state throughput. It's most valuable when latency requirements are stringent.
