#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <unordered_set>
#include <vector>
#include "AllocatorCommon.hpp"
#include "AllocBuffer.hpp"
#include "RootSet.hpp"
#include "GCStats.hpp"

namespace Elm {

// ============================================================================
// GC Phase State Machine
// ============================================================================

enum class GCPhase {
    Idle,       // No collection in progress.
    Marking,    // Incremental marking in progress.
    Sweeping    // Lazy sweeping in progress.
};

// ============================================================================
// Free-List Constants
// ============================================================================

// Number of segregated free lists (size classes 0..31 for sizes 8..256 bytes).
static constexpr size_t NUM_SIZE_CLASSES = 32;

// Maximum object size handled by free lists. Larger objects use bump allocation only.
static constexpr size_t MAX_SMALL_SIZE = 256;

// Bytes to sweep per allocation slow-path.
static constexpr size_t SWEEP_WORK_BUDGET = 4096;

// Marking work ratio: mark N bytes for each byte allocated during marking.
static constexpr size_t MARK_WORK_RATIO = 2;

// ============================================================================
// Free Cell Structure
// ============================================================================

// A free cell in the segregated free list. Overlays the object's memory.
// Size is implicit from the size class.
struct FreeCell {
    FreeCell* next;
};

// ============================================================================
// Per-Buffer Metadata
// ============================================================================

// Tracks per-buffer statistics for evacuation decisions.
struct BufferMetadata {
    AllocBuffer* buffer;
    size_t live_bytes;      // Computed during sweep.
    size_t garbage_bytes;   // Computed during sweep.
    bool fully_swept;       // True when sweep of this buffer is complete.

    float liveness() const {
        size_t total = buffer->usedBytes();
        return total > 0 ? static_cast<float>(live_bytes) / total : 0.0f;
    }
};

// ============================================================================
// Fragmentation Statistics
// ============================================================================

// Heap-wide fragmentation metrics computed after each sweep.
struct FragmentationStats {
    size_t total_free_bytes;    // Sum of all free cells (garbage reclaimed).
    size_t live_bytes;          // Bytes in live objects.
    size_t heap_bytes;          // Total committed heap (sum of used buffer space).

    // Returns heap utilization as a fraction [0, 1].
    // Low utilization indicates high fragmentation or garbage.
    float utilization() const {
        return heap_bytes > 0 ? static_cast<float>(live_bytes) / heap_bytes : 0.0f;
    }
};

// Threshold below which compaction should be triggered.
static constexpr float UTILIZATION_THRESHOLD = 0.70f;

// Target heap utilization after returning surplus buffers.
static constexpr float BUFFER_RETURN_THRESHOLD = 0.50f;

// Maximum bytes of live data to move per compaction slice.
static constexpr size_t COMPACTION_WORK_BUDGET = 8192;

// ============================================================================
// Compaction State Machine
// ============================================================================

enum class CompactionPhase {
    Idle,           // No compaction in progress.
    Evacuating,     // Moving live objects out of source buffers.
    FixingRefs      // Updating pointers to forwarding addresses.
};

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

    // Returns true if the pointer is within the old gen region.
    // O(1) using cached bounds. Inline for performance.
    inline bool contains(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= region_base_ && p < region_end_;
    }

private:
    // ========== Configuration ==========

    const HeapConfig* config_;    // Heap configuration parameters.
    Allocator* allocator_;        // Back-reference for acquiring buffers.

    // ========== AllocBuffer Collection ==========

    std::vector<AllocBuffer*> buffers_;   // All buffers owned by old gen.
    AllocBuffer* current_buffer_;          // Active buffer for allocation.
    size_t allocated_bytes;                // Current bytes in use.

    // Cached bounds for O(1) membership checks.
    char* region_base_;                    // Start of old gen region.
    char* region_end_;                     // End of committed old gen region.

    // ========== GC State Machine ==========

    GCPhase gc_phase_;                // Current GC phase (Idle, Marking, Sweeping).

    // ========== Marking State ==========

    std::vector<void *> mark_stack;   // Objects awaiting marking.
    u32 current_epoch;                // Current GC epoch number.
    bool marking_active;              // True if marking is in progress (legacy, kept for compatibility).
    Allocator *allocator_ref_;        // Reference to Allocator for nursery checks during marking.

    // ========== Lazy Sweep State ==========

    size_t sweep_buffer_index_;       // Which buffer we're currently sweeping.
    char* sweep_cursor_;              // Position within current buffer.
    std::vector<BufferMetadata> buffer_meta_;  // Per-buffer metadata.

    // ========== Fragmentation Statistics ==========

    FragmentationStats frag_stats_;   // Computed after each sweep completes.

    // ========== Compaction State ==========

    CompactionPhase compact_phase_;           // Current compaction phase.
    std::vector<size_t> evacuation_set_;      // Buffer indices to evacuate.
    size_t current_evac_index_;               // Current buffer being evacuated.
    char* evac_cursor_;                       // Position within current evacuation buffer.
    size_t fixup_buffer_index_;               // Buffer index for reference fixup.
    char* fixup_cursor_;                      // Position within fixup buffer.

    // ========== Free Lists ==========

    // Segregated free lists indexed by size class.
    // Each list contains free cells of size classToSize(i).
    FreeCell* free_lists_[NUM_SIZE_CLASSES];

    // ========== Size Class Helpers ==========

    // Maps an allocation size to a size class index.
    // Returns NUM_SIZE_CLASSES for sizes > MAX_SMALL_SIZE (large objects).
    static size_t sizeClass(size_t size) {
        size = (size + 7) & ~7;  // Align to 8 bytes.
        if (size <= MAX_SMALL_SIZE) {
            return (size / 8) - 1;  // Classes 0..31 for sizes 8..256.
        }
        return NUM_SIZE_CLASSES;  // Large object marker.
    }

    // Maps a size class index back to the allocation size.
    static size_t classToSize(size_t cls) {
        return (cls + 1) * 8;
    }

    // ========== Internal Methods ==========

    // Initializes the old generation with a reference to the allocator.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Resets to initial state, clearing all allocated objects. Used for testing.
    // If new_config is provided, reconfigures with new parameters.
    void reset(const HeapConfig* new_config = nullptr);

    // Begins marking phase, pushing roots onto the mark stack.
    // Takes collected roots and Allocator reference for nursery checks.
#if ENABLE_GC_STATS
    void startMark(const std::unordered_set<HPointer*> &roots, Allocator &alloc, GCStats &stats);
#else
    void startMark(const std::unordered_set<HPointer*> &roots, Allocator &alloc);
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

    // Lazy sweeping methods.
    void transitionToSweeping();
    void lazySweep(size_t target_class, size_t work_budget);
    void onSweepComplete();

    // Fragmentation and compaction methods.
    bool shouldCompact() const;
    void computeFragmentationStats();
    void scheduleCompaction();
    std::vector<size_t> selectEvacuationSet(size_t max_live_to_move);
    void incrementalCompactionSlice(size_t work_budget);
    size_t evacuateSlice(size_t work_budget);
    void prepareReferenceFixup();
    void fixReferencesSlice(size_t work_budget);
    void fixPointersInObject(void* obj);
    void fixHPointer(HPointer& ptr);
    void fixUnboxable(Unboxable& val, bool is_boxed);
    void* allocateForEvacuation(size_t size);
    void installForwardingPointer(void* old_location, void* new_location);
    void* getForwardingAddress(void* obj) const;
    bool isInEvacuationSet(size_t buffer_index) const;
    void freeEvacuatedBuffers();

    // Helper for bump allocation (used when free list is empty).
    void* bumpAllocate(size_t size);

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
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
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
    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
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

    // Size class helpers.
    static size_t sizeClass(size_t size) { return OldGenSpace::sizeClass(size); }
    static size_t classToSize(size_t cls) { return OldGenSpace::classToSize(cls); }

    // GC phase state.
    static GCPhase getGCPhase(const OldGenSpace& oldgen) { return oldgen.gc_phase_; }
    static CompactionPhase getCompactPhase(const OldGenSpace& oldgen) { return oldgen.compact_phase_; }

    // Sweep state.
    static size_t getSweepBufferIndex(const OldGenSpace& oldgen) { return oldgen.sweep_buffer_index_; }
    static const char* getSweepCursor(const OldGenSpace& oldgen) { return oldgen.sweep_cursor_; }

    // Fragmentation stats.
    static const FragmentationStats& getFragStats(const OldGenSpace& oldgen) { return oldgen.frag_stats_; }

    // Free lists.
    static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls) {
        return cls < NUM_SIZE_CLASSES ? oldgen.free_lists_[cls] : nullptr;
    }

    // Buffer metadata.
    static const std::vector<BufferMetadata>& getBufferMeta(const OldGenSpace& oldgen) {
        return oldgen.buffer_meta_;
    }
    static const std::vector<AllocBuffer*>& getBuffers(const OldGenSpace& oldgen) {
        return oldgen.buffers_;
    }

    // Manual control of lazy sweeping for testing.
    static void transitionToSweeping(OldGenSpace& oldgen) { oldgen.transitionToSweeping(); }
    static void lazySweep(OldGenSpace& oldgen, size_t target_class, size_t work_budget) {
        oldgen.lazySweep(target_class, work_budget);
    }

    // Compaction control for testing.
    static void scheduleCompaction(OldGenSpace& oldgen) { oldgen.scheduleCompaction(); }
    static void incrementalCompactionSlice(OldGenSpace& oldgen, size_t work_budget) {
        oldgen.incrementalCompactionSlice(work_budget);
    }
    static const std::vector<size_t>& getEvacuationSet(const OldGenSpace& oldgen) {
        return oldgen.evacuation_set_;
    }
    static void* getForwardingAddress(const OldGenSpace& oldgen, void* obj) {
        return oldgen.getForwardingAddress(obj);
    }
};

} // namespace Elm

#endif // ECO_OLDGENSPACE_H
