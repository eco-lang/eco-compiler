#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

// A compiled Elm program needs one heap whose every address fits in an HPointer word, and this component is
// the process-wide owner of that heap's address space and of the heap of the thread that runs Elm code.
//
// Three facts shape it.
//
// The first is that an HPointer to a heap object is the object's address, so the whole heap must lie below
// 2^43 (`HPOINTER_ADDRESS_LIMIT`; `Heap.hpp` states the encoding). `initialize` therefore reserves one range
// of `max_heap_size` bytes below that limit, without committing it, and every heap address comes from it.
// The range is split once: the old generation gets [base, base + `nursery_offset`) and the nursery the top
// `HeapConfig::nurseryRegionBytes()` bytes. The first `initialize` in a process decides the reservation and
// the split, and nothing moves them afterwards; a `reset` rebuilds only what is laid out inside them.
//
// The second is that a process has one mutator: one thread that runs Elm code, allocates and decides every
// collection (HEAP_007). Its heap is a `ThreadLocalHeap`, created by `initThread` and destroyed by
// `cleanupThread`, and the allocation and collection calls here pass straight to the calling thread's heap.
// `initThread` aborts when another heap is still live. The exceptions are a harness that has called
// `allowMultipleMutators(true)`, mutators that follow one another (one cleans up, then the next starts), and
// a forked child, where only the forking thread's heap is live. Collection work also runs on other threads,
// the members of the GC gangs, and some of them call the old-generation block supply below.
//
// The third is that the address space is shared even though a heap's spaces are not. The nursery region and
// the old-generation range are handed out from here, under `thread_mutex_`, to whichever heap asks:
//
//   - The nursery region is cut into slots, and a heap holds one slot. In the default layout each half of
//     the region is cut into equal slices, and a slot is the low and the high slice at one index, giving the
//     heap two contiguous semi-spaces (a `NurserySlicePair`). In the region layout (`nursery_regions = 1`) a
//     slot is a run of equal extents at a power-of-two stride (a `NurserySliceSet`). Either way a slot keeps
//     its *retained commit*, the highest offset it has ever had committed, after it is released, so that the
//     next heap to take it does not commit those pages again.
//   - The old generation takes its memory as blocks. A block comes from a list of extents released earlier,
//     or else from a bump pointer, `old_gen_committed`, that only ever grows. The bump never falls because a
//     fresh block is committed with a mapping placed at a fixed address, and placing one over an extent that
//     was released out of order would destroy live data. So there are two figures for the old generation:
//     the bytes in use (acquired minus released), which drive the collection triggers, and the high-water
//     mark of the bump, which is the hard limit at `nursery_offset`.
//
// When `gc_thread_mode` is 1 or 2, a `gc::PageWork` defers the discarding of released extents and commits
// ahead of the bump on helper threads. Its clock is the *sync point*, the end of the outermost collection
// pause, which `onGCPauseEnd` reports.
//
// `thread_mutex_` is recursive, because the block supply calls itself. It is taken by the block and slot
// calls, by `initThread`, `cleanupThread`, `reset` and the statistics calls, and at each sync point when
// there is page work. A heap is destroyed with it released, because destroying a heap joins GC threads
// whose own locks come before `thread_mutex_` in the process lock order: the gangs, then `thread_mutex_`,
// then the census, then the helper pool (HEAP_075). A `fork` takes them in that order (`GCFork.hpp`),
// and a fork from a thread that holds `thread_mutex_` is not supported.
/*
 * Two of the calls that lock the allocator:
 *   - initThread() acquires mutex to allocate regions
 *   - getCombinedStats() acquires mutex to iterate all thread heaps
 */

#include <atomic>
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
#include "GCReport.hpp"

namespace Elm {
class ThreadLocalHeap;
namespace gc { class PageWork; }

class Allocator;
// The storage of the one `Allocator`, defined in `Allocator.cpp`. `Allocator::instance` returns it
// directly, so that reaching the allocator costs no call and no check of a function-local static.
extern Allocator g_allocator_storage;

/**
 * The process's heap: the owner of its address reservation, of the old-generation block supply and the
 * nursery slots, and of the `ThreadLocalHeap` of each mutator.
 *
 * There is one, `g_allocator_storage`, and code reaches it through `instance`; nothing prevents another
 * being constructed, but nothing here supports one. Construction only zeroes it. `initialize` reserves the
 * address space, and must run before any allocation; `initThread` calls it if nothing has. The allocation,
 * collection and query calls act on the calling thread's heap, and most of them require `initThread` to
 * have been called on that thread first. Destruction drains any helper work, destroys the heaps (a forked
 * child's dead heaps are leaked instead) and releases the reservation.
 */
class Allocator {
public:
    // Returns the process's allocator.
    static inline Allocator &instance() noexcept {
        return g_allocator_storage;
    }

    // ========== Safe Public Pointer API ==========

    // Returns the address of the object `ptr` refers to, following forward headers to where it now lives.
    //
    // `ptr` must refer to a heap or `PermanentSpace` object, not an embedded constant or null. Those are
    // checked only in `ECO_HEAP_VALIDATE` builds, which also check a nursery address against the free
    // regions. Forward headers exist only during a collection; outside one this returns the word's address.
    void* resolve(HPointer ptr);

    // Returns the address of the object `ptr` refers to, as `resolve` does, inline.
    //
    // The common case, a header that is not `Tag_Forward`, is the word read as an address; otherwise this
    // calls `resolve`. `ptr` must not be an embedded constant (its `ptr_ind` must be 0), and nothing checks
    // it except an assertion.
    static inline void* resolveFast(HPointer ptr) {
        void* obj = fromPointerRaw(ptr);
        if (__builtin_expect(getHeader(obj)->tag == Tag_Forward, 0))
            return Allocator::instance().resolve(ptr);
        return obj;
    }

    // Returns the HPointer for the object at `obj`, which is the address as a word.
    //
    // `obj` must be non-null, 8-byte aligned and inside the heap or `PermanentSpace`; each is asserted.
    HPointer wrap(void* obj);

    // ========== Lifecycle ==========

    // Reserves the heap's address space and adopts `environmentConfig(config)` as the configuration.
    //
    // Later calls change nothing and return at once; only `reset` reconfigures. Throws
    // what `environmentConfig` throws for an invalid configuration, `std::invalid_argument` for a
    // `max_heap_size` above the HPointer address limit, and `std::bad_alloc` if the reservation fails.
    // Nothing is committed. In `gc_thread_mode` 1 or 2 it also configures the GC helper pool.
    void initialize(const HeapConfig& config = HeapConfig());
    // Returns the configuration a process runs with: `base`, overridden by the JSON in `$ECO_HEAP_CONFIG`,
    // then by the `ECO_GC_*` and `ECO_NURSERY_*` variables, then resolved and validated.
    //
    // Writes the helper jitter in microseconds from `ECO_GC_HELPER_JITTER_US` to `helper_jitter_us`, 0 when
    // it is unset. Throws `std::invalid_argument` for an invalid configuration, and may throw what the
    // JSON reader throws (`HeapConfigJson.hpp`).
    static HeapConfig environmentConfig(const HeapConfig& base, uint32_t& helper_jitter_us);

    // Returns the configuration in force. The reference stays valid, and changes only at a `reset`.
    const HeapConfig& getConfig() const { return config_; }

    // Makes the calling thread the mutator, creating its heap, and initializes the allocator first if
    // nothing has.
    //
    // A thread that already has a heap is left as it is. If another thread's heap is live, this prints a
    // message and aborts, unless `allowMultipleMutators(true)` is in force. The heap commits its memory on
    // demand, not here.
    void initThread();

    // Lets `initThread` create a heap while another is live, when `on` is true. For benchmark and test
    // harnesses only.
    //
    // Two live heaps share the block supply, the released-extent list and the page work, so neither
    // heap's collections depend on that heap alone (GC_DET_001 does not hold). `reset` turns it off.
    void allowMultipleMutators(bool on) {
        std::lock_guard<std::recursive_mutex> l(thread_mutex_);
        multi_mutator_opt_in_ = on;
    }

    // Destroys the calling thread's heap, after finishing its last tenure job and, in statistics builds,
    // keeping its statistics. Does nothing on a thread with no heap.
    void cleanupThread();
    // Finishes the calling thread's last tenure job, stopping or joining its collector, so that the run's
    // statistics include it. Does nothing on a thread with no heap. The heap stays live.
    void finishTenureForExit();

    // ========== Allocation ==========

    // Each call in this group acts on the calling thread's heap, as the `ThreadLocalHeap` function of the
    // same name describes, and requires `initThread` to have been called on the thread (asserted only).

    // Allocates `size` bytes for an object with tag `tag`, collecting first if needed.
    void *allocate(size_t size, Tag tag);

    // Allocates `size` bytes from the nursery by bumping its pointer, or returns null if they do not fit.
    // Never collects, and writes no header.
    void *allocateFast(size_t size);

    // Allocates `size` bytes for an object with tag `tag`, collecting as needed. Returns or aborts.
    void *allocateSlow(size_t size, Tag tag);

    // Allocates `size` bytes for compiled code's inline nursery allocation after its bump failed, collecting
    // and retrying. Writes no header (HEAP_034).
    void *allocateSlowRaw(size_t size);

    // Returns the address of the calling thread's nursery bump state, the {ptr, end} pair that compiled
    // code allocates from (HEAP_034).
    //
    // The address stays the same while the thread's heap lives; only its contents change.
    void *bumpState();

    // Makes at least `n` bytes free in the nursery's bump range without allocating them, collecting if
    // needed, so that `n` bytes of allocations checked once up front need no further check (HEAP_041).
    void ensureNursery(size_t n);

    // Allocates `total` contiguous bytes, which the caller divides into several objects, collecting if
    // needed.
    void *allocateRegionSlow(size_t total);

    // Allocates `size` bytes for an object with tag `tag` directly in the old generation.
    //
    // The object is an ordinary old-generation object, which a major collection frees when nothing refers
    // to it; the caller must root it to keep it.
    void *allocatePermanent(size_t size, Tag tag);

    // Allocates a String of `length` UTF-16 units copied from `chars`, with its body in the old generation,
    // pinned, and its header in the nursery. Returns the header (HEAP_026).
    HPointer allocLargeString(const u16* chars, size_t length);
    // Allocates a byte buffer of `length` bytes copied from `data`, laid out as `allocLargeString` lays out
    // a String. Returns the header (HEAP_026).
    HPointer allocLargeByteBuffer(const u8* data, size_t length);

    // Returns the large-object threshold in bytes: the size from which an allocation takes the large-object
    // path, as `HeapConfig::large_object_threshold` describes.
    size_t getLargeObjectThreshold() const {
        return config_.large_object_threshold;
    }

    // Returns a count that rises at the first `initialize` and at every `reset`.
    //
    // A `reset` destroys every heap and root set, so a cache that keeps heap pointers across calls can
    // compare this value with the one it saw and drop its contents when they differ.
    uint64_t heapGeneration() const { return heap_generation_; }

    // Returns the calling thread's heap, or null if the thread has none. The heap lives until
    // `cleanupThread` or `reset`.
    ThreadLocalHeap* getCurrentThreadHeap() const noexcept { return tl_heap_; }

    // ========== GC helper threads ==========

    // Reports a sync point: the end of `heap`'s outermost collection pause, with `had_major` true if the
    // pause ran a major collection.
    //
    // Advances the page work's clocks, which may post discards and commit-ahead work to the helper pool.
    // Does nothing in `gc_thread_mode` 0. `heap` is not used.
    void onGCPauseEnd(ThreadLocalHeap& heap, bool had_major);

    // Waits for every posted helper job to finish, leaving deferred discards pending. Does nothing in
    // `gc_thread_mode` 0.
    void drainHelperWork();

    // Returns the calling thread's nursery capacity per semi-space in bytes, or 0 if the thread has no heap.
    size_t nurseryCapacityBytes() const;

    // Returns the page work, for tests and validation, or null in `gc_thread_mode` 0. The pointer is valid
    // until the next `reset`.
    gc::PageWork* pageWork() const { return page_work_.get(); }

    // A hook for tests, null unless a test sets it, called with every range the old generation is about to
    // commit: a fresh bump, a fresh region, or a commit-ahead window.
    static void (*commit_observer_for_testing)(char* p, size_t n);

    // ========== Garbage Collection ==========

    // Runs a minor collection on the calling thread's heap, as `ThreadLocalHeap::minorGC` describes.
    void minorGC();

    // Runs a major collection on the calling thread's heap, as `ThreadLocalHeap::majorGC` describes.
    void majorGC();

    // ========== Explicit collections (HEAP_076) ==========
    // A caller runs these on its own thread's heap, outside any collection pause; either breach prints a
    // message and aborts. In each returned report, the `rss_*` figures, the `*_ns` timings and `trim_result`
    // are observations, which no collection decision reads.

    // Runs a major collection, finishes its sweep and shrinks the old generation, then discards every
    // pending released extent at once, then, on glibc, returns free `malloc` memory to the system. Returns
    // what happened, measured before and after.
    //
    // With decommit off there is nothing pending and nothing is discarded. No lock is held across the
    // collection.
    GCReport collectMajorAndRelease();

    // Runs a minor collection, which may go on to run a major one (`majors_run` says), and returns what
    // happened, measured before and after. There is no forced sweep, shrink, discard or trim, and the
    // timings and trim result for those keep their defaults.
    GCReport collectMinor();

    // ========== Root Management ==========

    // Returns the calling thread's root set, calling `initThread` first if the thread has no heap. For
    // callers that may run before `initThread`. The root set lives as long as the thread's heap.
    RootSet &getRootSetSlow();

    // Returns the calling thread's root set.
    //
    // The thread must have a heap; nothing checks it, and on a thread without one this dereferences null.
    // Use `getRootSetSlow` where that may be so.
    inline RootSet &getRootSet() noexcept;

    // ========== Diagnostics ==========

    // Returns whether the calling thread's heap wants to collect at a safepoint; false if it has no heap.
    bool shouldCollectAtSafepoint();

    // Runs the collection the calling thread's heap wants at a safepoint.
    void collectAtSafepoint();

    // Returns whether the calling thread's nursery is fuller than `threshold`, as
    // `ThreadLocalHeap::isNurseryNearFull` measures it; false if the thread has no heap.
    bool isNurseryNearFull(float threshold);

    // Returns whether `ptr` lies in the calling thread's nursery; false if the thread has no heap.
    bool isInNursery(void *ptr);

    // Returns whether `ptr` lies in the calling thread's old generation; false if the thread has no heap.
    bool isInOldGen(void *ptr);

    // Returns whether `ptr` lies anywhere in the reserved heap range, whichever space or heap it is in.
    // `PermanentSpace` is outside the range.
    bool isInHeap(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= heap_base && p < heap_base + heap_reserved;
    }

    // Checks, in `ECO_HEAP_VALIDATE` builds, that `hp` does not point into a free part of the calling
    // thread's nursery, aborting if it does. Does nothing otherwise.
    //
    // `hp` may be any 64-bit value, such as an unboxed Int read as an HPointer: an embedded constant, null,
    // and any address outside the nursery are passed over, and the check never dereferences an address
    // before finding it in the nursery.
    void validateInNurserySafe(HPointer hp);

    // Returns the bytes allocated in the calling thread's old generation, or 0 if the thread has no heap.
    size_t getOldGenAllocatedBytes() const;

    // Returns the old-generation bytes in use across the process: bytes acquired as blocks and regions,
    // minus bytes released. Not the commit high-water mark, despite the name; that is
    // `getOldGenCommitHighWaterBytes`.
    //
    // The read takes no lock. A relaxed atomic makes it safe while another thread updates the figure.
    size_t getOldGenCommittedBytes() const { return old_gen_in_use_bytes_.load(std::memory_order_relaxed); }
    // Returns the helper jitter in microseconds (`ECO_GC_HELPER_JITTER_US`, 0 for none), as read at
    // `initialize`.
    uint32_t helperJitterUs() const { return helper_jitter_us_; }

    // The two old-generation figures, which differ: the first falls when blocks are released, the second
    // never falls. Both restart at a `reset`.

    // Returns the highest value `getOldGenCommittedBytes` has reached.
    size_t getOldGenInUsePeakBytes() const { return old_gen_in_use_peak_; }
    // Returns the old-generation bump's high-water mark: the bytes from the heap base that the old
    // generation has committed since the last `reset`. It never passes the end of the old-generation range.
    size_t getOldGenCommitHighWaterBytes() const { return old_gen_committed; }

    // Returns the bytes committed since the last `reset` in the low half of the nursery region by the
    // slice-pair layout, plus every byte the region layout commits, which is counted here too.
    size_t getNurseryLowCommittedBytes() const { return nursery_low_committed_; }
    // Returns the bytes committed since the last `reset` in the high half of the nursery region by the
    // slice-pair layout.
    size_t getNurseryHighCommittedBytes() const { return nursery_high_committed_; }

    // Returns the old generation's cap in bytes: the smaller of the configured cap,
    // `HeapConfig::oldGenCapBytes()`, and the size of the old-generation range reserved at the first
    // `initialize`.
    //
    // The reservation never changes, but a `reset` may configure a smaller heap, and the cap follows it
    // down. Code that needs the old generation's cap should take it from here rather than from the
    // configuration.
    size_t getOldGenMaxBytes() const {
        const size_t config_cap = config_.oldGenCapBytes();
        return config_cap < nursery_offset ? config_cap : nursery_offset;
    }

    // Writes one line describing the heap, labelled `label`, to stderr: the old-generation and nursery
    // commit figures, the released extents, and the calling thread's old generation, with `pending_size`
    // added when it is not 0.
    //
    // Compiled to nothing unless the build sets `ECO_HEAP_TRACE`. When compiled in, it writes whether or
    // not `heapTraceEnabled()` is true.
    void dumpHeapState(const char* label, size_t pending_size = 0) const;

    // Returns whether heap tracing is on: compiled in with `ECO_HEAP_TRACE`, and the `ECO_HEAP_TRACE`
    // variable set to something other than empty or "0" when this is first called. Always false, and a
    // constant, in a build without it.
    static bool heapTraceEnabled();

#if ENABLE_GC_STATS
    // Returns the statistics of every heap destroyed since the process began, combined with those of every
    // live heap (in a forked child, only the forking thread's), together with the allocator's own figures:
    // the old-generation peak and high-water mark, page supply and the helper pool.
    GCStats getCombinedStats() const;
#endif

    // Creates an allocator with no reservation and no heaps. `initialize` does the rest.
    Allocator();
    ~Allocator();

private:

    // ========== Unified Heap ==========

    HeapConfig config_;
    char *heap_base;              // Start of the reservation; null before `initialize`.
    size_t heap_reserved;         // Bytes reserved.
    // The old-generation bump: the next fresh block or region starts at `heap_base + old_gen_committed`.
    // It only ever grows, until a `reset` zeroes it, so a fresh commit never lands on an extent that is in
    // use.
    size_t old_gen_committed;
    // Old-generation bytes acquired minus bytes released. Written only under `thread_mutex_`, by a relaxed
    // load and store, and read without the lock by the collection triggers.
    std::atomic<size_t> old_gen_in_use_bytes_;
    // Adds `n` to the in-use figure. The caller holds `thread_mutex_`.
    void addOldGenInUse(size_t n) {
        old_gen_in_use_bytes_.store(old_gen_in_use_bytes_.load(std::memory_order_relaxed) + n,
                                    std::memory_order_relaxed);
    }
    // Subtracts `n` from the in-use figure. The caller holds `thread_mutex_`.
    void subOldGenInUse(size_t n) {
        old_gen_in_use_bytes_.store(old_gen_in_use_bytes_.load(std::memory_order_relaxed) - n,
                                    std::memory_order_relaxed);
    }
    // The highest value of the in-use figure, updated by `noteOldGenInUsePeak` after each increase.
    size_t old_gen_in_use_peak_;
    size_t nursery_offset;        // Offset of the nursery region from `heap_base`; the old-gen range's size.
    size_t nursery_low_committed_;
    size_t nursery_high_committed_;
    // ---- Nursery slots, slice-pair layout (HEAP_042) ----
    //
    // `retained_low` and `retained_high` are the bytes from each slice's base that have ever been committed,
    // kept while the slot is free. They are kept per side because a grow that fails half way raises one side
    // only, and they may exceed the capacity of the heap holding the slot; the pages beyond it are committed
    // and unused. `rebuildNurserySliceTable` drops them, because slot bases move when the geometry changes.
    struct NurserySliceSlot {
        bool   in_use        = false;
        size_t retained_low  = 0;
        size_t retained_high = 0;
    };
    std::vector<NurserySliceSlot> nursery_slots_;
    // Size of one slice; in the region layout, the per-extent ceiling. 0 before `initialize`.
    size_t nursery_slice_bytes_;
    // ---- Nursery slots, region layout (HEAP_069) ----
    //
    // Built instead of the pair table when `config_.nursery_regions` is 1. A slot is `region_extents_`
    // extents at a stride of 2^`region_stride_log2_` bytes, and `retained[k]` is extent k's retained commit.
    struct NurseryRegionSlot {
        bool   in_use = false;
        size_t retained[8] = {};
    };
    std::vector<NurseryRegionSlot> region_slots_;
    size_t   region_stride_log2_ = 0;
    unsigned region_extents_ = 0;
    size_t   region_growth_bytes_ = 0;   // Largest capacity one extent may grow to (at most the stride).
    // Old-generation extents released and not yet reused, as (base, size). Their address range stays
    // reserved; their pages may have been discarded, or have a discard pending in `page_work_`.
    std::vector<std::pair<char*, size_t>> old_gen_free_blocks_;
    bool initialized;             // Set by the first `initialize`, and never cleared.
    uint32_t helper_jitter_us_ = 0;
    // Page work, the sync-point and major counts it is clocked by, and the page-supply counters, all guarded
    // by `thread_mutex_`. `page_work_` is null in `gc_thread_mode` 0; the counters are kept in every mode.
    std::unique_ptr<gc::PageWork> page_work_;
    uint64_t sync_epoch_ = 0;
    uint64_t major_epoch_ = 0;       // Sync points that ended a pause with a major collection.
    PageSupplyStats page_supply_;
    // Replaces `page_work_` with one built from `config_`, or with null in `gc_thread_mode` 0, and
    // configures the helper pool to match, first shutting it down if it was configured differently.
    void rebuildPageWork();
    // Returns whether the calling thread is inside a collection pause: its heap is in one, or it is a
    // `GCMarkGang` member running a job, which happens only inside its owner's pause. Every helper-job wait
    // is charged as a stall inside or outside a pause by this; nothing else depends on it.
    bool callerInPause() const;
#if ECO_HEAP_VALIDATE
    // Checks the page work against the heaps and aborts, naming `where`, on the first breach: every extent
    // it tracks must be in `old_gen_free_blocks_` exactly once, with the same size, and overlap no block a
    // live heap holds, and every populate in flight must lie in the old-generation range. The caller holds
    // `thread_mutex_`.
    void validatePageWork(const char* where) const;
#endif
    uint64_t heap_generation_ = 0;

#if ENABLE_GC_STATS
    // Statistics of the heaps destroyed so far, by `cleanupThread` or `reset`.
    GCStats accumulated_stats_;
#endif

    // When `initialize` finished, in steady-clock nanoseconds; 0 before. `getCombinedStats` measures the
    // run's wall time from it.
    uint64_t runtime_start_ns_ = 0;

    // ========== Thread-Local Heaps ==========

    // Guards `thread_heaps_`, `multi_mutator_opt_in_`, the slot tables, `old_gen_free_blocks_`,
    // `old_gen_committed`, the writes of `old_gen_in_use_bytes_`, `page_work_`, the epochs, `page_supply_`
    // and `accumulated_stats_`. Recursive, because block acquisition releases a split-off tail through
    // `releaseOldGenBlock`. Mutable so that `getCombinedStats` can lock it.
    mutable std::recursive_mutex thread_mutex_;
    std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> thread_heaps_;
    bool multi_mutator_opt_in_ = false;
    // Set in a forked child, with `fork_owner_` the id of the thread that forked (it keeps its id in the
    // child). Only the heap keyed by `fork_owner_` is live there. The others belong to threads that do not
    // exist in the child and may have been part way through an update at the fork, so they are dead: never
    // collected, never read, never destroyed (`dropForkDeadHeapsLocked` leaks them).
    bool fork_child_ = false;
    std::thread::id fork_owner_;
    // The allocator's layer of the process's fork handling, `gc::kForkAllocator`, run by `fork` in the lock
    // order the file comment gives.
    // Locks `thread_mutex_` before a fork.
    static void forkPrepare();
    // Unlocks `thread_mutex_` in the parent after a fork.
    static void forkParent();
    // Makes a forked child's allocator usable: constructs a fresh, unlocked `thread_mutex_` in place, since
    // unlocking the inherited one fails a check of its owner, and records the child's thread as the fork
    // owner.
    static void forkChild();
    // Removes every heap but the fork owner's from `thread_heaps_` without destroying it, in a forked child;
    // does nothing otherwise. The caller holds `thread_mutex_`.
    void dropForkDeadHeapsLocked();

    // The calling thread's heap, or null. `thread_heaps_` owns it; this only refers to it. Constant
    // initialization and the initial-exec TLS model make reading it a plain thread-local load with no call,
    // even in position-independent code.
    static constinit thread_local ThreadLocalHeap* tl_heap_
        __attribute__((tls_model("initial-exec")));

    // Sets the calling thread's heap to `h`, or to none when `h` is null, together with the thread-local
    // words compiled code reads beside it: `eco_tl_bump_state` and the root-stack cursors, base and limit.
    // The cursors are set to the start of `h`'s root stacks.
    //
    // This is the only code that writes `tl_heap_`, and writing it anywhere else would leave compiled code
    // allocating from the wrong nursery. Callers call it with no root range pushed.
    static void setThreadHeap(ThreadLocalHeap* h);

    // ========== Internal Methods ==========

    // Returns the calling thread's heap, or null if it has none.
    ThreadLocalHeap* getThreadHeap() const { return tl_heap_; }

    // Returns the allocator to its state after `initialize`, for tests: waits for all helper work and
    // discards every pending extent, destroys every heap after keeping its statistics, and empties the
    // block supply and its counters.
    //
    // With `new_config`, that configuration (resolved and validated, but without the environment) replaces
    // the current one, and the nursery slot geometry is rebuilt from it; throws `std::invalid_argument` if
    // it is invalid, before any heap is destroyed but after the page work has been drained and dropped.
    // The reservation and its split stay as the first `initialize` made them.
    void reset(const HeapConfig* new_config = nullptr);

    // Returns the start of the reservation.
    char *getHeapBase() const { return heap_base; }

    // Returns the size of the old-generation range, [`heap_base`, `heap_base` + `nursery_offset`), in
    // which every old-generation block lies (HEAP_043). Fixed at the first `initialize`.
    size_t getOldGenReservationBytes() const { return nursery_offset; }

    // Returns the bytes reserved.
    size_t getHeapReserved() const { return heap_reserved; }

    // Raises `old_gen_in_use_peak_` to the in-use figure if that is higher. Called after every increase;
    // the caller holds `thread_mutex_`.
    void noteOldGenInUsePeak() {
        const size_t v = old_gen_in_use_bytes_.load(std::memory_order_relaxed);
        if (v > old_gen_in_use_peak_) {
            old_gen_in_use_peak_ = v;
        }
    }

    // ---- Nursery slots, slice-pair layout (HEAP_042). Each call takes `thread_mutex_`. ----

    // Rebuilds both slot tables from the current configuration within the nursery region fixed at the first
    // `initialize`, dropping every retained commit. The region table is built only when
    // `config_.nursery_regions` is 1. Run once `config_` and `nursery_offset` are final.
    void rebuildNurserySliceTable();

    // Claims the first free slot and returns its two slices with capacity `initial`, clamped to the slice
    // size. Commits on each side only what lies beyond the slot's retained commit.
    //
    // Prints a message naming the settings that size the slots and aborts if every slot is taken. If a
    // commit fails, returns a pair with capacity 0 and leaves the slot free.
    NurserySlicePair acquireNurserySlicePair(size_t initial);

    // Raises `pair`'s capacity by `delta` on both sides, committing only what lies beyond the retained
    // commit, and returns true.
    //
    // Returns false with `pair.capacity` unchanged if `delta` is 0, the new capacity exceeds the slice, or a
    // commit fails. A low side committed before the high side failed stays committed, as retained commit.
    bool growNurserySlicePair(NurserySlicePair& pair, size_t delta);

    // Frees `pair`'s slot for another heap, keeping its retained commit.
    void releaseNurserySlicePair(const NurserySlicePair& pair);

    // Returns the slice size of the live geometry, or in the region layout the per-extent ceiling. 0 before
    // `initialize`.
    size_t getNurserySliceBytes() const { return nursery_slice_bytes_; }

    // ---- Nursery slots, region layout (HEAP_069). Each call takes `thread_mutex_`. ----

    // Claims the first free region slot and returns it with every extent at capacity `initial`, clamped to
    // the per-extent ceiling. Commits in each extent only what lies beyond its retained commit.
    //
    // Prints a message and aborts if every slot is taken. If a commit fails, returns a set with capacity 0
    // and leaves the slot free.
    NurserySliceSet acquireNurserySliceSet(size_t initial);
    // Raises the capacity of every extent of `set` by `delta` and returns true, or returns false with
    // `set.capacity` unchanged: for a `delta` of 0, a capacity past the ceiling, or a failed commit, after
    // which extents committed earlier keep it as retained commit.
    bool growNurserySliceSet(NurserySliceSet& set, size_t delta);
    // Frees `set`'s slot for another heap, keeping its retained commit.
    void releaseNurserySliceSet(const NurserySliceSet& set);
    // Returns log2 of the region stride in bytes; 0 when the region table is empty.
    size_t getRegionStrideLog2() const { return region_stride_log2_; }
    // Returns the number of extents in a region slot; 0 when the region table is empty.
    unsigned getRegionExtents() const { return region_extents_; }
    // Returns the largest capacity one extent may grow to; 0 when the region table is empty.
    size_t getRegionGrowthBytes() const { return region_growth_bytes_; }
    // Returns the number of region slots; 0 when the region table is empty.
    size_t getRegionSlotCount() const { return region_slots_.size(); }

    // Returns the number of slots in the slice-pair table.
    size_t getNurserySliceSlotCount() const { return nursery_slots_.size(); }

    // Returns the base of `size` committed old-generation bytes, `size` rounded up to 8, or null when the
    // old-generation range has no room left or a commit fails.
    //
    // The first released extent that fits is reused, any part of it beyond `size` being released again as
    // an extent of its own; otherwise the block is taken from the bump. An extent with a discard pending in
    // the page work has it cancelled, and one whose discard is already posted is waited for, before its
    // pages are handed out. Either way the block counts as in use.
    //
    // A request of exactly `alloc_buffer_size` must be a multiple of the OS page size, and is never given
    // an extent at `heap_base` or one whose size is not a multiple of the page. Other requests must
    // themselves be page multiples whenever a larger extent may be split (asserted).
    //
    // With `w = AvoidUnderPromo`, for a caller holding `OldGenSpace`'s promotion lock in a parallel
    // promotion with more than one worker, and with deferred discards on, the choice avoids waiting on a
    // helper: an extent whose discard is still pending first, else the bump, and only when the bump has no
    // room the first fit, which may wait.
    // Takes `thread_mutex_`, which may already be held by the caller.
    using AcquireWait = ::Elm::AcquireWait;
    char* acquireOldGenBlock(size_t size, AcquireWait w = AcquireWait::Allowed);

    // Returns the `size` bytes at `block`, `size` rounded up to 8, to the released extents, for a later
    // `acquireOldGenBlock`, and takes them off the in-use figure. The bump is not lowered.
    //
    // The pages are discarded only when `decommit_on_oldgen_release` is set: at once in `gc_thread_mode` 0,
    // and otherwise later, on a helper thread, as the page work decides. Takes `thread_mutex_`, which may
    // already be held by the caller.
    void releaseOldGenBlock(char* block, size_t size);

    // Grows `space`'s range toward `new_capacity_bytes` by acquiring blocks of `alloc_buffer_size` and adding
    // them to its unassigned blocks, stopping early when acquisition fails. The caller must not rely on
    // reaching the capacity asked for.
    //
    // The range, from the lowest to the highest block `space` holds, may include addresses that belong to
    // no block of `space`. Takes `thread_mutex_`.
    void ensureOldGenCapacityFor(OldGenSpace& space, size_t new_capacity_bytes);

    // Returns the base of `initial_size` committed bytes taken from the old-generation bump, rounded up to
    // 8, or null for a size of 0, when the range has no room, or when the commit fails. `max_size` is not
    // used. Takes `thread_mutex_`.
    char* acquireOldGenRegion(size_t initial_size, size_t max_size);

    // Commits `size` bytes at `nursery_base`, throwing `std::bad_alloc` if the commit fails.
    void commitNursery(char *nursery_base, size_t size);

    // ========== Internal Pointer Conversion ==========

    // Returns the address `ptr` holds, without following a forward header. `ptr` must not be an embedded
    // constant (asserted).
    static inline void* fromPointerRaw(HPointer ptr) {
        assert(ptr.ptr_ind == 0 && "Cannot convert an embedded constant HPointer to a pointer");
        // The word IS the raw absolute address (no heap_base, no shift): the ptr
        // field sits at bit 3, and constant/ptr_ind/null_cons_idx/padding are 0 for a
        // pointer, so masking the low 43 bits yields the 8-byte-aligned address.
        return hpToAddr(ptr);
    }

    // Returns the HPointer for the address `obj`, which must be 8-byte aligned and below 2^43 (both
    // asserted). Nothing checks that it is in the heap.
    static inline HPointer toPointerRaw(void* obj) {
        // A heap object is 8-byte aligned and lives below 2^43, so its address
        // maps directly onto the word: the low 3 bits (0) become constant/ptr_ind
        // (marking it a pointer), the address bits [3,43) become the ptr field,
        // and null_cons_idx/padding are 0. Reinterpreting the address as the word is
        // therefore the exact HPointer for it.
        uintptr_t addr = reinterpret_cast<uintptr_t>(obj);
        assert((addr & 0x7ULL) == 0 && "heap object must be 8-byte aligned");
        assert(addr < (1ULL << (POINTER_BITS + 3)) && "heap address exceeds HPointer range");
        return hpFromBits(static_cast<u64>(addr));
    }

    friend class NurserySpace;
    friend class OldGenSpace;
    friend class ThreadLocalHeap;
    friend class AllocatorTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

/**
 * Access for tests to the allocator's private calls and state. Each function forwards to the `Allocator`
 * member of the same or a similar name, with the same contract.
 */
class AllocatorTestAccess {
public:
    // Returns the address `ptr` holds, as `Allocator::fromPointerRaw` does.
    static void* fromPointer(HPointer ptr) {
        return Allocator::fromPointerRaw(ptr);
    }

    // Returns the HPointer for `obj`, as `Allocator::toPointerRaw` does.
    static HPointer toPointer(void* obj) {
        return Allocator::toPointerRaw(obj);
    }

    // Resets `alloc`, with `new_config` if it is not null, as `Allocator::reset` describes.
    static void reset(Allocator& alloc, const HeapConfig* new_config = nullptr) {
        alloc.reset(new_config);
    }

    // Returns the calling thread's nursery, or null if the thread has no heap.
    static NurserySpace* getNursery(Allocator& alloc);

    // Returns the calling thread's old generation, or null if the thread has no heap.
    static OldGenSpace* getOldGen(Allocator& alloc);

    // Returns the calling thread's heap, or null if it has none.
    static ThreadLocalHeap* getThreadHeap(Allocator& alloc) {
        return alloc.getThreadHeap();
    }

    // Returns whether a helper-job wait on this thread would be charged as inside a pause.
    static bool callerInPause(const Allocator& alloc) { return alloc.callerInPause(); }

    // Grows `space` toward `bytes` of capacity, as `Allocator::ensureOldGenCapacityFor` does. With
    // `SIZE_MAX` it takes blocks until acquisition fails, which spends the old-generation range.
    static void ensureOldGenCapacityFor(Allocator& alloc, OldGenSpace& space, size_t bytes) {
        alloc.ensureOldGenCapacityFor(space, bytes);
    }

    // Acquires `n` old-generation bytes with waiting allowed, as `Allocator::acquireOldGenBlock` does.
    static char* acquireOldGenBlock(Allocator& a, size_t n) { return a.acquireOldGenBlock(n); }
    // Releases the `n` bytes at `p`, as `Allocator::releaseOldGenBlock` does.
    static void releaseOldGenBlock(Allocator& a, char* p, size_t n) { a.releaseOldGenBlock(p, n); }
    // Returns the released old-generation extents. Reads them without the lock, so call it only while no
    // other thread can acquire or release; the reference is valid until `a` is destroyed.
    static const std::vector<std::pair<char*, size_t>>& freeBlocks(const Allocator& a) {
        return a.old_gen_free_blocks_;
    }
    // Returns whether a thread other than the caller holds `thread_mutex_`. The answer may be out of date
    // by the time it is returned.
    static bool threadMutexHeldElsewhere(Allocator& a) {
        if (!a.thread_mutex_.try_lock()) return true;
        a.thread_mutex_.unlock();
        return false;
    }
    // Makes `h` the calling thread's heap without registering the thread as a mutator, for a test in a
    // forked child whose only thread takes over a heap whose mutator stayed in the parent.
    //
    // This is outside the one-mutator rule, and sound only if that mutator was outside any pause and any
    // root-set update at the fork. In `ECO_HEAP_VALIDATE` builds the calling thread also becomes `h`'s
    // owner. `h` may be null, which leaves the thread with no heap.
    static void adoptThreadHeap(Allocator&, ThreadLocalHeap* h);

    // Claims a region slot, as `Allocator::acquireNurserySliceSet` does.
    static NurserySliceSet acquireSliceSet(Allocator& a, size_t initial) { return a.acquireNurserySliceSet(initial); }
    // Grows `s` by `d`, as `Allocator::growNurserySliceSet` does.
    static bool growSliceSet(Allocator& a, NurserySliceSet& s, size_t d) { return a.growNurserySliceSet(s, d); }
    // Frees `s`'s slot, as `Allocator::releaseNurserySliceSet` does.
    static void releaseSliceSet(Allocator& a, const NurserySliceSet& s) { a.releaseNurserySliceSet(s); }
    // Returns the number of region slots.
    static size_t regionSlotCount(Allocator& a) { return a.getRegionSlotCount(); }
    // Returns the slice size, as `Allocator::getNurserySliceBytes` does.
    static size_t sliceBytes(Allocator& a) { return a.getNurserySliceBytes(); }
    // Returns the number of slots in the slice-pair table.
    static size_t sliceSlotCount(Allocator& a) { return a.getNurserySliceSlotCount(); }
    // Returns the size of the nursery region, which the first `initialize` fixed.
    static size_t liveNurseryRegionBytes(Allocator& a) { return a.heap_reserved - a.nursery_offset; }
    // Returns the size of the old-generation range, which the first `initialize` fixed.
    static size_t oldGenReservationBytes(Allocator& a) { return a.nursery_offset; }

    // Returns the start of the reservation.
    static char* getHeapBase(Allocator& alloc) {
        return alloc.getHeapBase();
    }
};

} // namespace Elm

// The inline definitions below need `ThreadLocalHeap` complete, so they follow its header.
#include "ThreadLocalHeap.hpp"

namespace Elm {

inline RootSet &Allocator::getRootSet() noexcept {
    return tl_heap_->getRootSet();
}

inline bool Allocator::isInNursery(void *ptr) {
    return tl_heap_ && tl_heap_->isInNursery(ptr);
}

inline void AllocatorTestAccess::adoptThreadHeap(Allocator&, ThreadLocalHeap* h) {
    Allocator::setThreadHeap(h);
#if ECO_HEAP_VALIDATE
    if (h != nullptr) h->owner_ = std::this_thread::get_id();
#endif
}

} // namespace Elm

#endif // ECO_ALLOCATOR_H
