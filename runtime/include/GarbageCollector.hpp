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

    // Returns the root set for registering GC roots.
    RootSet &getRootSet() { return root_set; }

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

    // ========== Memory Pressure / Backpressure ==========

    // Sets the memory pressure threshold (in bytes). When old gen exceeds this,
    // allocating threads will block until GC makes progress.
    void setMemoryPressureThreshold(size_t threshold) {
        memory_pressure_threshold = threshold;
    }

    // Called by collector thread after major GC completes to wake blocked allocators.
    void signalGCComplete();

    // Returns true if memory pressure is currently active.
    bool isMemoryPressureActive() const {
        return memory_pressure.load(std::memory_order_relaxed);
    }

    // Signals shutdown - wakes any blocked allocators.
    void signalShutdown();

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
    RootSet root_set;

    // ========== Thread-Local Nurseries ==========

    std::mutex nursery_mutex;
    std::unordered_map<std::thread::id, std::unique_ptr<NurserySpace>> nurseries;

    thread_local static bool gc_in_progress; // Prevents recursive GC calls.

    // ========== Memory Pressure ==========

    std::atomic<bool> memory_pressure{false};      // Fast-path check flag.
    std::atomic<bool> shutdown_flag{false};        // Set when shutting down.
    std::mutex gc_wait_mutex;                      // Protects condition variable.
    std::condition_variable gc_wait_cv;            // For blocking allocators.
    size_t memory_pressure_threshold = DEFAULT_MEMORY_PRESSURE_THRESHOLD;

    // Checks memory pressure and blocks if necessary. Called from allocate().
    void checkMemoryPressure();

    // Updates the memory pressure flag based on current heap usage.
    void updateMemoryPressure();

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
