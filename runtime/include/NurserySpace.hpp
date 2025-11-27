#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

#include <vector>
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"

namespace Elm {

// Forward declaration for friend access.
class NurserySpaceTestAccess;

/**
 * Nursery with semi-space copying collector (Cheney's algorithm).
 *
 * Objects are allocated via bump pointer in from_space. When full, minorGC
 * evacuates live objects to to_space (or promotes to old gen), then swaps spaces.
 */
class NurserySpace {
public:
    NurserySpace();
    ~NurserySpace();

    // Allocates memory in the nursery using bump pointer. Returns nullptr if full.
    void *allocate(size_t size);

    // Returns the root set for this nursery.
    RootSet& getRootSet() { return root_set; }

#if ENABLE_GC_STATS
    // Returns the GC statistics for this nursery.
    const GCStats& getStats() const { return stats; }
    GCStats& getStats() { return stats; }
#endif

private:
    const HeapConfig* config_;  // Heap configuration parameters.
    char *memory;         // Total nursery memory (both semi-spaces).
    char *from_space;     // Current allocation space.
    char *to_space;       // Copy target during GC.
    char *alloc_ptr;      // Bump allocation pointer.
    char *scan_ptr;       // Cheney scan pointer during evacuation.
    size_t nursery_capacity_;  // Capacity of one semi-space (total_size / 2).

    RootSet root_set;     // Root set for this nursery.

#if ENABLE_GC_STATS
    GCStats stats;        // Performance statistics.
#endif

    // ========== Internal Methods ==========

    // Initializes this nursery with the given memory region from the main heap.
    void initialize(char *nursery_base, size_t size, const HeapConfig* config);

    // Performs minor GC, evacuating live objects to to_space or promoting to old gen.
    void minorGC(OldGenSpace &oldgen);

    // Returns true if the pointer points into this nursery's memory region.
    bool contains(void *ptr) const;

    // Returns the number of bytes currently allocated in the nursery.
    size_t bytesAllocated() const { return alloc_ptr - from_space; }

    // Returns true if the given allocation would push usage above the threshold.
    bool wouldExceedThreshold(size_t size, float threshold) const {
        size_t aligned_size = (size + 7) & ~7;
        size_t total_capacity = nursery_capacity_;
        size_t usage_after = (alloc_ptr - from_space) + aligned_size;
        return usage_after >= (size_t)(total_capacity * threshold);
    }

    // Resets the nursery to initial state. Used for testing.
    // If new_config is provided, reconfigures with new parameters.
    void reset(OldGenSpace &oldgen, const HeapConfig* new_config = nullptr);

    void evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);

    friend class Allocator;
    friend class NurserySpaceTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to NurserySpace internals.
class NurserySpaceTestAccess {
public:
    static bool contains(const NurserySpace& nursery, void* ptr) {
        return nursery.contains(ptr);
    }

    static size_t bytesAllocated(const NurserySpace& nursery) {
        return nursery.bytesAllocated();
    }
};

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
