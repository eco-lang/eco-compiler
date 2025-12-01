#ifndef ECO_THREAD_LOCAL_HEAP_H
#define ECO_THREAD_LOCAL_HEAP_H

#include <unordered_set>
#include "AllocatorCommon.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "GCStats.hpp"

namespace Elm {

class Allocator;

/**
 * Thread-local heap space containing nursery, old gen, and GC stats.
 *
 * Each thread owns its own ThreadLocalHeap instance, allowing completely
 * independent garbage collection without any synchronization between threads.
 *
 * Memory regions are allocated from the global Allocator's unified address
 * space, but once assigned to a thread, they are owned exclusively by that
 * thread's ThreadLocalHeap.
 */
class ThreadLocalHeap {
public:
    /**
     * Constructs a thread-local heap with the given memory regions.
     *
     * @param parent       Parent allocator (for heap base access)
     * @param nursery_base Base address of nursery region
     * @param nursery_size Total size of nursery (split into from/to spaces)
     * @param old_gen_base Base address of old generation region
     * @param old_gen_initial_size Initial committed size for old gen
     * @param old_gen_max_size Maximum size old gen can grow to
     * @param config       Heap configuration parameters
     */
    ThreadLocalHeap(Allocator* parent,
                    char* nursery_base, size_t nursery_size,
                    char* old_gen_base, size_t old_gen_initial_size, size_t old_gen_max_size,
                    const HeapConfig* config);

    ~ThreadLocalHeap() = default;

    // Non-copyable, non-movable (owns memory regions)
    ThreadLocalHeap(const ThreadLocalHeap&) = delete;
    ThreadLocalHeap& operator=(const ThreadLocalHeap&) = delete;
    ThreadLocalHeap(ThreadLocalHeap&&) = delete;
    ThreadLocalHeap& operator=(ThreadLocalHeap&&) = delete;

    // ========== Allocation ==========

    /**
     * Allocates an object in the nursery.
     * May trigger minor GC if nursery usage exceeds threshold.
     */
    void* allocate(size_t size, Tag tag);

    // ========== Garbage Collection ==========

    /** Triggers a minor GC on the nursery. */
    void minorGC();

    /** Triggers a major GC (mark-sweep on old gen). */
    void majorGC();

    // ========== Accessors ==========

    /** Returns the root set for this thread. */
    RootSet& getRootSet() { return nursery_.getRootSet(); }

    /** Returns the nursery space. */
    NurserySpace& getNursery() { return nursery_; }

    /** Returns the old generation space. */
    OldGenSpace& getOldGen() { return old_gen_; }

    /** Returns the parent allocator. */
    Allocator* getParent() { return parent_; }

    /** Returns the heap configuration. */
    const HeapConfig* getConfig() const { return config_; }

    // ========== Diagnostics ==========

    /** Returns true if the nursery is over the given threshold. */
    bool isNurseryNearFull(float threshold) const;

    /** Returns true if the pointer is in this thread's nursery. */
    bool isInNursery(void* ptr) const { return nursery_.contains(ptr); }

    /** Returns true if the pointer is in this thread's old gen. */
    bool isInOldGen(void* ptr) const { return old_gen_.contains(ptr); }

    /** Returns current bytes allocated in old gen. */
    size_t getOldGenAllocatedBytes() const { return old_gen_.getAllocatedBytes(); }

#if ENABLE_GC_STATS
    /** Returns GC statistics for this thread. */
    GCStats& getStats() { return stats_; }
    const GCStats& getStats() const { return stats_; }
#endif

private:
    Allocator* parent_;           // Parent allocator (for heap base, pointer conversion)
    const HeapConfig* config_;    // Heap configuration
    NurserySpace nursery_;        // Thread-local nursery
    OldGenSpace old_gen_;         // Thread-local old generation

#if ENABLE_GC_STATS
    GCStats stats_;               // Thread-local GC statistics
#endif

    /** Collects all roots from this thread's root set. */
    std::unordered_set<HPointer*> collectRoots();
};

} // namespace Elm

#endif // ECO_THREAD_LOCAL_HEAP_H
