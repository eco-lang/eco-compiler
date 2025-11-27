# 7. Allocation

Memory allocation and garbage collection are two sides of the same coin. How memory is reclaimed places constraints on how it is allocated, and allocation performance directly impacts application throughput. This chapter covers the fundamental allocation strategies, from simple bump-pointer allocation to sophisticated segregated-fits schemes, along with fragmentation management and concurrent allocation techniques.

---

## 7.1 The Relationship Between Allocation and Collection

There are three aspects to a memory management system: (i) allocation of memory in the first place, (ii) identification of live data, and (iii) reclamation for future use of memory previously allocated but currently occupied by dead objects. These tasks are not independent—in particular, the way space is reclaimed affects how it is allocated.

Several key differences between garbage-collected and explicitly-managed systems affect allocation strategy choices:

- **Batch freeing**: Garbage-collected systems free space all at once rather than one object at a time. Some algorithms (copying, compacting) free large contiguous regions at a time.
- **More information available**: Many garbage-collected systems have static knowledge of the size and type of object being allocated.
- **Different usage patterns**: Because of garbage collection's availability, programmers use heap allocation more freely and more often.

There are two fundamental strategies: sequential allocation and free-list allocation. We then consider the more complex case of allocation from multiple free-lists (segregated-fits).

---

## 7.2 Sequential (Bump Pointer) Allocation

Sequential allocation uses a large free chunk of memory. Given a request for n bytes, it allocates that much from one end of the free chunk. The data structure is simple: a free pointer and a limit pointer.

```pseudo
sequentialAllocate(n):
    result ← free
    newFree ← result + n
    if newFree > limit:
        return null    // signal 'Memory exhausted'
    free ← newFree
    return result
```

Sequential allocation is colloquially called **bump pointer allocation** because it "bumps" the free pointer. It is also called **linear allocation** because the sequence of allocation addresses is linear for a given chunk.

### Properties of Sequential Allocation

- **Simple**: The algorithm is trivial to implement and verify.
- **Efficient**: The fundamental performance difference between sequential allocation and segregated-fits free-list allocation is on the order of 1% of total execution time for typical Java systems.
- **Good locality**: Results in better cache locality than free-list allocation, especially for initial allocation of objects in moving collectors.
- **Requires compaction**: May be less suitable for non-moving collectors, since uncollected objects break larger chunks into smaller ones, resulting in many small sequential allocation chunks.

### When to Use Sequential Allocation

Sequential allocation is ideal for:
- Copying collectors (nursery allocation)
- Compacting collectors
- Region-based allocators where the entire region is freed at once

It is problematic for non-moving collectors unless combined with occasional compaction or used only within thread-local allocation buffers.

---

## 7.3 Free-List Allocation

The alternative to sequential allocation is free-list allocation. A data structure records the location and size of free cells of memory. The allocator considers each free cell in turn and, according to some policy, chooses one to allocate.

This general approach is called **sequential fits allocation** since the algorithm searches sequentially for a cell into which the request will fit. The classical versions are first-fit, next-fit, and best-fit.

### First-Fit Allocation

A first-fit allocator uses the first cell it finds that can satisfy the request. If the cell is larger than required, the allocator may split the cell and return the remainder to the free-list.

```pseudo
firstFitAllocate(n):
    prev ← addressOf(head)
    loop:
        curr ← next(prev)
        if curr = null:
            return null    // Memory exhausted
        else if size(curr) < n:
            prev ← curr
        else:
            return listAllocate(prev, curr, n)

listAllocate(prev, curr, n):
    result ← curr
    if shouldSplit(size(curr), n):
        remainder ← result + n
        next(remainder) ← next(curr)
        size(remainder) ← size(curr) - n
        next(prev) ← remainder
    else:
        next(prev) ← next(curr)
    return result
```

First-fit exhibits the following characteristics:
- Small remainder cells accumulate near the front of the list, slowing down allocation
- In terms of space utilization, it behaves similarly to best-fit since cells end up roughly sorted from smallest to largest

An alternative variation returns the portion at the end of the cell being split:

```pseudo
listAllocateAlt(prev, curr, n):
    if shouldSplit(size(curr), n):
        size(curr) ← size(curr) - n
        result ← curr + size(curr)
    else:
        next(prev) ← next(curr)
        result ← curr
    return result
```

### Next-Fit Allocation

Next-fit is a variation of first-fit that starts the search from the point where the last search succeeded. When it reaches the end of the list, it starts over from the beginning (hence sometimes called **circular first-fit**).

```pseudo
nextFitAllocate(n):
    start ← prev
    loop:
        curr ← next(prev)
        if curr = null:
            prev ← addressOf(head)    // restart from beginning
            curr ← next(prev)
        if prev = start:
            return null    // Memory exhausted
        else if size(curr) < n:
            prev ← curr
        else:
            return listAllocate(prev, curr, n)
```

While intuitively appealing, next-fit exhibits drawbacks:
- Objects from different phases of mutator execution become mixed together, affecting fragmentation
- Accesses through the roving pointer have poor locality because the pointer cycles through all free cells
- Allocated objects may exhibit poor locality, being spread out through memory

### Best-Fit Allocation

Best-fit allocation finds the cell whose size most closely matches the request. The idea is to minimize waste and avoid splitting large cells unnecessarily.

```pseudo
bestFitAllocate(n):
    best ← null
    bestSize ← ∞
    prev ← addressOf(head)
    loop:
        curr ← next(prev)
        if curr = null || size(curr) = n:
            if curr ≠ null:
                bestPrev ← prev
                best ← curr
            else if best = null:
                return null    // Memory exhausted
            return listAllocate(bestPrev, best, n)
        else if size(curr) < n || bestSize < size(curr):
            prev ← curr
        else:
            best ← curr
            bestPrev ← prev
            bestSize ← size(curr)
```

In practice, best-fit performs well for most programs, giving relatively low wasted space despite bad worst-case performance.

---

## 7.4 Speeding Free-List Allocation

Allocating from a single sequential list may not scale well to large memories. Several more sophisticated organizations have been devised.

### Balanced Binary Trees

Free cells can be organized in a balanced binary tree, sorted by size (for best-fit) or by address (for first-fit or next-fit). When sorting by size, entering only one cell of each size into the tree and chaining the rest from that tree node speeds search and reduces tree reorganization.

### Cartesian Trees

For first-fit or next-fit with address ordering, a **Cartesian tree** indexes by both address (primary key) and size (secondary key). It is totally ordered on addresses but organized as a heap for sizes, allowing quick search for the first or next fit satisfying a given size request.

```pseudo
firstFitAllocateCartesian(n):
    parent ← null
    curr ← root
    loop:
        if left(curr) ≠ null && max(left(curr)) > n:
            parent ← curr
            curr ← left(curr)
        else if prev < curr && size(curr) > n:
            prev ← curr
            return treeAllocate(curr, parent, n)
        else if right(curr) ≠ null && max(right(curr)) > n:
            parent ← curr
            curr ← right(curr)
        else:
            return null    // Memory exhausted
```

Each node maintains a value `max(n)` giving the maximum size of any nodes in that node's subtree.

### Bitmapped-Fits Allocation

A bitmap has one bit for each granule of the allocatable heap. Rather than scanning the heap itself, we scan the bitmap. Scanning a byte at a time by using the byte value to index pre-calculated tables gives the size of the largest run of free granules within the eight-granule unit.

Bitmaps have several virtues:
- **Robustness**: They are "on the side" and less vulnerable to corruption
- **Minimal constraints**: They don't require information in free/allocated cells, minimizing constraints on cell size
- **Compact scanning**: Scanning causes fewer cache misses, improving locality

---

## 7.5 Fragmentation

At the beginning, an allocation system generally has one or a small number of large cells of contiguous free memory. As a program runs, allocating and freeing cells, it typically produces a larger number of free cells, which can individually be small. This dispersal of free memory is called **fragmentation**.

### Effects of Fragmentation

- **Allocation failure**: There can be enough free memory in total to satisfy a request, but not enough in any particular free cell
- **Increased resource usage**: Fragmentation causes a program to use more address space, more resident pages, and more cache lines

### Types of Fragmentation

- **External fragmentation**: Unusable space outside any allocated cell—free cells too small to satisfy requests
- **Internal fragmentation**: Wasted space inside an individual cell because the requested size was rounded up

It is impractical to avoid fragmentation altogether. Even given a known request sequence, optimal allocation is NP-hard. However, some approaches tend to be better than others.

The only complete solution to fragmentation is compaction or copying collection.

---

## 7.6 Segregated-Fits Allocation

Much of the time consumed by a basic free-list allocator is spent searching for a free cell of appropriate size. Using multiple free-lists whose members are segregated by size can speed allocation.

The basic idea: there is some number k of size values, s₀ < s₁ < ... < sₖ₋₁. There are k+1 free-lists, f₀, ..., fₖ. The size b of a free cell on list fᵢ is constrained by sᵢ₋₁ < b ≤ sᵢ (where s₋₁ = 0 and sₖ = +∞).

When requesting a cell of size b < sₖ₋₁, the allocator rounds the request up to the smallest sᵢ such that b ≤ sᵢ. These sᵢ are called **size classes**.

```pseudo
segregatedFitAllocate(j):    // j is the index of size class sⱼ
    result ← remove(freeLists[j])
    if result = null:
        large ← allocateBlock()
        if large = null:
            return null    // Memory exhausted
        initialize(large, sizes[j])
        result ← remove(freeLists[j])
    return result
```

### Calculating Size Classes

Size classes s₀ through sₖ₋₁ might be evenly spaced: sᵢ = s₀ + c·i for some suitable c > 0. Then the size class is:
- sₖ if b > sₖ₋₁
- Otherwise sⱼ where j = ⌈(b - s₀ + c - 1) / c⌉

For example: s₀ = 8, c = 8, k = 16 gives size classes as multiples of eight from 8 to 128, using a general free-list algorithm for b > 128.

If c is a power of two, the division can be replaced by a shift operation.

### Populating Size Classes

**Big Bag of Pages (Block-Based)**: Choose a block size B (a power of two). When we need more cells of size s, allocate a block and slice it into cells of size s, putting them on that free-list. Associate with each block the fact that it is dedicated to cells of size s.

```pseudo
populateFromBlock(sizeClass):
    block ← allocateBlock()
    if block = null:
        return false
    cellSize ← sizes[sizeClass]
    cursor ← block
    while cursor + cellSize ≤ block + BLOCK_SIZE:
        add(freeLists[sizeClass], cursor)
        cursor ← cursor + cellSize
    return true
```

Block-based allocation simplifies recombining: it does not recombine unless all cells in a block are free, then returns the block to the pool.

**Splitting**: When we split a cell, we place the portion not allocated onto the appropriate free-list for its size. The **buddy system** uses sizes that are powers of two, making splitting and coalescing straightforward.

---

## 7.7 Additional Considerations

### Alignment

Depending on machine constraints or for improved memory hierarchy performance, allocated objects may require special alignment. Making double-words the granule of allocation is simple but potentially wasteful.

```pseudo
fits(n, a, m, blk):
    // need n bytes, alignment a modulo m, m a power of 2
    z ← blk - a             // back up
    z ← (z + m - 1) & ~(m - 1)    // round up
    z ← z + a               // go forward
    pad ← z - blk
    return n + pad ≤ size(blk)
```

### Heap Parsability

The sweeping phase of a mark-sweep collector must be able to advance from cell to cell in the heap. This capability is called **heap parsability**. Object headers typically record type information, from which size can be derived.

For arrays, the length field should come after the standard header so that the first array element falls at a consistent offset. This design supports upward parsing of the heap.

A bit map on the side indicating where each object starts makes heap parsing easy and simplifies object header format design.

### Boundary Tags

Many allocate-free systems associate a boundary tag with each cell, indicating the size and whether it is allocated or free. It may also indicate the size of the previous cell, making it easier to find neighbors for coalescing.

Garbage collection may not need boundary tags since it frees objects all at once and can know size from type information.

### Wilderness Preservation

The last free chunk in the heap is expandable (the "wilderness"). Allocating from the wilderness only as a last resort helps reduce fragmentation and defers the need to grow the heap.

### Crossing Maps

Some collection schemes require the allocator to fill in a crossing map. This indicates, for each aligned segment of the heap, the address of the last object that begins in that segment. Combined with heap parsability, this allows determining the start of an object from an address within it.

---

## 7.8 Allocation in Concurrent Systems

If multiple threads attempt to allocate simultaneously, they need to use atomic operations or locks, making allocation a serial bottleneck. The basic solution is to give each thread its own allocation area.

### Thread-Local Allocation Buffers (TLABs)

A TLAB is a region of memory dedicated to a single thread. The thread performs sequential allocation within its TLAB without synchronization. When the TLAB is exhausted, the thread obtains another chunk from a global pool (which does require synchronization).

```pseudo
tlabAllocate(size):
    size ← align(size)
    if tlab.bump + size ≤ tlab.end:
        obj ← tlab.bump
        tlab.bump ← tlab.bump + size
        return obj
    else:
        tlab ← refillTlab(defaultSize)
        if tlab = null:
            return null
        return tlabAllocate(size)

refillTlab(size):
    lock(globalHeap)
    chunk ← globalAllocate(size)
    unlock(globalHeap)
    if chunk = null:
        return null
    return initializeTlab(chunk)
```

### Adaptive TLAB Sizing

Individual threads may vary in their allocation rates. An adaptive algorithm can adjust the size of free space chunks handed out to each thread:
- A slowly allocating thread receives a small chunk
- A rapidly allocating thread gets a large chunk

One approach: initially request a 24-word TLAB. Each time another TLAB is requested, multiply the size by 1.5. When the collector runs, decay each thread's TLAB size by dividing by two.

### Processor-Local Allocation Buffers (PLABs)

Associating allocation buffers with processors rather than threads can be beneficial in some cases. This requires mechanisms to detect when a thread has been preempted and rescheduled.

For small numbers of threads, per-thread TLABs are better. Per-processor allocation buffers work better when there are many allocating threads. Systems can switch between approaches dynamically.

### Per-Thread Free-Lists

Each thread (or processor) can maintain its own set of segregated free-lists, in conjunction with incremental sweeping. When a thread sweeps a block incrementally during allocation, it puts free cells into its own free-lists. This naturally returns free buffers to threads that allocate them most frequently.

---

## 7.9 Summary

Allocation strategy shapes GC behavior and performance. The key trade-offs are:

| Strategy | Pros | Cons | Best For |
|----------|------|------|----------|
| **Sequential** | Simple, fast, good locality | Requires compaction/copying | Moving collectors |
| **First-fit** | Simple, reasonable performance | Small fragments accumulate | General use |
| **Best-fit** | Low wasted space | Slower search | Space-constrained |
| **Segregated-fits** | Fast (constant time for common sizes) | Internal fragmentation | Production systems |
| **TLABs** | Eliminates contention | TLAB waste, sizing complexity | Multithreaded |

Allocation cannot be considered independently of collection. Non-moving collectors demand free-list approaches; copying and compacting collectors suit sequential allocation. Block-based allocation reduces per-object overheads and fits well with organizations supporting multiple spaces. Fragmentation is inevitable but can be managed through size classes, coalescing, and occasional compaction.
