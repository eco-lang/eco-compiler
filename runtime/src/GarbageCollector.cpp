/**
 * GarbageCollector Implementation.
 *
 * This file implements the central GC coordinator that manages:
 *   - Unified heap address space (reserved via mmap, committed on demand).
 *   - Thread-local nurseries for fast allocation.
 *   - Old generation for long-lived objects.
 *   - Minor GC (copying collection in nurseries).
 *   - Major GC (concurrent mark-sweep in old gen).
 *
 * Memory layout:
 *   [0 .. heap_reserved/2)      - Old generation (grows from 0 upward).
 *   [heap_reserved/2 .. end)    - Nurseries (one per thread, 4MB each).
 */

#include "GarbageCollector.hpp"
#include <cstring>
#include <new>
#include <sys/mman.h>

namespace Elm {

// Global heap base for read barrier (used by fromPointer/toPointer).
char* g_heap_base = nullptr;

// Thread-local flag to prevent recursive GC calls during allocation.
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

// Initializes the GC with a reserved address space of max_heap_size bytes.
// Physical memory is committed lazily as needed for old gen and nurseries.
void GarbageCollector::initialize(size_t max_heap_size) {
    if (initialized) {
        return;
    }

    heap_reserved = max_heap_size;

    // Reserve address space without committing physical memory.
    // PROT_NONE means no access until we commit regions with mmap(MAP_FIXED).
    heap_base = static_cast<char *>(mmap(nullptr, heap_reserved,
                                         PROT_NONE,
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
    size_t initial_old_gen = INITIAL_OLD_GEN_SIZE;
    size_t max_old_gen = nursery_offset;  // Can grow to halfway point.
    growOldGen(initial_old_gen);
    old_gen.initialize(heap_base, old_gen_committed, max_old_gen);

    initialized = true;
}

// Commits additional physical memory for the old generation.
// Called when old gen needs to grow beyond its current committed size.
void GarbageCollector::growOldGen(size_t additional_size) {
    char *new_region = heap_base + old_gen_committed;

    void *result =
        mmap(new_region, additional_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }

    old_gen_committed += additional_size;
}

// Commits physical memory for a new thread's nursery.
void GarbageCollector::commitNursery(char *nursery_base, size_t size) {
    void *result = mmap(nursery_base, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);

    if (result == MAP_FAILED) {
        throw std::bad_alloc();
    }
}

// Returns the singleton GarbageCollector instance.
GarbageCollector &GarbageCollector::instance() {
    static GarbageCollector gc;
    return gc;
}

// Initializes GC state for the calling thread, creating its nursery.
// Must be called by each thread before it can allocate.
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

RootSet &GarbageCollector::getRootSet() {
    NurserySpace *nursery = getNursery();
    if (!nursery) {
        // Thread must call initThread() before using getRootSet().
        // Auto-initialize for convenience.
        initThread();
        nursery = getNursery();
    }
    return nursery->getRootSet();
}

std::vector<HPointer*> GarbageCollector::collectAllRoots() {
    std::vector<HPointer*> all_roots;
    std::lock_guard<std::mutex> lock(nursery_mutex);
    for (auto& [tid, nursery] : nurseries) {
        // Collect long-lived roots.
        const auto& roots = nursery->getRootSet().getRoots();
        all_roots.insert(all_roots.end(), roots.begin(), roots.end());
        // Collect stack roots.
        const auto& stack_roots = nursery->getRootSet().getStackRoots();
        all_roots.insert(all_roots.end(), stack_roots.begin(), stack_roots.end());
    }
    return all_roots;
}

// Allocates a heap object of the given size with the specified tag.
// Tries nursery first (fast path), falls back to old gen if nursery is full.
// May trigger minor GC if nursery usage exceeds threshold.
void *GarbageCollector::allocate(size_t size, Tag tag) {
    // FAST PATH: Check STW barrier first - blocks during major GC root marking.
    if (stw_barrier.load(std::memory_order_acquire)) [[unlikely]] {
        waitAtSTWBarrier();
    }

    NurserySpace *nursery = getNursery();

    if (nursery) {
        // Check if allocation would exceed threshold - trigger GC proactively.
        // But only if GC is not already in progress (prevent recursion).
        bool gc_triggered = false;
        if (!gc_in_progress && nursery->wouldExceedThreshold(size, NURSERY_GC_THRESHOLD)) {
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

// Triggers a minor GC on the current thread's nursery.
// Uses Cheney's copying algorithm to evacuate live objects to to-space
// or promote them to old gen if they've survived enough collections.
void GarbageCollector::minorGC() {
    if (gc_in_progress) {
        return;  // Prevent recursive GC calls.
    }

    gc_in_progress = true;

    NurserySpace *nursery = getNursery();
    if (nursery) {
        nursery->minorGC(old_gen);
    }

    gc_in_progress = false;
}

// Triggers a major GC cycle: concurrent mark-sweep on old generation.
// Briefly raises STW barrier during root collection, then marks concurrently.
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

    // Raise STW barrier - threads will block when they try to allocate.
    // This ensures a consistent view of roots and heap during initial marking.
    stw_barrier.store(true, std::memory_order_release);

    // Collect all roots from all threads.
    std::vector<HPointer*> all_roots = collectAllRoots();

    // Start marking phase - traces through ALL objects including nursery.
#if ENABLE_GC_STATS
    old_gen.startConcurrentMark(all_roots, *this, major_gc_stats);
#else
    old_gen.startConcurrentMark(all_roots, *this);
#endif

    // Lower STW barrier - threads can allocate again.
    stw_barrier.store(false, std::memory_order_release);
    gc_wait_cv.notify_all();

    // Continue with concurrent marking and sweep.
#if ENABLE_GC_STATS
    old_gen.finishMarkAndSweep(major_gc_stats);
#else
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

    // Signal completion - updates pressure state and wakes blocked allocators.
    signalGCComplete();
}

// ============================================================================
// Thread signalling.
// ============================================================================

void GarbageCollector::signalGCComplete() {
    // Wake all waiting threads to let them retry allocation.
    gc_wait_cv.notify_all();
}

void GarbageCollector::signalShutdown() {
    // Set shutdown flag and wake all blocked allocators.
    shutdown_flag.store(true, std::memory_order_release);
    gc_wait_cv.notify_all();
}

void GarbageCollector::waitAtSTWBarrier() {
    // Block until STW barrier is lowered or shutdown is signaled.
    std::unique_lock<std::mutex> lock(gc_wait_mutex);
    gc_wait_cv.wait(lock, [this] {
        return !stw_barrier.load(std::memory_order_acquire) ||
               shutdown_flag.load(std::memory_order_acquire);
    });
}

bool GarbageCollector::isInNursery(void *ptr) {
    // Check if the pointer is in any thread's nursery.
    std::lock_guard<std::mutex> lock(nursery_mutex);
    for (const auto& [tid, nursery] : nurseries) {
        if (nursery->contains(ptr)) {
            return true;
        }
    }
    return false;
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
    // Reset all nurseries (each nursery resets its own root set).
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
