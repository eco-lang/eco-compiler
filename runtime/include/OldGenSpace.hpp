#ifndef ECO_OLDGENSPACE_H
#define ECO_OLDGENSPACE_H

#include <atomic>
#include <mutex>
#include <vector>
#include "AllocatorCommon.hpp"
#include "RootSet.hpp"
#include "TLAB.hpp"
#include "GCStats.hpp"

namespace Elm {

// Follows a forwarding pointer if present, updating the HPointer in place.
void* readBarrier(HPointer& ptr);

/**
 * Old generation with concurrent mark-and-sweep and optional compaction.
 *
 * Uses free-list allocation protected by a recursive mutex. Supports TLABs
 * for lock-free promotion from nurseries during minor GC.
 */
class OldGenSpace {
public:
    OldGenSpace();
    ~OldGenSpace();

    // ========== Initialization ==========

    // Initializes the old generation with a memory region from the main heap.
    void initialize(char *base, size_t initial_size, size_t max_size);

    // Resets to initial state, clearing all allocated objects. Used for testing.
    void reset();

    // ========== Allocation ==========

    // Allocates memory using the free list. Thread-safe via internal locking.
    void *allocate(size_t size);

    // Allocates a new TLAB of the given size for lock-free promotion.
    TLAB* allocateTLAB(size_t size);

    // Seals an exhausted TLAB, adding it to the list for sweeping.
    void sealTLAB(TLAB* tlab);

    // ========== Mark-and-Sweep ==========

    // Begins a concurrent marking phase, pushing roots onto the mark stack.
#if ENABLE_GC_STATS
    void startConcurrentMark(RootSet &roots, GCStats &stats);
#else
    void startConcurrentMark(RootSet &roots);
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

    // ========== Queries ==========

    // Returns true if the pointer points into this old generation's memory.
    bool contains(void *ptr) const;

    // Returns the current number of bytes allocated in old gen.
    size_t getAllocatedBytes() const { return allocated_bytes.load(); }

    // Returns the maximum size this old gen can grow to.
    size_t getMaxSize() const { return max_region_size; }

    // ========== Compaction ==========

    // Selects sparsely-occupied blocks as candidates for evacuation.
    void selectCompactionSet();

    // Evacuates all objects from selected blocks to destination blocks.
    void performCompaction();

    // Evacuates all live objects from the specified block.
    void evacuateBlock(size_t block_index);

    // Converts fully-evacuated blocks into TLABs for reuse.
    void reclaimEvacuatedBlocks();

    // Returns true if compaction is currently in progress.
    bool isCompactionInProgress() const { return compaction_in_progress.load(); }

    // Sets the compaction-in-progress flag.
    void setCompactionInProgress(bool val) { compaction_in_progress.store(val); }

    // ========== Locking ==========

    // RAII lock guard for multi-operation critical sections.
    // Prefer adding atomic methods over using this directly.
    class ScopedLock {
    public:
        explicit ScopedLock(OldGenSpace &space)
            : lock_(space.alloc_mutex) {}
    private:
        std::lock_guard<std::recursive_mutex> lock_;
    };

private:
    struct FreeBlock {
        size_t size;
        FreeBlock *next;
    };

    // Metadata for compaction decisions.
    struct BlockInfo {
        char* start;
        char* end;
        size_t block_size;
        size_t live_bytes;           // Tracked during marking.
        size_t live_count;           // Number of live objects.
        bool is_evacuation_target;   // Selected for evacuation.
        bool is_evacuation_dest;     // Can receive evacuated objects.

        BlockInfo() : start(nullptr), end(nullptr), block_size(0),
                     live_bytes(0), live_count(0),
                     is_evacuation_target(false), is_evacuation_dest(false) {}
    };

    // ========== Memory Region ==========

    char *region_base;            // Base of assigned region in main heap.
    size_t region_size;           // Current committed size.
    size_t max_region_size;       // Maximum size this region can grow to.
    std::atomic<size_t> allocated_bytes{0};  // Current bytes in use.
    std::vector<char *> chunks;   // Memory chunks within the region.
    FreeBlock *free_list;         // Head of the free list.
    std::recursive_mutex alloc_mutex; // Protects free list; recursive for GC.

    // ========== Marking State ==========

    std::vector<void *> mark_stack;   // Objects awaiting marking.
    std::recursive_mutex mark_mutex;  // Protects marking operations.
    std::atomic<u32> current_epoch;   // Current GC epoch number.
    std::atomic<bool> marking_active; // True if marking is in progress.

    // ========== TLAB Support ==========

    std::atomic<char*> tlab_bump_ptr; // Lock-free bump pointer for TLAB creation.
    char* tlab_region_start;          // Start of TLAB region.
    char* tlab_region_end;            // End of TLAB region.
    std::mutex sealed_tlabs_mutex;    // Protects sealed_tlabs vector.
    std::vector<TLAB*> sealed_tlabs;  // Exhausted TLABs awaiting sweep.

    // ========== Compaction State ==========

    std::vector<BlockInfo> blocks;    // Block metadata for compaction.
    std::atomic<bool> compaction_in_progress{false};
    std::atomic<char*> compaction_frontier;   // Allocation point for compaction.
    std::mutex available_tlabs_mutex;         // Protects available_tlabs.
    std::vector<TLAB*> available_tlabs;       // TLABs reclaimed from compaction.

    // Internal allocation. Caller must hold alloc_mutex.
    void *allocate_internal(size_t size);

    void mark(void *obj);
    void markChildren(void *obj);
    void markHPointer(HPointer &ptr);
    void markUnboxable(Unboxable &val, bool is_boxed);
    void sweep();

    // Adds a new memory chunk. Caller must hold alloc_mutex.
    void addChunk(size_t size);

    void evacuateObject(void* obj);
    void* allocateForCompaction(size_t size);
    BlockInfo* getBlockForObject(void* obj);
    void initializeBlocks();
    void updateBlockLiveInfo(void* obj, size_t size);

    friend class NurserySpace;
    friend class ScopedLock;
};

} // namespace Elm

#endif // ECO_OLDGENSPACE_H
