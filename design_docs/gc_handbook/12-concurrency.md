# 12. Concurrency Preliminaries

Concurrent and parallel garbage collection has become essential as multiprocessor hardware is now ubiquitous. This chapter covers the foundational concepts required for understanding parallel and concurrent collection: hardware memory models, synchronization primitives, progress guarantees, and the key distinction between parallel and concurrent collection.

---

## 12.1 Parallel vs Concurrent Collection

It is important to distinguish two related but different terms:

- **Parallel collection**: Multiple collector threads work simultaneously to complete garbage collection faster, but all mutator threads are stopped during collection (stop-the-world with multiple GC threads).

- **Concurrent collection**: Collector threads run at the same time as mutator threads, interleaving collection work with program execution to reduce pause times.

A collector may be both parallel and concurrent—using multiple collector threads that run concurrently with mutators. The key challenge for concurrent collectors is maintaining correctness as the mutator modifies the heap while the collector is examining it.

---

## 12.2 Hardware Foundations

### Processors and Threads

A **processor** is a hardware unit that executes instructions. A **thread** is a sequential program execution. Modern hardware includes:

- **Symmetric Multiprocessors (SMP)**: Multiple processors with equal access times to all memory
- **Chip Multiprocessors (CMP)**: Multiple cores on a single chip
- **NUMA**: Non-uniform memory access where some memory is "closer" to certain processors
- **SMT/Hyperthreading**: Multiple logical processors sharing execution resources

### Memory Hierarchy and Caches

Memory access is slow (hundreds of cycles), so processors use caches:

- **Cache line**: Unit of cache storage (typically 32-64 bytes)
- **Cache hit/miss**: Whether requested data is in cache
- **Write-through vs write-back**: When modified data is propagated to memory
- **Inclusive vs exclusive**: Whether higher-level caches contain copies of lower-level data

### Cache Coherence

Caches may hold different values for the same address. The **MESI protocol** maintains coherence:

- **Modified**: This cache has the only copy, which has been updated
- **Exclusive**: This cache has the only copy, matching memory
- **Shared**: Multiple caches may have copies, all matching memory
- **Invalid**: This cache does not hold a valid copy

```pseudo
// Cache coherence ensures:
// - Only one writer at a time for any line
// - All caches agree on values for shared lines
// - Reads see the most recent write

// False sharing: Different data on same cache line
// causes unnecessary coherence traffic
```

---

## 12.3 Memory Consistency Models

Hardware and compilers may reorder memory operations for performance. The **memory consistency model** defines what reorderings are allowed.

### Sequential Consistency

The strongest model—all operations appear to execute in some total order consistent with each thread's program order. Simple to reason about but expensive to implement.

### Relaxed Consistency

Most modern hardware allows certain reorderings:

| Reordering | Description |
|------------|-------------|
| R → R | Reads may be reordered with other reads |
| R → W | Reads may be reordered with later writes |
| W → W | Writes may be reordered with other writes |
| W → R | Writes may be reordered with later reads (most common) |

### Memory Fences

**Fences** (barriers) prevent certain reorderings:

```pseudo
// Full fence: No operation may cross the fence
fullFence():
    atomic
        // All prior operations complete before
        // any subsequent operation begins

// Acquire fence: Subsequent operations cannot move before
acquireFence():
    // Operations after cannot move up

// Release fence: Prior operations cannot move after
releaseFence():
    // Operations before cannot move down
```

---

## 12.4 Atomic Primitives

### Compare-and-Swap (CAS)

```pseudo
CompareAndSwap(address, expected, new):
    atomic
        current ← *address
        if current = expected:
            *address ← new
        return current

CompareAndSet(address, expected, new):
    atomic
        current ← *address
        if current = expected:
            *address ← new
            return true
        return false
```

**The ABA Problem**: CAS cannot detect if a value changed from A to B and back to A. Solutions include:
- Version counters
- Load-linked/store-conditional

### Load-Linked/Store-Conditional (LL/SC)

```pseudo
LoadLinked(address):
    atomic
        reservation ← address    // Per-processor
        reserved ← true
        return *address

StoreConditional(address, value):
    atomic
        if reserved and reservation = address:
            *address ← value
            return true
        return false

// Any write to the reserved address clears the reservation
// Solves ABA problem: detects ANY intervening write
```

### Atomic Arithmetic

```pseudo
FetchAndAdd(address, value):
    atomic
        old ← *address
        *address ← old + value
        return old

AtomicIncrement(address):
    atomic
        *address ← *address + 1

AtomicDecrement(address):
    atomic
        *address ← *address - 1
```

---

## 12.5 Progress Guarantees

Different guarantees about how threads make progress under contention:

### Blocking

A thread may be delayed indefinitely by another thread's delay. Locks are blocking.

### Lock-Free

At least one thread makes progress in a finite number of steps. Other threads may starve but the system as a whole progresses.

```pseudo
// Lock-free stack push
lockFreePush(stack, node):
    loop:
        oldTop ← stack.top
        node.next ← oldTop
        if CompareAndSet(&stack.top, oldTop, node):
            return
        // CAS failed - retry
```

### Wait-Free

Every thread makes progress in a finite number of steps regardless of other threads. No starvation possible.

```pseudo
// Wait-free consensus (simplified)
waitFreeConsensus(proposed):
    // Each thread proposes a value
    // First to write wins
    if CompareAndSet(&decision, null, proposed):
        return proposed
    else:
        return decision
```

### Obstruction-Free

A thread makes progress if it runs in isolation (no interference). May not progress under contention but simpler than lock-free.

---

## 12.6 Spin Locks

### Basic Test-and-Set Lock

```pseudo
testAndSetLock(lock):
    while TestAndSet(lock) = LOCKED:
        // Spin

testAndSetUnlock(lock):
    *lock ← UNLOCKED
```

**Problem**: Every spin iteration causes cache coherence traffic.

### Test-and-Test-and-Set Lock

```pseudo
testAndTestAndSetLock(lock):
    loop:
        // Spin on cached value (no bus traffic)
        while *lock = LOCKED:
            // Wait
        // Now try to acquire
        if TestAndSet(lock) = UNLOCKED:
            return
        // Failed - retry

testAndTestAndSetUnlock(lock):
    *lock ← UNLOCKED
```

### Ticket Locks

Fair ordering based on tickets:

```pseudo
ticketLock(lock):
    myTicket ← FetchAndAdd(&lock.ticket, 1)
    while lock.serving ≠ myTicket:
        // Wait for my turn

ticketUnlock(lock):
    lock.serving ← lock.serving + 1
```

### MCS Queue Locks

Scalable lock with per-thread waiting:

```pseudo
mcsLock(lock, myNode):
    myNode.next ← null
    myNode.locked ← true

    pred ← FetchAndStore(&lock.tail, myNode)
    if pred ≠ null:
        pred.next ← myNode
        while myNode.locked:
            // Spin on local variable (no bus traffic)

mcsUnlock(lock, myNode):
    if myNode.next = null:
        if CompareAndSet(&lock.tail, myNode, null):
            return
        // Someone is in process of linking
        while myNode.next = null:
            // Wait for link

    myNode.next.locked ← false
```

---

## 12.7 Work Sharing and Stealing

Parallel collectors need to distribute work among threads efficiently.

### Work Packets

Divide work into packets that threads can claim:

```pseudo
workPacketLoop(globalPool):
    while true:
        packet ← globalPool.take()
        if packet = null:
            if terminationDetected():
                return
            continue

        for each item in packet:
            process(item)
            if localBuffer.full():
                globalPool.put(localBuffer)
                localBuffer.clear()

    // Flush remaining work
    if not localBuffer.empty():
        globalPool.put(localBuffer)
```

### Work Stealing Deques

Each thread has a double-ended queue. Threads push/pop from one end; other threads steal from the other end:

```pseudo
workStealingDeque:
    // Owner operations (no synchronization needed)
    pushBottom(item):
        tasks[bottom] ← item
        bottom ← bottom + 1

    popBottom():
        bottom ← bottom - 1
        if bottom < top:
            bottom ← top  // Empty
            return null
        item ← tasks[bottom]
        if bottom > top:
            return item
        // Race with stealer
        if not CompareAndSet(&top, bottom, bottom + 1):
            item ← null  // Stealer won
        bottom ← bottom + 1
        return item

    // Thief operation (needs synchronization)
    steal():
        t ← top
        b ← bottom
        if t >= b:
            return null  // Empty
        item ← tasks[t]
        if CompareAndSet(&top, t, t + 1):
            return item
        return null  // Lost race
```

---

## 12.8 Termination Detection

Determining when all work is complete is non-trivial in parallel systems.

### Counter-Based Termination

```pseudo
// Global work counter
workCounter ← 0

addWork(amount):
    AtomicAdd(&workCounter, amount)

completeWork(amount):
    AtomicAdd(&workCounter, -amount)

isTerminated():
    return workCounter = 0
```

### Epoch-Based Termination

```pseudo
// Two-phase termination
terminationDetection():
    // Phase 1: Request termination
    terminationRequested ← true

    // Wait for all threads to acknowledge
    for each thread:
        while not thread.acknowledged:
            wait()

    // Phase 2: Check no new work appeared
    if workCounter = 0:
        return true

    terminationRequested ← false
    return false
```

### Dijkstra Token Ring

```pseudo
// Token passes around ring of threads
tokenTermination(threadId, numThreads):
    if threadId = 0:
        token ← WHITE
        passToken(token, 1)

    token ← receiveToken()

    if hasWork():
        token ← BLACK

    if threadId = numThreads - 1:
        if token = WHITE:
            // Termination detected
            broadcastTermination()
        else:
            // Retry with white token
            passToken(WHITE, 0)
    else:
        passToken(token, threadId + 1)
```

---

## 12.9 The Tricolor Abstraction

Concurrent marking uses three colors to track object state:

- **White**: Not yet visited (potentially garbage)
- **Grey**: Visited but children not yet scanned
- **Black**: Visited and all children scanned

### The Tricolor Invariant

**Strong tricolor invariant**: No black object points to a white object.

**Weak tricolor invariant**: If a black object points to a white object, there must be a path from a grey object to the white object.

Maintaining these invariants ensures the collector doesn't miss live objects.

```pseudo
// Basic tricolor marking
mark():
    // Initialize: all white
    for each object in heap:
        object.color ← WHITE

    // Grey roots
    for each root in Roots:
        root.color ← GREY
        greySet.add(root)

    // Process until no grey
    while not greySet.isEmpty():
        object ← greySet.remove()
        for each child in pointers(object):
            if child.color = WHITE:
                child.color ← GREY
                greySet.add(child)
        object.color ← BLACK

    // White objects are garbage
```

---

## 12.10 Write Barriers for Concurrent Marking

### Snapshot-at-the-Beginning (SATB)

Preserves the heap graph as it existed at the start of marking:

```pseudo
satbWriteBarrier(object, field, newValue):
    oldValue ← object[field]
    object[field] ← newValue

    if gcState = MARKING and isHeapPointer(oldValue):
        if not isMarked(oldValue):
            satbBuffer.push(oldValue)
```

SATB ensures that any object reachable at the start of marking remains reachable to the collector, even if the mutator removes the last reference.

### Incremental Update (Dijkstra)

Records new references from black objects:

```pseudo
incrementalUpdateBarrier(object, field, newValue):
    object[field] ← newValue

    if gcState = MARKING:
        if isBlack(object) and isWhite(newValue):
            shade(newValue)  // Make grey
```

### Comparison

| Aspect | SATB | Incremental Update |
|--------|------|-------------------|
| **Floating garbage** | None (preserves start state) | May float (new allocations) |
| **Re-marking** | Not needed | May need re-marking |
| **Barrier cost** | Logs old value | Checks colors |
| **Termination** | Clean (drain SATB buffers) | May need multiple passes |

---

## 12.11 Parallel Marking

Stop-the-world with multiple marker threads:

```pseudo
parallelMark():
    // Initialize work
    for each root in Roots:
        workPackets.add(root)

    // Parallel processing
    parallel for each thread:
        while packet ← workPackets.steal():
            for each object in packet:
                if tryMark(object):
                    for each child in pointers(object):
                        localWork.add(child)

            if localWork.full():
                workPackets.put(localWork)
                localWork ← new WorkPacket()

        // Termination synchronization
        barrier()

tryMark(object):
    loop:
        mark ← object.markBit
        if mark = MARKED:
            return false
        if CompareAndSet(&object.markBit, mark, MARKED):
            return true
```

---

## 12.12 Parallel Copying

Multiple threads evacuate objects in parallel:

```pseudo
parallelCopy():
    // Each thread has its own allocation buffer (PLAB)
    parallel for each thread:
        while object ← greySet.steal():
            for each field in pointers(object):
                child ← object[field]
                if inFromSpace(child):
                    newLocation ← evacuate(child, myPLAB)
                    object[field] ← newLocation

evacuate(object, plab):
    // Try to install forwarding pointer
    loop:
        header ← object.header
        if isForwarded(header):
            return getForwardingAddress(header)

        size ← objectSize(object)
        newLocation ← plab.allocate(size)
        copyObject(object, newLocation, size)

        if CompareAndSet(&object.header, header, makeForwarding(newLocation)):
            return newLocation

        // Lost race - another thread copied it
        plab.rollback(size)
```

---

## 12.13 NUMA Considerations

For NUMA systems, locality matters:

- Allocate objects in memory near the allocating processor
- Keep thread-local GC structures in local memory
- Avoid cross-node work stealing when possible
- Consider NUMA-aware region placement

```pseudo
numaAwareAllocate(size, thread):
    node ← thread.numaNode
    if localHeap[node].hasSpace(size):
        return localHeap[node].allocate(size)
    else:
        return fallbackAllocate(size)
```

---

## 12.14 Summary

Concurrent and parallel collection builds on these foundations:

| Concept | Purpose |
|---------|---------|
| **Memory models** | Define legal operation orderings |
| **Atomic primitives** | Enable lock-free algorithms |
| **Progress guarantees** | Ensure forward progress |
| **Spin locks** | Mutual exclusion with various trade-offs |
| **Work stealing** | Load balancing for parallel GC |
| **Termination detection** | Know when collection is complete |
| **Tricolor invariant** | Correctness for concurrent marking |
| **Write barriers** | Maintain invariants during concurrent mutation |

The next chapters explore specific parallel and concurrent collector algorithms: parallel GC (Chapter 14), concurrent barriers (Chapter 15), concurrent mark-sweep (Chapter 16), and concurrent copying (Chapter 17).
