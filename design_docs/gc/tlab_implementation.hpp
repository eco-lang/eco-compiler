// TLAB Implementation Sketch - Changes to allocator.hpp
//
// This shows the specific additions needed to support TLABs

#ifndef ECO_TLAB_H
#define ECO_TLAB_H

#include <atomic>

namespace Elm {

// ============================================================================
// TLAB (Thread-Local Allocation Buffer)
// ============================================================================

/**
 * A thread-local allocation buffer for fast, lock-free allocation into old gen.
 * Each thread gets a TLAB for promoting objects during minor GC, avoiding
 * mutex contention on the global OldGenSpace free-list.
 */
class TLAB {
public:
    /**
     * Create a TLAB from a memory region.
     * @param base Start of the memory region
     * @param size Size of the region in bytes
     */
    TLAB(char* base, size_t size)
        : start(base), end(base + size), alloc_ptr(base) {}

    /**
     * Allocate from this TLAB using thread-local bump pointer.
     * NO SYNCHRONIZATION - thread has exclusive access.
     *
     * @param size Number of bytes to allocate (will be 8-byte aligned)
     * @return Pointer to allocated memory, or nullptr if TLAB exhausted
     */
    void* allocate(size_t size) {
        // Align to 8 bytes
        size = (size + 7) & ~7;

        // Check if we have space
        if (alloc_ptr + size > end) {
            return nullptr; // TLAB exhausted
        }

        // Bump pointer allocation (thread-local, no sync!)
        void* result = alloc_ptr;
        alloc_ptr += size;
        return result;
    }

    // Query methods
    size_t bytesUsed() const { return alloc_ptr - start; }
    size_t bytesRemaining() const { return end - alloc_ptr; }
    size_t capacity() const { return end - start; }
    bool isEmpty() const { return alloc_ptr == start; }
    bool isFull() const { return alloc_ptr == end; }

    // Memory region
    char* start;      // Start of TLAB
    char* end;        // End of TLAB
    char* alloc_ptr;  // Current allocation pointer (thread-local)
};

// ============================================================================
// OldGenSpace TLAB Support
// ============================================================================

// Add these members to OldGenSpace class:
/*

class OldGenSpace {
public:
    // ... existing public methods ...

    // NEW: TLAB allocation
    // Allocate a new TLAB using lock-free atomic bump pointer
    // Returns nullptr if TLAB region is exhausted
    TLAB* allocateTLAB(size_t size = TLAB_DEFAULT_SIZE);

    // NEW: Return a sealed TLAB to be swept by GC
    // TLABs should be sealed when exhausted or when thread exits
    void sealTLAB(TLAB* tlab);

private:
    // ... existing private members ...

    // NEW: TLAB configuration
    static constexpr size_t TLAB_DEFAULT_SIZE = 128 * 1024; // 128KB
    static constexpr size_t TLAB_MIN_SIZE = 64 * 1024;      // 64KB minimum

    // NEW: TLAB region (lock-free allocation)
    // Memory layout:
    //   [region_base ... tlab_region_start ... tlab_region_end]
    //   [Free-list region][    TLAB region                    ]
    std::atomic<char*> tlab_bump_ptr;  // Atomic bump pointer for TLAB creation
    char* tlab_region_start;           // Start of TLAB region
    char* tlab_region_end;             // End of TLAB region (= region_base + max_region_size)

    // NEW: Sealed TLABs awaiting sweep
    std::mutex sealed_tlabs_mutex;
    std::vector<TLAB*> sealed_tlabs;   // TLABs returned by threads, swept during GC
};

*/

// ============================================================================
// NurserySpace TLAB Support
// ============================================================================

// Add these members to NurserySpace class:
/*

class NurserySpace {
public:
    // ... existing public methods ...

    // Destructor should seal any active TLAB
    ~NurserySpace();

private:
    // ... existing private members ...

    // NEW: Current TLAB for promoting to old gen
    TLAB* promotion_tlab;  // Thread-local TLAB for fast promotions

    // Modified evacuate() signature stays the same, implementation changes
    void evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
};

*/

} // namespace Elm

#endif // ECO_TLAB_H
