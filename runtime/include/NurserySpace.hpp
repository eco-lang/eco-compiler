#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

#include <vector>
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"
#include "TLAB.hpp"

namespace Elm {

// Thread-local nursery space with semi-space copying collector
class NurserySpace {
public:
    NurserySpace();
    ~NurserySpace();

    // Initialize with assigned region from main heap
    void initialize(char *nursery_base, size_t size);

    // Allocate in nursery (bump allocation)
    void *allocate(size_t size);

    // Run minor GC (semi-space copy)
    void minorGC(RootSet &roots, OldGenSpace &oldgen);

    // Check if pointer is in nursery
    bool contains(void *ptr) const;

    // Get current allocation stats
    size_t bytesAllocated() const { return alloc_ptr - from_space; }
    size_t bytesRemaining() const { return from_space + (NURSERY_SIZE / 2) - alloc_ptr; }

    // Check if allocation would exceed threshold (for automatic GC triggering)
    bool wouldExceedThreshold(size_t size, float threshold = 0.9f) const {
        size_t aligned_size = (size + 7) & ~7;
        size_t total_capacity = NURSERY_SIZE / 2;
        size_t usage_after = (alloc_ptr - from_space) + aligned_size;
        return usage_after >= (size_t)(total_capacity * threshold);
    }

    // Reset to initial state (for testing)
    void reset(OldGenSpace &oldgen);

#if ENABLE_GC_STATS
    // Get GC statistics
    const GCStats& getStats() const { return stats; }
    GCStats& getStats() { return stats; }
#endif

private:
    char *memory; // Total nursery memory (both semi-spaces)
    char *from_space; // Current allocation space
    char *to_space; // Copy target during GC
    char *alloc_ptr; // Bump allocation pointer
    char *scan_ptr; // Scan pointer for Cheney's algorithm

    TLAB* promotion_tlab; // Thread-local TLAB for promotions to old gen

#if ENABLE_GC_STATS
    GCStats stats; // Performance statistics
#endif

    void evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
};

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
