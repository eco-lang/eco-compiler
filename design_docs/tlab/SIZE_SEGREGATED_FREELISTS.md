# Size-Segregated Free List Management

## Overview

Size segregation is the core strategy for managing memory efficiently in the thread-local free-list allocator. By grouping objects of the same size together, we achieve:

1. **Zero internal fragmentation** within blocks
2. **Fast allocation** via array indexing
3. **Efficient recycling** after garbage collection
4. **Cache-friendly** access patterns

## Size Class Definition

### Predefined Size Classes

Based on analysis of Elm object sizes:

```cpp
// Size classes in bytes (8-byte aligned)
constexpr size_t SIZE_CLASSES[] = {
    16,   // Tiny:   Header only (ElmInt, ElmFloat, ElmChar)
    24,   // Small:  Header + 1 field (some Records)
    32,   // Normal: Header + 2-3 fields (Tuple2, Cons, small Custom)
    40,   // Medium: Header + 4 fields (Tuple3)
    48,   // Large:  Small Custom with 3-4 fields
    64,   // XLarge: Medium Custom/Record (5-7 fields)
    96,   // 2XL:    Larger Custom/Record (9-11 fields)
    128,  // 3XL:    Large Custom/Record (13-15 fields)
    256,  // 4XL:    Very large Custom/Record/Closure
    // Objects > 256 bytes use free-list allocator
};

constexpr size_t NUM_SIZE_CLASSES = sizeof(SIZE_CLASSES) / sizeof(SIZE_CLASSES[0]);
constexpr size_t MAX_SIZE_CLASS = 256;
```

### Size Class Selection

```cpp
// Map object size to size class (round up)
size_t getSizeClass(size_t size) {
    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        if (size <= SIZE_CLASSES[i]) {
            return i;
        }
    }
    return SIZE_CLASS_INVALID;  // Too large, use free-list
}

// Get size class index for direct indexing
size_t getSizeClassIndex(size_t size) {
    size_t sc = getSizeClass(size);
    if (sc == SIZE_CLASS_INVALID) {
        throw std::runtime_error("Object too large for size classes");
    }
    return sc;
}
```

### Tuning Size Classes

Size classes can be tuned based on profiling:

```cpp
// Profile allocation sizes during execution
struct AllocationProfile {
    std::map<size_t, size_t> size_histogram;  // size → count

    void record(size_t size) {
        size_histogram[size]++;
    }

    // Suggest optimal size classes
    std::vector<size_t> suggestSizeClasses(size_t num_classes) {
        // Find most common sizes
        // Use k-means clustering to group sizes
        // Return optimal size class boundaries
    }
};
```

## Block Structure

### Fixed-Size Block Layout

Each block contains objects of exactly one size class:

```
Block for 32-byte objects (8KB block = 256 objects):
┌─────────────────────────────────────────────────────────────┐
│ [Obj 0] [Obj 1] [Obj 2] [Obj 3] ... [Obj 254] [Obj 255]    │
│  32 B    32 B    32 B    32 B         32 B     32 B         │
└─────────────────────────────────────────────────────────────┘
  ^                                                      ^
  block->start                                      block->end

Each object:
┌──────────┬─────────────────────────┐
│  Header  │      Payload (24B)      │
│   (8B)   │                         │
└──────────┴─────────────────────────┘
```

### Block Metadata

```cpp
struct Block {
    char* start;              // Start address of block
    char* end;                // End address (start + obj_size * count)
    size_t obj_size;          // Size of objects in this block
    size_t obj_count;         // Number of objects in block
    size_t size_class_index;  // Which size class this belongs to
    size_t live_count;        // Number of live objects (after sweep)
    size_t dead_count;        // Number of dead objects (after sweep)

    Block(char* start, size_t obj_size, size_t obj_count)
        : start(start),
          end(start + obj_size * obj_count),
          obj_size(obj_size),
          obj_count(obj_count),
          live_count(0),
          dead_count(0) {}

    bool contains(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= start && p < end;
    }

    // Get object index within block
    size_t getObjectIndex(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        return (p - start) / obj_size;
    }
};
```

## Size Class Management

### Per-Size-Class State

```cpp
struct SizeClass {
    size_t obj_size;                    // Size of objects in this class
    std::vector<Block*> blocks;         // All blocks for this size class
    FreeList recycled;                  // Recycled objects from sweep
    std::mutex mutex;                   // Protects blocks and recycled list
    std::atomic<size_t> total_objects;  // Total objects allocated
    std::atomic<size_t> live_objects;   // Live objects (updated after sweep)

    SizeClass(size_t obj_size)
        : obj_size(obj_size),
          total_objects(0),
          live_objects(0) {}

    // Allocation rate (objects per second)
    double allocationRate() const {
        // Track over time window
    }

    // Survival rate (live / total)
    double survivalRate() const {
        return (double)live_objects / total_objects;
    }
};
```

### Global Size Class Array

```cpp
class SizeSegregatedAllocator {
private:
    SizeClass size_classes[NUM_SIZE_CLASSES];

public:
    SizeSegregatedAllocator() {
        // Initialize size classes
        for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
            size_classes[i] = SizeClass(SIZE_CLASSES[i]);
        }
    }

    SizeClass& getSizeClass(size_t size) {
        size_t index = getSizeClassIndex(size);
        return size_classes[index];
    }
};
```

## Free List Structures

### Global Free List (Linked List)

Used by the collector to accumulate dead objects during sweep:

```cpp
class FreeList {
private:
    struct FreeNode {
        FreeNode* next;
    };

    FreeNode* head;
    size_t count;
    std::mutex mutex;  // For thread-safe access

public:
    FreeList() : head(nullptr), count(0) {}

    // Add dead object to free list
    void push(void* obj) {
        std::lock_guard<std::mutex> lock(mutex);

        FreeNode* node = static_cast<FreeNode*>(obj);
        node->next = head;
        head = node;
        count++;
    }

    // Remove object from free list
    void* pop() {
        std::lock_guard<std::mutex> lock(mutex);

        if (!head) return nullptr;

        void* obj = head;
        head = head->next;
        count--;
        return obj;
    }

    // Batch pop: fill array with up to max_count objects
    size_t popBatch(void** array, size_t max_count) {
        std::lock_guard<std::mutex> lock(mutex);

        size_t popped = 0;
        while (head && popped < max_count) {
            array[popped++] = head;
            head = head->next;
            count--;
        }
        return popped;
    }

    size_t size() const { return count; }
    bool empty() const { return count == 0; }
};
```

### Thread-Local Free List Array

Used by mutator threads for fast allocation:

```cpp
struct FreeListArray {
    void** slots;           // Array of object pointers
    size_t capacity;        // Maximum objects
    size_t top;             // Current stack pointer (next free slot)

    // For lazy initialization
    char* base_block;       // Base address of fresh block
    size_t obj_size;        // Size of each object
    bool lazy_init;         // Lazy mode enabled?

    FreeListArray(size_t capacity)
        : capacity(capacity),
          top(0),
          base_block(nullptr),
          obj_size(0),
          lazy_init(false) {
        slots = new void*[capacity];
    }

    ~FreeListArray() {
        delete[] slots;
    }

    // Pop object (allocation)
    void* pop() {
        if (lazy_init) {
            // Lazy mode: generate objects sequentially
            if (top < capacity) {
                void* obj = base_block + (top * obj_size);
                top++;
                return obj;
            }
            // Exhausted, disable lazy mode
            lazy_init = false;
            return nullptr;
        } else {
            // Normal mode: pop from array
            if (top > 0) {
                return slots[--top];
            }
            return nullptr;
        }
    }

    // Push object (free/return)
    bool push(void* obj) {
        if (lazy_init) {
            // Cannot push in lazy mode
            return false;
        }

        if (top >= capacity) {
            return false;  // Full
        }

        slots[top++] = obj;
        return true;
    }

    bool isEmpty() const { return top == 0 && !lazy_init; }
    bool isFull() const { return top >= capacity && !lazy_init; }
    size_t size() const { return lazy_init ? 0 : top; }
};
```

## Lazy Initialization Optimization

### Motivation

When allocating a new block, we could eagerly initialize a free list:

```cpp
// EAGER (slow):
FreeListArray* array = new FreeListArray(256);
for (size_t i = 0; i < 256; i++) {
    array->slots[i] = block_start + (i * obj_size);
}
// Cost: O(n) initialization
```

But this is wasteful if objects are allocated sequentially anyway!

### Lazy Approach

Instead, mark the array as "lazy" and generate addresses on-demand:

```cpp
// LAZY (fast):
FreeListArray* array = new FreeListArray(256);
array->base_block = block_start;
array->obj_size = obj_size;
array->lazy_init = true;
// Cost: O(1) initialization

// On first pop:
void* obj = array->pop();  // Returns block_start + (0 * obj_size)
// On second pop:
void* obj = array->pop();  // Returns block_start + (1 * obj_size)
// ...
```

### Implementation

```cpp
void* FreeListArray::pop() {
    if (lazy_init) {
        if (top < capacity) {
            // Compute address on-the-fly
            void* obj = base_block + (top * obj_size);
            top++;

            // Initialize object header
            Header* hdr = static_cast<Header*>(obj);
            memset(hdr, 0, sizeof(Header));

            return obj;
        }

        // Exhausted
        lazy_init = false;
        top = 0;  // Reset for reuse
        return nullptr;
    } else {
        // Normal free-list mode
        if (top > 0) {
            return slots[--top];
        }
        return nullptr;
    }
}
```

**Cost**: O(1) per allocation, no upfront initialization cost

### When to Use Lazy Mode

- **New blocks**: Objects never allocated before
- **Low fragmentation**: Expect most objects to be allocated sequentially
- **Fresh TLABs**: Thread just requested new allocation space

### When to Use Normal Mode

- **Recycled free lists**: Objects reclaimed from GC sweep
- **High fragmentation**: Objects scattered throughout memory
- **Partial lists**: Not all objects available sequentially

## Block Allocation Strategy

### Default Block Size

```cpp
// Default: 256 objects per block
constexpr size_t DEFAULT_OBJECTS_PER_BLOCK = 256;

size_t getDefaultBlockSize(size_t obj_size) {
    return obj_size * DEFAULT_OBJECTS_PER_BLOCK;
}
```

**Example**:
- 32-byte objects: 256 × 32 = 8 KB per block
- 64-byte objects: 256 × 64 = 16 KB per block
- 128-byte objects: 256 × 128 = 32 KB per block

### Adaptive Block Sizing

Adjust block size based on size class:

```cpp
size_t getAdaptiveBlockSize(size_t obj_size) {
    // Smaller objects = larger blocks (more objects)
    // Larger objects = smaller blocks (fewer objects)

    if (obj_size <= 32) {
        return obj_size * 512;  // 16 KB for 32-byte objects
    } else if (obj_size <= 64) {
        return obj_size * 256;  // 16 KB for 64-byte objects
    } else if (obj_size <= 128) {
        return obj_size * 128;  // 16 KB for 128-byte objects
    } else {
        return obj_size * 64;   // 16 KB for 256-byte objects
    }
}
```

**Rationale**: Keep block size roughly constant (~16 KB) across size classes

### Block Allocation

```cpp
Block* SizeClass::allocateBlock() {
    size_t block_size = getAdaptiveBlockSize(obj_size);
    size_t obj_count = block_size / obj_size;

    // Allocate memory
    void* mem = mmap(nullptr, block_size,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS,
                     -1, 0);

    if (mem == MAP_FAILED) {
        throw std::bad_alloc();
    }

    // Create block metadata
    Block* block = new Block(static_cast<char*>(mem), obj_size, obj_count);

    // Register block
    std::lock_guard<std::mutex> lock(mutex);
    blocks.push_back(block);
    total_objects += obj_count;

    return block;
}
```

## Request and Return Flow

### Thread Requests Free List

```cpp
FreeListArray* SizeSegregatedAllocator::requestFreeList(
    size_t size,
    size_t requested_count = DEFAULT_OBJECTS_PER_BLOCK
) {
    SizeClass& sc = getSizeClass(size);

    std::lock_guard<std::mutex> lock(sc.mutex);

    // Try recycled free list first
    if (sc.recycled.size() >= requested_count) {
        // Batch pop from recycled list
        FreeListArray* array = new FreeListArray(requested_count);
        size_t popped = sc.recycled.popBatch(array->slots, requested_count);
        array->top = popped;
        array->lazy_init = false;  // Normal mode
        return array;
    }

    // Not enough recycled, allocate new block
    Block* block = sc.allocateBlock();

    // Return as lazy-initialized array
    FreeListArray* array = new FreeListArray(block->obj_count);
    array->base_block = block->start;
    array->obj_size = block->obj_size;
    array->lazy_init = true;  // Lazy mode!

    return array;
}
```

### Thread Returns Filled Block

```cpp
void SizeSegregatedAllocator::returnFilledBlock(Block* block) {
    // Block is full of live objects, nothing to do
    // Objects are already tracked in blocks vector
    // GC will sweep them in next cycle
}
```

### Thread Returns Empty/Partial List

```cpp
void SizeSegregatedAllocator::returnPartialList(
    size_t size,
    FreeListArray* array
) {
    SizeClass& sc = getSizeClass(size);

    std::lock_guard<std::mutex> lock(sc.mutex);

    // Transfer objects back to recycled free list
    while (!array->isEmpty()) {
        void* obj = array->pop();
        sc.recycled.push(obj);
    }

    delete array;
}
```

## Sweep and Recycling

### Sweep Phase per Size Class

```cpp
void SizeClass::sweep() {
    std::lock_guard<std::mutex> lock(mutex);

    // Clear old recycled list
    recycled = FreeList();

    size_t total_live = 0;
    size_t total_dead = 0;

    // Walk all blocks in this size class
    for (Block* block : blocks) {
        char* ptr = block->start;

        while (ptr < block->end) {
            Header* hdr = reinterpret_cast<Header*>(ptr);

            if (hdr->color == static_cast<u32>(Color::White)) {
                // Dead object
                recycled.push(ptr);
                total_dead++;
            } else {
                // Live object
                hdr->color = static_cast<u32>(Color::White);  // Reset
                total_live++;
            }

            ptr += obj_size;  // Fixed-size stride
        }

        // Update block statistics
        block->live_count = total_live;
        block->dead_count = total_dead;
    }

    // Update size class statistics
    live_objects = total_live;
}
```

### Parallel Sweep

Since size classes are independent, sweep can be parallelized:

```cpp
void SizeSegregatedAllocator::parallelSweep() {
    std::vector<std::thread> workers;

    for (size_t i = 0; i < NUM_SIZE_CLASSES; i++) {
        workers.emplace_back([this, i]() {
            size_classes[i].sweep();
        });
    }

    for (auto& w : workers) {
        w.join();
    }
}
```

**Speedup**: Near-linear with number of size classes (up to NUM_SIZE_CLASSES cores)

## Fragmentation Analysis

### Internal Fragmentation

**Definition**: Wasted space within allocated objects

**Size-segregated approach**:
- Objects rounded up to next size class
- Example: 30-byte object allocated in 32-byte class → 2 bytes wasted
- Average waste: ~12.5% per allocation (for uniform distribution)

**Mitigation**:
- Choose size classes to match common object sizes
- Profile allocation sizes and adjust classes

### External Fragmentation

**Definition**: Wasted space between allocated objects

**Size-segregated approach**:
- **Within blocks**: Zero! (all objects same size)
- **Between blocks**: Possible if entire blocks are empty

**Example**:
```
Block with 256 32-byte objects:
[Live][Dead][Dead][Live][Dead]...[Live]
      └────┬────┘     └────┬────┘
     Recycled     Recycled

After sweep:
- Dead objects added to free list
- Live objects stay in place
- No compaction needed
```

### Comparison with Traditional Free List

| Metric | Traditional | Size-Segregated |
|--------|-------------|-----------------|
| Internal frag | Variable | Bounded (~12.5%) |
| External frag | High | Low |
| Allocation speed | O(n) walk | O(1) array access |
| Coalescing needed | Yes | No |

## Memory Overhead

### Per Size Class

```cpp
sizeof(SizeClass) =
    8 (obj_size) +
    24 (vector<Block*>) +
    24 (FreeList) +
    40 (mutex) +
    16 (atomics) +
    ... (padding)
  ≈ 128 bytes
```

**Total**: 128 × 9 size classes = **1,152 bytes**

### Per Block

```cpp
sizeof(Block) =
    8 (start) +
    8 (end) +
    8 (obj_size) +
    8 (obj_count) +
    8 (size_class_index) +
    8 (live_count) +
    8 (dead_count)
  = 56 bytes
```

**Example**: 1,000 blocks = **56 KB metadata**

### Per Thread-Local Array

```cpp
sizeof(FreeListArray) =
    8 (slots pointer) +
    8 (capacity) +
    8 (top) +
    8 (base_block) +
    8 (obj_size) +
    1 (lazy_init) +
    7 (padding)
  = 48 bytes

Array storage:
    capacity * 8 (pointer per slot)
```

**Example**: 256-object array = 48 + 2,048 = **2,096 bytes**

### Total Overhead

For a typical workload:
- 9 size classes: 1 KB
- 100 blocks: 6 KB
- 10 threads × 9 arrays: 180 KB

**Total**: ~187 KB overhead for managing GBs of heap

**Overhead percentage**: <0.02% of 1 GB heap

## Performance Characteristics

### Allocation

```cpp
// Fast path: O(1) array access
void* obj = array->pop();
```

**Cost**:
- Array bounds check: 2 cycles
- Load pointer: 1 cycle
- Decrement top: 1 cycle
- **Total**: ~4-5 cycles

### Deallocation (Sweep)

```cpp
// Walk block: O(n) where n = objects in block
for (each object in block) {
    if (color == White) {
        recycled.push(obj);  // O(1)
    }
}
```

**Cost**:
- Per object: 5-10 cycles (header check + push)
- Per block (256 objects): ~2,000 cycles
- Per size class (10 blocks): ~20,000 cycles

### Block Request

```cpp
// Request new free list: O(1) amortized
FreeListArray* array = requestFreeList(size, count);
```

**Cost**:
- Recycled list check: O(1)
- New block allocation: O(1) amortized
- **Total**: 100-1,000 cycles (rare)

## Tuning Guidelines

### Choosing Size Classes

1. **Profile allocation sizes** in production workload
2. **Identify peaks** in size histogram
3. **Set size classes** to cover peaks with <15% waste
4. **Test and iterate**

### Choosing Block Size

1. **Target 8-16 KB per block** (good cache locality)
2. **Adjust for large objects** (fewer objects per block)
3. **Consider allocation rate** (high rate = larger blocks)

### Choosing Array Size

1. **Match block size** (one array per block)
2. **Consider thread count** (more threads = smaller arrays)
3. **Balance**: Too small = frequent requests, too large = waste

## Conclusion

Size-segregated free lists provide:

- ✅ **O(1) allocation** via array indexing
- ✅ **Zero internal fragmentation** within blocks
- ✅ **Efficient recycling** after GC sweep
- ✅ **Thread-local operation** with minimal synchronization
- ✅ **Tunable** to workload characteristics

The lazy initialization optimization makes fresh block allocation extremely fast, while recycled free lists ensure efficient memory reuse. This design is ideal for long-lived objects in the old generation where recycling is valuable.
