# Thread-Segregated Generational GC Design

## Executive Summary

This document outlines a refactoring plan to transform eco-runtime's GC from the current architecture (thread-local nurseries + shared old gen) to a fully thread-segregated design where each thread owns both its nursery and old generation. This design is particularly well-suited to Elm's immutable semantics.

## Current Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Unified Heap (1 GB)                       │
├─────────────────────────────────┬───────────────────────────┤
│      Shared Old Generation      │   Thread-Local Nurseries  │
│       (Mark-and-Sweep)          │    (Cheney Semi-space)    │
│         [0 .. 512MB)            │     [512MB .. 1GB)        │
│                                 ├───────┬───────┬───────────┤
│    ┌─────────────────────┐      │ T1    │ T2    │ T3 ...    │
│    │ Free-list + TLABs   │      │Nursery│Nursery│           │
│    │ Concurrent mark     │      │ 4MB   │ 4MB   │           │
│    │ Compaction          │      └───────┴───────┴───────────┤
└─────────────────────────────────┴───────────────────────────┘
```

**Problems with current design:**
1. Old gen requires locking (TLABs help, but sweep/compaction still global)
2. Major GC requires stop-the-world for ALL threads
3. Old gen size is shared resource contention
4. Complex: mark-sweep + free-list + TLABs + compaction

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Heap (Per-Thread)                             │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    Thread 1 Private Heap                      │   │
│  │  ┌─────────────────────┐  ┌───────────────────────────────┐  │   │
│  │  │    Nursery (G0)     │  │      Old Generation (G1)      │  │   │
│  │  │   Semi-space copy   │  │       Semi-space copy         │  │   │
│  │  │  ┌──────┬──────┐    │  │    ┌──────────┬──────────┐    │  │   │
│  │  │  │ from │  to  │    │  │    │   from   │    to    │    │  │   │
│  │  │  │ 2MB  │ 2MB  │    │  │    │  16MB    │   16MB   │    │  │   │
│  │  │  └──────┴──────┘    │  │    └──────────┴──────────┘    │  │   │
│  │  └─────────────────────┘  └───────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    Thread 2 Private Heap                      │   │
│  │              ... (same structure) ...                         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │         Optional: Shared Heap (for escaped objects)          │   │
│  │              Mark-sweep (collected rarely)                    │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Design Rationale

### Why Thread-Segregated?

1. **No synchronization for most GC operations** - each thread collects independently
2. **Bounded pause times** - only the collecting thread pauses
3. **Better cache locality** - thread's working set stays together
4. **Simpler implementation** - same algorithm (Cheney) for both generations
5. **Elm's immutability** - no write barriers needed EVEN between thread-local generations

### Why Semi-Space Copying for Old Gen?

The GC Handbook (Chapter 10.2) describes Erlang's approach:

> "Because Erlang does not allow destructive assignment, thread-local heaps can be collected independently. Local heaps are managed with a generational, stop-and-copy Cheney-style collector."

**Comparison of Old Gen Strategies:**

| Strategy | Memory | Fragmentation | Complexity | Pause Time |
|----------|--------|---------------|------------|------------|
| Semi-space copy | 2x | None | Low | Proportional to live data |
| Mark-sweep | 1x | High | Medium | Proportional to heap size |
| Mark-compact | 1x | None | High | 2-3x mark-sweep |
| Immix | 1.1x | Low | High | Medium |

**Recommendation: Semi-space copying** because:
- Same algorithm as nursery → code reuse
- Automatic compaction → no fragmentation
- Simple implementation → fewer bugs
- For Elm workloads, live data << heap size, so 2x overhead is acceptable

### Alternative: Appel-Style Flexible Generations

The Handbook (Section 9.7) describes Appel's collector:

> "The young generation can expand on demand until it fills all of the heap except that required by other spaces."

This allows the nursery and old gen to share a single address range, with the boundary moving based on survival rates. Consider this as a future optimization.

## Detailed Design

### 1. Memory Layout

```cpp
// Per-thread heap structure
struct ThreadHeap {
    // Nursery (Generation 0) - small, frequently collected
    char* nursery_memory;      // Total nursery space
    char* nursery_from;        // Current allocation space
    char* nursery_to;          // Copy target
    char* nursery_alloc;       // Bump pointer
    char* nursery_scan;        // Cheney scan pointer
    size_t nursery_capacity;   // Size of one semi-space

    // Old Generation (Generation 1) - larger, less frequent
    char* oldgen_memory;       // Total old gen space
    char* oldgen_from;         // Current allocation space
    char* oldgen_to;           // Copy target (or reserved)
    char* oldgen_alloc;        // Bump pointer
    char* oldgen_scan;         // Cheney scan pointer
    size_t oldgen_capacity;    // Size of one semi-space
    size_t oldgen_used;        // Bytes currently in use

    // Root set for this thread
    RootSet roots;

    // Configuration
    const GCConfig* config;

    // Statistics
    GCStats stats;
};
```

### 2. Sizing Recommendations

Based on Handbook guidance and Elm workload characteristics:

| Component | Size | Rationale |
|-----------|------|-----------|
| Nursery semi-space | 2 MB | Small for quick minor GCs (~1-5ms) |
| Old gen semi-space | 16-64 MB | Larger, collected less often |
| Max threads | 16-32 | 16 threads × 68MB = ~1GB per instance |

```cpp
// Suggested defaults in GCConfig
constexpr size_t THREAD_NURSERY_SIZE = 4 * 1024 * 1024;     // 4 MB total (2x2 MB)
constexpr size_t THREAD_OLDGEN_SIZE = 32 * 1024 * 1024;     // 32 MB total (2x16 MB)
constexpr size_t MAX_THREAD_HEAPS = 32;                      // Support up to 32 threads
```

### 3. Collection Algorithm

#### Minor GC (Nursery → Old Gen)

Unchanged from current implementation - Cheney's algorithm:

```
1. Flip from_space ↔ to_space
2. Evacuate roots to to_space OR promote to old gen if age >= PROMOTION_AGE
3. Cheney scan: walk to_space, evacuate children
4. Process promoted objects (scan for nursery pointers)
```

**Key change:** Promotion now goes to thread-local old gen via simple bump allocation (no TLAB needed since it's single-threaded).

#### Major GC (Old Gen compaction)

Also Cheney's algorithm, but operating on old gen:

```
1. Flip old_from ↔ old_to
2. Scan all roots (both nursery and old gen objects)
3. Evacuate live old gen objects to old_to
4. Cheney scan old_to until scan == alloc
5. Update any nursery objects pointing to moved old gen objects
```

**Critical insight from Elm semantics:**
- Old gen objects can ONLY point to OTHER old gen objects (older objects)
- Nursery objects MAY point to old gen objects
- Old gen objects NEVER point to nursery objects (immutability)

Therefore, major GC only needs to:
1. Trace from roots
2. Copy surviving old gen objects
3. Update pointers in nursery objects that referenced moved old gen objects

### 4. Pointer Update Strategy

When old gen objects move during major GC:

```cpp
void majorGC() {
    // Phase 1: Copy all live old gen objects, leaving forwarding pointers
    flipOldGen();
    evacuateRoots();  // May include nursery roots pointing to old gen
    cheneyScaonOldGen();

    // Phase 2: Update nursery objects that point to moved old gen objects
    // Walk entire nursery and update any pointers that hit forwarding pointers
    updateNurseryPointers();
}

void updateNurseryPointers() {
    char* ptr = nursery_from;
    while (ptr < nursery_alloc) {
        void* obj = ptr;
        scanAndUpdatePointers(obj);  // Follow forwarding pointers
        ptr += getObjectSize(obj);
    }
}
```

### 5. Handling Shared/Escaped Objects

For pure thread isolation (Erlang-style), objects that need to be shared are copied:

```cpp
// When sending a message to another thread:
HPointer sendMessage(ThreadHeap& target, HPointer obj) {
    // Deep copy the object graph to target's heap
    return deepCopyTo(target, obj);
}
```

Alternatively, provide an optional shared heap for objects that escape:

```cpp
struct SharedHeap {
    // Mark-sweep for long-lived shared objects
    // Collected when ALL threads are at safe points
    OldGenSpace shared;
};
```

### 6. GC Triggers

```cpp
// Minor GC trigger (unchanged)
if (nursery_alloc + size > nursery_from + nursery_capacity * 0.9) {
    minorGC();
}

// Major GC trigger (new)
// Option 1: When old gen is nearly full
if (oldgen_used > oldgen_capacity * 0.75) {
    majorGC();
}

// Option 2: After N minor GCs
if (minor_gc_count % 10 == 0) {
    majorGC();
}

// Option 3: Based on promotion rate
if (bytes_promoted_since_last_major > threshold) {
    majorGC();
}
```

## Refactoring Plan

### Phase 1: Create ThreadHeap Abstraction

**Files to modify:**
- `runtime/include/ThreadHeap.hpp` (NEW)
- `runtime/src/ThreadHeap.cpp` (NEW)

**Tasks:**

1.1. Create `ThreadHeap` class combining NurserySpace functionality:
```cpp
class ThreadHeap {
public:
    void initialize(char* base, size_t nursery_size, size_t oldgen_size, const GCConfig* config);
    void* allocate(size_t size, Tag tag);
    void minorGC();
    void majorGC();
    RootSet& getRootSet();
    // ...
private:
    // Nursery state
    char* nursery_memory;
    char* nursery_from;
    char* nursery_to;
    char* nursery_alloc;
    size_t nursery_capacity;

    // Old gen state
    char* oldgen_memory;
    char* oldgen_from;
    char* oldgen_to;
    char* oldgen_alloc;
    size_t oldgen_capacity;

    RootSet root_set;
    const GCConfig* config;
};
```

1.2. Implement old gen allocation (simple bump pointer):
```cpp
void* ThreadHeap::allocateOldGen(size_t size) {
    size = (size + 7) & ~7;  // Align
    if (oldgen_alloc + size > oldgen_from + oldgen_capacity) {
        return nullptr;  // Trigger major GC
    }
    void* result = oldgen_alloc;
    oldgen_alloc += size;
    return result;
}
```

1.3. Implement old gen Cheney copy (majorGC):
```cpp
void ThreadHeap::majorGC() {
    // Flip spaces
    std::swap(oldgen_from, oldgen_to);
    oldgen_alloc = oldgen_from;
    oldgen_scan = oldgen_from;

    // Evacuate roots (may include nursery pointers to old gen)
    for (HPointer* root : root_set.getRoots()) {
        evacuateToOldGen(*root);
    }

    // Also scan nursery for old gen pointers
    scanNurseryForOldGenPointers();

    // Cheney scan old gen
    while (oldgen_scan < oldgen_alloc) {
        void* obj = oldgen_scan;
        scanObjectOldGen(obj);
        oldgen_scan += getObjectSize(obj);
    }

    // Update any nursery pointers to moved old gen objects
    updateNurseryPointers();
}
```

### Phase 2: Modify NurserySpace

**Files to modify:**
- `runtime/include/NurserySpace.hpp`
- `runtime/src/NurserySpace.cpp`

**Tasks:**

2.1. Remove OldGenSpace dependency from minorGC:
```cpp
// Before:
void NurserySpace::minorGC(OldGenSpace& oldgen);

// After:
void NurserySpace::minorGC(ThreadHeap& heap);
// Or integrate NurserySpace into ThreadHeap entirely
```

2.2. Change promotion to use ThreadHeap's old gen:
```cpp
void NurserySpace::evacuate(HPointer& ptr, ThreadHeap& heap, ...) {
    // ...
    if (hdr->age >= config_->promotion_age) {
        // Promote to thread-local old gen (simple bump alloc)
        new_obj = heap.allocateOldGen(size);
        if (!new_obj) {
            heap.majorGC();  // Old gen full, collect first
            new_obj = heap.allocateOldGen(size);
        }
        // Copy and set up forwarding pointer...
    }
    // ...
}
```

2.3. Remove TLAB logic (no longer needed for thread-local old gen):
- Delete `promotion_tlab` member
- Remove TLAB allocation/sealing in evacuate()

### Phase 3: Simplify OldGenSpace

**Option A: Remove OldGenSpace entirely**

If fully thread-segregated, OldGenSpace becomes unnecessary:
- Delete `runtime/include/OldGenSpace.hpp`
- Delete `runtime/src/OldGenSpace.cpp`
- Delete `runtime/include/TLAB.hpp`

**Option B: Keep OldGenSpace for shared heap**

If some objects can escape threads:
- Rename to `SharedHeap`
- Keep mark-sweep (collected rarely)
- Remove TLAB, compaction (not needed for rare collection)

### Phase 4: Update GarbageCollector

**Files to modify:**
- `runtime/include/GarbageCollector.hpp`
- `runtime/src/GarbageCollector.cpp`

**Tasks:**

4.1. Replace `nurseries` map with `thread_heaps` map:
```cpp
// Before:
std::unordered_map<std::thread::id, std::unique_ptr<NurserySpace>> nurseries;
OldGenSpace old_gen;

// After:
std::unordered_map<std::thread::id, std::unique_ptr<ThreadHeap>> thread_heaps;
// Optional:
// SharedHeap shared_heap;
```

4.2. Update `initThread()`:
```cpp
void GarbageCollector::initThread() {
    std::lock_guard<std::mutex> lock(heap_mutex);
    auto tid = std::this_thread::get_id();
    if (thread_heaps.find(tid) == thread_heaps.end()) {
        char* heap_base = allocateThreadHeapRegion();
        auto heap = std::make_unique<ThreadHeap>();
        heap->initialize(heap_base,
                        config_.nursery_size,
                        config_.oldgen_size,  // NEW
                        &config_);
        thread_heaps[tid] = std::move(heap);
    }
}
```

4.3. Update memory layout:
```cpp
// Before: Heap split 50/50 between old gen and nurseries
// After: Each thread gets a contiguous region for nursery + old gen

void GarbageCollector::initialize(const GCConfig& config) {
    // Reserve space for max threads
    size_t per_thread = config_.nursery_size + config_.oldgen_size;
    size_t total = per_thread * config_.max_threads;

    heap_base = mmap(nullptr, total, PROT_NONE, ...);
    // ...
}

char* GarbageCollector::allocateThreadHeapRegion() {
    size_t per_thread = config_.nursery_size + config_.oldgen_size;
    char* base = heap_base + (num_threads * per_thread);
    // Commit physical memory
    mmap(base, per_thread, PROT_READ | PROT_WRITE, MAP_FIXED, ...);
    num_threads++;
    return base;
}
```

4.4. Remove STW barrier for major GC (each thread collects independently):
```cpp
// Before: majorGC() raises STW barrier, collects all roots
// After: majorGC() only collects current thread's heap

void GarbageCollector::majorGC() {
    ThreadHeap* heap = getThreadHeap();
    if (heap) {
        heap->majorGC();  // Thread-local, no synchronization
    }
}
```

### Phase 5: Update GCConfig

**Files to modify:**
- `runtime/include/AllocatorCommon.hpp`

**Tasks:**

5.1. Add thread-local old gen configuration:
```cpp
struct GCConfig {
    // ... existing fields ...

    // Thread-local old gen sizing (NEW)
    size_t oldgen_size = THREAD_OLDGEN_SIZE;      // 32 MB default
    size_t max_threads = MAX_THREAD_HEAPS;        // 32 default

    // Major GC triggers (NEW)
    float oldgen_gc_threshold = 0.75f;            // Collect at 75% full
    u32 minor_gcs_per_major = 10;                 // Or after 10 minor GCs

    // Remove old gen fields that are no longer relevant
    // size_t initial_old_gen_size;  // REMOVE
    // size_t min_old_gen_chunk_size;  // REMOVE
    // TLAB fields...  // REMOVE
    // Compaction thresholds...  // REMOVE
};
```

5.2. Update validation:
```cpp
void GCConfig::validate() const {
    // ... existing validations ...

    // New validations
    if (oldgen_size == 0) {
        throw std::invalid_argument("oldgen_size must be > 0");
    }
    if (oldgen_size % 2 != 0) {
        throw std::invalid_argument("oldgen_size must be even (two semi-spaces)");
    }
    if (max_threads == 0 || max_threads > 256) {
        throw std::invalid_argument("max_threads must be in [1, 256]");
    }
    // ...
}
```

### Phase 6: Update Tests

**Files to modify:**
- `test/GarbageCollectorTest.hpp`
- `test/NurserySpaceTest.hpp`
- `test/OldGenSpaceTest.hpp` → Delete or rename to `test/ThreadHeapTest.hpp`
- `test/TLABTest.hpp` → Delete
- `test/CompactionTest.hpp` → Modify for semi-space compaction
- `test/HeapGenerators.hpp`
- `test/HeapGenerators.cpp`
- `test/main.cpp`

**Tasks:**

6.1. Create `ThreadHeapTest.hpp`:
```cpp
void testThreadHeapBasicAllocation();
void testThreadHeapMinorGC();
void testThreadHeapMajorGC();
void testThreadHeapPromotionToOldGen();
void testThreadHeapOldGenCompaction();
void testThreadHeapMultipleGenerationCycles();
```

6.2. Update property-based tests in `main.cpp`:
- Test that major GC preserves all reachable old gen objects
- Test that nursery objects correctly point to moved old gen objects
- Test multiple minor + major GC cycles

6.3. Remove obsolete tests:
- TLAB tests (no longer used)
- Shared old gen tests
- Free-list allocation tests
- Mark-sweep tests

### Phase 7: Delete Obsolete Code

**Files to delete:**
- `runtime/include/OldGenSpace.hpp` (if not keeping shared heap)
- `runtime/src/OldGenSpace.cpp`
- `runtime/include/TLAB.hpp`
- `test/OldGenSpaceTest.hpp`
- `test/OldGenSpaceTest.cpp`
- `test/TLABTest.hpp`
- `test/TLABTest.cpp`

**Code to remove from remaining files:**
- TLAB-related code in NurserySpace
- Free-list allocation code
- Mark-sweep code
- Block-based compaction code

## Implementation Order

Recommended implementation sequence:

```
Week 1: Phase 1 - ThreadHeap abstraction
├── Create ThreadHeap.hpp/cpp with basic structure
├── Implement old gen semi-space layout
├── Implement bump-pointer allocation for old gen
└── Implement majorGC with Cheney's algorithm

Week 2: Phase 2 & 3 - Integrate nursery and remove old code
├── Modify NurserySpace to promote to ThreadHeap
├── Remove TLAB logic
├── Remove OldGenSpace (or convert to SharedHeap)
└── Update forwarding pointer handling

Week 3: Phase 4 - Update GarbageCollector
├── Replace nurseries map with thread_heaps
├── Update memory layout for per-thread heaps
├── Remove STW barrier for major GC
└── Update allocate() and GC triggers

Week 4: Phase 5 & 6 - Config and tests
├── Update GCConfig with new parameters
├── Create ThreadHeapTest
├── Update property-based tests
└── Run full test suite, fix issues

Week 5: Phase 7 - Cleanup
├── Delete obsolete files
├── Remove dead code
├── Update documentation
└── Performance benchmarking
```

## Risks and Mitigations

### Risk 1: Memory Overhead
**Issue:** Semi-space copying uses 2x memory per generation.
**Mitigation:**
- Accept the trade-off (Elm workloads typically have low live data)
- Consider Appel-style flexible sizing as future optimization
- Make sizes configurable

### Risk 2: Major GC Pause Times
**Issue:** Large old gen may cause long pauses.
**Mitigation:**
- Old gen pause = O(live data), not O(heap size)
- If live data is small relative to heap, pauses are short
- Can implement incremental/concurrent marking as future work

### Risk 3: Object Sharing Between Threads
**Issue:** Some objects may need to be accessed by multiple threads.
**Mitigation:**
- Erlang-style copying for message passing
- Optional shared heap for escaped objects
- Analyze Elm runtime to determine if true sharing occurs

### Risk 4: Regression in Existing Tests
**Issue:** Significant architecture change may break tests.
**Mitigation:**
- Maintain same public API (allocate, minorGC, etc.)
- Phase implementation to maintain working state
- Run tests after each phase

## Future Enhancements

### 1. Appel-Style Flexible Generations
Allow nursery and old gen to share space, with dynamic boundary:
```cpp
// Single contiguous space, boundary moves based on survival rate
[from-space | to-space] where boundary can shift
```

### 2. Generational Remembered Sets
For cases where old gen objects might point to nursery (if Elm semantics change):
```cpp
std::vector<HPointer*> remembered_set;
```

### 3. Concurrent Old Gen Collection
If major GC pauses become problematic:
- Concurrent marking with Doligez-Leroy-Gonthier style barriers
- Incremental copying

### 4. Large Object Space
Objects too large for semi-space copying:
```cpp
class LargeObjectSpace {
    // Mark-sweep for objects > threshold
    // Not copied, only marked
};
```

## References

- The Garbage Collection Handbook, Chapter 9: Generational Garbage Collection
- The Garbage Collection Handbook, Chapter 10.2: Thread-Local Heaps (Erlang, Doligez-Leroy)
- The Garbage Collection Handbook, Chapter 4: Copying Collection (Cheney's Algorithm)
- Erlang runtime system: BEAM garbage collector
- OCaml runtime: Doligez-Leroy-Gonthier collector
