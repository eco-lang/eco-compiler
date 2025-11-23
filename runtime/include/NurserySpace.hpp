#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

#include <vector>
#include "AllocatorCommon.hpp"
#include "GCStats.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"
#include "TLAB.hpp"

namespace Elm {

/**
 * Thread-local nursery with semi-space copying collector (Cheney's algorithm).
 *
 * Objects are allocated via bump pointer in from_space. When full, minorGC
 * evacuates live objects to to_space (or promotes to old gen), then swaps spaces.
 */
class NurserySpace {
public:
    NurserySpace();
    ~NurserySpace();

    // Initializes this nursery with the given memory region from the main heap.
    void initialize(char *nursery_base, size_t size);

    // Allocates memory in the nursery using bump pointer. Returns nullptr if full.
    void *allocate(size_t size);

    // Performs minor GC, evacuating live objects to to_space or promoting to old gen.
    void minorGC(RootSet &roots, OldGenSpace &oldgen);

    // Returns true if the pointer points into this nursery's memory region.
    bool contains(void *ptr) const;

    // Returns the number of bytes currently allocated in the nursery.
    size_t bytesAllocated() const { return alloc_ptr - from_space; }

    // Returns the number of bytes still available for allocation.
    size_t bytesRemaining() const { return from_space + (NURSERY_SIZE / 2) - alloc_ptr; }

    // Returns true if the given allocation would push usage above the threshold.
    bool wouldExceedThreshold(size_t size, float threshold = NURSERY_GC_THRESHOLD) const {
        size_t aligned_size = (size + 7) & ~7;
        size_t total_capacity = NURSERY_SIZE / 2;
        size_t usage_after = (alloc_ptr - from_space) + aligned_size;
        return usage_after >= (size_t)(total_capacity * threshold);
    }

    // Resets the nursery to initial state. Used for testing.
    void reset(OldGenSpace &oldgen);

#if ENABLE_GC_STATS
    // Returns the GC statistics for this nursery.
    const GCStats& getStats() const { return stats; }
    GCStats& getStats() { return stats; }
#endif

private:
    char *memory;         // Total nursery memory (both semi-spaces).
    char *from_space;     // Current allocation space.
    char *to_space;       // Copy target during GC.
    char *alloc_ptr;      // Bump allocation pointer.
    char *scan_ptr;       // Cheney scan pointer during evacuation.

    TLAB* promotion_tlab; // TLAB for lock-free promotions to old gen.

#if ENABLE_GC_STATS
    GCStats stats;        // Performance statistics.
#endif

    void evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
};

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
