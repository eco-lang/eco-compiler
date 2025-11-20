# TLAB (Thread-Local Allocation Buffer) Design for OldGenSpace

## Overview

This design adds lock-free thread-local allocation to the old generation while maintaining compatibility with the existing mark-and-sweep collector.

## Key Concepts

### TLAB Structure
Each TLAB is a 128KB contiguous memory region assigned exclusively to one thread for fast bump-pointer allocation:

```
[=== TLAB ===]
^            ^             ^
start     alloc_ptr       end
          (bumps up)
```

- **start**: Beginning of TLAB region
- **end**: End of TLAB region
- **alloc_ptr**: Thread-local bump pointer (no synchronization needed)

### Memory Layout

```
Old Gen Space:
[=== Free-List Region ===][======= TLAB Region =======]
^                         ^                            ^
region_base          tlab_region_start         region_end
                     (atomic bump ptr)

Free-list region: Legacy allocation for large objects, pre-TLAB allocations
TLAB region: Lock-free TLAB allocation via atomic CAS
```

### Allocation Flow

```
Thread promotes object during minor GC
    |
    v
Try allocate from current TLAB (fast path, no lock)
    |
    +---> Success? Return object
    |
    +---> TLAB full?
            |
            v
          Seal current TLAB
            |
            v
          Request new TLAB (atomic CAS on global bump pointer)
            |
            v
          Success? Continue with new TLAB
            |
            v
          TLAB region full? Fall back to free-list allocation (slow path, mutex)
```

### Sweep Integration

Sweep must handle three memory areas:
1. **Free-list region**: Objects allocated before TLAB, or large objects
2. **Sealed TLABs**: Fully or partially used TLABs returned to GC
3. **Active TLABs**: Currently held by threads (not swept - thread keeps them across GC)

## Implementation Details

### 1. TLAB Class

```cpp
class TLAB {
public:
    TLAB(char* base, size_t size)
        : start(base), end(base + size), alloc_ptr(base) {}

    // Thread-local allocation (no synchronization)
    void* allocate(size_t size) {
        size = (size + 7) & ~7; // 8-byte align
        if (alloc_ptr + size > end) {
            return nullptr; // TLAB exhausted
        }
        void* result = alloc_ptr;
        alloc_ptr += size;
        return result;
    }

    size_t bytesUsed() const { return alloc_ptr - start; }
    size_t bytesRemaining() const { return end - alloc_ptr; }
    bool isEmpty() const { return alloc_ptr == start; }

    char* start;
    char* end;
    char* alloc_ptr;
};
```

### 2. OldGenSpace Changes

```cpp
class OldGenSpace {
public:
    // NEW: TLAB allocation methods
    TLAB* allocateTLAB(size_t size = TLAB_DEFAULT_SIZE);
    void sealTLAB(TLAB* tlab);

    // Existing methods
    void* allocate(size_t size); // Fallback for large objects
    void sweep(); // Modified to handle TLABs

private:
    // Existing free-list allocation
    FreeBlock *free_list;
    std::recursive_mutex alloc_mutex;

    // NEW: TLAB region (atomic bump pointer allocation)
    static constexpr size_t TLAB_DEFAULT_SIZE = 128 * 1024; // 128KB
    std::atomic<char*> tlab_bump_ptr;  // Atomic bump pointer for TLAB allocation
    char* tlab_region_start;           // Start of TLAB region
    char* tlab_region_end;             // End of TLAB region

    // NEW: Sealed TLABs (for sweep to process)
    std::mutex sealed_tlabs_mutex;
    std::vector<TLAB*> sealed_tlabs;

    // Helper: Initialize TLAB region
    void initializeTLABRegion();
};
```

### 3. Allocation Flow

#### allocateTLAB() - Lock-free TLAB creation

```cpp
TLAB* OldGenSpace::allocateTLAB(size_t size) {
    size = std::max(size, TLAB_DEFAULT_SIZE);
    size = (size + 7) & ~7; // Align to 8 bytes

    // Atomic bump pointer allocation (lock-free!)
    char* current = tlab_bump_ptr.load(std::memory_order_relaxed);
    char* new_ptr;

    do {
        new_ptr = current + size;

        // Check if we have space
        if (new_ptr > tlab_region_end) {
            return nullptr; // TLAB region exhausted
        }

        // Try to CAS: if current is still tlab_bump_ptr, update to new_ptr
    } while (!tlab_bump_ptr.compare_exchange_weak(
        current, new_ptr,
        std::memory_order_release,
        std::memory_order_relaxed
    ));

    // Success! We claimed [current, new_ptr)
    TLAB* tlab = new TLAB(current, size);
    return tlab;
}
```

**Key points:**
- **Lock-free**: Multiple threads can request TLABs concurrently via CAS
- **Memory ordering**: Release/acquire ensures visibility of allocated regions
- **Retry loop**: CAS failure means another thread grabbed that space; retry with updated value

#### sealTLAB() - Return TLAB to GC

```cpp
void OldGenSpace::sealTLAB(TLAB* tlab) {
    if (!tlab || tlab->isEmpty()) {
        delete tlab; // Nothing to track
        return;
    }

    std::lock_guard<std::mutex> lock(sealed_tlabs_mutex);
    sealed_tlabs.push_back(tlab);
}
```

**Note**: This needs a mutex because `sealed_tlabs` is a vector. Could be optimized with lock-free data structure if needed.

### 4. NurserySpace Integration

```cpp
class NurserySpace {
private:
    TLAB* promotion_tlab; // Current TLAB for promotions to old gen

public:
    void evacuate(HPointer &ptr, OldGenSpace &oldgen,
                  std::vector<void*> *promoted_objects) {
        // ... existing checks ...

        if (hdr->age >= PROMOTION_AGE) {
            void* new_obj = nullptr;

            // FAST PATH: Try TLAB allocation (no lock!)
            if (promotion_tlab) {
                new_obj = promotion_tlab->allocate(size);
            }

            // TLAB exhausted? Seal and get new one
            if (!new_obj) {
                if (promotion_tlab && promotion_tlab->bytesRemaining() == 0) {
                    oldgen.sealTLAB(promotion_tlab);
                    promotion_tlab = nullptr;
                }

                // Get new TLAB (lock-free CAS)
                if (!promotion_tlab) {
                    promotion_tlab = oldgen.allocateTLAB();
                }

                if (promotion_tlab) {
                    new_obj = promotion_tlab->allocate(size);
                }
            }

            // SLOW PATH: Fallback to free-list for large objects or TLAB region full
            if (!new_obj) {
                new_obj = oldgen.allocate(size); // Takes mutex
            }

            if (new_obj) {
                // ... existing promotion code (memcpy, update header, etc.) ...
            }
        }

        // ... rest of evacuate ...
    }
};
```

### 5. Modified Sweep

```cpp
void OldGenSpace::sweep() {
    std::lock_guard<std::recursive_mutex> lock(alloc_mutex);

    FreeBlock *new_free_list = nullptr;

    // 1. Sweep sealed TLABs
    {
        std::lock_guard<std::mutex> tlock(sealed_tlabs_mutex);

        for (TLAB* tlab : sealed_tlabs) {
            char* ptr = tlab->start;
            char* used_end = tlab->alloc_ptr; // Only sweep used portion!

            while (ptr < used_end) {
                Header* hdr = reinterpret_cast<Header*>(ptr);
                size_t obj_size = getObjectSize(ptr);

                if (hdr->color == static_cast<u32>(Color::White)) {
                    // Dead object - reclaim to free list
                    FreeBlock* block = reinterpret_cast<FreeBlock*>(ptr);
                    block->size = obj_size;
                    block->next = new_free_list;
                    new_free_list = block;
                } else {
                    // Live object - reset color for next cycle
                    hdr->color = static_cast<u32>(Color::White);
                }

                ptr += obj_size;
            }

            delete tlab; // TLAB metadata no longer needed
        }

        sealed_tlabs.clear();
    }

    // 2. Sweep free-list region (existing allocations, large objects)
    // Only sweep up to where TLAB region starts
    char* ptr = region_base;
    char* end = std::min(tlab_region_start, region_base + region_size);

    while (ptr < end) {
        Header* hdr = reinterpret_cast<Header*>(ptr);

        if (hdr->tag >= Tag_Forward) {
            ptr += sizeof(Header);
            continue;
        }

        size_t obj_size = getObjectSize(ptr);

        if (hdr->color == static_cast<u32>(Color::White)) {
            FreeBlock* block = reinterpret_cast<FreeBlock*>(ptr);
            block->size = obj_size;
            block->next = new_free_list;
            new_free_list = block;
        } else {
            hdr->color = static_cast<u32>(Color::White);
        }

        ptr += obj_size;
    }

    free_list = new_free_list;
}
```

### 6. Initialization

```cpp
void OldGenSpace::initialize(char *base, size_t initial_size, size_t max_size) {
    region_base = base;
    region_size = initial_size;
    max_region_size = max_size;

    // Split region: 50% free-list, 50% TLAB
    size_t tlab_region_size = max_size / 2;
    tlab_region_start = base + (max_size - tlab_region_size);
    tlab_region_end = base + max_size;

    // Initialize free-list with first half
    FreeBlock *block = reinterpret_cast<FreeBlock*>(region_base);
    block->size = tlab_region_start - region_base;
    block->next = nullptr;
    free_list = block;

    // Initialize TLAB bump pointer
    tlab_bump_ptr.store(tlab_region_start, std::memory_order_relaxed);

    chunks.push_back(region_base);
}
```

## Performance Characteristics

### Fast Path (Common Case)
```
Thread promotes object:
  1. bump promotion_tlab->alloc_ptr (thread-local, no sync)
  2. memcpy object
  3. return

Cost: ~10-20 CPU cycles (bump + memcpy)
```

### TLAB Exhaustion (Periodic)
```
Thread's TLAB is full:
  1. Seal TLAB (mutex on sealed_tlabs vector)
  2. Allocate new TLAB (atomic CAS on bump pointer)
  3. Continue allocation

Cost: ~100-200 CPU cycles
Frequency: Every 128KB of promotions
```

### Fallback Path (Rare)
```
TLAB region exhausted or large object:
  1. Take alloc_mutex
  2. Walk free-list
  3. Return

Cost: ~500-2000 CPU cycles (mutex + free-list walk)
Frequency: Large objects (>128KB) or TLAB region full
```

## Memory Overhead

- **TLAB metadata**: 24 bytes per TLAB (3 pointers)
- **Sealed TLABs vector**: ~8 bytes per sealed TLAB (vector pointer)
- **Atomic bump pointer**: 8 bytes total
- **Per-thread**: 1 TLAB pointer in NurserySpace (8 bytes)

**Total per thread**: ~40 bytes + 1 active TLAB (128KB)

## Advantages

1. **Lock-free allocation**: Most promotions avoid mutex entirely
2. **Cache friendly**: Thread works in its own 128KB region
3. **GC compatible**: Sweep handles TLABs naturally
4. **Scalable**: Contention only on TLAB creation (every 128KB)
5. **Simple**: Minimal changes to existing code

## Edge Cases

### Thread Exit
When a thread exits, its nursery is destroyed. The `promotion_tlab` should be sealed:

```cpp
NurserySpace::~NurserySpace() {
    if (promotion_tlab) {
        GarbageCollector::instance().getOldGen().sealTLAB(promotion_tlab);
        promotion_tlab = nullptr;
    }
}
```

### Large Object Promotion
Objects larger than TLAB size skip TLAB and go directly to free-list:

```cpp
if (size > TLAB_DEFAULT_SIZE) {
    new_obj = oldgen.allocate(size); // Free-list allocation
} else {
    // Try TLAB...
}
```

### TLAB Region Exhaustion
When TLAB region is full, `allocateTLAB()` returns nullptr. Code falls back to free-list allocation.

Could grow TLAB region dynamically, but simpler to just use free-list fallback.

## Future Optimizations

1. **Lock-free sealed_tlabs**: Use lock-free queue instead of mutex-protected vector
2. **TLAB sizing heuristics**: Adjust TLAB size based on promotion rate
3. **TLAB recycling**: Reuse empty TLABs instead of always allocating new ones
4. **Per-size-class TLABs**: Separate TLABs for different object sizes
