# Thread-Local Free-List Allocator with Concurrent Mark-Sweep GC

## Overview

This design combines **thread-local free-list allocation** with a **non-moving concurrent mark-sweep garbage collector**, inspired by systems like JVM HotSpot's TLAB+CMS, MMTk mark-sweep spaces, and the existing ObjectPool implementation in this codebase.

### Key Difference from Current TLAB Design

**Current TLAB**: Bump-pointer allocation within thread-local buffers (fast linear allocation)

**This Design**: Size-segregated free-list allocation within thread-local buffers (optimized for fixed-size object recycling)

## Architecture Components

### 1. Global OldGen Pool
- Manages the entire old generation memory space
- Provides blocks of memory to threads via TLAB allocator
- Maintains size-segregated free lists for different object sizes
- Runs the concurrent mark-sweep collector

### 2. TLAB (Thread-Local Allocation Buffer)
- Allocates blocks of memory from OldGen for exclusive thread use
- Provides free lists (as arrays) to program threads
- Manages block ownership and return to OldGen
- No synchronization needed during fast-path allocation

### 3. ObjectPool Integration
- Leverages existing `ObjectPool<T>` infrastructure
- Provides bin-based recycling of fixed-size objects
- Thread-local caching of full/empty bins
- Gatherer mechanism for consolidating partial bins

### 4. Size-Segregated Free Lists
- Separate free lists for common object sizes (e.g., 16, 24, 32, 48, 64, 128 bytes)
- Reduces fragmentation by grouping similar-sized objects
- Allows efficient recycling during sweep phase

## Memory Model

```
Old Generation Space:
┌────────────────────────────────────────────────────────────────┐
│                         OldGen Pool                            │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │  Size Class 16B  │  │  Size Class 32B  │  │  Size 64B... │ │
│  │  ┌────────────┐  │  │  ┌────────────┐  │  │              │ │
│  │  │ Free List  │  │  │  │ Free List  │  │  │              │ │
│  │  │ (recycled) │  │  │  │ (recycled) │  │  │              │ │
│  │  └────────────┘  │  │  └────────────┘  │  │              │ │
│  │                  │  │                  │  │              │ │
│  │  ┌────────────┐  │  │  ┌────────────┐  │  │              │ │
│  │  │ New Blocks │  │  │  │ New Blocks │  │  │              │ │
│  │  └────────────┘  │  │  └────────────┘  │  │              │ │
│  └──────────────────┘  └──────────────────┘  └──────────────┘ │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ Request free list for size class
                              ▼
┌────────────────────────────────────────────────────────────────┐
│                    Thread-Local TLAB                           │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Free List Array (e.g., 256 slots for 32-byte objects)  │  │
│  │  [obj₀][obj₁][obj₂]...[obj₂₅₅]                          │  │
│  │   │                                                       │  │
│  │   └─► Pop for allocation (O(1), no lock)                │  │
│  │                                                           │  │
│  │  Thread bumps index: free_list[--top]                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  When exhausted: Request new free list from OldGen            │
│  When block full: Return ownership to OldGen                  │
└────────────────────────────────────────────────────────────────┘
```

## Core Mechanisms

### Thread Requests Allocation Space

```cpp
// Thread wants to allocate 100 objects of size 32 bytes
FreeListArray* free_list = oldgen.requestFreeList(
    size_class = 32,
    count = 100
);

// Fast-path allocation (no synchronization)
void* obj = free_list->pop();  // O(1) array indexing
```

### OldGen Provides Free Lists

The OldGen can satisfy requests in two ways:

#### Option 1: Recycled Free List
Objects reclaimed during previous sweep are already available:
```cpp
// Return recycled objects as array
FreeListArray* oldgen.getFreeList(size, count) {
    if (recycled_lists[size].available >= count) {
        return recycled_lists[size].pop(count);
    }
    // Fall through to Option 2
}
```

#### Option 2: New Block Allocation
Allocate a fresh block and create free list:
```cpp
FreeListArray* oldgen.allocateNewBlock(size, count) {
    // Allocate contiguous block
    char* block = allocateBlock(size * count);

    // Create free list with special sentinel
    FreeListArray* list = new FreeListArray(block, size, count);
    list->setLazyInit();  // Special marker

    return list;
}
```

### Lazy Free List Initialization (Optimization)

Instead of setting up all pointers immediately, use a **special sentinel node**:

```cpp
struct FreeListArray {
    void* base_ptr;         // Start of block
    size_t obj_size;        // Size of each object
    size_t capacity;        // Total slots
    size_t top;             // Current position
    bool lazy_init;         // Special mode

    void* pop() {
        if (lazy_init) {
            // Sequential allocation from fresh block
            if (top < capacity) {
                void* result = base_ptr + (top * obj_size);
                top++;
                return result;
            }
            lazy_init = false;  // Exhausted, no longer lazy
        } else {
            // Normal free list pop
            if (top > 0) {
                return slots[--top];
            }
        }
        return nullptr;  // Exhausted
    }
};
```

**Optimization benefit**: Avoids O(n) initialization cost for fresh blocks. Objects are "virtually" in the free list and allocated sequentially on first use.

### Block Ownership and Return

```cpp
// Thread fills a block with live objects
void ThreadLocalAllocator::returnFilledBlock(Block* block) {
    // Transfer ownership back to OldGen
    oldgen.registerBlock(block);
}

// Thread exhausts free list
void ThreadLocalAllocator::requestMoreSpace() {
    if (current_list->isEmpty()) {
        // Return empty block (no live objects)
        oldgen.returnEmptyBlock(current_list);

        // Get new free list
        current_list = oldgen.requestFreeList(size_class, count);
    }
}
```

## Concurrent Mark-Sweep Collector

### Collector Thread Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  1. Concurrent Mark Phase                                   │
│     ┌─────────────────────────────────────────────────┐    │
│     │ • Start from roots                               │    │
│     │ • Use tri-color marking (White/Grey/Black)       │    │
│     │ • Mark objects using color bits in headers       │    │
│     │ • Program threads continue allocating            │    │
│     │ • Objects allocated during mark are Black        │    │
│     └─────────────────────────────────────────────────┘    │
│                         │                                    │
│                         ▼                                    │
│  2. Stop-the-World Finalization (brief)                     │
│     ┌─────────────────────────────────────────────────┐    │
│     │ • Pause program threads                          │    │
│     │ • Mark any new roots created during concurrent   │    │
│     │ • Ensure marking is complete                     │    │
│     └─────────────────────────────────────────────────┘    │
│                         │                                    │
│                         ▼                                    │
│  3. Concurrent Sweep Phase                                  │
│     ┌─────────────────────────────────────────────────┐    │
│     │ • Walk all allocated blocks                      │    │
│     │ • For each object:                               │    │
│     │   - White (unmarked) → Dead, add to free list    │    │
│     │   - Black (marked) → Live, reset to White        │    │
│     │ • Rebuild size-segregated free lists             │    │
│     │ • Program threads continue with allocation       │    │
│     └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Sweep Phase: Rebuilding Free Lists

```cpp
void OldGenSpace::sweepSizeClass(size_t size_class) {
    FreeList* recycled = new FreeList(size_class);

    // Walk all blocks registered for this size class
    for (Block* block : registered_blocks[size_class]) {
        char* ptr = block->start;
        char* end = block->end;

        while (ptr < end) {
            Header* hdr = (Header*)ptr;

            if (hdr->color == Color::White) {
                // Dead object - add to recycled free list
                recycled->push((void*)ptr);
            } else {
                // Live object - reset color for next cycle
                hdr->color = Color::White;
            }

            ptr += size_class;  // Fixed-size objects
        }
    }

    // Store recycled free list for future allocations
    recycled_lists[size_class] = recycled;
}
```

## Size Classes and Segregation

### Predefined Size Classes

Based on common Elm object sizes:

```cpp
constexpr size_t SIZE_CLASSES[] = {
    16,   // Small: Header only
    24,   // Header + 1 field
    32,   // Header + 2-3 fields (Tuple2, Cons)
    40,   // Header + 4 fields (Tuple3)
    48,   // Small Custom
    64,   // Medium Custom/Record
    96,   // Larger Custom/Record
    128,  // Large Custom/Record
    256,  // Very large
    // Large objects (>256) use free-list allocator
};

size_t getObjectSizeClass(size_t size) {
    for (size_t sc : SIZE_CLASSES) {
        if (size <= sc) return sc;
    }
    return 0;  // Use free-list for large objects
}
```

### Benefits of Size Segregation

1. **Reduced Fragmentation**: Objects of same size grouped together
2. **Efficient Recycling**: Sweep can batch free objects by size
3. **Fast Allocation**: Array indexing within size class (O(1))
4. **Cache Locality**: Similar objects likely accessed together
5. **Simple Free List**: No size metadata needed in free blocks

## Integration with Existing Code

### Relationship to Current TLAB Implementation

The current TLAB implementation uses **bump-pointer allocation**:
- Fast for short-lived nursery objects
- Excellent cache locality
- Simple evacuation during minor GC

This new design uses **free-list allocation**:
- Optimized for recycling old generation objects
- Non-moving (objects stay in place)
- Better for long-lived objects with mixed lifetimes

**Both can coexist**:
- **Nursery**: Keep current bump-pointer TLAB for minor GC promotions
- **OldGen**: Add this free-list TLAB for old generation allocation

### Integration with ObjectPool

The existing `ObjectPool<T>` can be adapted:

```cpp
// Current ObjectPool: Manages bins of objects
ObjectPool<ElmObject> pool;
ElmObject* obj = pool.allocate();

// New design: OldGen provides bins as free-list arrays
class OldGenSpace {
    ObjectPoolManager<FreeListArray> size_class_pools[NUM_SIZE_CLASSES];

    FreeListArray* requestFreeList(size_t size, size_t count) {
        size_t sc = getSizeClass(size);

        // Get from pool or create new
        FreeListArray* list = size_class_pools[sc].getLocalPool()->allocate();
        if (!list) {
            list = allocateNewBlock(sc, count);
        }
        return list;
    }
};
```

The `ObjectPool` naturally handles:
- Thread-local caching of full/empty bins
- Global pool coordination
- Gatherer for partial bins on thread exit

### Coexistence with Current Mark-Sweep

The existing OldGenSpace already has mark-sweep:
- **Mark**: Uses tri-color algorithm (already implemented)
- **Sweep**: Currently walks free-list region

**New sweep logic**:
```cpp
void OldGenSpace::sweep() {
    // Part 1: Sweep size-segregated blocks (NEW)
    for (size_t sc : SIZE_CLASSES) {
        sweepSizeClass(sc);
    }

    // Part 2: Sweep free-list region (EXISTING)
    sweepFreeListRegion();

    // Part 3: Sweep sealed TLABs (EXISTING)
    sweepSealedTLABs();
}
```

## Allocation Fast Path

### Thread-Local Allocation (No Lock)

```cpp
class ThreadLocalOldGenAllocator {
    FreeListArray* current_lists[NUM_SIZE_CLASSES];

    void* allocate(size_t size) {
        size_t sc = getSizeClass(size);

        // Fast path: Pop from thread-local free list (no sync!)
        void* obj = current_lists[sc]->pop();

        if (obj) {
            return obj;  // Success!
        }

        // Slow path: Request new free list
        current_lists[sc] = oldgen.requestFreeList(sc, DEFAULT_COUNT);
        return current_lists[sc]->pop();
    }
};
```

**Performance**:
- **Fast path**: Array index + bounds check (~5 cycles)
- **No synchronization**: Thread-local only
- **No cache misses**: Sequential access within block

## Memory Layout Example

### Size Class 32 Bytes

```
Block of 256 objects (8KB total):
┌────────────────────────────────────────────────────────────┐
│ [Obj 0: 32B] [Obj 1: 32B] [Obj 2: 32B] ... [Obj 255: 32B] │
└────────────────────────────────────────────────────────────┘
     │              │              │                │
     │              │              │                │
  Header+Data   Header+Data   Header+Data      Header+Data

Free List Array (thread-local):
┌────────────────────────────────────────┐
│ slots: [255] → Obj 255                 │
│        [254] → Obj 254                 │
│        [253] → Obj 253                 │
│        ...                             │
│        [0]   → Obj 0                   │
│ top: 256 (all available)               │
└────────────────────────────────────────┘

After allocating 3 objects:
┌────────────────────────────────────────┐
│ slots: [255] → Obj 255                 │
│        [254] → Obj 254                 │
│        [253] → Obj 253 ← top = 253     │
│        [252] → (allocated)             │
│        [251] → (allocated)             │
│        [250] → (allocated)             │
│        ...                             │
└────────────────────────────────────────┘
```

## Performance Characteristics

### Allocation Performance

| Operation | Current TLAB | Free-List TLAB | Notes |
|-----------|--------------|----------------|-------|
| Fast path | 5-10 cycles | 5-10 cycles | Both are pointer arithmetic |
| Synchronization | None | None | Both are thread-local |
| Cache locality | Excellent | Good | Bump-pointer slightly better |
| Recycling benefit | None | Excellent | Free-list reuses memory |

### GC Performance

| Phase | Cost | Concurrency |
|-------|------|-------------|
| Mark | O(live set) | Concurrent with mutation |
| Finalize | O(new roots) | Stop-the-world (brief) |
| Sweep | O(heap size) | Concurrent with mutation |

### Fragmentation Characteristics

**Current TLAB**: Can fragment when objects die at different rates
**Free-List TLAB**: Segregated by size reduces fragmentation significantly

**Example**:
- 32-byte objects only share blocks with other 32-byte objects
- No wasted space from splitting/coalescing
- Dead objects immediately recyclable (exact fit)

## Implementation Strategy

### Phase 1: Size-Segregated Block Management

```cpp
class SizeSegregatedAllocator {
    struct SizeClass {
        size_t obj_size;
        std::vector<Block*> blocks;
        FreeList recycled;
        std::mutex mutex;  // For block registration
    };

    SizeClass size_classes[NUM_SIZE_CLASSES];

    Block* allocateBlock(size_t size_class, size_t count);
    void registerBlock(size_t size_class, Block* block);
    FreeListArray* requestFreeList(size_t size_class, size_t count);
};
```

### Phase 2: Free List Array Structure

```cpp
struct FreeListArray {
    void** slots;           // Array of object pointers
    char* base_block;       // For lazy initialization
    size_t capacity;        // Number of slots
    size_t top;             // Stack pointer
    size_t obj_size;        // Size of each object
    bool lazy_init;         // Lazy mode flag

    void* pop();
    bool push(void* obj);
    bool isEmpty() const;
    bool isFull() const;
};
```

### Phase 3: Thread-Local Allocator

```cpp
class ThreadLocalOldGenAllocator {
    FreeListArray* current_lists[NUM_SIZE_CLASSES];
    SizeSegregatedAllocator* global_allocator;

    void* allocate(size_t size);
    void free(void* obj, size_t size);
    void returnBlock(size_t size_class, Block* block);
    ~ThreadLocalOldGenAllocator();  // Return blocks on thread exit
};
```

### Phase 4: Modified Sweep

```cpp
void OldGenSpace::sweep() {
    // For each size class
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        size_t obj_size = SIZE_CLASSES[i];
        FreeList recycled;

        // Walk all blocks in this size class
        for (Block* block : size_classes[i].blocks) {
            sweepBlock(block, obj_size, &recycled);
        }

        // Store recycled list for future allocations
        size_classes[i].recycled = recycled;
    }
}

void sweepBlock(Block* block, size_t obj_size, FreeList* recycled) {
    char* ptr = block->start;
    while (ptr < block->end) {
        Header* hdr = (Header*)ptr;

        if (hdr->color == Color::White) {
            recycled->push(ptr);  // Dead → recycle
        } else {
            hdr->color = Color::White;  // Live → reset
        }

        ptr += obj_size;  // Fixed-size stride
    }
}
```

## Edge Cases and Solutions

### 1. Large Objects (>256 bytes)

**Solution**: Fall back to existing free-list allocator
```cpp
void* allocate(size_t size) {
    if (size > MAX_SIZE_CLASS) {
        return oldgen.allocate(size);  // Use free-list
    }
    // Use size-segregated allocator
}
```

### 2. Thread Exit with Partial Blocks

**Solution**: Use gatherer mechanism (already in ObjectPool)
```cpp
~ThreadLocalOldGenAllocator() {
    for (size_t sc = 0; sc < NUM_SIZE_CLASSES; sc++) {
        if (current_lists[sc] && !current_lists[sc]->isEmpty()) {
            global_allocator->gatherPartialList(sc, current_lists[sc]);
        }
    }
}
```

### 3. Allocation During Concurrent Mark

**Solution**: Conservatively mark new objects as Black
```cpp
void* allocate(size_t size) {
    void* obj = free_list->pop();

    Header* hdr = (Header*)obj;
    if (marking_active) {
        hdr->color = Color::Black;  // Born during mark = live
    }

    return obj;
}
```

### 4. Block Exhaustion

**Solution**: Request more blocks from global allocator
```cpp
FreeListArray* requestFreeList(size_t sc, size_t count) {
    // Try recycled first
    if (size_classes[sc].recycled.available >= count) {
        return size_classes[sc].recycled.popArray(count);
    }

    // Allocate new block
    return allocateNewBlock(sc, count);
}
```

## Advantages Over Current Design

### For OldGen Allocation

1. **Object Recycling**: Dead objects become available immediately after sweep
2. **Non-Moving**: Objects stay at same address (simpler, no pointer updates)
3. **Size-Optimized**: Each size class is independently managed
4. **Concurrent-Friendly**: Mark-sweep naturally works with free lists

### For Multi-Threaded Workloads

1. **Zero Contention Fast Path**: Thread-local free list access
2. **Scalable**: Each thread operates independently
3. **Fair**: No global lock contention
4. **Predictable**: Fixed-size allocation is deterministic

### For Memory Efficiency

1. **Low Fragmentation**: Size segregation groups similar objects
2. **High Reuse**: Recycled objects fit perfectly (no splitting)
3. **Tunable**: Size classes can be adjusted based on profiling
4. **Compact**: No metadata overhead in free blocks

## Trade-offs and Considerations

### Advantages
- ✅ Excellent recycling of old generation objects
- ✅ Non-moving (no pointer fixup complexity)
- ✅ Thread-local allocation (no synchronization)
- ✅ Size-segregated (low fragmentation)
- ✅ Works naturally with concurrent mark-sweep

### Disadvantages
- ❌ More complex than bump-pointer allocation
- ❌ Requires size class tuning
- ❌ Multiple free lists to manage
- ❌ Some memory overhead per size class
- ❌ Lazy initialization adds code complexity

### When to Use This Design

**Best for**:
- Long-lived objects in old generation
- Mixed object lifetimes (some die, some survive)
- Multi-threaded allocation workloads
- Systems where recycling is important

**Not ideal for**:
- Short-lived nursery objects (use bump-pointer TLAB)
- Single-threaded workloads (free-list complexity not worth it)
- Extremely tight memory budgets (overhead per size class)

## Compatibility with Existing System

### Can Coexist With Current TLAB

```
Memory Layout:
┌──────────────────────────────────────────────────────┐
│  Old Gen Space                                       │
│  ┌────────────────┐  ┌────────────────────────────┐ │
│  │  Free-List     │  │  Size-Segregated Blocks    │ │
│  │  Region        │  │  (NEW)                     │ │
│  │  (for large    │  │  ┌──────┐ ┌──────┐        │ │
│  │   objects)     │  │  │ 16B  │ │ 32B  │ ...    │ │
│  │                │  │  └──────┘ └──────┘        │ │
│  └────────────────┘  └────────────────────────────┘ │
│                                                      │
│  ┌────────────────────────────────────────────────┐ │
│  │  Bump-Pointer TLAB Region (EXISTING)          │ │
│  │  [TLAB 1] [TLAB 2] [TLAB 3] ...               │ │
│  └────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

### Allocation Strategy

```cpp
void* OldGenSpace::allocate(size_t size, AllocStrategy strategy) {
    if (strategy == PROMOTION) {
        // Use bump-pointer TLAB (existing)
        return promotion_tlab->allocate(size);
    } else {
        // Use free-list TLAB (new)
        return size_segregated->allocate(size);
    }
}
```

## Conclusion

This design provides a **robust, scalable thread-local free-list allocator** that:

1. **Integrates naturally** with the existing ObjectPool infrastructure
2. **Complements** the current bump-pointer TLAB for nursery promotions
3. **Optimizes** old generation allocation through size segregation and recycling
4. **Scales** to multi-threaded workloads with zero contention on fast path
5. **Works seamlessly** with concurrent mark-sweep GC

The lazy initialization optimization and size segregation make this design particularly suitable for Elm's immutable object model, where objects of specific sizes (tuples, records, customs) dominate the heap.
