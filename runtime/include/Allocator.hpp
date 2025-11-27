#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

#include <memory>
#include "AllocatorCommon.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"
#include "GCStats.hpp"

namespace Elm {

class AllocBuffer;

/**
 * Central allocator managing nursery and old generation.
 *
 * Singleton that owns the unified heap address space. Single-threaded version
 * with one nursery and shared old gen.
 *
 * Memory layout:
 *   [0 .. heap_reserved/2)      - Old generation (AllocBuffers allocated here)
 *   [heap_reserved/2 .. end)    - Nursery
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
    void initialize(const HeapConfig& config = HeapConfig());

    // Initializes allocator state, creating the nursery.
    void initThread();

    // ========== Allocation ==========

    // Allocates an object in the nursery. Asserts if nursery is full.
    void *allocate(size_t size, Tag tag);

    // ========== Garbage Collection ==========

    // Triggers a minor GC on the nursery.
    void minorGC();

    // Triggers a major GC (mark-and-sweep on old gen).
    void majorGC();

    // ========== Root Management ==========

    // Returns the root set.
    RootSet &getRootSet();

    // ========== Diagnostics ==========

    // Returns true if the nursery is over the threshold.
    bool isNurseryNearFull(float threshold) {
        if (nursery) {
            size_t total_capacity = config_.nurserySize() / 2;
            size_t usage = nursery->bytesAllocated();
            return usage >= (size_t)(total_capacity * threshold);
        }
        return false;
    }

    // Returns true if the given pointer is in the nursery.
    bool isInNursery(void *ptr);

    // Returns true if the given pointer is in the old generation.
    bool isInOldGen(void *ptr);

    // Returns true if the given pointer is anywhere in the heap (nursery or old gen).
    // O(1) bounds check - used for validation during GC.
    bool isInHeap(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= heap_base && p < heap_base + heap_reserved;
    }

    // Returns the current number of bytes allocated in old gen.
    size_t getOldGenAllocatedBytes() const { return old_gen.getAllocatedBytes(); }

#if ENABLE_GC_STATS
    // Returns the global major GC statistics.
    GCStats& getMajorGCStats() { return major_gc_stats; }
    const GCStats& getMajorGCStats() const { return major_gc_stats; }

    // Returns combined nursery and major GC statistics.
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
    size_t nursery_committed_;    // Committed bytes in nursery region.
    bool initialized;             // True after initialize() has been called.

    OldGenSpace old_gen;

    // ========== Single Nursery ==========

    std::unique_ptr<NurserySpace> nursery;

    // ========== Internal Methods ==========

    // Resets the allocator to initial state. Used for testing.
    // If new_config is provided, reconfigures with new parameters.
    void reset(const HeapConfig* new_config = nullptr);

    // Collects all roots for major GC.
    std::vector<HPointer*> collectAllRoots();

    // Returns the nursery, or nullptr if not initialized.
    NurserySpace *getNursery();

    // Returns the old generation space.
    OldGenSpace &getOldGen() { return old_gen; }

    // Returns the base address of the unified heap.
    char *getHeapBase() const { return heap_base; }

    // Returns the total reserved heap size.
    size_t getHeapReserved() const { return heap_reserved; }

    // Returns the heap configuration.
    const HeapConfig& getConfig() const { return config_; }

    // Acquires a new AllocBuffer of the specified size from the old gen region.
    // Returns nullptr if unable to allocate (out of address space).
    AllocBuffer* acquireAllocBuffer(size_t size);

    // Acquires a block of memory from the nursery region for NurserySpace.
    // Returns nullptr if unable to allocate (out of address space).
    char* acquireNurseryBlock(size_t size);

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
    friend class AllocatorTestAccess;

#if ENABLE_GC_STATS
    GCStats major_gc_stats; // Global major GC statistics.
#endif
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

    // Access nursery for testing.
    static NurserySpace* getNursery(Allocator& alloc) {
        return alloc.getNursery();
    }

    // Access old gen for testing.
    static OldGenSpace& getOldGen(Allocator& alloc) {
        return alloc.getOldGen();
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_H
