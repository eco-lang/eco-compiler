# 9. Generational Garbage Collection

The goal of a garbage collector is to find dead objects and reclaim the space they occupy. Tracing collectors (and copying collectors in particular) are most efficient if the space they manage contains few live objects. Generational collectors exploit the **weak generational hypothesis**—that most objects die young—by concentrating reclamation effort on the youngest objects to maximize yield (recovered space) while minimizing effort.

---

## 9.1 The Generational Hypothesis

The weak generational hypothesis appears to be widely valid regardless of programming paradigm or implementation language. Studies have consistently shown:

- **Lisp**: 98% of data recovered by a collection had been allocated since the previous one; 50-90% of objects survive less than 10KB of allocation
- **Haskell**: 75-95% of heap data died before they were 10KB old; only 5% lived longer than 1MB
- **Standard ML**: 98% of any given generation reclaimed at each collection
- **Java**: 1-40% of objects survive 100KB; less than 21% live beyond 1MB; 65-96% survive no longer than 64KB

The **strong generational hypothesis**—that even for older objects, younger ones have lower survival rates—has less evidence. Object lifetimes are not random; they commonly live in clumps and die together because programs operate in phases.

---

## 9.2 Generational Collection Overview

Generational collectors segregate objects by age into **generations**, typically physically distinct areas of the heap. Younger generations are collected in preference to older ones, and objects that survive long enough are **promoted** (or **tenured**) from the generation being collected to an older one.

Most generational collectors manage younger generations by copying. If few objects are live in the generation being collected, the mark/cons ratio between volume of data processed and volume allocated will be low. By tuning nursery size, we can control expected pause times—typically of the order of ten milliseconds on current hardware.

```pseudo
minorCollection():
    // Evacuate from roots
    for each root in Roots:
        if inYoungGeneration(*root):
            *root ← evacuate(*root)

    // Process remembered set (old→young pointers)
    for each slot in rememberedSet:
        if inYoungGeneration(*slot):
            *slot ← evacuate(*slot)

    // Cheney scan of copied objects
    scan ← toSpaceStart
    while scan < allocationPointer:
        for each field in Pointers(objectAt(scan)):
            if inYoungGeneration(*field):
                *field ← evacuate(*field)
        scan ← scan + objectSize(scan)

    // Flip spaces
    swap(fromSpace, toSpace)
```

---

## 9.3 Measuring Time

Before objects can be segregated by age, we need to decide how time is measured. There are two choices:

### Bytes Allocated

Space allocated is a largely machine-independent measure. It directly measures pressure on the memory manager and is closely related to collection frequency. Unfortunately, measuring time in bytes is tricky in multithreaded systems—a global measure may inflate an object's lifetime by including allocation by unrelated threads.

### Collections Survived

In practice, generational collectors often measure time in terms of how many collections an object has survived. This is more convenient to record and requires fewer bits, but is appropriately considered an approximate proxy for actual age.

---

## 9.4 Inter-Generational Pointers

A generation's roots must be discovered before it can be collected. These consist not only of pointer values held in registers, stacks, and globals, but also any references to objects in this generation from objects in other parts of the heap that are not being collected at the same time.

Inter-generational pointers can arise in two ways:
1. The mutator creates a pointer when it writes a reference to a young object into a field of an old object
2. The collector creates inter-generational pointers when it promotes an object

Both cases can be detected with a **write barrier**:

```pseudo
writeBarrier(src, field, newValue):
    src[field] ← newValue
    if isOld(src) and isYoung(newValue):
        cardTable[address(src) >> CARD_SHIFT] ← DIRTY
```

### Remembered Sets

The data structures used to record inter-generational pointers are called **remembered sets**. They record the location of possible sources of pointers from one space to another. The source rather than target is recorded because:
1. It allows a moving collector to update the source field with an object's new address
2. A source field may be updated multiple times between collections—remembering the source ensures the collector processes only the object referenced at collection time

### Pointer Direction

By guaranteeing that younger generations will be collected whenever an older one is, young-to-old pointers need not be recorded. Many pointer writes are initializing stores to newly created objects, which by definition refer to older objects.

Different languages have different patterns:
- **ML**: Programmers explicitly annotate mutable variables; writes to these are the only source of old-to-young references
- **Haskell**: Old-to-new pointers arise only when a thunk is evaluated and overwritten
- **Java**: The programming paradigm centers on updating object state, leading to more frequent old-young pointers

---

## 9.5 Generations and Heap Layout

A wide variety of strategies organize generations. Collectors may use two or more generations, which may be segregated physically or logically. The structure within a generation may be flat or comprise a number of age-based subspaces, called **steps** or **buckets**.

### En Masse Promotion

The simplest arrangement is for each generation except the oldest to be implemented as a single semispace. When collected, all surviving objects are promoted en masse to the next generation.

```pseudo
evacuate(ptr):
    if isForwarded(ptr):
        return forwardingAddress(ptr)

    size ← objectSize(ptr)
    newLocation ← oldGenerationAlloc(size)
    copy(ptr, newLocation, size)
    setForwardingAddress(ptr, newLocation)
    return newLocation
```

Advantages:
- Simplicity
- Optimal utilization of young generation memory
- No per-object age records needed
- No copy reserve space needed in the nursery

Disadvantage: May lead to promotion rates 50-100% higher than requiring objects to survive multiple collections.

### Aging Semispaces

Promotion can be delayed by structuring a generation into two or more aging spaces. This allows objects to be copied between fromspace and tospace an arbitrary number of times within the generation before being promoted.

### Age Recording in Object Headers

Some collectors store an object's age in its header (stealing bits from header words). Individual live objects can either be evacuated to tospace or promoted based on their age:

```pseudo
evacuateWithAge(ptr):
    if isForwarded(ptr):
        return forwardingAddress(ptr)

    size ← objectSize(ptr)
    age ← getAge(ptr)

    if age >= PROMOTION_AGE:
        newLocation ← oldGenerationAlloc(size)
    else:
        newLocation ← toSpaceAlloc(size)
        setAge(newLocation, age + 1)

    copy(ptr, newLocation, size)
    setForwardingAddress(ptr, newLocation)
    return newLocation
```

### Survivor Spaces

Ungar organized the young generation as one large **creation space** (eden) and two smaller **survivor semispaces**. Objects are allocated in eden, which is scavenged alongside the survivor fromspace at each minor collection. This improves space utilization because eden is much larger than the survivor spaces.

For example, HotSpot's default eden vs survivor ratio is 32:1, using a copy reserve of less than 3% of the young generation.

```pseudo
minorCollectionWithSurvivorSpaces():
    // Evacuate from eden and survivor fromspace
    for each root in Roots:
        *root ← evacuateToSurvivorOrOld(*root)

    // Process remembered set
    for each slot in rememberedSet:
        *slot ← evacuateToSurvivorOrOld(*slot)

    // Cheney scan
    scan ← survivorToSpaceStart
    while scan < survivorAllocationPointer:
        for each field in Pointers(objectAt(scan)):
            *field ← evacuateToSurvivorOrOld(*field)
        scan ← scan + objectSize(scan)

    // Flip survivor spaces
    swap(survivorFrom, survivorTo)
    // Clear eden
    edenAllocationPointer ← edenStart

evacuateToSurvivorOrOld(ptr):
    if not inYoungGeneration(ptr) or isForwarded(ptr):
        return isForwarded(ptr) ? forwardingAddress(ptr) : ptr

    size ← objectSize(ptr)
    age ← getAge(ptr)

    if age >= PROMOTION_AGE:
        newLocation ← oldGenerationAlloc(size)
    else:
        if survivorAllocationPointer + size > survivorEnd:
            // Overflow: promote
            newLocation ← oldGenerationAlloc(size)
        else:
            newLocation ← survivorAllocationPointer
            survivorAllocationPointer ← survivorAllocationPointer + size
        setAge(newLocation, age + 1)

    copy(ptr, newLocation, size)
    setForwardingAddress(ptr, newLocation)
    return newLocation
```

---

## 9.6 Multiple Generations

Adding further generations is one solution to the dilemma of preserving short pause times for nursery collections without incurring excessively frequent full heap collections. The role of intermediate generations is to filter out objects that have survived collection of the youngest generation but do not live much longer.

### Trade-offs

Using multiple generations has drawbacks:
- Most systems collect all younger generations when any older generation is collected
- Pause times for intermediate generation collections are longer than nursery collections
- More complex to implement
- May introduce additional overheads to the collector's tracing loop
- Increases the number of inter-generational pointers created

Most modern generational collectors for object-oriented systems provide just two generations. Even collectors that provide more than two often use only two by default.

---

## 9.7 Adapting to Program Behavior

### Appel-Style Collection

Appel introduced an adaptive generational layout that gives as much room as possible to the young generation. The heap is divided into three regions: old generation, copy reserve, and young generation.

```pseudo
appel-StyleLayout():
    // After minor collection, survivors promoted to end of old generation
    // Space not needed for old generation split equally:
    //   - Copy reserve (for next collection)
    //   - New young generation

    if youngGenerationSize < MINIMUM_THRESHOLD:
        majorCollection()

appel-MajorCollection():
    // old < reserve guarantees safety
    // Collect old generation, then slide survivors to bottom
    // Remaining space becomes copy reserve + young generation
```

Advantage: Offers good memory utilization and reduces collections needed compared with fixed-size configurations.

Caution: Must avoid thrashing—collect old generation whenever young generation size falls below a minimum.

### Feedback-Controlled Promotion

**Demographic feedback-mediated tenuring** attempts to smooth out long pauses from promotion bursts. The volume promoted at one collection is used as a predictor for the next collection's length, throttling or accelerating promotion accordingly.

**HotSpot Ergonomics** provides adaptive mechanism for resizing generations based on user-provided goals:
1. First attempts to meet maximum pause time goal
2. Then targets throughput (fraction of time in GC)
3. Finally, shrinks footprint once other goals are satisfied

---

## 9.8 Card Tables

The most common implementation of remembered sets uses **card tables**. The heap is divided into fixed-size cards (typically 128-512 bytes). The card table has one byte (or bit) per card. When a pointer is stored into an object, the write barrier marks the corresponding card as dirty:

```pseudo
cardMarkingWriteBarrier(src, field, newValue):
    src[field] ← newValue
    cardTable[address(src) >> CARD_SHIFT] ← DIRTY
```

At collection time, the collector scans only dirty cards to find inter-generational pointers:

```pseudo
processDirtyCards():
    for cardIndex from 0 to cardTableSize:
        if cardTable[cardIndex] = DIRTY:
            cardStart ← cardIndex << CARD_SHIFT
            cardEnd ← cardStart + CARD_SIZE
            // Scan all objects in this card
            for each object in objectsInRange(cardStart, cardEnd):
                for each field in Pointers(object):
                    if inYoungGeneration(*field):
                        *field ← evacuate(*field)
            cardTable[cardIndex] ← CLEAN
```

### Card Table Trade-offs

- **Card size**: Smaller cards mean more precise remembered sets but larger card tables and more overhead
- **Card marking cost**: Unconditional store (no conditional check) is fastest but may re-dirty clean cards
- **Scanning cost**: Must parse objects within cards, which requires heap parsability

---

## 9.9 Space Management

Young generations are usually managed by evacuation. Old generations support a wider range of strategies:

### Mark-Sweep for Old Generation

Mark-sweep offers better memory utilization than copying, especially in small heaps. The drawback is that it is non-moving and may fragment. The solution is to run an additional compacting pass over the old generation when fragmentation damages performance.

### Switching Between Copying and Marking

Better space utilization can be obtained with a smaller copy reserve and switching from copying to compacting whenever the reserve is too small. The collector must be able to switch on the fly:

```pseudo
minorCollectionWithFallback():
    // Start copying
    for each root in Roots:
        if inYoungGeneration(*root):
            *root ← evacuateOrMark(*root)

    // If copy reserve exhausted during copying,
    // switch to marking for remaining objects

evacuateOrMark(ptr):
    if copyReserveExhausted:
        mark(ptr)
        return ptr
    else:
        return evacuate(ptr)
```

---

## 9.10 Older-First Garbage Collection

Generational garbage collection collects the youngest prefix of objects. Alternatives include:

### Renewal Older-First

Consider an object's "age" to be time since it was created or last collected. The heap is divided into k steps. When full, the oldest steps are condemned, and survivors are evacuated to the youngest end (thus "renewed").

```pseudo
renewalOlderFirst():
    // Condemn oldest k-j steps
    for each object in oldestSteps:
        if isLive(object):
            evacuateTo(youngestStep, object)

    // Survivors now youngest; steps renumbered
```

### Deferred Older-First

A fixed-size collection window slides from oldest to youngest end. When the heap is full, the window is collected, ignoring older or younger objects. Survivors move to immediately after the oldest region.

The intuition: the collector seeks a "sweet spot" where the window finds few survivors, achieving low mark/cons ratio.

---

## 9.11 Issues to Consider

### Nursery Sizing

- **Too small**: Collections too frequent; objects don't have time to die; high promotion rates
- **Too large**: Long pause times; potentially worse locality

### Nepotism

Treating inter-generational pointer sources as roots exacerbates floating garbage. Old garbage holding young pointers causes young garbage children to be promoted rather than reclaimed.

### Write Barrier Cost

Typically the collector accounts for a small fraction of execution time. A write barrier comprising a few instructions in its fast path yet accounting for 5% of execution time would be hard to optimize away by reducing collection time.

### Working Set

Promoting objects prematurely may dilute the program's working set, harming cache performance.

---

## 9.12 Summary

Generational garbage collection exploits the weak generational hypothesis to concentrate effort on the youngest objects, where most garbage lies. Key components include:

| Component | Purpose |
|-----------|---------|
| **Young generation** | Fast copying collection; short pause times |
| **Old generation** | Less frequent collection; mark-sweep or compact |
| **Promotion policy** | When to move objects to older generation |
| **Remembered sets** | Track old→young pointers as minor GC roots |
| **Card tables** | Efficient implementation of remembered sets |
| **Survivor spaces** | Delay promotion; improve space utilization |

Tuning involves balancing:
- Pause time (smaller nursery = shorter pauses)
- Throughput (larger nursery = less overhead)
- Promotion rate (affects old generation pressure)
- Write barrier cost (affects mutator performance)

Variants like Appel-style collection and older-first schemes adapt to different workload characteristics.
