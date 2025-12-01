#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

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
class ThreadLocalHeap;

/**
 * Central allocator managing thread-local heaps.
 *
 * Singleton that owns the unified heap address space. Each thread gets its own
 * ThreadLocalHeap with independent nursery, old gen, and GC stats.
 *
 * Memory layout:
 *   [0 .. heap_reserved/2)      - Old generation region (carved up per-thread)
 *   [heap_reserved/2 .. end)    - Nursery region (carved up per-thread)
 *
 * Thread safety:
 *   - initThread() acquires mutex to allocate regions
 *   - allocate(), minorGC(), majorGC() are lock-free (use thread-local heap)
 *   - getCombinedStats() acquires mutex to iterate all thread heaps
 */
class Allocator {
public:
    // Returns the singleton Allocator instance.
    static Allocator &instance();

    // ========== Safe Public Pointer API ==========

    // Resolves an HPointer to its physical address.
    // Follows any forwarding pointer chain to the final location.
    // Returns nullptr for embedded constants (Nil, True, False, Unit).
    // Asserts on invalid pointer or corrupted memory.
    void* resolve(HPointer ptr);

    // Wraps a physical address as an HPointer.
    // Used after allocate() to get a storable pointer.
    HPointer wrap(void* obj);

    // ========== Lifecycle ==========

    // Initializes the allocator with the given configuration.
    // Validates config parameters and throws std::invalid_argument on failure.
    // Must be called before any thread calls initThread().
    void initialize(const HeapConfig& config = HeapConfig());

    // Initializes the calling thread's heap space.
    // Creates a ThreadLocalHeap with nursery and old gen regions.
    // Thread-safe: acquires mutex to allocate regions from shared address space.
    void initThread();

    // Cleans up the calling thread's heap space.
    // Should be called before the thread exits.
    void cleanupThread();

    // ========== Allocation ==========

    // Allocates an object in the thread-local nursery.
    // Delegates to the calling thread's ThreadLocalHeap.
    void *allocate(size_t size, Tag tag);

    // ========== Garbage Collection ==========

    // Triggers a minor GC on the thread-local nursery.
    void minorGC();

    // Triggers a major GC on the thread-local old gen.
    void majorGC();

    // ========== Root Management ==========

    // Returns the thread-local root set.
    RootSet &getRootSet();

    // ========== Diagnostics ==========

    // Returns true if the thread-local nursery is over the threshold.
    bool isNurseryNearFull(float threshold);

    // Returns true if the given pointer is in the calling thread's nursery.
    bool isInNursery(void *ptr);

    // Returns true if the given pointer is in the calling thread's old gen.
    bool isInOldGen(void *ptr);

    // Returns true if the given pointer is anywhere in the heap (any thread).
    // O(1) bounds check - used for validation during GC.
    bool isInHeap(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= heap_base && p < heap_base + heap_reserved;
    }

    // Returns the current number of bytes allocated in thread-local old gen.
    size_t getOldGenAllocatedBytes() const;

#if ENABLE_GC_STATS
    // Returns combined statistics from all thread heaps.
    // Thread-safe: acquires mutex to iterate all thread heaps.
    GCStats getCombinedStats() const;
#endif

private:
    Allocator();
    ~Allocator();

    // ========== Unified Heap ==========

    HeapConfig config_;           // Heap configuration parameters.
    char *heap_base;              // Base of reserved address space.
    size_t heap_reserved;         // Total address space reserved.
    size_t old_gen_committed;     // Committed bytes in old gen region.
    size_t nursery_offset;        // Where nursery starts (halfway point).
    size_t nursery_low_committed_;   // Committed bytes in nursery low region.
    size_t nursery_high_committed_;  // Committed bytes in nursery high region.
    bool initialized;             // True after initialize() has been called.

#if ENABLE_GC_STATS
    // Accumulated stats from thread heaps that were destroyed during reset.
    // This ensures stats survive across test runs that reset the allocator.
    GCStats accumulated_stats_;
#endif

    // ========== Thread-Local Heaps ==========

    mutable std::recursive_mutex thread_mutex_;  // Protects thread_heaps_ and region allocation.
    std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> thread_heaps_;

    // Thread-local fast access (set in initThread, cleared in cleanupThread).
    static thread_local ThreadLocalHeap* tl_heap_;

    // ========== Internal Methods ==========

    // Returns the calling thread's heap, or nullptr if not initialized.
    ThreadLocalHeap* getThreadHeap() const { return tl_heap_; }

    // Resets the allocator to initial state. Used for testing.
    // If new_config is provided, reconfigures with new parameters.
    void reset(const HeapConfig* new_config = nullptr);

    // Returns the base address of the unified heap.
    char *getHeapBase() const { return heap_base; }

    // Returns the total reserved heap size.
    size_t getHeapReserved() const { return heap_reserved; }

    // Returns the heap configuration.
    const HeapConfig& getConfig() const { return config_; }

    // Acquires a block of memory from the nursery low region.
    // Thread-safe: acquires thread_mutex_.
    char* acquireNurseryBlockLow(size_t size);

    // Acquires a block of memory from the nursery high region.
    // Thread-safe: acquires thread_mutex_.
    char* acquireNurseryBlockHigh(size_t size);

    // Acquires a block of memory from the old gen region.
    // Thread-safe: acquires thread_mutex_.
    // Returns pointer to base of committed block.
    char* acquireOldGenBlock(size_t size);

    // Acquires a region of memory from the old gen region.
    // Thread-safe: caller must hold thread_mutex_.
    // Returns base address and commits initial_size bytes.
    char* acquireOldGenRegion(size_t initial_size, size_t max_size);

    void commitNursery(char *nursery_base, size_t size);

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
    friend class ThreadLocalHeap;
    friend class AllocatorTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

// For test code only - provides privileged access to internal allocator state.
// This class is a friend of Allocator and can access internal functions.
class AllocatorTestAccess {
public:
    // Raw pointer conversion (no forwarding resolution).
    static void* fromPointer(HPointer ptr) {
        return Allocator::fromPointerRaw(ptr);
    }

    static HPointer toPointer(void* obj) {
        return Allocator::toPointerRaw(obj);
    }

    // Reset allocator state for testing.
    static void reset(Allocator& alloc, const HeapConfig* new_config = nullptr) {
        alloc.reset(new_config);
    }

    // Access thread-local nursery for testing.
    static NurserySpace* getNursery(Allocator& alloc);

    // Access thread-local old gen for testing.
    static OldGenSpace* getOldGen(Allocator& alloc);

    // Access thread-local heap for testing.
    static ThreadLocalHeap* getThreadHeap(Allocator& alloc) {
        return alloc.getThreadHeap();
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_H
