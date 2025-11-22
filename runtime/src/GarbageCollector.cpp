#include "GarbageCollector.hpp"
#include <cstring>
#include <new>
#include <sys/mman.h>

namespace Elm {

// Global heap base for read barrier.
char* g_heap_base = nullptr;

// Define the thread_local flag for preventing recursive GC.
thread_local bool GarbageCollector::gc_in_progress = false;

GarbageCollector::GarbageCollector() :
    heap_base(nullptr), heap_reserved(0), old_gen_committed(0), nursery_offset(0), next_nursery_offset(0),
    initialized(false) {
    // Initialization happens in initialize() method.
}

GarbageCollector::~GarbageCollector() {
    if (heap_base) {
        munmap(heap_base, heap_reserved);
    }
}

void GarbageCollector::initialize(size_t max_heap_size) {
    if (initialized)
        return;

    heap_reserved = max_heap_size;

    // Reserve address space without committing physical memory.
    heap_base = static_cast<char *>(mmap(nullptr, heap_reserved,
                                         PROT_NONE,  // No access initially.
                                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0));

    if (heap_base == MAP_FAILED) {
        throw std::bad_alloc();
    }

    // Set global heap_base for read barrier.
    g_heap_base = heap_base;

    // Nurseries start at halfway point.
    nursery_offset = heap_reserved / 2;
    next_nursery_offset = nursery_offset;

    // Old gen starts at offset 0, can grow up to halfway point.
    // Commit initial 1MB for old gen.
    size_t initial_old_gen = 1 * 1024 * 1024;  // 1MB.
    size_t max_old_gen = nursery_offset;  // Can grow to halfway point.
    growOldGen(initial_old_gen);
    old_gen.initialize(heap_base, old_gen_committed, max_old_gen);

    initialized = true;
}

void GarbageCollector::growOldGen(size_t additional_size) {
    // Commit more memory for old gen.
    char *new_region = heap_base + old_gen_committed;

    void *result =
        mmap(new_region, additional_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }

    old_gen_committed += additional_size;
}

void GarbageCollector::commitNursery(char *nursery_base, size_t size) {
    // Commit memory for a nursery.
    void *result = mmap(nursery_base, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }
}

GarbageCollector &GarbageCollector::instance() {
    static GarbageCollector gc;
    return gc;
}

void GarbageCollector::initThread() {
    // Ensure GC is initialized.
    if (!initialized) {
        initialize();
    }

    std::lock_guard<std::mutex> lock(nursery_mutex);
    auto tid = std::this_thread::get_id();
    if (nurseries.find(tid) == nurseries.end()) {
        // Allocate nursery from the main heap.
        char *nursery_base = heap_base + next_nursery_offset;

        // Check we have space in reserved address space.
        if (next_nursery_offset + NURSERY_SIZE > heap_reserved) {
            throw std::bad_alloc();  // Out of heap space.
        }

        // Commit physical memory for this nursery.
        commitNursery(nursery_base, NURSERY_SIZE);

        auto nursery = std::make_unique<NurserySpace>();
        nursery->initialize(nursery_base, NURSERY_SIZE);
        nurseries[tid] = std::move(nursery);

        next_nursery_offset += NURSERY_SIZE;
    }
}

NurserySpace *GarbageCollector::getNursery() {
    auto tid = std::this_thread::get_id();
    std::lock_guard<std::mutex> lock(nursery_mutex);
    auto it = nurseries.find(tid);
    if (it != nurseries.end()) {
        return it->second.get();
    }
    return nullptr;
}

void *GarbageCollector::allocate(size_t size, Tag tag) {
    NurserySpace *nursery = getNursery();

    if (nursery) {
        // Check if allocation would exceed 90% threshold - trigger GC proactively.
        // But only if GC is not already in progress (prevent recursion).
        bool gc_triggered = false;
        if (!gc_in_progress && nursery->wouldExceedThreshold(size, 0.9f)) {
            minorGC();
            gc_triggered = true;
        }

        void *obj = nursery->allocate(size);
        if (obj) {
            Header *hdr = getHeader(obj);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = tag;
            // For variable-sized types, hdr->size stores the element count.
            // For fixed-size types, it's unused (but set to total size for consistency).
            switch (tag) {
                case Tag_String:
                    hdr->size = (size - sizeof(ElmString)) / sizeof(u16);
                    break;
                case Tag_Custom:
                    hdr->size = (size - sizeof(Custom)) / sizeof(Unboxable);
                    break;
                case Tag_Record:
                    hdr->size = (size - sizeof(Record)) / sizeof(Unboxable);
                    break;
                case Tag_DynRecord:
                    hdr->size = (size - sizeof(DynRecord)) / sizeof(HPointer);
                    break;
                case Tag_FieldGroup:
                    hdr->size = (size - sizeof(FieldGroup)) / sizeof(u32);
                    break;
                case Tag_Closure:
                    hdr->size = (size - sizeof(Closure)) / sizeof(Unboxable);
                    break;
                default:
                    hdr->size = size;
                    break;
            }
            return obj;
        }

        // Nursery full - trigger GC only if we haven't already and if GC is not in progress.
        if (!gc_triggered && !gc_in_progress) {
            minorGC();
        }

        // Try again after GC.
        obj = nursery->allocate(size);
        if (obj) {
            Header *hdr = getHeader(obj);
            std::memset(hdr, 0, sizeof(Header));
            hdr->tag = tag;
            switch (tag) {
                case Tag_String:
                    hdr->size = (size - sizeof(ElmString)) / sizeof(u16);
                    break;
                case Tag_Custom:
                    hdr->size = (size - sizeof(Custom)) / sizeof(Unboxable);
                    break;
                case Tag_Record:
                    hdr->size = (size - sizeof(Record)) / sizeof(Unboxable);
                    break;
                case Tag_DynRecord:
                    hdr->size = (size - sizeof(DynRecord)) / sizeof(HPointer);
                    break;
                case Tag_FieldGroup:
                    hdr->size = (size - sizeof(FieldGroup)) / sizeof(u32);
                    break;
                case Tag_Closure:
                    hdr->size = (size - sizeof(Closure)) / sizeof(Unboxable);
                    break;
                default:
                    hdr->size = size;
                    break;
            }
            return obj;
        }
    }

    // Allocate in old gen.
    void *obj = old_gen.allocate(size);
    if (obj) {
        Header *hdr = getHeader(obj);
        hdr->tag = tag;
        switch (tag) {
            case Tag_String:
                hdr->size = (size - sizeof(ElmString)) / sizeof(u16);
                break;
            case Tag_Custom:
                hdr->size = (size - sizeof(Custom)) / sizeof(Unboxable);
                break;
            case Tag_Record:
                hdr->size = (size - sizeof(Record)) / sizeof(Unboxable);
                break;
            case Tag_DynRecord:
                hdr->size = (size - sizeof(DynRecord)) / sizeof(HPointer);
                break;
            case Tag_FieldGroup:
                hdr->size = (size - sizeof(FieldGroup)) / sizeof(u32);
                break;
            case Tag_Closure:
                hdr->size = (size - sizeof(Closure)) / sizeof(Unboxable);
                break;
            default:
                hdr->size = size;
                break;
        }
    }
    return obj;
}

void GarbageCollector::minorGC() {
    // Prevent recursive GC calls.
    if (gc_in_progress) {
        return;
    }

    // Set flag to indicate GC is in progress.
    gc_in_progress = true;

    NurserySpace *nursery = getNursery();
    if (nursery) {
        nursery->minorGC(root_set, old_gen);
    }

    // Clear flag when done.
    gc_in_progress = false;
}

void GarbageCollector::majorGC() {
    // Prevent recursive GC calls.
    if (gc_in_progress) {
        return;
    }

#if ENABLE_GC_STATS
    auto gc_start = GC_STATS_TIMER_START();
#endif

    // Set flag to indicate GC is in progress.
    gc_in_progress = true;

#if ENABLE_GC_STATS
    old_gen.startConcurrentMark(root_set, major_gc_stats);
    old_gen.finishMarkAndSweep(major_gc_stats);
#else
    old_gen.startConcurrentMark(root_set);
    old_gen.finishMarkAndSweep();
#endif

    // Perform compaction after marking.
    old_gen.selectCompactionSet();
    old_gen.setCompactionInProgress(true);
    old_gen.performCompaction();
    old_gen.reclaimEvacuatedBlocks();
    old_gen.setCompactionInProgress(false);

    // Clear flag when done.
    gc_in_progress = false;

#if ENABLE_GC_STATS
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
    GC_STATS_MAJOR_RECORD_GC_END(major_gc_stats, elapsed_ns);
#endif
}

#if ENABLE_GC_STATS
GCStats GarbageCollector::getCombinedNurseryStats() {
    GCStats combined;
    std::lock_guard<std::mutex> lock(nursery_mutex);
    for (const auto& [tid, nursery] : nurseries) {
        combined.combine(nursery->getStats());
    }
    return combined;
}
#endif

void GarbageCollector::reset() {
    // Reset root set.
    root_set.reset();

    // Reset all nurseries.
    {
        std::lock_guard<std::mutex> lock(nursery_mutex);
        for (auto& [tid, nursery] : nurseries) {
            nursery->reset(old_gen);
        }
    }

    // Reset old gen (must be after nurseries to handle any sealed TLABs).
    old_gen.reset();

    // Note: We do NOT reset GC stats here - stats accumulate across runs.

    // Reset thread-local GC flag.
    gc_in_progress = false;
}

} // namespace Elm
