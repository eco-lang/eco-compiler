#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <vector>
#include "AllocatorCommon.hpp"
#include "AllocBuffer.hpp"
#include "RootSet.hpp"
#include "GCStats.hpp"

namespace Elm {

// Forward declarations.
class Allocator;
class OldGenSpaceTestAccess;

// Follows a forwarding pointer if present, updating the HPointer in place.
// Note: This is primarily for test code; production code uses Allocator::resolve().
void* readBarrier(HPointer& ptr);

/**
 * Old generation with mark-and-sweep collection.
 *
 * Uses AllocBuffer-based bump-pointer allocation. Each AllocBuffer is a
 * contiguous region of memory obtained from the Allocator. Objects are
 * allocated by bumping a pointer within the current buffer.
 *
 * Single-threaded version.
 */
class OldGenSpace {
public:
    OldGenSpace();
    ~OldGenSpace();

    // ========== Allocation ==========

    // Allocates memory using bump pointer in current AllocBuffer.
    // Acquires new buffer from Allocator if current is exhausted.
    void *allocate(size_t size);

    // ========== Queries ==========

    // Returns the current number of bytes allocated in old gen.
    size_t getAllocatedBytes() const { return allocated_bytes; }

    // Returns true if the pointer is within any of this old gen's buffers.
    bool contains(void* ptr) const;

private:
    // ========== Configuration ==========

    const HeapConfig* config_;    // Heap configuration parameters.
    Allocator* allocator_;        // Back-reference for acquiring buffers.

    // ========== AllocBuffer Collection ==========

    std::vector<AllocBuffer*> buffers_;   // All buffers owned by old gen.
    AllocBuffer* current_buffer_;          // Active buffer for allocation.
    size_t allocated_bytes;                // Current bytes in use.

    // ========== Marking State ==========

    std::vector<void *> mark_stack;   // Objects awaiting marking.
    u32 current_epoch;                // Current GC epoch number.
    bool marking_active;              // True if marking is in progress.
    Allocator *allocator_ref_;        // Reference to Allocator for nursery checks during marking.

    // ========== Internal Methods ==========

    // Initializes the old generation with a reference to the allocator.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Resets to initial state, clearing all allocated objects. Used for testing.
    // If new_config is provided, reconfigures with new parameters.
    void reset(const HeapConfig* new_config = nullptr);

    // Begins marking phase, pushing roots onto the mark stack.
    // Takes collected roots and Allocator reference for nursery checks.
#if ENABLE_GC_STATS
    void startMark(const std::vector<HPointer*> &roots, Allocator &alloc, GCStats &stats);
#else
    void startMark(const std::vector<HPointer*> &roots, Allocator &alloc);
#endif

    // Performs incremental marking work. Returns true if more work remains.
#if ENABLE_GC_STATS
    bool incrementalMark(size_t work_units, GCStats &stats);
#else
    bool incrementalMark(size_t work_units);
#endif

    // Completes marking and performs sweep to reclaim unmarked objects.
#if ENABLE_GC_STATS
    void finishMarkAndSweep(GCStats &stats);
#else
    void finishMarkAndSweep();
#endif

    void markChildren(void *obj);
    void markHPointer(HPointer &ptr);
    void markUnboxable(Unboxable &val, bool is_boxed);
    void sweep();

    friend class Allocator;
    friend class NurserySpace;
    friend class ThreadLocalHeap;
    friend class OldGenSpaceTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to OldGenSpace internals.
class OldGenSpaceTestAccess {
public:
#if ENABLE_GC_STATS
    static void startMark(OldGenSpace& oldgen, const std::vector<HPointer*>& roots,
                          Allocator& alloc, GCStats& stats) {
        oldgen.startMark(roots, alloc, stats);
    }

    static bool incrementalMark(OldGenSpace& oldgen, size_t work_units, GCStats& stats) {
        return oldgen.incrementalMark(work_units, stats);
    }

    static void finishMarkAndSweep(OldGenSpace& oldgen, GCStats& stats) {
        oldgen.finishMarkAndSweep(stats);
    }
#else
    static void startMark(OldGenSpace& oldgen, const std::vector<HPointer*>& roots,
                          Allocator& alloc) {
        oldgen.startMark(roots, alloc);
    }

    static bool incrementalMark(OldGenSpace& oldgen, size_t work_units) {
        return oldgen.incrementalMark(work_units);
    }

    static void finishMarkAndSweep(OldGenSpace& oldgen) {
        oldgen.finishMarkAndSweep();
    }
#endif
};

} // namespace Elm

#endif // ECO_OLDGENSPACE_H
