# 19. Work-Based and Real-Time Garbage Collection

Real-time garbage collection extends automatic memory management to applications with strict timing constraints. Unlike conventional collectors that prioritize throughput, real-time collectors must bound their impact on the mutator, ensuring that deadlines are met predictably. This chapter covers scheduling strategies for real-time collection, including work-based, slack-based, and time-based approaches, as well as techniques for controlling fragmentation in bounded-latency systems.

---

## 19.1 Real-Time Systems and Requirements

Real-time systems impose operational deadlines on tasks. A task that fails to meet its deadline may degrade service quality (soft real-time) or cause system failure (hard real-time).

### Characterizing Real-Time Constraints

```pseudo
RealTimeTask:
    deadline: Time           // Maximum response time
    period: Time             // Interval between activations
    wcet: Time               // Worst-case execution time

hardRealTime(task):
    // Every deadline must be met - failure is unacceptable
    return task always completes within task.deadline

softRealTime(task, failureRate):
    // Occasional missed deadlines tolerable
    return missedDeadlines / totalDeadlines < failureRate
```

### Why Conventional GC Fails for Real-Time

Stop-the-world collectors have pause times proportional to heap size. Even concurrent collectors have unpredictable pauses due to:

1. **Lock contention**: Barriers may require synchronization
2. **Phase transitions**: Flipping spaces, root scanning
3. **Large objects**: Arrays cause variable-length work
4. **Scheduling interference**: GC threads compete with mutators

The goal is to characterize and bound GC's impact so that schedulability analysis can incorporate it.

---

## 19.2 Scheduling Strategies

### Work-Based Scheduling

Collector work is taxed on mutator operations (typically allocation):

```pseudo
// Tax allocation with proportional GC work
allocateWithTax(size):
    obj ← bumpAllocate(size)

    // Perform GC work proportional to allocation
    gcWork ← size * GC_RATIO
    while gcWork > 0 and hasGreyObjects():
        object ← greyQueue.pop()
        scanObject(object)
        gcWork ← gcWork - objectSize(object)

    return obj
```

**Properties:**
- GC progress tied to allocation rate
- Collector never falls behind
- Variable pause times depending on phase

### Slack-Based Scheduling

Collector runs only during slack time when no real-time tasks execute:

```pseudo
// High-priority tasks never taxed
allocateHighPriority(size):
    return bumpAllocate(size)  // No GC work

// Low-priority tasks taxed to maintain progress
allocateLowPriority(size):
    while behindSchedule():
        yield()  // Let collector catch up
    return bumpAllocate(size)

// Collector runs at low priority
collectorThread():
    while true:
        waitForSlack()
        performCollectorIncrement()
```

**Properties:**
- High-priority tasks unaffected
- Works well with periodic tasks
- Degrades under overload (no slack available)

### Time-Based Scheduling

Fixed proportion of time reserved for collector:

```pseudo
QUANTUM_SIZE = 500µs    // 500 microseconds
MMU_TARGET = 0.70       // 70% minimum mutator utilization

timeBasedScheduler():
    while true:
        // Mutator quantum
        allowMutatorsFor(QUANTUM_SIZE * MMU_TARGET)

        // Collector quantum
        if gcInProgress():
            suspendMutators()
            collectFor(QUANTUM_SIZE * (1 - MMU_TARGET))
            resumeMutators()
```

**Properties:**
- Predictable utilization regardless of allocation rate
- May waste time if collector finishes early
- Space consumption varies with allocation bursts

---

## 19.3 Work-Based Copying: Blelloch and Cheng

Blelloch and Cheng developed a parallel, concurrent replicating collector with provable bounds on space and time.

### Machine and Application Model

The algorithm assumes:
- Shared-memory multiprocessor with atomic `TestAndSet` and `FetchAndAdd`
- Sequential consistency (practical implementations need memory fences)
- Fixed-size allocation quanta

### The Replication Invariant

During collection, every live object has both a primary copy and a replica. Mutators must update both copies:

```pseudo
Object:
    forwardingAddress: Address  // Points to replica when grey/black
    copyCount: int              // For replica: fields remaining to copy

makeGrey(primary):
    // Race to create replica
    if TestAndSet(&primary.forwardingAddress) ≠ 0:
        // Lost race - wait for winner to set forwarding
        while primary.forwardingAddress = 1:
            spinWait()
    else:
        // Won race - allocate replica
        replica ← allocate(length(primary))
        replica.copyCount ← length(primary)
        primary.forwardingAddress ← replica
        localStack.push(primary)

    return primary.forwardingAddress
```

### Incremental Copying

Copy one slot at a time to bound work per operation:

```pseudo
copyOneSlot(primary):
    replica ← primary.forwardingAddress
    i ← replica.copyCount - 1
    replica.copyCount ← -(i + 1)  // Lock slot during copy

    value ← primary[i]
    if isPointer(primary, i):
        value ← makeGrey(value)   // Grey children
    replica[i] ← value

    replica.copyCount ← i         // Unlock with decremented count

    if i > 0:
        localStack.push(primary)  // More work remains
```

### Mutator Operations

```pseudo
// Allocate primary and replica together
New(n):
    primary ← allocate(n)
    replica ← allocate(n)
    primary.forwardingAddress ← replica
    replica.copyCount ← 0         // No copying needed
    lastAllocated ← primary
    lastLength ← n
    lastCount ← 0
    return primary

// Initialize slots in both copies
InitSlot(value):
    lastAllocated[lastCount] ← value
    if isPointer(lastAllocated, lastCount):
        value ← makeGrey(value)
    lastAllocated.forwardingAddress[lastCount] ← value
    lastCount ← lastCount + 1
    collect(k)  // Tax initialization

// Write to both copies
atomic Write(primary, i, value):
    if isPointer(primary, i):
        makeGrey(primary[i])      // SATB barrier
    primary[i] ← value

    if primary.forwardingAddress ≠ 0:
        // Wait for replica to exist
        while primary.forwardingAddress = 1:
            spinWait()
        replica ← primary.forwardingAddress

        // Wait if slot being copied
        while replica.copyCount = -(i + 1):
            spinWait()

        if isPointer(primary, i):
            value ← makeGrey(value)
        replica[i] ← value

    collect(k)  // Tax writes
```

### Space and Time Bounds

The algorithm guarantees:
- **Space**: At most `2(R(1 + 2/k) + N + 5PD)` words, where R is reachable space, N is object count, D is maximum depth, P is processors, k is work ratio
- **Time**: Mutators stopped for at most O(k) instructions

---

## 19.4 Slack-Based Collection: Henriksson

Henriksson's collector runs entirely in slack time, using lazy evacuation to minimize high-priority task overhead.

### Heap Organization

```pseudo
// Two semispaces with Cheney-style copying
Heap:
    fromBot, fromTop: Address   // Fromspace bounds
    toBot, toTop: Address       // Tospace bounds
    bottom: Address             // Evacuated objects frontier
    top: Address                // New allocations frontier
    scan: Address               // Scanning progress
```

### Lazy Evacuation

Instead of copying immediately, schedule copying for later:

```pseudo
forward(fromRef):
    toRef ← forwardingAddress(fromRef)

    if toRef = fromRef:  // Not yet evacuated
        toRef ← toAddress(fromRef)
        if toRef = null:  // Not scheduled
            toRef ← schedule(fromRef)

    return toRef

schedule(fromRef):
    // Reserve space but don't copy yet
    toRef ← bottom
    bottom ← bottom + size(fromRef)

    if bottom > top:
        error "Out of memory"

    toAddress(fromRef) ← toRef
    // toRef is empty shell - forwarding points back to original
    forwardingAddress(toRef) ← fromRef
    return toRef
```

### Deferred Copying

The collector copies contents when it scans the reserved shell:

```pseudo
scanObject(toRef):
    fromRef ← forwardingAddress(toRef)

    // Now actually copy the data
    move(fromRef, toRef)

    // Process children
    for each field in Pointers(toRef):
        process(field)

    // Update forwarding for mutators
    forwardingAddress(fromRef) ← toRef

    return toRef + size(toRef)
```

### Brooks Indirection Barrier

All accesses go through the forwarding pointer:

```pseudo
Read(src, i):
    src ← forwardingAddress(src)  // One indirection
    return src[i]

Write(src, i, ref):
    src ← forwardingAddress(src)
    if ref in fromspace:
        ref ← forward(ref)        // Dijkstra barrier
    src[i] ← ref
```

### GC Ratio

To ensure collection completes before space exhaustion:

```pseudo
GCR_min = W_max / F_min

// W_max = worst-case work to evacuate fromspace
// F_min = minimum free space needed after flip

behind():
    GCR_current ← workDone / allocated
    return GCR_current < GCR_min
```

---

## 19.5 Time-Based Collection: Metronome

Metronome guarantees minimum mutator utilization (MMU) through precise time scheduling.

### Utilization Model

```pseudo
// Over any window of size Δt, mutator gets at least μ(Δt) fraction
μ(Δt) = floor(Δt / (Qt + Ct)) * Qt + x
        ────────────────────────────────
                    Δt

// Where:
// Qt = mutator quantum
// Ct = collector quantum
// x = partial mutator quantum remainder

// Asymptotically: lim μ(Δt) = Qt / (Qt + Ct)
```

### Alarm Thread Scheduling

```pseudo
alarmThread():
    while true:
        sleepFor(QUANTUM_SIZE)

        if gcInProgress() and needsCollectorQuanta():
            initiateMutatorSuspension()
            wakeCollectorThread()

collectorThread():
    while gcInProgress():
        waitForAlarm()
        completeMutatorSuspension()

        // Perform bounded collector work
        deadline ← currentTime() + COLLECTOR_QUANTUM
        while currentTime() < deadline:
            if not hasWork():
                break
            performIncrementalWork()

        resumeMutators()
```

### Arraylets for Predictable Allocation

Large arrays split into fixed-size chunks to avoid fragmentation:

```pseudo
ARRAYLET_SIZE = 2KB

allocateArray(length):
    if length * elementSize < ARRAYLET_SIZE:
        return allocateContiguous(length)

    // Allocate spine + arraylets
    numArraylets ← ceiling(length * elementSize / ARRAYLET_SIZE)
    spine ← allocateSpine(numArraylets)

    for i from 0 to numArraylets - 1:
        spine[i] ← allocateArraylet()

    return ArrayHeader(spine, length)

arrayAccess(array, index):
    arrayletIndex ← index / ELEMENTS_PER_ARRAYLET
    offset ← index mod ELEMENTS_PER_ARRAYLET
    return array.spine[arrayletIndex][offset]
```

---

## 19.6 Combining Approaches: Tax-and-Spend

Tax-and-Spend combines work-based taxation with slack-based credits.

### The Economic Model

```pseudo
// Collector threads accumulate credits during slack
collectorThread():
    while true:
        // Run at low priority during slack
        quantum ← performCollectorQuantum()
        creditBank.deposit(quantum.work)

// Mutator threads pay tax, can spend credits
mutatorOperation():
    taxDue ← calculateTax()

    // Try to withdraw credits
    creditAvailable ← creditBank.withdraw(taxDue)
    taxRemaining ← taxDue - creditAvailable

    if taxRemaining > 0:
        // Must perform collector work
        performCollectorWork(taxRemaining)
```

### Per-Thread Utilization

Different threads can have different MMU targets:

```pseudo
ThreadConfig:
    targetMMU: float        // e.g., 0.90 for high-priority
    quantumSize: Time       // Smaller = more responsive

taxThread(thread, work):
    allowedGCTime ← work.time * (1 - thread.targetMMU)

    if thread.gcTimeThisWindow < allowedGCTime:
        performCollectorWork(min(remaining, thread.quantumSize))
        thread.gcTimeThisWindow += workTime
```

### Ragged Epochs for Consensus

Global agreement without stopping all threads:

```pseudo
shared globalEpoch: int
perThread localEpoch: int

// Thread updates at safe points
updateEpoch():
    memoryFence()
    localEpoch ← globalEpoch

// Wait for all threads to reach epoch
waitForEpoch(targetEpoch):
    while true:
        confirmed ← min(localEpoch for all threads)
        if confirmed >= targetEpoch:
            return
        yield()
```

---

## 19.7 Controlling Fragmentation

Real-time collectors must bound fragmentation to ensure space guarantees.

### Incremental Compaction (Metronome)

```pseudo
defragmentSizeClass(sizeClass, targetPages):
    // Sort pages by density
    pages ← sizeClass.pages
    sort(pages, byLiveObjects, descending)

    allocPage ← firstNonFullPage(pages)
    evacuatePage ← lastPage(pages)
    pagesEvacuated ← 0

    while pagesEvacuated < targetPages:
        if allocPage = evacuatePage:
            break

        for each liveObject in evacuatePage:
            dest ← allocPage.allocate(objectSize)
            if dest = null:
                allocPage ← nextPage(allocPage)
                dest ← allocPage.allocate(objectSize)

            copyObject(liveObject, dest)
            installForwarding(liveObject, dest)

        evacuatePage ← previousPage(evacuatePage)
        pagesEvacuated ← pagesEvacuated + 1
```

### Staccato: Wait-Free Compaction

Uses COPYING bit and ragged synchronization for lock-free moves:

```pseudo
copyObjects(candidates):
    // Phase 1: Mark as copying
    for each p in candidates:
        CompareAndSet(&p.forwarding, p, p | COPYING)

    waitForRaggedSync()  // Mutators see COPYING bit
    readFence()          // Collector sees mutator updates

    // Phase 2: Copy contents
    replicas ← []
    for each p in candidates:
        r ← allocate(size(p))
        copy(p, r)
        r.forwarding ← r
        replicas.add(r)

    writeFence()         // Push copies to mutators
    waitForRaggedSync()  // Mutators can see copies

    // Phase 3: Commit or abort
    aborted ← []
    for each (p, r) in zip(candidates, replicas):
        if not CompareAndSet(&p.forwarding, p | COPYING, r):
            // Mutator aborted our copy
            free(r)
            aborted.add(p)

    return aborted

// Mutator access with abort capability
Access(p):
    r ← p.forwarding
    if (r & COPYING) = 0:
        return r  // Normal access

    // Try to abort the copy
    if CompareAndSet(&p.forwarding, r, p):
        return p  // Abort succeeded

    // Collector committed or another aborted
    return p.forwarding & ~COPYING
```

### Schism: Fragmented Allocation

Eliminate external fragmentation by allocating in fixed-size fragments:

```pseudo
FRAGMENT_SIZE = 128 bytes

// Objects as linked list of oblets
allocateObject(size):
    numFragments ← ceiling(size / FRAGMENT_SIZE)
    sentinel ← allocateFragment()
    sentinel.type ← objectType

    current ← sentinel
    for i from 1 to numFragments - 1:
        next ← allocateFragment()
        current.nextFragment ← next
        current ← next

    return sentinel

// Arrays with spine pointing to arraylets
allocateArray(length, elementSize):
    totalSize ← length * elementSize
    numArraylets ← ceiling(totalSize / FRAGMENT_SIZE)

    sentinel ← allocateFragment()
    sentinel.type ← arrayType
    sentinel.length ← length

    if numArraylets ≤ INLINE_SPINE_SIZE:
        // Inline spine in sentinel
        sentinel.spine ← sentinel.inlineSpine
    else:
        // Separate spine (may need compaction)
        sentinel.spine ← allocateSpine(numArraylets)

    for i from 0 to numArraylets - 1:
        sentinel.spine[i] ← allocateFragment()

    return sentinel
```

---

## 19.8 Summary

Real-time garbage collection trades throughput for predictability:

| Approach | Scheduling | Strengths | Weaknesses |
|----------|------------|-----------|------------|
| **Work-based** | Tax per allocation | Never falls behind | Variable pause times |
| **Slack-based** | Low-priority slack | No high-priority impact | Fails under overload |
| **Time-based** | Fixed quanta | Predictable MMU | Space varies with allocation |
| **Tax-and-Spend** | Hybrid with credits | Best of both | Implementation complexity |

Key techniques for bounded latency:
- **Incremental copying**: Copy one slot at a time (Blelloch/Cheng)
- **Lazy evacuation**: Schedule copy, defer actual work (Henriksson)
- **Arraylets/oblets**: Bound allocation unit size (Metronome, Schism)
- **Wait-free barriers**: CAS-based abort mechanism (Staccato, Chicken)
- **Ragged synchronization**: Global consensus without global stop

Design considerations:
- Worst-case execution time analysis requires tight bounds
- Memory ordering critical on modern multiprocessors
- Fragmentation must be controlled for space guarantees
- Per-thread utilization allows priority differentiation
- Formal analysis needed for hard real-time certification

