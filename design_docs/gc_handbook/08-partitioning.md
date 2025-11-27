# 8. Partitioning the Heap

So far we have assumed a monolithic approach to garbage collection: all objects are managed by the same algorithm and all are collected at the same time. However, substantial performance benefits accrue from treating different categories of object differently. The best-known example is generational collection, which segregates objects by age and preferentially collects younger objects. This chapter explores why, how, and when to partition the heap.

---

## 8.1 Terminology

It is useful to distinguish the sets of objects to which we want to apply certain memory management policies from the mechanisms used to implement those policies efficiently.

We use the term **space** to indicate a logical set of objects that receive similar treatment. A space may use one or more chunks of address space. **Chunks** are contiguous and often power-of-two sized and aligned.

---

## 8.2 Why to Partition

It is often effective to split the heap into partitions, each managed under a different policy or with a different mechanism. These ideas were first explored in Bishop's influential thesis [1977]. The motivations include:

### Partitioning by Mobility

In a hybrid collector, it may be necessary to distinguish objects that can be moved from those that either cannot be moved or are costly to move. It may be impossible to move objects due to:
- Lack of communication between the run-time system and the compiler
- An object being passed to the operating system (e.g., an I/O buffer)
- References passed to libraries that don't expect garbage collection (e.g., Java Native Interface)

**Conservative stack scanning** treats every slot in every stack frame as a potential reference. Since it identifies a superset of true pointer slots, it cannot change values of any identified slots (since an integer might look like a pointer). Thus, conservative collection cannot move any object directly referenced by the roots. However, with appropriate object information, a **mostly-copying collector** can safely move any object except those appearing directly reachable from ambiguous roots.

### Partitioning by Size

The cost of moving large objects may outweigh the fragmentation costs of not moving them. A common strategy is to allocate objects larger than a certain threshold into a separate **large object space (LOS)**. Large objects are typically placed on separate pages (minimum size might be half a page) and managed by a non-moving collector such as mark-sweep.

By placing an object on its own page, it can also be "copied" virtually using Baker's Treadmill or by remapping virtual memory pages.

### Partitioning for Space

It is desirable to create objects in a space managed by a strategy that supports fast allocation and good spatial locality. Both copying and sliding collectors eliminate fragmentation and allow sequential allocation. However:
- Copying collectors require twice the address space of non-moving collectors
- Mark-compact collection is comparatively slow

Therefore, it is useful to segregate objects so different spaces can be managed differently:
- Objects expected to live long → non-moving space with occasional compaction
- Objects with high allocation/mortality rates → copying collector for fast allocation and cheap collection

### Partitioning by Kind

Physically segregating objects of different categories allows a property (such as type) to be determined simply from the object's address rather than by retrieving a field value or chasing a pointer. Benefits include:

- **Cache advantage**: No need to load a further field
- **Space savings**: The property can be associated with the space rather than replicated in each object's header
- **Collector optimization**: Objects without pointers don't need to be scanned by a tracing collector

Conservative collectors particularly benefit from placing large compressed bitmaps in areas that are never scanned, as they are a frequent source of false pointers.

Virtual machines often generate and store code sequences in the heap. Code objects tend to be large and long-lived, so it is often desirable not to relocate them.

### Partitioning for Yield

The best-known reason for segregation is to exploit **object demographics**. It is common for some objects to remain in use from allocation to program end, while others have very short lives. As early as 1976, Deutsch and Bobrow noted that "a newly allocated datum is likely to be either 'nailed down' or abandoned within a relatively short time."

The **weak generational hypothesis** states that "most objects die young." The insight behind generational and quasi-generational strategies is that the best way to reclaim the most storage for the least effort is to concentrate collection effort on objects most likely to be garbage.

If the distribution of object lifetimes is sufficiently skewed, it is worth repeatedly collecting a subset of the heap rather than the entire heap. There is a trade-off: by not tracing the whole heap at every collection, the collector allows some garbage to **float** in the heap, reducing space available for new objects and increasing collection frequency.

### Partitioning to Reduce Pause Time

The cost of tracing collection largely depends on the volume of live objects to be traced. By restricting the size of the **condemned space** that the collector traces, we bound the volume of objects scavenged or marked, and hence the time required for garbage collection.

However, collecting a subset improves only **expected** pause times. Since collection of a single space may return insufficient free space, it may still be necessary to collect the whole heap. Thus, partitioned collection cannot reduce worst-case pause times.

The extreme case is allowing a space to be reclaimed in **constant time**. If no objects within a condemned region are reachable from outside that region, there is no tracing work—the memory can be returned en masse to the allocator. This requires appropriate object access disciplines and heap structures (such as stacks of scoped regions).

### Partitioning for Locality

The importance of locality for good performance continues to increase as the memory hierarchy becomes more complex. Simple collectors tend to interact poorly with virtual memory and caches:
- Tracing collectors touch every live object
- Mark-sweep collectors may touch dead objects too
- Copying collectors may touch every page even though only half is in use

A collector should improve the locality of the system as a whole. Generational collectors obtain locality improvements for both:
- **The collector**: Concentrating effort on a subsection likely to return the most free space
- **The mutator**: Reducing working set size, since younger objects typically have higher mutation rates

### Partitioning by Thread

Garbage collection requires synchronization between mutator and collector threads. This cost can be reduced if we halt just a single thread and collect only objects allocated by that thread which cannot have escaped to become reachable by other threads.

To achieve this, the collector must distinguish objects accessible from only one thread from those that may be shared, for example by allocating in **thread-local heaplets**. At a larger granularity, it may be desirable to distinguish objects accessible to particular tasks in a multi-tasking virtual machine.

### Partitioning by Availability

In NUMA machines, some memory banks are closer to particular processors than others. Collectors can preferentially allocate objects in "near" memory to minimize latency. The **Bookmarking collector** cooperates with the virtual memory system to improve page swapping choices and allow tracing to complete without accessing non-resident pages.

### Partitioning by Mutability

Recently created objects tend to be modified more frequently than longer-lived objects. Reference counting incurs a high per-update overhead and thus is less suitable for frequently modified objects. Conversely, in very large heaps, only a small proportion of objects will be updated in any period, but a tracing collector must still visit all candidates for garbage.

Some systems segregate objects by mutability (and by thread) to allow each thread to have its own space of immutable, unshared objects along with a single shared space. This requires a strong property: there must be no pointers to objects inside a thread's local heap from objects outside it. This is achieved through **copy-on-write** for escaping references (semantically transparent since targets are immutable).

---

## 8.3 How to Partition

### Contiguous Address Ranges

The most common way to partition the heap is by dividing it into non-overlapping ranges of addresses. At its simplest, each space occupies a contiguous chunk of heap memory. It is more efficient to align chunks on power-of-two boundaries—an object's space is then encoded in the highest bits of its address and can be found by a shift or mask operation.

```pseudo
getSpace(objectAddress):
    spaceIndex ← objectAddress >> SPACE_SHIFT
    return spaceTable[spaceIndex]
```

Once the space identity is known, the collector can decide how to process the object (mark it, copy it, ignore it, etc.). If the layout of spaces is known at compile time, this test is particularly efficient—a comparison against a constant.

### Discontiguous Spaces

Contiguous areas may not make efficient use of memory in 32-bit systems. Although reserving virtual address space doesn't commit physical memory, contiguous spaces are inflexible and may lead to virtual memory exhaustion. An additional difficulty is that operating systems map library code segments in unpredictable places.

The alternative is implementing spaces as **discontiguous sets of chunks** (frames) of fixed size. Operations are more efficient if frames are aligned on 2^n boundaries and are a multiple of the operating system's page size.

### Header-Based Partitioning

It is not always necessary to implement spaces by physically segregating objects. An object's space may be indicated by bits in its header. Although this precludes fast address comparison, it offers advantages:
- Allows partitioning by properties that vary at run time (age, thread reachability)
- Facilitates handling temporarily pinned objects
- May be more accurate than static choices

The downside: dynamic segregation imposes more work on the write barrier. Whenever a pointer update causes its referent to become potentially shared, the referent and its transitive closure must be marked as shared.

### Completeness Considerations

Collecting only a subset of partitions necessarily leads to an **incomplete** collector that cannot reclaim any garbage in uncollected partitions. Even with round-robin collection of every partition, garbage cycles that span partitions will not be collected.

Solutions:
- Collect the entire heap when other tactics fail
- More sophisticated strategies like the Train collector (Mature Object Spaces)

---

## 8.4 When to Partition

Partitioning decisions can be made statically (at compile time) or dynamically—when an object is allocated, at collection time, or as the mutator accesses objects.

### By the Collector (Dynamic)

The best-known scheme is **generational**, where objects are segregated by age. As an object's age increases beyond some threshold, it is **promoted** (moved physically or logically) to the next space.

Mostly-copying collectors may also dynamically segregate objects that cannot be moved while pinned.

### By the Allocator

Most commonly, allocators determine from the size of an allocation request whether the object should go in a large object space. In systems with explicit memory regions or thread-local allocation, the allocator places objects in appropriate regions.

Some generational systems attempt to **co-locate** a new object in the same region as one that will point to it, anticipating eventual promotion there.

### By the Compiler (Static)

An object's space may be decided statically by its type, because it is code, or through analysis. If objects of a particular kind share a common property (such as immortality), the compiler can determine the space and generate appropriate code.

**Pretenuring**: If the compiler knows certain objects (allocated at a particular point in the code) will usually be promoted, it can allocate them directly into the older generation.

### By the Mutator (Runtime)

Objects may be repartitioned by the mutator in a concurrent collector. Mutator access to objects may be mediated by read or write barriers, which may cause objects to be moved or marked. The write barrier can logically segregate objects as they escape their allocating thread. Collaboration between the run-time system and OS can repartition objects as pages are swapped.

---

## 8.5 Common Partitioning Patterns

### Generational

Young generation collected frequently with copying; old generation uses mark-sweep or mark-compact. Card tables or remembered sets track inter-generational pointers.

```pseudo
minorCollection():
    condemned ← youngGeneration
    roots ← globalRoots ∪ rememberedSet
    for each ref in roots:
        if inSpace(ref, youngGeneration):
            evacuate(ref, oldGeneration)
    scan(oldGeneration)
    resetRememberedSet()
```

### Region-Based (G1/Immix Style)

Heap divided into equal-sized regions tracked individually. The collector marks lines within regions; evacuates selected regions based on liveness; provides partial compaction.

```pseudo
selectRegionsForEvacuation():
    candidates ← []
    for each region in heap:
        liveness ← countLiveBytes(region)
        if liveness < EVACUATION_THRESHOLD:
            candidates.add(region)
    return sortByLiveness(candidates)[:MAX_EVACUATE]
```

### Per-Thread Heaps

Each thread has its own nursery and local old space. Remembered sets track cross-thread pointers. Collection of a thread's local heap can proceed without stopping other threads.

### Large Object Space

Page-aligned blocks managed by mark-sweep (no copying). Objects above a size threshold are routed here.

### Pointer-Free Space

Objects without pointer fields can skip scanning during tracing. Only scanned for reachability from other spaces.

---

## 8.6 Design Considerations

### Routing Allocations

The system must decide which space receives each allocation based on:
- Size thresholds
- Type tags or compiler hints
- Thread identity
- Pretenuring analysis results

### Cross-Space Pointers

Remembered sets or card tables must track pointers between spaces. The write barrier is responsible for detecting and recording these.

### Space Accounting

Per-region liveness tracking allows the collector to choose evacuation targets efficiently. Regions with low liveness offer the best yield for evacuation.

### Region Size Trade-offs

- Smaller regions → more metadata overhead but finer-grained control
- Larger regions → less overhead but coarser control over pause time and evacuation

### Promotion and Demotion

Policies must define:
- When objects are old enough to promote
- Whether objects can be demoted (rare in practice)
- Direct allocation into older generations (pretenuring)

---

## 8.7 Summary

Partitioning tailors GC strategy to object characteristics, enabling better pause control, fragmentation management, and locality. The main reasons to partition include:

| Dimension | Benefit |
|-----------|---------|
| **Mobility** | Separate movable from pinned objects |
| **Size** | Handle large objects differently |
| **Kind** | Skip scanning pointer-free objects |
| **Age** | Concentrate effort on likely garbage |
| **Thread** | Reduce synchronization overhead |
| **Locality** | Improve cache/NUMA performance |

Partitioning can be implemented through:
- Contiguous address ranges with fast space lookup
- Discontiguous chunks for flexible memory use
- Header bits for dynamic partitioning

Successful designs define clear routing rules, maintain cross-space remembered sets, and track per-region liveness to drive policy decisions. The next chapters examine generational collection in detail (Chapter 9) and other partitioning schemes (Chapter 10).
