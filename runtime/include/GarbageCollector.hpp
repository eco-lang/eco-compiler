#ifndef ECO_GARBAGECOLLECTOR_H
#define ECO_GARBAGECOLLECTOR_H

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include "AllocatorCommon.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"
#include "GCStats.hpp"

namespace Elm {

/**
 * Central GC coordinator managing nurseries and old generation.
 *
 * Singleton that owns the unified heap address space and coordinates GC across
 * all threads. Each thread gets its own nursery; old gen is shared.
 */
class GarbageCollector {
public:
    // Returns the singleton GarbageCollector instance.
    static GarbageCollector &instance();

    // Initializes the GC with the given maximum heap size.
    void initialize(size_t max_heap_size = DEFAULT_MAX_HEAP_SIZE);

    // Initializes GC for the calling thread, creating its nursery.
    void initThread();

    // Allocates an object. Tries nursery first, falls back to old gen.
    void *allocate(size_t size, Tag tag);

    // Triggers a minor GC on the current thread's nursery.
    void minorGC();

    // Triggers a major GC (concurrent mark-and-sweep on old gen).
    void majorGC();

    // Resets the GC to initial state. Used for testing.
    void reset();

    // Returns the root set for the current thread. Thread must have called initThread().
    RootSet &getRootSet();

    // Collects all roots from all threads for major GC.
    std::vector<HPointer*> collectAllRoots();

    // Returns the current thread's nursery, or nullptr if not initialized.
    NurserySpace *getNursery();

    // Returns the old generation space.
    OldGenSpace &getOldGen() { return old_gen; }

    // Returns the base address of the unified heap.
    char *getHeapBase() const { return heap_base; }

    // Returns true if the current thread's nursery is over the threshold.
    bool isNurseryNearFull(float threshold = NURSERY_GC_THRESHOLD) {
        NurserySpace *nursery = getNursery();
        if (nursery) {
            size_t total_capacity = NURSERY_SIZE / 2;
            size_t usage = nursery->bytesAllocated();
            return usage >= (size_t)(total_capacity * threshold);
        }
        return false;
    }

    // ========== Thread signalling ==========

    // Called by collector thread after major GC completes to wake blocked allocators.
    void signalGCComplete();

    // Signals shutdown - wakes any blocked allocators.
    void signalShutdown();

    // ========== Stop-the-World Barrier ==========

    // Returns true if the given pointer is in any thread's nursery.
    bool isInNursery(void *ptr);

    // Returns true if STW barrier is currently active.
    bool isSTWActive() const {
        return stw_barrier.load(std::memory_order_relaxed);
    }

#if ENABLE_GC_STATS
    // Returns the global major GC statistics.
    GCStats& getMajorGCStats() { return major_gc_stats; }
    const GCStats& getMajorGCStats() const { return major_gc_stats; }

    // Returns combined statistics from all nurseries.
    GCStats getCombinedNurseryStats();
#endif

private:
    GarbageCollector();
    ~GarbageCollector();

    // ========== Unified Heap ==========

    char *heap_base;              // Base of reserved address space.
    size_t heap_reserved;         // Total address space reserved.
    size_t old_gen_committed;     // Committed bytes in old gen.
    size_t nursery_offset;        // Where nurseries start (halfway point).
    size_t next_nursery_offset;   // Next available nursery location.
    bool initialized;             // True after initialize() has been called.

    OldGenSpace old_gen;

    // ========== Thread-Local Nurseries ==========

    std::mutex nursery_mutex;
    std::unordered_map<std::thread::id, std::unique_ptr<NurserySpace>> nurseries;

    thread_local static bool gc_in_progress; // Prevents recursive GC calls.

    // ========== Thread signalling ==========

    std::atomic<bool> shutdown_flag{false};        // Set when shutting down.
    std::atomic<bool> stw_barrier{false}; // When true, threads block on allocation.
    std::mutex gc_wait_mutex;                      // Protects condition variable.
    std::condition_variable gc_wait_cv;            // For blocking allocators.

    // Blocks until STW barrier is lowered. Called from allocate().
    void waitAtSTWBarrier();

#if ENABLE_GC_STATS
    GCStats major_gc_stats; // Global major GC statistics.
#endif

    void growOldGen(size_t additional_size);
    void commitNursery(char *nursery_base, size_t size);
};

// Converts a logical HPointer to a physical memory address.
// Returns nullptr if the pointer represents an embedded constant.
inline void *fromPointer(HPointer ptr) {
    if (ptr.constant != 0) {
        return nullptr;
    }
    char *heap_base = GarbageCollector::instance().getHeapBase();
    uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
    return heap_base + byte_offset;
}

// Converts a physical memory address to a logical HPointer.
inline HPointer toPointer(void *obj) {
    HPointer ptr;
    char *heap_base = GarbageCollector::instance().getHeapBase();
    uintptr_t byte_offset = static_cast<char *>(obj) - heap_base;
    ptr.ptr = byte_offset >> 3;
    ptr.constant = 0;
    ptr.padding = 0;
    return ptr;
}

} // namespace Elm

#endif // ECO_GARBAGECOLLECTOR_H
