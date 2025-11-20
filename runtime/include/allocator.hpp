#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

#include <atomic>
#include <iostream>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>
#include "heap.hpp"
#include "gc_stats.hpp"

namespace Elm {

// GC Color states for tri-color marking
enum class Color : u32 {
    White = 0, // Not marked (garbage)
    Grey = 1, // Marked but children not scanned
    Black = 2 // Marked and children scanned
};

// Maximum age before promotion to old gen
constexpr u32 PROMOTION_AGE = 1;

// Nursery size per thread (e.g., 4MB)
constexpr size_t NURSERY_SIZE = 4 * 1024 * 1024;

// Forward declarations
class OldGenSpace;
class RootSet;

// ============================================================================
// TLAB (Thread-Local Allocation Buffer)
// ============================================================================

/**
 * A thread-local allocation buffer for fast, lock-free allocation into old gen.
 * Each thread gets a TLAB for promoting objects during minor GC, avoiding
 * mutex contention on the global OldGenSpace free-list.
 */
class TLAB {
public:
    /**
     * Create a TLAB from a memory region.
     * @param base Start of the memory region
     * @param size Size of the region in bytes
     */
    TLAB(char* base, size_t size)
        : start(base), end(base + size), alloc_ptr(base) {}

    /**
     * Allocate from this TLAB using thread-local bump pointer.
     * NO SYNCHRONIZATION - thread has exclusive access.
     *
     * @param size Number of bytes to allocate (will be 8-byte aligned)
     * @return Pointer to allocated memory, or nullptr if TLAB exhausted
     */
    void* allocate(size_t size) {
        // Align to 8 bytes
        size = (size + 7) & ~7;

        // Check if we have space
        if (alloc_ptr + size > end) {
            return nullptr; // TLAB exhausted
        }

        // Bump pointer allocation (thread-local, no sync!)
        void* result = alloc_ptr;
        alloc_ptr += size;
        return result;
    }

    // Query methods
    size_t bytesUsed() const { return alloc_ptr - start; }
    size_t bytesRemaining() const { return end - alloc_ptr; }
    size_t capacity() const { return end - start; }
    bool isEmpty() const { return alloc_ptr == start; }
    bool isFull() const { return alloc_ptr == end; }

    // Memory region
    char* start;      // Start of TLAB
    char* end;        // End of TLAB
    char* alloc_ptr;  // Current allocation pointer (thread-local)
};

// Thread-local nursery space with semi-space copying collector
class NurserySpace {
public:
    NurserySpace();
    ~NurserySpace();

    // Initialize with assigned region from main heap
    void initialize(char *nursery_base, size_t size);

    // Allocate in nursery (bump allocation)
    void *allocate(size_t size);

    // Run minor GC (semi-space copy)
    void minorGC(RootSet &roots, OldGenSpace &oldgen);

    // Check if pointer is in nursery
    bool contains(void *ptr) const;

    // Get current allocation stats
    size_t bytesAllocated() const { return alloc_ptr - from_space; }
    size_t bytesRemaining() const { return from_space + (NURSERY_SIZE / 2) - alloc_ptr; }

#if ENABLE_GC_STATS
    // Get GC statistics
    const GCStats& getStats() const { return stats; }
    GCStats& getStats() { return stats; }
#endif

private:
    char *memory; // Total nursery memory (both semi-spaces)
    char *from_space; // Current allocation space
    char *to_space; // Copy target during GC
    char *alloc_ptr; // Bump allocation pointer
    char *scan_ptr; // Scan pointer for Cheney's algorithm

    TLAB* promotion_tlab; // Thread-local TLAB for promotions to old gen

#if ENABLE_GC_STATS
    GCStats stats; // Performance statistics
#endif

    void evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
};

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
    void startConcurrentMark(RootSet &roots);

    // Perform incremental marking work
    bool incrementalMark(size_t work_units);

    // Complete marking and sweep
    void finishMarkAndSweep();

    // Check if pointer is in old gen
    bool contains(void *ptr) const;

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
    static constexpr size_t TLAB_DEFAULT_SIZE = 128 * 1024; // 128KB
    static constexpr size_t TLAB_MIN_SIZE = 64 * 1024;      // 64KB minimum
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

// Root set management
class RootSet {
public:
    void addRoot(HPointer *root);
    void removeRoot(HPointer *root);
    void addStackRoot(void *stack_ptr, size_t size);
    void clearStackRoots();

    const std::vector<HPointer *> &getRoots() const { return roots; }
    const std::vector<std::pair<void *, size_t>> &getStackRoots() const { return stack_roots; }

private:
    std::vector<HPointer *> roots;
    std::vector<std::pair<void *, size_t>> stack_roots;
    std::mutex mutex;
};

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

    // Commit more old gen memory
    void growOldGen(size_t additional_size);

    // Commit nursery memory
    void commitNursery(char *nursery_base, size_t size);
};

// Helper functions for heap operations
inline Header *getHeader(void *obj) { return static_cast<Header *>(obj); }

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

// TODO: Useful to have just this as an inline:
//    char *heap_base = GarbageCollector::instance().getHeapBase();
//    uintptr_t byte_offset = static_cast<uintptr_t>(fwd->pointer) << 3;
//    return heap_base + byte_offset;

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

// TODO: Useful to have just this as an inline:
//    char *heap_base = GarbageCollector::instance().getHeapBase();
//    uintptr_t byte_offset = static_cast<char *>(new_obj) - heap_base;
//    fwd->pointer = byte_offset >> 3; // Store as offset in 8-byte units

inline size_t getObjectSize(void *obj) {
    Header *hdr = getHeader(obj);

    size_t size;
    switch (hdr->tag) {
        case Tag_Int:
            size = sizeof(ElmInt);
            break;
        case Tag_Float:
            size = sizeof(ElmFloat);
            break;
        case Tag_Char:
            size = sizeof(ElmChar);
            break;
        case Tag_String:
            size = sizeof(ElmString) + hdr->size * sizeof(u16);
            break;
        case Tag_Tuple2:
            size = sizeof(Tuple2);
            break;
        case Tag_Tuple3:
            size = sizeof(Tuple3);
            break;
        case Tag_Cons:
            size = sizeof(Cons);
            break;
        case Tag_Custom:
            size = sizeof(Custom) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_Record:
            size = sizeof(Record) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_DynRecord:
            size = sizeof(DynRecord) + hdr->size * sizeof(HPointer);
            break;
        case Tag_FieldGroup:
            size = sizeof(FieldGroup) + hdr->size * sizeof(u32);
            break;
        case Tag_Closure: {
            Closure *cl = static_cast<Closure *>(obj);
            size = sizeof(Closure) + cl->n_values * sizeof(Unboxable);
            break;
        }
        case Tag_Process:
            size = sizeof(Process);
            break;
        case Tag_Task:
            size = sizeof(Task);
            break;
        case Tag_Forward:
            size = sizeof(Forward);
            break;
        default:
            size = sizeof(Header);
            break;
    }

    // Always return 8-byte aligned size
    return (size + 7) & ~7;
}

} // namespace Elm

#endif // ECO_ALLOCATOR_H