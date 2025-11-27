# 13. Atomics and Synchronization Primitives

This chapter provides the synchronization tools used by concurrent and parallel garbage collectors. These primitives—spin locks, compare-and-swap, load-linked/store-conditional, and lock-free data structures—underpin barriers, concurrent marking, work distribution, and the safe installation of forwarding pointers during parallel compaction.

---

## 13.1 Fundamental Atomic Operations

### Test-and-Set (TAS)

The simplest atomic primitive. It atomically reads a memory location, returns the old value, and sets it to a specified value (typically 1 for "locked"):

```pseudo
TestAndSet(address):
    atomic
        old ← *address
        if old = 0:
            *address ← 1
        return old
```

**Properties:**
- Simple and widely available
- Consensus number of 2 (can solve consensus for 2 threads)
- Causes cache line ping-pong under contention

### Compare-and-Swap (CAS)

The workhorse of lock-free programming. Atomically compares a memory location to an expected value and, if equal, replaces it with a new value:

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

**Properties:**
- Consensus number of infinity (universal)
- Can implement any lock-free data structure
- Subject to the ABA problem

### Fetch-and-Add

Atomically reads a value, adds to it, and returns the original:

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

**Uses in GC:**
- Bump pointer allocation under contention
- Work counters for termination detection
- Reference counting updates

### Load-Linked/Store-Conditional (LL/SC)

A pair of operations that solve the ABA problem by detecting any intervening write:

```pseudo
LoadLinked(address):
    atomic
        // Mark this address as "linked" for this processor
        reservation ← address
        reserved ← true
        return *address

StoreConditional(address, value):
    atomic
        // Succeeds only if no write occurred since LoadLinked
        if reserved and reservation = address:
            *address ← value
            reserved ← false
            return true
        return false
```

**Key difference from CAS:** LL/SC detects ANY intervening write, not just whether the value changed back. This solves ABA without version numbers.

**Caveats:**
- Less portable than CAS
- Spurious failures possible (interrupts, context switches)
- Hardware may have restrictions on operations between LL and SC

---

## 13.2 Spin Locks

### Basic Spin Lock

The simplest mutual exclusion mechanism:

```pseudo
spinLock(lock):
    while TestAndSet(lock) = 1:
        // Spin until acquired

spinUnlock(lock):
    *lock ← 0
```

**Problem:** Every spin iteration performs an atomic operation, causing cache line invalidations and bus traffic. Under contention, this severely degrades performance.

### Test-and-Test-and-Set (TTAS)

Reduces bus traffic by spinning on a cached copy:

```pseudo
ttasLock(lock):
    while true:
        // Spin on cached value (no bus traffic)
        while *lock = 1:
            pause()  // CPU hint for spin wait

        // Value appears free - try to acquire
        if TestAndSet(lock) = 0:
            return
        // Failed - someone else got it, retry

ttasUnlock(lock):
    *lock ← 0
```

The key insight: reading a shared variable doesn't cause coherence traffic if the line is already in the cache. Only the atomic operation requires exclusive access.

### Exponential Backoff

Reduces contention by waiting longer after failures:

```pseudo
ttasBackoffLock(lock):
    delay ← MIN_DELAY
    while true:
        while *lock = 1:
            pause()

        if TestAndSet(lock) = 0:
            return

        // Failed - back off
        sleep(random(0, delay))
        delay ← min(delay * 2, MAX_DELAY)
```

### Ticket Locks

Provides fairness through FIFO ordering:

```pseudo
ticketLock(lock):
    myTicket ← FetchAndAdd(&lock.next, 1)
    while lock.serving ≠ myTicket:
        pause()

ticketUnlock(lock):
    lock.serving ← lock.serving + 1
```

**Properties:**
- FIFO fairness
- Each waiter spins on a different value
- Still causes cache invalidation storm on unlock

### MCS Queue Lock

Scalable lock where each thread spins on its own local variable:

```pseudo
MCSNode:
    next: MCSNode
    locked: boolean

mcsLock(lock, myNode):
    myNode.next ← null
    myNode.locked ← true

    predecessor ← FetchAndStore(&lock.tail, myNode)
    if predecessor ≠ null:
        // Link into queue
        predecessor.next ← myNode
        // Spin on LOCAL variable (no cache traffic)
        while myNode.locked:
            pause()

mcsUnlock(lock, myNode):
    if myNode.next = null:
        // Might be the only one
        if CompareAndSet(&lock.tail, myNode, null):
            return
        // Someone is linking in - wait for them
        while myNode.next = null:
            pause()

    // Pass the lock to successor
    myNode.next.locked ← false
```

**Advantages:**
- O(1) space per lock
- Each thread spins on local memory
- FIFO fairness
- No cache invalidation storm

---

## 13.3 The ABA Problem

### The Problem

CAS can be fooled when a value changes from A to B and back to A:

```
Thread 1: Read A
Thread 2: Change A → B → A
Thread 1: CAS succeeds (still sees A)
```

This is problematic when the "A" after Thread 2's changes has a different meaning than the original "A".

### Example in GC

During copying collection with forwarding pointers:

```
Time 1: Object at address X has header H
Time 2: First GC copies object, installs forwarding pointer
Time 3: Second GC completes, new object at X has header H (by coincidence)
Time 4: CAS(X.header, H, forward) succeeds incorrectly
```

### Solutions

**Version counters:** Pair the value with a monotonically increasing counter:

```pseudo
ABAFreeUpdate(address, expectedValue, newValue):
    loop:
        current ← *address
        if current.value ≠ expectedValue:
            return false

        newPair ← (newValue, current.version + 1)
        if CompareAndSetWide(address, current, newPair):
            return true
```

**Use LL/SC:** The hardware detects any intervening write:

```pseudo
ABAFreeLLSC(address, expectedValue, newValue):
    loop:
        current ← LoadLinked(address)
        if current ≠ expectedValue:
            return false
        if StoreConditional(address, newValue):
            return true
```

**Hazard pointers:** Protect values being accessed from reclamation.

**Epoch-based reclamation:** Defer reclamation until all threads have advanced past dangerous epochs.

---

## 13.4 CAS Patterns in GC

### Installing Forwarding Pointers

When multiple threads try to copy the same object:

```pseudo
evacuate(object):
    // Optimistic copy
    newLocation ← allocateFromPLAB(objectSize(object))
    copyData(object, newLocation)

    // Try to install forwarding pointer
    oldHeader ← object.header
    if isForwarded(oldHeader):
        // Another thread already did it
        freePLAB(newLocation)
        return getForwardAddress(oldHeader)

    newHeader ← makeForwardingPointer(newLocation)
    if CompareAndSet(&object.header, oldHeader, newHeader):
        return newLocation
    else:
        // Lost race - use winner's copy
        freePLAB(newLocation)
        return getForwardAddress(object.header)
```

### Atomic Mark Bit

Setting mark bits during parallel marking:

```pseudo
tryMark(object):
    loop:
        header ← object.header
        if isMarked(header):
            return false  // Already marked

        newHeader ← setMarkBit(header)
        if CompareAndSet(&object.header, header, newHeader):
            return true
        // Header changed - retry
```

### Lock-Free Reference Count Update

```pseudo
incrementRefCount(object):
    loop:
        count ← object.refCount
        if CompareAndSet(&object.refCount, count, count + 1):
            return

decrementRefCount(object):
    loop:
        count ← object.refCount
        if CompareAndSet(&object.refCount, count, count - 1):
            if count - 1 = 0:
                free(object)
            return
```

---

## 13.5 Lock-Free Data Structures

### Single-Producer/Single-Consumer Queue

The simplest lock-free queue:

```pseudo
SPSCQueue:
    buffer: array[SIZE]
    head: integer  // Written by consumer
    tail: integer  // Written by producer

enqueue(item):
    t ← tail
    if (t + 1) mod SIZE = head:
        return FULL
    buffer[t] ← item
    // Memory barrier: item must be visible before tail update
    releaseFence()
    tail ← (t + 1) mod SIZE
    return OK

dequeue():
    h ← head
    if h = tail:
        return EMPTY
    // Memory barrier: see tail update before reading item
    acquireFence()
    item ← buffer[h]
    head ← (h + 1) mod SIZE
    return item
```

### Michael-Scott Queue

Lock-free multi-producer/multi-consumer queue:

```pseudo
MSQueue:
    head: Node
    tail: Node

enqueue(value):
    node ← new Node(value, null)
    loop:
        t ← tail
        next ← t.next
        if t = tail:  // Still consistent
            if next = null:
                // Try to link at end
                if CompareAndSet(&t.next, null, node):
                    // Try to advance tail (may fail, that's OK)
                    CompareAndSet(&tail, t, node)
                    return
            else:
                // Tail is behind - help advance it
                CompareAndSet(&tail, t, next)

dequeue():
    loop:
        h ← head
        t ← tail
        next ← h.next
        if h = head:  // Still consistent
            if h = t:
                if next = null:
                    return EMPTY
                // Tail behind - advance it
                CompareAndSet(&tail, t, next)
            else:
                value ← next.value
                if CompareAndSet(&head, h, next):
                    // Don't free h yet - ABA hazard
                    return value
```

### Chase-Lev Work-Stealing Deque

Used for parallel GC work distribution:

```pseudo
WorkStealingDeque:
    tasks: array
    top: integer    // Thieves CAS here
    bottom: integer // Owner accesses here

// Owner operations - fast path without CAS
ownerPush(task):
    b ← bottom
    tasks[b] ← task
    // Barrier: task visible before bottom update
    releaseFence()
    bottom ← b + 1

ownerPop():
    b ← bottom - 1
    bottom ← b
    // Barrier: bottom visible before reading top
    fullFence()
    t ← top
    if t > b:
        bottom ← t  // Empty
        return null
    task ← tasks[b]
    if t < b:
        return task  // No race
    // Race with thief - CAS to resolve
    if CompareAndSet(&top, t, t + 1):
        return task
    else:
        bottom ← t + 1  // Thief won
        return null

// Thief operation - needs CAS
steal():
    t ← top
    // Barrier: see top before bottom
    acquireFence()
    b ← bottom
    if t >= b:
        return null  // Empty
    task ← tasks[t]
    if CompareAndSet(&top, t, t + 1):
        return task
    return null  // Lost race
```

---

## 13.6 Termination Detection

### Global Work Counter

```pseudo
workCounter ← 0

addWork(n):
    AtomicAdd(&workCounter, n)

completeWork(n):
    AtomicAdd(&workCounter, -n)

isTerminated():
    return workCounter = 0
```

**Problem:** Race between adding work and checking termination.

### Two-Phase Termination

```pseudo
terminationProtocol():
    // Phase 1: All threads signal idle
    allIdle ← true
    for each thread:
        if not thread.idle:
            allIdle ← false
            break

    if not allIdle:
        return false

    // Phase 2: Verify no new work
    memoryBarrier()
    return workCounter = 0
```

### Dijkstra's Token Ring

```pseudo
tokenRingTermination():
    // Thread 0 initiates with WHITE token
    if myId = 0:
        token ← WHITE
        send(token, nextThread)

    token ← receive()

    // If I did work since last check, color token BLACK
    if didWorkSinceLastToken:
        token ← BLACK
        didWorkSinceLastToken ← false

    if myId = lastThread:
        if token = WHITE:
            // Termination confirmed
            broadcast(TERMINATE)
        else:
            // Retry
            send(WHITE, thread0)
    else:
        send(token, nextThread)
```

---

## 13.7 Memory Ordering for GC

### Publication Pattern

When making an object visible to other threads:

```pseudo
publishObject(object):
    // Initialize all fields first
    object.field1 ← value1
    object.field2 ← value2

    // Release fence: all writes above visible before publication
    releaseFence()

    sharedPointer ← object
```

### Consumption Pattern

When accessing a shared object:

```pseudo
consumeObject():
    ptr ← sharedPointer
    if ptr = null:
        return null

    // Acquire fence: see publication writes
    acquireFence()

    // Safe to access ptr.field1, ptr.field2
    return ptr
```

### GC State Transitions

```pseudo
// Collector signals marking phase
startMarking():
    gcState ← MARKING
    // All threads must see MARKING before we begin
    fullFence()
    beginMark()

// Mutator checks state
writeBarrier(obj, field, value):
    obj[field] ← value
    state ← gcState
    if state = MARKING:
        // Full fence not needed - state was set with release
        recordForMarking(obj, field, value)
```

---

## 13.8 Summary

Synchronization primitives form the foundation of parallel and concurrent GC:

| Primitive | Use in GC | Considerations |
|-----------|-----------|----------------|
| **TAS/TTAS** | Simple locks | High contention = cache thrashing |
| **CAS** | Forwarding pointers, mark bits | Watch for ABA problem |
| **LL/SC** | ABA-free updates | Less portable |
| **FetchAndAdd** | Counters, allocation | Unconditional success |
| **MCS Lock** | High-contention locks | Scalable, fair |
| **Work-stealing** | Parallel marking/copying | Load balancing |

Key patterns:
- Use CAS for installing forwarding pointers
- Use work-stealing deques for load balancing
- Use version counters or LL/SC to avoid ABA
- Use appropriate memory ordering for publication/consumption
- Use two-phase or token-based termination detection
