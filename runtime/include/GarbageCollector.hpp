#ifndef ECO_GARBAGECOLLECTOR_H
#define ECO_GARBAGECOLLECTOR_H

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

// Main GC controller
class GarbageCollector {
public:
    static GarbageCollector &instance();

    // Initialize GC with max heap size (default 1GB)
    void initialize(size_t max_heap_size = 1ULL * 1024 * 1024 * 1024);

    // Initialize GC for a thread
    void initThread();

    // Allocate object (tries nursery first, then old gen)
    void *allocate(size_t size, Tag tag);

    // Trigger minor GC
    void minorGC();

    // Trigger major GC (concurrent mark-and-sweep)
    void majorGC();

    // Root set management
    RootSet &getRootSet() { return root_set; }

    // Get thread-local nursery
    NurserySpace *getNursery();

    // Get old gen space
    OldGenSpace &getOldGen() { return old_gen; }

    // Get heap base pointer (for logical pointer conversion)
    char *getHeapBase() const { return heap_base; }

    // Reset to initial state (for testing)
    void reset();

#if ENABLE_GC_STATS
    // Get global Major GC stats (collector thread writes, no mutex protection)
    GCStats& getMajorGCStats() { return major_gc_stats; }
    const GCStats& getMajorGCStats() const { return major_gc_stats; }
#endif

private:
    GarbageCollector();
    ~GarbageCollector();

    // Unified heap
    char *heap_base; // Base pointer for entire heap
    size_t heap_reserved; // Total address space reserved
    size_t old_gen_committed; // How much old gen memory actually committed
    size_t nursery_offset; // Where nurseries start (halfway point)
    size_t next_nursery_offset; // Next available nursery location
    bool initialized; // Whether initialize() has been called

    OldGenSpace old_gen;
    RootSet root_set;

    // Thread-local nursery spaces
    std::mutex nursery_mutex;
    std::unordered_map<std::thread::id, std::unique_ptr<NurserySpace>> nurseries;

    // Flag to prevent recursive GC calls
    thread_local static bool gc_in_progress;

#if ENABLE_GC_STATS
    // Global Major GC statistics (no mutex - single collector thread assumed)
    GCStats major_gc_stats;
#endif

    // Commit more old gen memory
    void growOldGen(size_t additional_size);

    // Commit nursery memory
    void commitNursery(char *nursery_base, size_t size);
};

// Implementations of fromPointer and toPointer (need GarbageCollector defined)
inline void *fromPointer(HPointer ptr) {
    if (ptr.constant != 0) {
        return nullptr; // It's a constant, not a heap pointer
    }
    // ptr.ptr is a logical offset in 8-byte units
    // Convert to byte offset by shifting left 3 (multiply by 8)
    char *heap_base = GarbageCollector::instance().getHeapBase();
    uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
    return heap_base + byte_offset;
}

inline HPointer toPointer(void *obj) {
    HPointer ptr;
    // Convert absolute address to logical offset
    char *heap_base = GarbageCollector::instance().getHeapBase();
    uintptr_t byte_offset = static_cast<char *>(obj) - heap_base;
    ptr.ptr = byte_offset >> 3; // Divide by 8 (shift right 3)
    ptr.constant = 0;
    ptr.padding = 0;
    return ptr;
}

} // namespace Elm

#endif // ECO_GARBAGECOLLECTOR_H
