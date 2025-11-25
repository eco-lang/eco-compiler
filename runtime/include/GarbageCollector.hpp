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

    // ========== Safe Public Pointer API ==========

    // Resolves an HPointer to its physical address.
    // Follows any forwarding pointer chain to the final location.
    // Returns nullptr for embedded constants (Nil, True, False, Unit).
    // Asserts on invalid pointer or corrupted memory.
    void* resolve(HPointer ptr);

    // Wraps a physical address as an HPointer.
    // Used after allocate() to get a storable pointer.
    HPointer wrap(void* obj);

    // Initializes the GC with the given configuration.
    // Validates config parameters and throws std::invalid_argument on failure.
    void initialize(const GCConfig& config = GCConfig());

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

    // Returns the total reserved heap size.
    size_t getHeapReserved() const { return heap_reserved; }

    // Returns true if the current thread's nursery is over the threshold.
    bool isNurseryNearFull(float threshold) {
        NurserySpace *nursery = getNursery();
        if (nursery) {
            size_t total_capacity = config_.nursery_size / 2;
            size_t usage = nursery->bytesAllocated();
            return usage >= (size_t)(total_capacity * threshold);
        }
        return false;
    }

    // Returns the GC configuration.
    const GCConfig& getConfig() const { return config_; }

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

    GCConfig config_;             // GC configuration parameters.
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

    // ========== Internal Pointer Conversion ==========

    // Raw pointer conversion - internal use only, no forward resolution.
    // Friends can access these for performance-critical GC operations.
    static inline void* fromPointerRaw(HPointer ptr) {
        if (ptr.constant != 0) return nullptr;
        char* heap_base = instance().heap_base;
        uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
        return heap_base + byte_offset;
    }

    static inline HPointer toPointerRaw(void* obj) {
        HPointer ptr;
        char* heap_base = instance().heap_base;
        uintptr_t byte_offset = static_cast<char*>(obj) - heap_base;
        ptr.ptr = byte_offset >> 3;
        ptr.constant = 0;
        ptr.padding = 0;
        return ptr;
    }

    friend class NurserySpace;
    friend class OldGenSpace;
    friend class GCTestAccess;

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

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to raw pointer conversion.
// This class is a friend of GarbageCollector and can access internal functions.
class GCTestAccess {
public:
    static void* fromPointer(HPointer ptr) {
        return GarbageCollector::fromPointerRaw(ptr);
    }

    static HPointer toPointer(void* obj) {
        return GarbageCollector::toPointerRaw(obj);
    }
};

} // namespace Elm

#endif // ECO_GARBAGECOLLECTOR_H
