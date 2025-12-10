#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <unordered_set>
#include <vector>
#include "AllocatorCommon.hpp"
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

// Number of segregated free lists (size classes 0-31 for 8-256 byte objects).
static constexpr size_t NUM_SIZE_CLASSES = 32;

// Maximum object size for free list allocation (larger objects use bump allocation).
static constexpr size_t MAX_SMALL_SIZE = 256;

// Bytes to sweep per allocation slow-path invocation.
static constexpr size_t SWEEP_WORK_BUDGET = 4096;

// Incremental marking work ratio (mark N bytes for each byte allocated).
static constexpr size_t MARK_WORK_RATIO = 2;

// ============================================================================
// Free Cell Structure
// ============================================================================

// A free cell in the segregated free list.
// Overlays a freed object's memory, preserving the header for size calculation.
//
// The original Header is preserved to allow getObjectSize() to work correctly
// during subsequent GC sweeps. The next pointer is stored after the header,
// in the space that would normally hold object data. This requires all free
// list objects to be at least sizeof(Header) + sizeof(FreeCell*) = 16 bytes.
struct FreeCell {
    Header header;    // Preserved original header (8 bytes)
    FreeCell* next;   // Free list link (8 bytes, stored in object's data area)
};

// ============================================================================
// Block Info Structure
// ============================================================================

// Tracks a memory block for bump-pointer allocation.
// Simpler replacement for the previous AllocBuffer abstraction.
struct BlockInfo {
    char* start;        // Start of the memory block.
    char* end;          // End of the memory block (exclusive).
    char* alloc_ptr;    // Current allocation pointer (bump pointer).

    // Returns the number of bytes used in this block.
    size_t usedBytes() const { return alloc_ptr - start; }

    // Returns the number of remaining bytes available for allocation.
    size_t remainingBytes() const { return end - alloc_ptr; }

    // Allocates memory from this block using bump pointer.
    // Returns nullptr if not enough space.
    void* allocate(size_t size) {
        size = (size + 7) & ~7;  // Align to 8 bytes.
        if (alloc_ptr + size > end) {
            return nullptr;
        }
        void* result = alloc_ptr;
        alloc_ptr += size;
        return result;
    }
};

// ============================================================================
// Per-Block Metadata
// ============================================================================

// Tracks per-block statistics for compaction decisions.
struct BufferMetadata {
    size_t block_index;     // Index into blocks_ vector.
    size_t live_bytes;      // Live object bytes (computed during sweep).
    size_t garbage_bytes;   // Garbage bytes (computed during sweep).
    bool fully_swept;       // True when this block has been fully swept.
};

// ============================================================================
// Fragmentation Statistics
// ============================================================================

// Heap-wide fragmentation metrics (computed after each sweep completes).
struct FragmentationStats {
    size_t total_free_bytes;    // Total bytes in free lists (reclaimed garbage).
    size_t live_bytes;          // Total bytes in live objects.
    size_t heap_bytes;          // Total committed heap bytes (all blocks).

    // Returns heap utilization as a fraction in range [0.0, 1.0].
    // Low utilization indicates fragmentation or excess garbage.
    float utilization() const {
        return heap_bytes > 0 ? static_cast<float>(live_bytes) / heap_bytes : 0.0f;
    }
};

// Utilization threshold below which compaction is triggered.
static constexpr float UTILIZATION_THRESHOLD = 0.70f;

// Target utilization after returning surplus buffers to the OS.
static constexpr float BUFFER_RETURN_THRESHOLD = 0.50f;

// Maximum bytes of live data to evacuate per incremental compaction slice.
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
// Primarily for test code; production uses Allocator::resolve() instead.
void* readBarrier(HPointer& ptr);

/**
 * Old generation with mark-and-sweep collection.
 *
 * Uses block-based bump-pointer allocation with lazy sweeping. Each block
 * is a contiguous region obtained from the Allocator. Objects are allocated
 * by bumping a pointer within the current block, falling back to free lists
 * for smaller objects after sweeping.
 *
 * Thread-local (one instance per thread).
 */
class OldGenSpace {
public:
    OldGenSpace();
    ~OldGenSpace();

    // ========== Allocation ==========

    // Allocates memory using bump pointer allocation.
    // Acquires a new block from the Allocator if the current block is exhausted.
    void *allocate(size_t size);

    // ========== Queries ==========

    // Returns the current number of bytes allocated in this old gen space.
    size_t getAllocatedBytes() const { return allocated_bytes; }

    // Returns true if the pointer is within this old gen's committed region.
    // O(1) check using cached bounds. Inlined for performance.
    inline bool contains(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= region_base_ && p < region_end_;
    }

private:
    // ========== Configuration ==========

    const HeapConfig* config_;    // Heap configuration parameters.
    Allocator* allocator_;        // Back-reference for acquiring buffers.

    // ========== Block Management ==========

    std::vector<BlockInfo> blocks_;        // All memory blocks owned by this old gen.
    size_t current_block_index_;           // Index of active allocation block (or -1).
    size_t allocated_bytes;                // Total bytes currently allocated.

    // Cached bounds for O(1) membership checks (updated when blocks change).
    char* region_base_;                    // Start of old gen region.
    char* region_end_;                     // End of committed old gen region.

    // ========== GC State Machine ==========

    GCPhase gc_phase_;                // Current GC phase (Idle, Marking, or Sweeping).

    // ========== Marking State ==========

    std::vector<void *> mark_stack;   // Stack of objects awaiting marking (grey set).
    u32 current_epoch;                // Current GC epoch number (increments each cycle).
    bool marking_active;              // True if marking is in progress (legacy flag).
    Allocator *allocator_ref_;        // Reference to Allocator (for nursery membership checks).

    // ========== Lazy Sweep State ==========

    size_t sweep_buffer_index_;       // Index of block currently being swept.
    char* sweep_cursor_;              // Current position within sweep block.
    std::vector<BufferMetadata> buffer_meta_;  // Per-block metadata for compaction.

    // ========== Fragmentation Statistics ==========

    FragmentationStats frag_stats_;   // Heap-wide fragmentation stats (updated after sweep).

    // ========== Compaction State ==========

    CompactionPhase compact_phase_;           // Current compaction phase (Idle, Evacuating, or FixingRefs).
    std::vector<size_t> evacuation_set_;      // Block indices selected for evacuation.
    size_t current_evac_index_;               // Index within evacuation_set_ being processed.
    char* evac_cursor_;                       // Position within current evacuation block.
    size_t fixup_buffer_index_;               // Block index for reference fixup pass.
    char* fixup_cursor_;                      // Position within current fixup block.

    // ========== Free Lists ==========

    // Segregated free lists indexed by size class.
    // Each list contains free cells of size classToSize(i).
    FreeCell* free_lists_[NUM_SIZE_CLASSES];

    // ========== Size Class Helpers ==========

    // Maps an allocation size to its segregated free list index.
    // Returns NUM_SIZE_CLASSES for sizes > MAX_SMALL_SIZE (use bump allocation).
    static size_t sizeClass(size_t size) {
        size = (size + 7) & ~7;  // Align to 8 bytes.
        if (size <= MAX_SMALL_SIZE) {
            return (size / 8) - 1;  // Classes 0-31 map to sizes 8-256.
        }
        return NUM_SIZE_CLASSES;  // Large object indicator.
    }

    // Maps a size class index back to its allocation size in bytes.
    static size_t classToSize(size_t cls) {
        return (cls + 1) * 8;
    }

    // ========== Internal Methods ==========

    // Initializes this old gen space with allocator reference and configuration.
    void initialize(Allocator* allocator, const HeapConfig* config);

    // Resets to initial state (clears all blocks, stats, and GC state).
    // If new_config is provided, reconfigures with new parameters. Used for testing.
    void reset(const HeapConfig* new_config = nullptr);

    // Begins incremental marking phase.
    // Pushes all root pointers onto the mark stack for processing.
    // jit_roots contains raw 64-bit heap pointers from JIT-compiled globals.
#if ENABLE_GC_STATS
    void startMark(const std::unordered_set<HPointer*> &roots,
                   const std::unordered_set<uint64_t*> &jit_roots,
                   Allocator &alloc, GCStats &stats);
#else
    void startMark(const std::unordered_set<HPointer*> &roots,
                   const std::unordered_set<uint64_t*> &jit_roots,
                   Allocator &alloc);
#endif

    // Performs incremental marking work (processes work_units worth of objects).
    // Returns true if more marking work remains.
#if ENABLE_GC_STATS
    bool incrementalMark(size_t work_units, GCStats &stats);
#else
    bool incrementalMark(size_t work_units);
#endif

    // Finishes any remaining marking work and transitions to lazy sweeping.
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
        std::unordered_set<uint64_t*> empty_jit_roots;
        oldgen.startMark(roots, empty_jit_roots, alloc, stats);
    }

    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          const std::unordered_set<uint64_t*>& jit_roots,
                          Allocator& alloc, GCStats& stats) {
        oldgen.startMark(roots, jit_roots, alloc, stats);
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
        std::unordered_set<uint64_t*> empty_jit_roots;
        oldgen.startMark(roots, empty_jit_roots, alloc);
    }

    static void startMark(OldGenSpace& oldgen, const std::unordered_set<HPointer*>& roots,
                          const std::unordered_set<uint64_t*>& jit_roots,
                          Allocator& alloc) {
        oldgen.startMark(roots, jit_roots, alloc);
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

    // Block metadata.
    static const std::vector<BufferMetadata>& getBufferMeta(const OldGenSpace& oldgen) {
        return oldgen.buffer_meta_;
    }
    static const std::vector<BlockInfo>& getBlocks(const OldGenSpace& oldgen) {
        return oldgen.blocks_;
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
