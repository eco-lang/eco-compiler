#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

#include <atomic>
#include <iostream>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>
#include "heap.hpp"

namespace Elm {

// GC Color states for tri-color marking
enum class Color : u32 {
    White = 0, // Not marked (garbage)
    Grey = 1, // Marked but children not scanned
    Black = 2 // Marked and children scanned
};

// Maximum age before promotion to old gen
constexpr u32 PROMOTION_AGE = 4;

// Nursery size per thread (e.g., 4MB)
constexpr size_t NURSERY_SIZE = 4 * 1024 * 1024;

// Forward declarations
class OldGenSpace;
class RootSet;

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

private:
    char *memory; // Total nursery memory (both semi-spaces)
    char *from_space; // Current allocation space
    char *to_space; // Copy target during GC
    char *alloc_ptr; // Bump allocation pointer
    char *scan_ptr; // Scan pointer for Cheney's algorithm

    //void *forward(void *obj);
    void *copy(void *obj, OldGenSpace &oldgen);
    void evacuate(HPointer &ptr, OldGenSpace &oldgen);
    void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen);
    //void flipSpaces();
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

    std::mutex &getMutex() { return alloc_mutex; }

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
    std::mutex alloc_mutex; // Mutex for allocation

    std::vector<void *> mark_stack; // Stack for marking
    std::mutex mark_mutex; // Mutex for marking operations

    std::atomic<u32> current_epoch; // Current GC epoch
    std::atomic<bool> marking_active; // Is marking in progress?

    void mark(void *obj);
    void markChildren(void *obj);
    void markHPointer(HPointer &ptr);
    void markUnboxable(Unboxable &val, bool is_boxed);
    void sweep();
    void addChunk(size_t size);

    friend class NurserySpace;
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

    switch (hdr->tag) {
        case Tag_Int:
            return sizeof(ElmInt);
        case Tag_Float:
            return sizeof(ElmFloat);
        case Tag_Char:
            return sizeof(ElmChar);
        case Tag_String:
            return sizeof(ElmString) + hdr->size * sizeof(u16);
        case Tag_Tuple2:
            return sizeof(Tuple2);
        case Tag_Tuple3:
            return sizeof(Tuple3);
        case Tag_Cons:
            return sizeof(Cons);
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            return sizeof(Custom) + hdr->size * sizeof(Unboxable);
        }
        case Tag_Record: {
            return sizeof(Record) + hdr->size * sizeof(Unboxable);
        }
        case Tag_DynRecord: {
            return sizeof(DynRecord) + hdr->size * sizeof(HPointer);
        }
        case Tag_FieldGroup: {
            return sizeof(FieldGroup) + hdr->size * sizeof(u32);
        }
        case Tag_Closure: {
            Closure *cl = static_cast<Closure *>(obj);
            return sizeof(Closure) + cl->n_values * sizeof(Unboxable);
        }
        case Tag_Process:
            return sizeof(Process);
        case Tag_Task:
            return sizeof(Task);
        case Tag_Forward:
            return sizeof(Forward);
        default:
            return sizeof(Header);
    }
}

} // namespace Elm

#endif // ECO_ALLOCATOR_H