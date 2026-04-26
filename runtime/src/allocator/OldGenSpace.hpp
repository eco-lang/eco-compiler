#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <unordered_set>
#include <utility>
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

// Per-major-GC phase telemetry. Filled in by majorGC()/finishMarkAndSweep
// when ECO_GC_PHASE_PROFILE is set. Costs nothing when disabled.
struct MajorGCPhaseProfile {
    uint64_t mark_ns        = 0;
    uint64_t sweep_ns       = 0;
    uint64_t capacity_ns    = 0;
    uint64_t mark_iterations = 0;  // Calls to incrementalMark(1000) in the loop.
    uint64_t mark_units_done = 0;  // Total objects popped from mark stack.
    size_t   mark_stack_peak = 0;  // Peak mark-stack depth observed.
    size_t   blocks_scanned  = 0;  // Buffer count walked in sweep.
    size_t   live_bytes_after = 0;
    size_t   garbage_bytes    = 0;
    size_t   shrink_blocks_released = 0;
    size_t   shrink_bytes_released  = 0;
};

// ============================================================================
// Free-List Constants (Segregated-Fits + Big Bag of Pages)
// ============================================================================
//
// The old gen is a segregated-fits allocator backed by a "Big Bag of Pages":
//
//   - At init, the configured initial_old_gen_size is committed as one
//     contiguous region and sliced into pages of `alloc_buffer_size` bytes.
//     Each page extent lives in `unassigned_blocks_` until it is first used.
//
//   - Allocation requests of size < `large_object_threshold` are routed to a
//     fixed-cell size class: small classes (8..256, step 8) and medium
//     classes (powers of two: 512, 1024, 2048, ...). On first use, a class
//     pulls a page from the bag and slices it into uniform Tag_Free cells.
//
//   - Allocation requests in [large_object_threshold, alloc_buffer_size) pull
//     a page from the bag, install a single Tag_Free cell spanning the page,
//     and split it via the larger-cell path (no fixed-cell slicing).
//
//   - Allocation requests >= `alloc_buffer_size` go to allocateLargeBlock,
//     which acquires a dedicated pinned block sized to fit the object.
//
//   - Sweep coalesces adjacent garbage into a single Tag_Free cell and pushes
//     it onto the free list of the appropriate size class. Splitting is the
//     only mechanism that re-divides large free cells into smaller ones.

// Small classes: 32 classes covering 8..256 bytes in steps of 8.
static constexpr size_t NUM_SMALL_CLASSES = 32;
static constexpr size_t MAX_SMALL_SIZE = 256;

// Medium classes: powers of two starting at 512 B. We statically reserve room
// up through 65536 B (8 medium classes), but the runtime cap is set from
// `large_object_threshold` so the actual class count is config-dependent.
static constexpr size_t MEDIUM_CLASS_BASE = 512;
static constexpr size_t NUM_MEDIUM_CLASSES_MAX = 8;  // 512..65536
static constexpr size_t NUM_SIZE_CLASSES =
    NUM_SMALL_CLASSES + NUM_MEDIUM_CLASSES_MAX;

// Bytes to sweep per allocation slow-path invocation.
static constexpr size_t SWEEP_WORK_BUDGET = 4096;

// Incremental marking work ratio (mark N bytes for each byte allocated).
static constexpr size_t MARK_WORK_RATIO = 2;

// ============================================================================
// Free Cell Structure
// ============================================================================
//
// A free cell overlays a span of unallocated bytes and chains into a per-class
// free list. The header carries Tag_Free and the cell's full byte size, so
// any sweep walk can skip over it just like any other heap object.
struct FreeCell {
    Header header;    // Tag_Free; header.size = byte size of this cell.
    FreeCell* next;   // Free-list link, stored in the cell's data area.
};

// Smallest free cell that can be linked into a free list.
static constexpr size_t MIN_FREE_CELL_SIZE = sizeof(FreeCell);

// ============================================================================
// Block Info Structure
// ============================================================================

// Tracks a page (or large block) currently materialized in `blocks_`. A page
// enters `blocks_` only once it has been pulled from `unassigned_blocks_` and
// either populated for a size class or wrapped as a single splittable cell.
struct BlockInfo {
    char* start;            // Start of the page/block (inclusive).
    char* end;              // End of the page/block (exclusive).
    char* end_of_objects;   // Sweep watermark: parse [start, end_of_objects).
    size_t size_class;      // Advisory: preferred class for this page (or
                            // NUM_SIZE_CLASSES if mixed/large).
    bool is_large;          // True for dedicated large-object (pinned) blocks.

    size_t totalBytes() const { return static_cast<size_t>(end - start); }
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
 * Segregated-fits allocator backed by a "Big Bag of Pages": the initial
 * old-gen region is precommitted and sliced into pages, each pulled from the
 * bag on demand. See the file-level comment block above for the full design.
 *
 * Thread-local (one instance per thread).
 */
class OldGenSpace {
public:
    OldGenSpace();
    ~OldGenSpace();

    // ========== Allocation ==========

    // Allocates memory using the segregated-fits + BBoP scheme described
    // above. Acquires additional capacity from the Allocator only if the bag
    // of pages is empty AND no free cell of sufficient size is available.
    void *allocate(size_t size);

    // ========== Queries ==========

    // Returns the current number of bytes allocated in this old gen space.
    size_t getAllocatedBytes() const { return allocated_bytes; }

    // Returns committed capacity of this thread-local old gen (bytes).
    size_t getCommittedBytes() const {
        return (region_end_ > region_base_)
                   ? static_cast<size_t>(region_end_ - region_base_)
                   : 0;
    }

    // True when allocated/committed has reached major_gc_initiating_occupancy.
    // Thread-local: each thread's old gen triggers its own major GC.
    bool shouldTriggerMajorGC() const;

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

    // Runtime number of size classes; depends on `large_object_threshold`.
    // Always satisfies NUM_SMALL_CLASSES <= num_size_classes_ <= NUM_SIZE_CLASSES.
    size_t num_size_classes_;

    // ========== Block Management ==========

    std::vector<BlockInfo> blocks_;        // Pages currently in use.
    size_t allocated_bytes;                // Total bytes currently allocated.

    // Bag of pre-committed-but-unassigned pages (start, end). Each entry is
    // a page of `alloc_buffer_size` bytes carved from the initial region or
    // a post-GC capacity grow.
    std::vector<std::pair<char*, char*>> unassigned_blocks_;

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
    size_t evac_block_index_;                 // Destination block for evacuation bump-allocation.
    char* evac_alloc_ptr_;                    // Bump pointer within evacuation destination block.
    size_t fixup_buffer_index_;               // Block index for reference fixup pass.
    char* fixup_cursor_;                      // Position within current fixup block.

    // ========== Free Lists ==========

    // Segregated free lists indexed by size class.
    // Each list contains free cells of size classToSize(i).
    FreeCell* free_lists_[NUM_SIZE_CLASSES];

    // Indices into `blocks_` of large/pinned blocks whose single object died
    // in the most recent sweep. `allocateLargeBlock` consults this list
    // before asking the Allocator for a fresh block.
    std::vector<size_t> free_large_blocks_;

    // ========== Size Class Helpers ==========

    // Maps an allocation request size to its size-class index. Used at
    // ALLOCATION time: returns the smallest class whose cellSize >= size, so
    // a popped cell can always satisfy the request. Returns NUM_SIZE_CLASSES
    // if the size doesn't fit any fixed-cell class (caller must use the
    // page-as-single-cell + split path).
    static size_t sizeClass(size_t size) {
        size = (size + 7) & ~7;
        if (size <= MAX_SMALL_SIZE) {
            return (size / 8) - 1;  // Classes 0..31 cover 8..256.
        }
        // Medium classes 32..(NUM_SMALL_CLASSES + NUM_MEDIUM_CLASSES_MAX - 1).
        // Class i (i >= 32) holds cells of size MEDIUM_CLASS_BASE << (i - 32).
        // Find smallest medium class that holds `size`.
        size_t cell = MEDIUM_CLASS_BASE;
        for (size_t i = 0; i < NUM_MEDIUM_CLASSES_MAX; ++i) {
            if (size <= cell) return NUM_SMALL_CLASSES + i;
            cell <<= 1;
        }
        return NUM_SIZE_CLASSES;  // Doesn't fit any fixed class.
    }

    // Maps a free-cell SPAN size to the class it can safely live on. Used
    // at PLACEMENT time (split tails, coalesced runs, bag-page tails): returns
    // the LARGEST class whose cellSize <= span, so the fast-path consumer of
    // free_lists_[cls] is guaranteed a cell of at least classToSize(cls)
    // bytes (the invariant the fast path relies on). Returns NUM_SIZE_CLASSES
    // if span is below the smallest cell size (caller must drop or merge it).
    //
    // This differs from `sizeClass` (which rounds UP for allocation lookup):
    // medium classes step by powers of 2, so a 352-byte span placed via
    // sizeClass would land on cls=32 (cellSize=512). The fast path would
    // then hand it out as a 512-byte slot, causing buffer overflow when the
    // caller writes more than 352 bytes. freeListClassFor instead routes
    // 352 bytes to cls=31 (cellSize=256), and leftover bytes are pushed onto
    // smaller classes by the cell-placement helper.
    static size_t freeListClassFor(size_t span) {
        span &= ~static_cast<size_t>(7);
        if (span < 8) return NUM_SIZE_CLASSES;
        if (span <= MAX_SMALL_SIZE) {
            // Small classes step by 8: largest cls with (cls+1)*8 <= span.
            return (span / 8) - 1;
        }
        if (span < MEDIUM_CLASS_BASE) {
            // span in (256, 512): no medium fits. Largest small class (256).
            return NUM_SMALL_CLASSES - 1;
        }
        // Medium: largest k with (MEDIUM_CLASS_BASE << k) <= span.
        size_t k = 0;
        while (k + 1 < NUM_MEDIUM_CLASSES_MAX &&
               (MEDIUM_CLASS_BASE << (k + 1)) <= span) {
            ++k;
        }
        return NUM_SMALL_CLASSES + k;
    }

    // Maps a size class index back to its allocation size in bytes.
    static size_t classToSize(size_t cls) {
        if (cls < NUM_SMALL_CLASSES) return (cls + 1) * 8;
        return MEDIUM_CLASS_BASE << (cls - NUM_SMALL_CLASSES);
    }

    // ========== Internal Methods ==========

    // Initializes this old gen space: precommits `initial_old_gen_size` and
    // slices it into pages stored in `unassigned_blocks_`.
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
    void finishMarkAndSweep(GCStats &stats, MajorGCPhaseProfile &profile);
#else
    void finishMarkAndSweep();
    void finishMarkAndSweep(MajorGCPhaseProfile &profile);
#endif

    void markChildren(void *obj);
    void markHPointer(HPointer &ptr);
    void markUnboxable(Unboxable &val, bool is_boxed);
    void sweep();

    // Lazy sweeping methods.
    void transitionToSweeping();
    void lazySweep(size_t target_class, size_t work_budget);
    void onSweepComplete();

    // Post-major-GC growth: if live/capacity > initiating_occupancy, grow
    // committed capacity so live/capacity <= target_utilization. Bounded by
    // the global old-gen cap. See `major_gc_75_50_policy.md`.
    void adjustCapacityAfterMajorGC();

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

    // ========== Segregated-Fits + BBoP Internal Helpers ==========

    // Top-level dispatch for non-large allocations: tries the size-class
    // fast path, then splitting from larger cells, then population from a
    // bag page.
    void* allocateFromSizeClass(size_t cls, size_t requested_size);

    // Allocates by pulling an unassigned page, wrapping it as a single
    // Tag_Free cell, and splitting off a `requested_size` chunk. Used for
    // allocations in the [large_object_threshold, alloc_buffer_size) range,
    // and as a fallback when no fixed-cell class can satisfy a request.
    void* allocateFromBagPage(size_t requested_size);

    // Walks free lists for classes > target_cls; if a cell large enough is
    // found, carves off `alloc_size` bytes and returns the front, pushing
    // the remainder onto the appropriate free list.
    void* tryAllocateBySplittingLarger(size_t target_cls, size_t alloc_size);

    // Linear scan over `blocks_` to find the BlockInfo whose [start, end)
    // contains addr. Returns nullptr if no block matches (e.g. the address
    // is from a freshly-acquired bag page that hasn't been registered yet).
    // Linear cost: blocks_.size() is bounded by total committed pages.
    const BlockInfo* findBlockContaining(char* addr) const {
        for (const auto& block : blocks_) {
            if (addr >= block.start && addr < block.end) {
                return &block;
            }
        }
        return nullptr;
    }

    // Pulls a page from `unassigned_blocks_`, slices it into uniform cells
    // of `classToSize(cls)`, and links them onto `free_lists_[cls]`. Returns
    // true if a page was available and populated.
    bool populateFromBlock(size_t cls);

    // Initializes an object header in newly allocated memory. Sets color to
    // Black during marking/sweeping (so the object is not treated as garbage
    // mid-cycle), White otherwise. Tag/size are written by the caller.
    void initObjectHeader(void* obj);

    // Allocates a single object that exceeds alloc_buffer_size by acquiring
    // a dedicated old-gen block sized exactly to fit it. The caller is
    // expected to mark the resulting object's header with pin = 1 so it is
    // excluded from compaction.
    void* allocateLargeBlock(size_t size);

    // ========== Large-block reuse helpers ==========

    // Marks `blocks_[idx]` (an `is_large` block whose single object died) as
    // available for reuse via `allocateFromFreeLargeBlocks`. Asserts that
    // the block is not already on the list.
    void markBlockAsFreeLarge(size_t block_index);

    // Returns a previously-released large block sized >= `size`, or nullptr
    // if no such block is available. On success, resets the block's
    // BufferMetadata to live, re-initialises the object header, and updates
    // bookkeeping. The caller initialises the tag/size after.
    void* allocateFromFreeLargeBlocks(size_t size);

    // Looks for a fully-free regular page large enough to host `size` and
    // re-purposes it as a large block. On success, flips `is_large = true`,
    // drops embedded free cells, resets `end_of_objects` and bookkeeping,
    // and returns the page base. Returns nullptr if no such page exists.
    void* allocateFromEmptyRegularBlocks(size_t size);

    // ========== Shrink path helpers ==========
    //
    // Called from `adjustCapacityAfterMajorGC` to release fully-free pages
    // back to the Allocator after a major GC reclaims most live data.
    // Must NOT be called while holding `Allocator::thread_mutex_`; each
    // helper acquires it transiently inside the Allocator.

    // Releases a fully-free block from `blocks_` back to the Allocator.
    // Walks free lists to drop any FreeCell that lies inside the block, drops
    // a `free_large_blocks_` entry if applicable, removes the BlockInfo and
    // BufferMetadata, and patches indices that referenced the moved-from slot.
    void releaseBlockToAllocator(size_t block_index);

    // Releases an unassigned bag-page extent back to the Allocator. These
    // pages were never materialized into `blocks_`, so this is just an
    // Allocator round-trip plus a swap-remove from `unassigned_blocks_`.
    void releaseUnassignedBlockToAllocator(size_t unassigned_index);

    // Removes any FreeCell that lies inside `[blocks_[idx].start, ...end)`
    // from every per-class free list. Called before releasing a block so
    // its embedded free cells don't leave dangling free-list pointers.
    void removeFreeCellsForBlock(size_t block_index);

    // Patches indices stored in BufferMetadata, evacuation_set_,
    // evac_block_index_, sweep_buffer_index_, fixup_buffer_index_, and
    // free_large_blocks_ when blocks_ has had a swap-remove move the
    // last-index entry to old_idx. Called by releaseBlockToAllocator.
    void fixupIndicesAfterBlockMove(size_t old_idx, size_t new_idx);

    // Inspects post-GC live/heap and, if heap is well above the desired
    // capacity, releases fully-free pages until heap ≈ desired_heap.
    void maybeShrinkCapacity();

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
    static size_t freeListClassFor(size_t span) {
        return OldGenSpace::freeListClassFor(span);
    }

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
        assert(cls < NUM_SIZE_CLASSES && "getFreeList: invalid size class (>= NUM_SIZE_CLASSES)");
        return oldgen.free_lists_[cls];
    }

    // Block metadata.
    static const std::vector<BufferMetadata>& getBufferMeta(const OldGenSpace& oldgen) {
        return oldgen.buffer_meta_;
    }
    static const std::vector<BlockInfo>& getBlocks(const OldGenSpace& oldgen) {
        return oldgen.blocks_;
    }
    static const std::vector<std::pair<char*, char*>>& getUnassignedBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.unassigned_blocks_;
    }
    static const std::vector<size_t>& getFreeLargeBlocks(
            const OldGenSpace& oldgen) {
        return oldgen.free_large_blocks_;
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
