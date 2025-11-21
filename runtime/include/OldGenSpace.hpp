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

// Old generation space with concurrent mark-and-sweep
class OldGenSpace {
public:
    OldGenSpace();
    ~OldGenSpace();

    // Initialize with assigned region from main heap
    void initialize(char *base, size_t initial_size, size_t max_size);

    // Allocate in old gen (free list allocation)
    void *allocate(size_t size);

    // Start concurrent marking phase
#if ENABLE_GC_STATS
    void startConcurrentMark(RootSet &roots, GCStats &stats);
#else
    void startConcurrentMark(RootSet &roots);
#endif

    // Perform incremental marking work
#if ENABLE_GC_STATS
    bool incrementalMark(size_t work_units, GCStats &stats);
#else
    bool incrementalMark(size_t work_units);
#endif

    // Complete marking and sweep
#if ENABLE_GC_STATS
    void finishMarkAndSweep(GCStats &stats);
#else
    void finishMarkAndSweep();
#endif

    // Check if pointer is in old gen
    bool contains(void *ptr) const;

    // Reset to initial state (for testing)
    void reset();

    // TLAB allocation methods
    TLAB* allocateTLAB(size_t size);
    void sealTLAB(TLAB* tlab);

    // RAII lock guard for multi-operation critical sections
    // WARNING: Use this ONLY when absolutely unavoidable!
    // Prefer creating a new public method that performs the entire operation atomically.
    // This class exists for rare cases where external code must coordinate multiple
    // operations under a single lock, but such cases should be carefully reviewed.
    class ScopedLock {
    public:
        explicit ScopedLock(OldGenSpace &space)
            : lock_(space.alloc_mutex) {}
        // Automatic unlock on destruction via std::lock_guard
    private:
        std::lock_guard<std::recursive_mutex> lock_;
    };

    // TLAB constants
    static constexpr size_t TLAB_DEFAULT_SIZE = 128 * 1024; // 128KB
    static constexpr size_t TLAB_MIN_SIZE = 64 * 1024;      // 64KB minimum

private:
    struct FreeBlock {
        size_t size;
        FreeBlock *next;
    };

    char *region_base; // Base of assigned region in main heap
    size_t region_size; // Current committed size
    size_t max_region_size; // Maximum size can grow to
    std::vector<char *> chunks; // Memory chunks (within region)
    FreeBlock *free_list; // Free list for allocation
    std::recursive_mutex alloc_mutex; // Recursive mutex for allocation (allows re-entrant calls)

    std::vector<void *> mark_stack; // Stack for marking
    std::recursive_mutex mark_mutex; // Recursive mutex for marking operations

    std::atomic<u32> current_epoch; // Current GC epoch
    std::atomic<bool> marking_active; // Is marking in progress?

    // TLAB (Thread-Local Allocation Buffer) support
    std::atomic<char*> tlab_bump_ptr;  // Atomic bump pointer for TLAB creation
    char* tlab_region_start;           // Start of TLAB region
    char* tlab_region_end;             // End of TLAB region
    std::mutex sealed_tlabs_mutex;     // Protects sealed_tlabs vector
    std::vector<TLAB*> sealed_tlabs;   // TLABs awaiting sweep

    // Internal allocation without locking
    // REQUIRES: Caller must hold alloc_mutex
    // This is called by public allocate() which holds the lock, and may call itself recursively
    void *allocate_internal(size_t size);

    void mark(void *obj);
    void markChildren(void *obj);
    void markHPointer(HPointer &ptr);
    void markUnboxable(Unboxable &val, bool is_boxed);
    void sweep();

    // Add a new memory chunk to the old gen space
    // REQUIRES: Caller must hold alloc_mutex (modifies free_list)
    void addChunk(size_t size);

    friend class NurserySpace;
    friend class ScopedLock;
};

} // namespace Elm

#endif // ECO_OLDGENSPACE_H
