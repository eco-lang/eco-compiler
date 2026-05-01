#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>
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
    // Follows forwarding pointers to the final evacuated location if present.
    // Returns nullptr for embedded constants (Nil, True, False, Unit, etc.).
    // Asserts on invalid pointers or corrupted memory.
    void* resolve(HPointer ptr);

    // Wraps a physical address as an HPointer.
    // Converts raw pointer returned by allocate() into a storable logical pointer.
    HPointer wrap(void* obj);

    // ========== Lifecycle ==========

    // Initializes the allocator with the given configuration.
    // Validates config parameters and throws std::invalid_argument on failure.
    // Must be called before any thread calls initThread().
    void initialize(const HeapConfig& config = HeapConfig());

    // Initializes the calling thread's heap space.
    // Creates a ThreadLocalHeap with dedicated nursery and old gen regions.
    // Thread-safe: acquires mutex to carve out regions from the unified heap.
    void initThread();

    // Cleans up the calling thread's heap space.
    // Should be called before the thread exits.
    void cleanupThread();

    // ========== Allocation ==========

    // Allocates an object in the thread-local nursery.
    // Delegates to the calling thread's ThreadLocalHeap.
    void *allocate(size_t size, Tag tag);

    // Fast-path allocation: bump-pointer only, no GC, no header init.
    // Returns nullptr if nursery has insufficient space.
    void *allocateFast(size_t size);

    // Slow-path allocation: may trigger GC, always succeeds or aborts.
    void *allocateSlow(size_t size, Tag tag);

    // Slow-path region allocation: contiguous region, may GC.
    void *allocateRegionSlow(size_t total);

    // Allocates an object directly in old generation (bypasses nursery).
    // Use for permanent objects like string literals that should never be collected.
    void *allocatePermanent(size_t size, Tag tag);

    // Split-header allocation paths (HEAP_026): the body lives pinned in old
    // gen; the small header lives in the nursery. Returns the header's
    // HPointer. See plans/large-object-split-header-bodies.md.
    HPointer allocLargeString(const u16* chars, size_t length);
    HPointer allocLargeByteBuffer(const u8* data, size_t length);

    // Returns the configured split-header threshold in bytes; allocations
    // whose total payload size meets or exceeds this should route through
    // the split path.
    size_t getLargeHeaderSplitThreshold() const {
        return config_.large_header_split_threshold;
    }

    // ========== Garbage Collection ==========

    // Triggers a minor GC on the thread-local nursery.
    void minorGC();

    // Triggers a major GC on the thread-local old gen.
    void majorGC();

    // ========== Root Management ==========

    // Returns the thread-local root set.
    RootSet &getRootSet();

    // ========== Diagnostics ==========

    // Fast-path check: should GC run at this safepoint?
    bool shouldCollectAtSafepoint();

    // Slow-path: perform collection at safepoint.
    void collectAtSafepoint();

    // Returns true if the thread-local nursery is over the threshold.
    bool isNurseryNearFull(float threshold);

    // Returns true if the pointer is in the calling thread's nursery.
    bool isInNursery(void *ptr);

    // Returns true if the pointer is in the calling thread's old gen.
    bool isInOldGen(void *ptr);

    // Returns true if the pointer is anywhere in the unified heap (any thread).
    // O(1) bounds check using base and reserved size.
    bool isInHeap(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= heap_base && p < heap_base + heap_reserved;
    }

    // Returns the current number of bytes allocated in thread-local old gen.
    size_t getOldGenAllocatedBytes() const;

    // Returns committed bytes in the shared old-gen region (all threads).
    size_t getOldGenCommittedBytes() const { return old_gen_in_use_bytes_; }

    // Returns committed bytes in the low / high nursery regions.
    size_t getNurseryLowCommittedBytes() const { return nursery_low_committed_; }
    size_t getNurseryHighCommittedBytes() const { return nursery_high_committed_; }

    // Returns the start offset of the nursery region (== old-gen cap).
    size_t getOldGenMaxBytes() const { return nursery_offset; }

    // Diagnostics: dumps heap state (old-gen + nursery commit counters plus
    // per-thread allocated_bytes and block counts) to stderr. Always emits;
    // callers guard with heapTraceEnabled() when the dump is only useful
    // during verbose tracing.
    void dumpHeapState(const char* label, size_t pending_size = 0) const;

    // Returns true when the environment variable ECO_HEAP_TRACE is set to a
    // non-zero / non-empty value. Queried once per process and cached.
    static bool heapTraceEnabled();

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
    size_t heap_reserved;         // Total address space reserved (bytes).
    // Bump-pointer high-water mark for old-gen mmap. Always grows (never
    // decremented) so a `MAP_FIXED` mmap from this position is guaranteed
    // to land on un-mapped address space, never overlaying live data at a
    // non-LIFO-released block.
    size_t old_gen_committed;
    // Bytes currently in use in the old gen — i.e. acquired minus released.
    // Decremented when a block is returned via `releaseOldGenBlock`. Used
    // by `getOldGenCommittedBytes()` and tests; not used for mmap arithmetic.
    size_t old_gen_in_use_bytes_;
    size_t nursery_offset;        // Byte offset where nursery region begins (heap midpoint).
    size_t nursery_low_committed_;   // Committed bytes in first half of nursery region.
    size_t nursery_high_committed_;  // Committed bytes in second half of nursery region.
    // Free-lists of previously-released nursery blocks, reused by subsequent
    // acquires before we bump the committed pointer. Entries are pairs of
    // (block pointer, block size); acquires pop a block whose size matches.
    std::vector<std::pair<char*, size_t>> nursery_low_freelist_;
    std::vector<std::pair<char*, size_t>> nursery_high_freelist_;
    // Free list of previously-released old-gen blocks (pages or large blocks)
    // that have been returned by `releaseOldGenBlock`. The virtual mapping is
    // retained; physical RSS may have been dropped via `madvise(MADV_DONTNEED)`.
    // `acquireOldGenBlock` consults this list (first-fit by size) before
    // bumping `old_gen_committed`.
    std::vector<std::pair<char*, size_t>> old_gen_free_blocks_;
    bool initialized;             // True after initialize() has been called.

#if ENABLE_GC_STATS
    // Accumulated statistics from destroyed thread heaps.
    // Preserves stats across test runs when the allocator is reset.
    GCStats accumulated_stats_;
#endif

    // ========== Thread-Local Heaps ==========

    mutable std::recursive_mutex thread_mutex_;  // Protects thread_heaps_ map and region allocation.
    std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> thread_heaps_;

    // Thread-local cache for fast access to current thread's heap (avoids map lookup).
    static thread_local ThreadLocalHeap* tl_heap_;

    // ========== Internal Methods ==========

    // Returns the calling thread's heap, or nullptr if not initialized.
    ThreadLocalHeap* getThreadHeap() const { return tl_heap_; }

    // Resets the allocator to initial state (clears all heaps and stats).
    // If new_config is provided, reconfigures with new parameters. Used for testing.
    void reset(const HeapConfig* new_config = nullptr);

    // Returns the base address of the unified heap.
    char *getHeapBase() const { return heap_base; }

    // Returns the total reserved heap size.
    size_t getHeapReserved() const { return heap_reserved; }

    // Returns the heap configuration.
    const HeapConfig& getConfig() const { return config_; }

    // Acquires a block of memory from the lower nursery region.
    // Thread-safe: acquires thread_mutex_.
    // First tries to reuse a block from the free-list populated by
    // releaseNurseryBlockLow; if that's empty, bumps nursery_low_committed_.
    char* acquireNurseryBlockLow(size_t size);

    // Acquires a block of memory from the upper nursery region.
    // Thread-safe: acquires thread_mutex_.
    // First tries to reuse a block from the free-list; otherwise bumps the
    // committed pointer.
    char* acquireNurseryBlockHigh(size_t size);

    // Returns a low-region nursery block to the free-list for reuse by a
    // later acquireNurseryBlockLow. Called by ~NurserySpace when a
    // ThreadLocalHeap is destroyed. Thread-safe.
    void releaseNurseryBlockLow(char* block, size_t size);

    // Returns a high-region nursery block to the free-list for reuse by a
    // later acquireNurseryBlockHigh. Thread-safe.
    void releaseNurseryBlockHigh(char* block, size_t size);

    // Acquires a block of memory from the old gen region.
    // Thread-safe: acquires thread_mutex_.
    // Returns pointer to base of committed block.
    // First scans `old_gen_free_blocks_` for a previously-released block of
    // size >= requested. On hit, optionally `madvise(MADV_WILLNEED)` and
    // re-add the size to `old_gen_committed`. Otherwise bumps the committed
    // pointer, calling `mmap` to materialize the page.
    char* acquireOldGenBlock(size_t size);

    // Returns an old-gen block to the free list for reuse by a later
    // `acquireOldGenBlock`. The virtual mapping is retained; if
    // `config_.decommit_on_oldgen_release` is true, also drops the physical
    // RSS via `madvise(MADV_DONTNEED)`. Subtracts `size` from
    // `old_gen_committed`. Thread-safe: acquires `thread_mutex_`.
    void releaseOldGenBlock(char* block, size_t size);

    // Post-major-GC growth hook: if an OldGenSpace has post-GC occupancy
    // above `major_gc_initiating_occupancy`, grow its committed range up to
    // `new_capacity_bytes` by acquiring additional old-gen blocks. Stops
    // early at the global old-gen cap. Best-effort: the caller must not
    // assume the requested capacity was achieved.
    void ensureOldGenCapacityFor(OldGenSpace& space, size_t new_capacity_bytes);

    // Acquires a contiguous region from the old gen address space.
    // Pre-condition: caller must hold thread_mutex_.
    // Commits initial_size bytes immediately, reserves space for growth to max_size.
    char* acquireOldGenRegion(size_t initial_size, size_t max_size);

    // Commits physical memory for a nursery block.
    void commitNursery(char *nursery_base, size_t size);

    // ========== Internal Pointer Conversion ==========

    // Raw pointer conversion without forwarding resolution.
    // Internal use only - friends can access for performance-critical GC operations.
    static inline void* fromPointerRaw(HPointer ptr) {
        assert(ptr.constant == 0 && "Cannot convert HPointer with constant field set (embedded constant)");
        char* heap_base = instance().heap_base;
        uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
        return heap_base + byte_offset;
    }

    // Converts a physical address to an HPointer without validation.
    // Internal use only - friends can access for performance-critical GC operations.
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

    // Converts a physical address to an HPointer.
    static HPointer toPointer(void* obj) {
        return Allocator::toPointerRaw(obj);
    }

    // Resets allocator state for testing.
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

    // Heap base address — used by sentinel-discipline tests to verify no
    // allocation lands at heap_base + 0.
    static char* getHeapBase(Allocator& alloc) {
        return alloc.getHeapBase();
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_H
