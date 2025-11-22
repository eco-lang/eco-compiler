# Lock-Free Analysis for eco-runtime Mutexes

This document analyzes all mutexes in the garbage collector and evaluates whether they can be converted to lock-free alternatives.

## Current Mutexes

The codebase currently uses 6 mutexes:

| Mutex | Type | Location |
|-------|------|----------|
| `nursery_mutex` | `std::mutex` | `GarbageCollector.hpp:73` |
| `RootSet::mutex` | `std::mutex` | `RootSet.hpp:28` |
| `alloc_mutex` | `std::recursive_mutex` | `OldGenSpace.hpp:116` |
| `mark_mutex` | `std::recursive_mutex` | `OldGenSpace.hpp:119` |
| `sealed_tlabs_mutex` | `std::mutex` | `OldGenSpace.hpp:128` |
| `available_tlabs_mutex` | `std::mutex` | `OldGenSpace.hpp:135` |

---

## 1. GarbageCollector::nursery_mutex

**Protects:** Thread-to-nursery mapping (`std::unordered_map<std::thread::id, std::unique_ptr<NurserySpace>>`)

**Operations Under Lock:**
- `initThread()`: Look up thread, insert new NurserySpace if not present
- `getNursery()`: Look up thread ID and return NurserySpace pointer
- `reset()`: Iterate and reset all nurseries

**Current Impact:** Hit on every allocation when looking up thread's nursery

### Lock-Free Analysis

**Verdict: PARTIALLY POSSIBLE - HIGH VALUE**

The hot path (`getNursery()`) can be optimized using thread-local caching:

```cpp
class GarbageCollector {
    // Existing:
    std::mutex nursery_mutex;
    std::unordered_map<std::thread::id, std::unique_ptr<NurserySpace>> nurseries;
    std::atomic<size_t> next_nursery_offset; // Make atomic

    // New thread-local cache:
    inline static thread_local NurserySpace* cached_nursery = nullptr;

    NurserySpace* getNursery() {
        if (cached_nursery) return cached_nursery;  // Fast path - no lock!

        std::lock_guard<std::mutex> lock(nursery_mutex);
        auto it = nurseries.find(std::this_thread::get_id());
        if (it != nurseries.end()) {
            cached_nursery = it->second.get();
            return cached_nursery;
        }
        return nullptr;
    }
};
```

**Benefits:**
- Eliminates mutex from allocation hot path
- First access per thread takes lock, subsequent accesses are lock-free
- `initThread()` still uses lock (acceptable - called once per thread)

---

## 2. RootSet::mutex

**Protects:** Root set vectors (`std::vector<HPointer*>` and `std::vector<std::pair<void*, size_t>>`)

**Operations Under Lock:**
- `addRoot()`: Push to vector
- `removeRoot()`: Find and erase (O(n))
- `addStackRoot()`: Push to vector
- `clearStackRoots()`: Clear vector
- `reset()`: Clear both vectors

### Lock-Free Analysis

**Verdict: NOT WORTH CONVERTING**

**Why:**
1. Root operations are infrequent compared to allocations
2. Not on the allocation hot path
3. Lock-free alternatives add significant complexity:
   - Lock-free linked list requires hazard pointers or epoch-based reclamation
   - RCU pattern causes memory churn
   - `removeRoot()` with linear scan is inherently challenging

**Alternative:** Use `std::shared_mutex` for reader/writer split if needed:

```cpp
std::shared_mutex mutex;

const std::vector<HPointer*>& getRoots() {
    std::shared_lock lock(mutex);  // Multiple readers allowed
    return roots;
}

void addRoot(HPointer* root) {
    std::unique_lock lock(mutex);  // Exclusive for writes
    roots.push_back(root);
}
```

---

## 3. OldGenSpace::alloc_mutex (recursive)

**Protects:** Free list allocation (`FreeBlock* free_list`, `region_size`, `chunks`)

**Operations Under Lock:**
- `allocate()`: Wraps `allocate_internal()`
- `allocate_internal()`: First-fit search, block splitting, may call `addChunk()`
- `addChunk()`: Grows heap with mmap, adds to free_list
- `sweep()`: Rebuilds entire free_list

### Lock-Free Analysis

**Verdict: ALREADY OPTIMIZED - LOW PRIORITY**

The current design already avoids this mutex on the hot path:

1. **Nursery allocation**: Bump pointer (no locks)
2. **TLAB allocation**: Lock-free atomic CAS on bump pointer
3. **Free-list allocation**: Only for large objects or TLAB exhaustion

**Lock-Free Free-List Options (for reference):**

**Option A: Lock-free with CAS**
```cpp
void* allocate_lockfree(size_t size) {
    FreeBlock* prev = nullptr;
    FreeBlock* curr = free_list.load();

    while (curr) {
        if (curr->size >= size) {
            FreeBlock* next = curr->next.load();
            if (prev == nullptr) {
                if (free_list.compare_exchange_strong(curr, next)) {
                    return curr;
                }
            } else {
                if (prev->next.compare_exchange_strong(curr, next)) {
                    return curr;
                }
            }
            // Restart on CAS failure
            prev = nullptr;
            curr = free_list.load();
            continue;
        }
        prev = curr;
        curr = curr->next.load();
    }
    return nullptr;
}
```

**Challenges:**
- ABA problem requires hazard pointers or tagged pointers
- Block splitting is non-trivial atomically
- Complexity outweighs benefits given TLAB design

**Option B: Size-segregated lock-free lists**
- Multiple free lists by size class
- Simpler lock-free pop from head
- Wastes memory due to size class rounding

**Recommendation:** Keep the mutex. The TLAB design already handles the hot path.

---

## 4. OldGenSpace::mark_mutex (recursive)

**Protects:** Mark stack and marking state (`mark_stack`, `marking_active`, `current_epoch`, `blocks`)

**Operations Under Lock:**
- `startConcurrentMark()`: Initialize marking, populate mark_stack from roots
- `incrementalMark()`: Pop/push mark_stack, update object colors

### Lock-Free Analysis

**Verdict: CAN BE ELIMINATED OR IMPROVED**

**If single-threaded marking (current implementation):**
- The mutex is unnecessary - remove it entirely
- `marking_active` and `current_epoch` are already atomic

**If parallel marking desired:**
Use work-stealing deques (Chase-Lev algorithm):

```cpp
class WorkStealingDeque {
    std::atomic<int64_t> top;    // Local end (push/pop)
    std::atomic<int64_t> bottom; // Steal end
    std::atomic<void**> array;

    void push(void* obj);   // Local thread only
    void* pop();            // Local thread only
    void* steal();          // Other threads can steal
};
```

**Benefits:**
- Single writer pushes objects locally
- Multiple readers can steal work for parallel marking
- Well-studied algorithm with known correctness

---

## 5. OldGenSpace::sealed_tlabs_mutex

**Protects:** Vector of sealed TLABs (`std::vector<TLAB*>`)

**Operations Under Lock:**
- `sealTLAB()`: Push TLAB pointer to vector
- `sweep()`: Iterate, process, and clear
- `reset()`: Delete all and clear

### Lock-Free Analysis

**Verdict: EASILY LOCK-FREE - HIGH VALUE**

Classic MPSC (multiple producer, single consumer) pattern:
- **Producers:** Multiple mutator threads sealing TLABs
- **Consumer:** Single GC thread processes during sweep

**Implementation:**

Add to `TLAB.hpp`:
```cpp
class TLAB {
    // ... existing fields ...
    TLAB* next = nullptr;  // For lock-free list
};
```

Replace mutex with atomic:
```cpp
std::atomic<TLAB*> sealed_tlabs_head{nullptr};

void sealTLAB(TLAB* tlab) {
    if (!tlab || tlab->isEmpty()) {
        delete tlab;
        return;
    }

    // Lock-free push to head
    tlab->next = sealed_tlabs_head.load(std::memory_order_relaxed);
    while (!sealed_tlabs_head.compare_exchange_weak(
        tlab->next, tlab,
        std::memory_order_release,
        std::memory_order_relaxed));
}

void sweep() {
    // Atomically grab entire list
    TLAB* list = sealed_tlabs_head.exchange(nullptr, std::memory_order_acquire);

    // Process all TLABs - exclusive access, no lock needed
    while (list) {
        TLAB* next = list->next;
        // ... sweep this TLAB ...
        delete list;
        list = next;
    }
}
```

**Benefits:**
- Zero contention between threads sealing TLABs
- Simple implementation
- No ABA concerns (TLABs are consumed, not reused)

---

## 6. OldGenSpace::available_tlabs_mutex

**Protects:** Vector of available TLABs for recycling (`std::vector<TLAB*>`)

**Operations Under Lock:**
- `reclaimEvacuatedBlocks()`: Push reclaimed TLABs
- `reset()`: Delete all and clear

### Lock-Free Analysis

**Verdict: EASILY LOCK-FREE - HIGH VALUE**

Single producer (GC), multiple consumers (mutator threads) pattern.

**Implementation (Treiber Stack):**

```cpp
std::atomic<TLAB*> available_tlabs_head{nullptr};

// GC pushes reclaimed TLABs
void addAvailableTLAB(TLAB* tlab) {
    tlab->next = available_tlabs_head.load(std::memory_order_relaxed);
    while (!available_tlabs_head.compare_exchange_weak(
        tlab->next, tlab,
        std::memory_order_release,
        std::memory_order_relaxed));
}

// Mutator thread gets a recycled TLAB
TLAB* getAvailableTLAB() {
    TLAB* head = available_tlabs_head.load(std::memory_order_acquire);
    while (head) {
        if (available_tlabs_head.compare_exchange_weak(
            head, head->next,
            std::memory_order_release,
            std::memory_order_relaxed)) {
            head->next = nullptr;
            return head;
        }
    }
    return nullptr;  // No available TLABs
}
```

**Benefits:**
- Completes lock-free TLAB lifecycle
- Enables efficient TLAB recycling without contention

---

## Summary

| Mutex | Lock-Free? | Recommendation | Priority |
|-------|-----------|----------------|----------|
| `nursery_mutex` | Partially | Thread-local caching for hot path | **HIGH** |
| `RootSet::mutex` | No | Keep (or use `shared_mutex`) | LOW |
| `alloc_mutex` | No | Keep - TLAB already handles hot path | LOW |
| `mark_mutex` | Yes | Remove if single-threaded; work-stealing if parallel | MEDIUM |
| `sealed_tlabs_mutex` | **YES** | Lock-free MPSC stack | **HIGH** |
| `available_tlabs_mutex` | **YES** | Lock-free Treiber stack | **HIGH** |

## Implementation Order

### Phase 1: High-Impact Changes
1. **Thread-local nursery caching** - Eliminates mutex from every allocation
2. **Lock-free sealed_tlabs** - MPSC pattern for TLAB sealing
3. **Lock-free available_tlabs** - Treiber stack for TLAB recycling

### Phase 2: Cleanup
4. **Evaluate mark_mutex** - Remove if single-threaded marking confirmed

### Phase 3: Optional
5. Consider `shared_mutex` for RootSet if profiling shows contention

## Current Design Assessment

The existing architecture is already well-optimized:
- Bump pointer nursery allocation (no locks)
- Lock-free TLAB allocation (atomic CAS)
- Thread-local allocation buffers (no contention)

The main opportunities are:
1. Eliminating nursery lookup mutex with caching
2. Making TLAB management fully lock-free

These changes would make the entire allocation path completely lock-free.

---

**Document Version:** 1.0
**Last Updated:** 2025-11-22
**Author:** Claude Code (AI Assistant)
