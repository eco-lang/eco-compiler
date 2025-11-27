# 11. Run-time Interface

The heart of an automatic memory management system is the collector and allocator, their algorithms and data structures, but these are of little use without suitable means to access them from a program. Furthermore, some algorithms impose requirements on the programming language implementation—for example, to provide certain information or to enforce particular invariants. The interfaces between the collector (and allocator) and the rest of the system are the focus of this chapter.

---

## 11.1 Interface to Allocation

From the point of view of a programming language, a request for a new object returns an object that is not only allocated but also initialized to whatever extent the language and its implementation require. We break allocation and initialization into three steps:

1. **Allocate** a cell of the proper size and alignment
2. **System initialization**: Initialize fields that must be properly set before the object is usable (dispatch vector, header fields, hash code, length)
3. **Secondary initialization**: Set or update fields after the object reference has "escaped" from the allocation subsystem

Different languages span this range:
- **C**: Only Step 1; programmer does all initialization
- **Java**: Steps 1 and 2 provide a type-safe but "blank" object; Step 3 happens in constructors
- **Haskell**: Everything happens in Steps 1 and 2; Step 3 is disallowed

### Allocation Interface Parameters

Arguments to allocation may include:
- **Size**: In bytes, words, or other granule size
- **Alignment constraint**: Power of two, possibly with offset
- **Kind of object**: Array vs non-array, pointer-free vs pointer-containing
- **Specific type**: For header initialization

### Post-Conditions

The allocator may guarantee varying levels of initialization:
- Cell has requested size and alignment only
- Cell is zeroed (important for type safety)
- Cell appears to be an object of requested type (header filled in)
- Fully type-safe object with zeroed fields
- Fully initialized object

### Speeding Allocation

Since systems allocate at high rates, tuning allocation to be fast is important:

```pseudo
// Sequential allocation fast path
sequentialAllocateFast(size):
    result ← bumpPointer
    newBump ← result + size
    if newBump > heapLimit:
        return slowPath(size)
    bumpPointer ← newBump
    return result

// Segregated-fits fast path
segregatedAllocateFast(sizeClass):
    list ← freeLists[sizeClass]
    if list = null:
        return slowPath(sizeClass)
    head ← list.first
    freeLists[sizeClass] ← head.next
    return head
```

Key techniques:
- Inline the common case (fast path); call out to slow path for rare cases
- Dedicate registers to bump pointer and heap limit
- Combine multiple allocations in a basic block into one larger allocation with a single limit test

### Zeroing

Systems requiring zeroing (like Java) have several options:

- **Per-object zeroing**: Simple but may cause cache misses
- **Bulk zeroing**: More efficient; use `bzero` or special instructions like `dcbz`
- **Demand-zero pages**: Good for startup but may have overhead for reused pages
- **Ahead-of-allocator zeroing**: Zero somewhat ahead to prefetch into cache

```pseudo
zeroAhead(allocPointer, prefetchDistance):
    // Zero a region ahead of current allocation
    zeroStart ← alignUp(allocPointer + prefetchDistance)
    zeroEnd ← zeroStart + ZERO_CHUNK_SIZE
    bzero(zeroStart, ZERO_CHUNK_SIZE)
```

---

## 11.2 Finding Pointers

Collectors need to find pointers to determine reachability. Moving collectors require **precise** knowledge; non-moving collectors can use **conservative** estimates.

### Conservative Pointer Finding

The foundational technique treats each pointer-sized aligned sequence of bytes as a possible pointer (an **ambiguous pointer**):

```pseudo
isAmbiguousPointer(value):
    // Step 1: Range check
    if value < heapStart or value >= heapEnd:
        return false

    // Step 2: Check if block is allocated
    blockIndex ← value >> BLOCK_SHIFT
    block ← blockTable[blockIndex]
    if block = null:
        return false

    // Step 3: Check if object at offset is allocated
    offset ← value - blockStart(block)
    if offset mod block.cellSize ≠ 0:
        return false

    cellIndex ← offset / block.cellSize
    return block.allocatedBitmap[cellIndex]
```

**Black-listing**: To avoid false retention, the collector avoids allocating blocks whose addresses correspond to common non-pointer values. If an unallocated block is referenced by an ambiguous pointer, that block is black-listed.

### Accurate Pointer Finding with Tagged Values

Some systems include a tag with each value indicating its type:

**Bit-stealing**: Reserve low bits for tags; pointers have zeros (due to alignment), integers have other values:

| Tag | Value |
|-----|-------|
| 00 | Pointer |
| 10 | Object header |
| x1 | Integer (31-bit) |

**Big bag of pages**: Associate type information with entire blocks via table lookup. Numbers have full native length but require memory references.

### Accurate Pointer Finding in Objects

Finding pointers in objects requires knowing each object's type. Approaches include:

- **Header with type pointer**: Object header contains pointer to dispatch vector/type info
- **Bit vector**: Bitmap indicating which fields are pointers
- **Vector of offsets**: List of pointer field offsets (can be permuted for cache optimization)
- **Pointer/non-pointer partitioning**: Segregate pointer and non-pointer fields
- **Generated methods**: Compile tracing/copying methods for each type

```pseudo
scanObject(object):
    typeInfo ← getType(object)
    pointerBitmap ← typeInfo.pointerBitmap

    for fieldIndex from 0 to typeInfo.fieldCount:
        if pointerBitmap[fieldIndex]:
            processPointer(object.fields[fieldIndex])
```

### Accurate Pointer Finding in Stacks

Finding pointers in stacks involves three issues:

1. **Finding frames**: Dynamic chain pointers, return addresses
2. **Finding pointers within frames**: Stack maps per function/location
3. **Handling registers**: Caller-save vs callee-save conventions

```pseudo
processStack(thread):
    regs ← getRegisters(thread)
    done ← {}  // Registers already processed
    frame ← topFrame(thread)

    processFrame(frame, regs, done)
    setRegisters(thread, regs)

processFrame(frame, regs, done):
    ip ← getIP(frame)
    caller ← getCallerFrame(frame)

    if caller ≠ null:
        restore ← {}
        // Un-save callee-save registers to get caller's view
        for each (reg, slot) in calleeSavedRegs(ip):
            restore.add((reg, regs[reg]))
            regs[reg] ← frame.slots[slot]

        processFrame(caller, regs, done)

        // Re-save updated values
        for each (reg, slot) in calleeSavedRegs(ip):
            frame.slots[slot] ← regs[reg]

        // Restore our view
        for each (reg, value) in restore:
            regs[reg] ← value
            done.remove(reg)

    // Process pointer slots
    for each slot in pointerSlots(ip):
        processPointer(frame.slots[slot])

    // Process pointer registers (not already done)
    for each reg in pointerRegs(ip):
        if reg not in done:
            processPointer(regs[reg])
            done.add(reg)
```

---

## 11.3 Interior and Derived Pointers

### Interior Pointers

An **interior pointer** points somewhere inside an object rather than at its start. Supporting interior pointers requires mapping any interior address to the object's base:

```pseudo
findObjectBase(interiorPtr):
    // Using crossing map
    card ← interiorPtr >> CARD_SHIFT
    lastObjectStart ← crossingMap[card]

    // Walk forward through objects until we find the containing one
    current ← lastObjectStart
    while current + objectSize(current) ≤ interiorPtr:
        current ← current + objectSize(current)

    return current
```

### Derived Pointers

A **derived pointer** results from pointer arithmetic (e.g., `base + offset`). Options:

- Store base pointer separately alongside derived pointer
- Compute base from derived using crossing map
- Restrict optimizations to avoid derived pointers at GC points

---

## 11.4 References from External Code

External code (native libraries, JNI) may hold references to heap objects. Solutions:

- **Handles/roots registration**: External code registers roots explicitly
- **Pinning**: Prevent objects from moving while referenced externally
- **Copying to external buffers**: Copy data out for external use

```pseudo
jniGetStringChars(jstring):
    // Pin the string or copy to native buffer
    string ← resolveHandle(jstring)
    if canPin(string):
        pin(string)
        return string.chars
    else:
        buffer ← nativeAlloc(string.length * 2)
        copyChars(string, buffer)
        return buffer
```

---

## 11.5 Stack Barriers

Stack barriers are checks on stack operations to detect certain conditions:

- **Generational stack scanning**: Mark cards dirty when stack frames contain old→young references
- **Incremental root scanning**: Process stack incrementally during concurrent collection
- **Overflow detection**: Detect stack overflow for collection triggering

```pseudo
// Example: Generational stack barrier on return
returnBarrier():
    if currentFrame.containsYoungPointers:
        markFrameCard(currentFrame, DIRTY)
    // Normal return proceeds
```

---

## 11.6 GC-Safe Points and Mutator Suspension

Garbage collection typically requires mutator threads to be in a **safe state**—a point where all roots are known and the heap is consistent.

### Safe Points

Safe points are locations in code where the compiler can describe the root set:
- Method prologues/epilogues
- Loop back-edges
- Allocation sites
- Call sites

```pseudo
// Safe point check
safePointCheck():
    if gcRequested:
        saveState()
        signalSafe()
        waitForGCComplete()
        restoreState()
```

### Polling

Mutators periodically poll a flag to check for GC requests:

```pseudo
// Polling at safe points
poll():
    if *pollPage ≠ 0:
        enterSafePoint()

// Triggering GC - set poll flag
requestGC():
    protectPage(pollPage)  // Causes trap on next poll
```

### Handshake Protocol

Safe handshake between mutator and collector:

```pseudo
stopTheWorld():
    // Request all threads to stop
    gcRequested ← true
    protectSafePointPage()

    // Wait for all threads to reach safe points
    for each thread in mutatorThreads:
        while not thread.atSafePoint:
            wait()

    // All mutators stopped - proceed with GC

resumeTheWorld():
    gcRequested ← false
    unprotectSafePointPage()

    // Signal all threads to resume
    for each thread in mutatorThreads:
        thread.resume()
```

---

## 11.7 Garbage Collecting Code

Code may embed pointers (literal pools, inline constants) that the collector must handle:

- **Relocation info**: Metadata describing pointer locations in code
- **Position-independent code**: Avoid embedded absolute addresses
- **Code in data heap**: Treat code objects like data objects
- **Separate code space**: Non-moving code space with special handling

---

## 11.8 Read and Write Barriers

Barriers are code sequences that execute on read or write operations to maintain collector invariants.

### Write Barriers

Most common; used for generational and concurrent collectors:

```pseudo
// Card marking write barrier
writeBarrierCard(src, field, value):
    src[field] ← value
    cardTable[addressOf(src) >> CARD_SHIFT] ← DIRTY

// Store buffer write barrier
writeBarrierStoreBuffer(src, field, value):
    src[field] ← value
    if isOld(src) and isYoung(value):
        storeBuffer.push(&src[field])

// SATB (Snapshot-at-the-Beginning) barrier
writeBarrierSATB(src, field, value):
    oldValue ← src[field]
    if oldValue ≠ null and not isMarked(oldValue):
        satbBuffer.push(oldValue)
    src[field] ← value

// Incremental update barrier
writeBarrierIncremental(src, field, value):
    src[field] ← value
    if isBlack(src) and isWhite(value):
        shade(value)  // Mark grey
```

### Read Barriers

Less common; used for some concurrent copying collectors:

```pseudo
// Brooks forwarding pointer barrier
readBarrierBrooks(ref):
    return ref.forwardingPointer

// To-space invariant barrier
readBarrierToSpace(ref):
    if inFromSpace(ref):
        return evacuate(ref)
    return ref
```

### Barrier Implementation

Barriers can be implemented via:
- **Inlined code**: Fast but increases code size
- **Function calls**: Slower but smaller
- **Page protection**: Hardware-assisted via memory protection traps
- **Compiler cooperation**: Compiler generates appropriate barrier code

---

## 11.9 Card Tables

Card tables are a common remembered set implementation:

```pseudo
CARD_SIZE = 512  // bytes per card
CARD_SHIFT = 9   // log2(CARD_SIZE)

// Mark card dirty on write
markCard(address):
    cardIndex ← address >> CARD_SHIFT
    cardTable[cardIndex] ← DIRTY

// Scan dirty cards
scanDirtyCards():
    for cardIndex from 0 to cardTableSize:
        if cardTable[cardIndex] = DIRTY:
            cardStart ← cardIndex << CARD_SHIFT
            scanObjectsInRange(cardStart, cardStart + CARD_SIZE)
            cardTable[cardIndex] ← CLEAN
```

Trade-offs:
- **Smaller cards**: More precise but larger card table
- **Byte vs bit cards**: Byte is faster to write; bit is more compact
- **Conditional vs unconditional marking**: Conditional avoids re-dirtying but costs a branch

---

## 11.10 Virtual Memory Page Protection

Page protection can implement various GC features:

### Read/Write Barriers via Traps

Protect pages to detect access; handle in signal handler:

```pseudo
protectedReadBarrier(ref):
    // Access causes SIGSEGV if page protected
    value ← *ref
    return value

// Signal handler
handlePageFault(address):
    page ← pageOf(address)
    if isProtectedForGC(page):
        processPage(page)
        unprotect(page)
        return RESUME
    // Real fault - propagate
```

### Incremental Collection with Page Protection

Protect fromspace; trap on access triggers copying:

```pseudo
setupIncrementalCollection():
    protectAllPages(fromSpace, READ_PROTECT)

handleFromSpaceAccess(address):
    object ← findObject(address)
    newLocation ← evacuate(object)
    unprotectPage(pageOf(address))
    // Update register/stack with new address if needed
```

### Guard Pages

Use guard pages for stack overflow detection or heap bounds:

```pseudo
setupHeapGuard():
    guardPage ← heapEnd
    protectPage(guardPage, NO_ACCESS)

handleGuardFault(address):
    if address in guardPage:
        triggerGC()
        // Or expand heap
```

---

## 11.11 Choosing Heap Size

Heap sizing affects performance significantly:

- **Too small**: Frequent collections, thrashing
- **Too large**: Long pauses, poor locality, memory pressure

Adaptive sizing strategies:
- Target a GC overhead percentage
- Respond to allocation rate
- Resize based on live data volume after collection

```pseudo
adaptiveHeapSize(liveData, gcTime, mutatorTime):
    gcOverhead ← gcTime / (gcTime + mutatorTime)

    if gcOverhead > TARGET_OVERHEAD:
        newSize ← heapSize * GROW_FACTOR
    else if gcOverhead < TARGET_OVERHEAD / 2:
        newSize ← max(liveData * MIN_HEADROOM, heapSize / SHRINK_FACTOR)
    else:
        newSize ← heapSize

    return clamp(newSize, MIN_HEAP, MAX_HEAP)
```

---

## 11.12 Summary

The runtime-GC interface defines how to find roots and pointers precisely and how barriers record mutations:

| Component | Purpose |
|-----------|---------|
| **Allocation interface** | Fast path/slow path; zeroing; initialization |
| **Pointer finding** | Conservative vs accurate; objects, stacks, registers |
| **Stack maps** | Per-location root information; callee-save handling |
| **Safe points** | Locations where GC can occur safely |
| **Write barriers** | Track mutations for generational/concurrent GC |
| **Read barriers** | Intercept reads for concurrent copying |
| **Card tables** | Coarse-grained remembered sets |
| **Page protection** | Hardware-assisted barriers and incremental collection |

Accurate object and stack metadata enable moving collectors and reduce retention. The choice of barrier implementation and remembered set structure significantly impacts both mutator and collector performance.
