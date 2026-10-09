#ifndef ECO_ALLOCATOR_H
#define ECO_ALLOCATOR_H

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

/**
 * Central allocator managing thread-local heaps.
 *
 * Singleton that owns the unified heap address space. Each thread gets its own
 * ThreadLocalHeap with independent nursery, old gen, and GC stats.
 *
 * Memory layout (HEAP_043; the split is configurable via
 * HeapConfig::nursery_region_bytes, 4 GiB of 24 GiB by default):
 *   [0 .. nursery_offset)       - Old generation region (carved up per-thread)
 *   [nursery_offset .. end)     - Nursery region: two halves, each carved into
 *                                 fixed-size slices, one pair per heap
 *
 * Thread safety:
 *   - initThread() acquires mutex to allocate regions
 *   - allocate(), minorGC(), majorGC() are lock-free (use thread-local heap)
 *   - getCombinedStats() acquires mutex to iterate all thread heaps
 */
class Allocator;
// Namespace-scope storage for the singleton. Defined in Allocator.cpp.
// Used directly by the inline `Allocator::instance()` accessor below to avoid
// the magic-static guard-variable load + function call that previously cost
// ~5% of CPU on the Stage 7 self-compile.
extern Allocator g_allocator_storage;

class Allocator {
public:
    // Returns the singleton Allocator instance.
    // Trivially default-constructed; real initialization happens in
    // `initialize()` which must be called before any allocation.
    static inline Allocator &instance() noexcept {
        return g_allocator_storage;
    }

    // ========== Safe Public Pointer API ==========

    // Resolves an HPointer to its physical address.
    // Follows forwarding pointers to the final evacuated location if present.
    // Returns nullptr for embedded constants (Nil, True, False, Unit, etc.).
    // Asserts on invalid pointers or corrupted memory.
    void* resolve(HPointer ptr);

    // Inline fast-path resolve for hot kernel dereferences (plan D9). Under
    // HEAP_028 the word IS the address, so the common (no-forwarding) case is a
    // pure reinterpret; only when the target header is Tag_Forward — the rare
    // old-gen compaction window — do we fall to the out-of-line resolve() loop.
    // Header-defined so it actually inlines into kernel callers (unlike the
    // out-of-line resolve(), which is a separate TU with no LTO). Caller must
    // have already excluded embedded constants (ptr_ind == 0).
    static inline void* resolveFast(HPointer ptr) {
        void* obj = fromPointerRaw(ptr);
        if (__builtin_expect(getHeader(obj)->tag == Tag_Forward, 0))
            return Allocator::instance().resolve(ptr);
        return obj;
    }

    // Wraps a physical address as an HPointer.
    // Converts raw pointer returned by allocate() into a storable logical pointer.
    HPointer wrap(void* obj);

    // ========== Lifecycle ==========

    // Initializes the allocator with the given configuration.
    // Validates config parameters and throws std::invalid_argument on failure.
    // Must be called before any thread calls initThread().
    void initialize(const HeapConfig& config = HeapConfig());
    // The production configuration for `base`: $ECO_HEAP_CONFIG, then the
    // ECO_GC_* / ECO_NURSERY_* variables, resolved and validated (throws on an
    // invalid one). initialize() uses it; so does EcoRunner::reset().
    static HeapConfig environmentConfig(const HeapConfig& base, uint32_t& helper_jitter_us);

    // Returns the heap configuration. Read-only.
    const HeapConfig& getConfig() const { return config_; }

    // Initializes the calling thread's heap space.
    // Creates a ThreadLocalHeap with dedicated nursery and old gen regions.
    // Thread-safe: acquires mutex to carve out regions from the unified heap.
    // HEAP_007 / CR-012 (option F): at most one live ThreadLocalHeap per
    // process; a second live mutator aborts in initThread. Sequential
    // mutators (one cleans up, then the next initThread) stay legal.
    void initThread();

    // CR-012: lets initThread create a second live ThreadLocalHeap. For the
    // benchmark driver (main.cpp --threads) and test harnesses ONLY:
    // UNSUPPORTED (process-wide committed bytes, decommit clocks and the
    // released-extent list are shared, so per-heap GC_DET_001 does not hold).
    // Reset to false by reset().
    void allowMultipleMutators(bool on) {
        std::lock_guard<std::recursive_mutex> l(thread_mutex_);
        multi_mutator_opt_in_ = on;
    }

    // Cleans up the calling thread's heap space.
    // Should be called before the thread exits.
    void cleanupThread();
    // threaded-gc-07: stats-only merge of the calling thread's last tenure job (exit).
    void finishTenureForExit();

    // ========== Allocation ==========

    // Allocates an object in the thread-local nursery.
    // Delegates to the calling thread's ThreadLocalHeap.
    void *allocate(size_t size, Tag tag);

    // Fast-path allocation: bump-pointer only, no GC, no header init.
    // Returns nullptr if nursery has insufficient space.
    void *allocateFast(size_t size);

    // Slow-path allocation: may trigger GC, always succeeds or aborts.
    void *allocateSlow(size_t size, Tag tag);

    // Slow path for the compiled-code inline nursery bump (HEAP_034):
    // minor GC + retry, NO header init. See ThreadLocalHeap::allocateSlowRaw.
    void *allocateSlowRaw(size_t size);

    // Address of the calling thread's nursery bump state {ptr, end} —
    // consumed by eco_bump_state() for the compiled-code inline allocation
    // fast path (HEAP_034). Address-stable for the thread's lifetime
    // (NurserySpace is a by-value member of the heap-allocated
    // ThreadLocalHeap).
    void *bumpState();

    // Capacity guarantee for a hoisted allocation check (HEAP_041): makes
    // `bump.end - bump.ptr >= n` true without allocating. May GC.
    // See ThreadLocalHeap::ensureNursery.
    void ensureNursery(size_t n);

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

    // Returns the configured large-object threshold in bytes. Allocations
    // whose total payload size meets or exceeds this either bypass the
    // nursery (generic LOT path) or, for Tag_String / Tag_ByteBuffer, route
    // through the split-header path.
    size_t getLargeObjectThreshold() const {
        return config_.large_object_threshold;
    }

    // Monotonically increasing counter bumped on every initialize()/reset().
    // Consumers that cache heap pointers across the process lifetime (e.g. the
    // string-literal interning table) compare it to detect a heap reset — which
    // destroys all thread heaps and RootSets — and drop their now-stale caches.
    // The shipped AOT runtime bumps this exactly once (at startup); only the
    // test harness resets, so this is effectively free in production.
    uint64_t heapGeneration() const { return heap_generation_; }

    // Returns the calling thread's ThreadLocalHeap (or nullptr if the
    // thread isn't initialized). Public form of the internal accessor; used
    // by the GC_STATS_TLH_RECORD_ALLOC helper to find the current thread's
    // GCStats from a free function context. Inline because it's just a
    // thread-local read.
    ThreadLocalHeap* getCurrentThreadHeap() const noexcept { return tl_heap_; }

    // ========== GC helper threads (threaded-gc-03) ==========

    // The helper sync point: called by ThreadLocalHeap at the end of the
    // OUTERMOST minor/major pause (P§3.5). A no-op in gc_thread_mode 0.
    void onGCPauseEnd(ThreadLocalHeap& heap, bool had_major);

    // Waits for every posted helper job (the atexit stats path; NOT the
    // signal path). A no-op in mode 0.
    void drainHelperWork();

    // threaded-gc-04: the calling thread's current nursery per-side capacity
    // (0 without a heap). Bounds builder-built chunk chains (HEAP_SNAPSHOT_001
    // S1): builders stay in the nursery until finished.
    size_t nurseryCapacityBytes() const;

    // Test/validation access to the page-work state (nullptr in mode 0).
    gc::PageWork* pageWork() const { return page_work_.get(); }

    // Test hook: observes every range this allocator maps RW for the old gen
    // (bump commits and commit-ahead windows). nullptr in production.
    static void (*commit_observer_for_testing)(char* p, size_t n);

    // ========== Garbage Collection ==========

    // Triggers a minor GC on the thread-local nursery.
    void minorGC();

    // Triggers a major GC on the thread-local old gen.
    void majorGC();

    // ========== Explicit collections (plans/frontend-heap-release.md §3.5, HEAP_076) ==========
    // Called only from a kernel Task binding (Eco.GC) or a test, on the
    // owning mutator, outside any GC pause (fatal otherwise). Each returns a
    // GCReport whose rss_*, *_ns and trim_result are observations only.

    // A full release: ThreadLocalHeap::majorGCAndShrink (one pause, one sync
    // point: STW major, sweep to Idle, forced shrink), then under
    // thread_mutex_ only PageWork::drainAll(true) (every Pending extent
    // discarded now; mode 0 already discarded inline; nothing with decommit
    // off), then malloc_trim(0) on glibc.
    GCReport collectMajorAndRelease();

    // A minor GC (it may chain into a major; majors_run reports it), with the
    // same before/after snapshots. No sweep, shrink, discard or trim.
    GCReport collectMinor();

    // ========== Root Management ==========

    // Returns the thread-local root set. The slow form lazily initializes the
    // calling thread's heap if it has not been set up yet — used by external
    // callers (Scheduler, PlatformRuntime) that may run before `initThread()`.
    // The hot path goes through `getRootSet()` below, which is inlined.
    RootSet &getRootSetSlow();

    // Hot-path inline accessor. By the time runtime helpers call this
    // (eco_gc_push_stack_range etc.), the calling thread has long since been
    // initialized, so the null check would always fall through. Skipping it
    // here eliminates the function call to `getRootSetSlow()` plus its
    // null-check branch on the runtime hot path. Callers that may run
    // pre-initThread should use `getRootSetSlow()`.
    inline RootSet &getRootSet() noexcept;

    // ========== Diagnostics ==========

    // Fast-path check: should GC run at this safepoint?
    bool shouldCollectAtSafepoint();

    // Slow-path: perform collection at safepoint.
    void collectAtSafepoint();

    // Returns true if the thread-local nursery is over the threshold.
    bool isNurseryNearFull(float threshold);

    // Returns true if the pointer is in the calling thread's nursery.
    // Defined inline at the bottom of this header (needs the complete
    // ThreadLocalHeap) — item 51: it runs twice per marked object from
    // OldGenSpace's pushMarkRoot/markOneObject, and a cross-TU call with
    // no LTO was the whole cost.
    bool isInNursery(void *ptr);

    // Returns true if the pointer is in the calling thread's old gen.
    bool isInOldGen(void *ptr);

    // Returns true if the pointer is anywhere in the unified heap (any thread).
    // O(1) bounds check using base and reserved size.
    bool isInHeap(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return p >= heap_base && p < heap_base + heap_reserved;
    }

    // Stale-pointer barrier safe for arbitrary 64-bit values (e.g. an
    // unboxed Int reinterpreted as an HPointer). Never dereferences:
    // decodes to a physical address via heap_base + (ptr<<3), bounds-
    // checks against the nursery, and only then runs the always-on
    // free-region tripwire. Returns silently for embedded constants,
    // null pointers, and any address outside the nursery.
    void validateInNurserySafe(HPointer hp);

    // Returns the current number of bytes allocated in thread-local old gen.
    size_t getOldGenAllocatedBytes() const;

    // Returns committed bytes in the shared old-gen region (all threads).
    // CR-012 hardening: a relaxed atomic, so an opted-in second mutator's
    // unlocked trigger read is not a data race (the value is still shared).
    size_t getOldGenCommittedBytes() const { return old_gen_in_use_bytes_.load(std::memory_order_relaxed); }
    // threaded-gc-05b: ECO_GC_HELPER_JITTER_US, also the mark gang's probe.
    uint32_t helperJitterUs() const { return helper_jitter_us_; }

    // C0 census (TEMPORARY, plans/contiguous-nursery-space.md §3.3). Two
    // DIFFERENT old-gen walls: the peak of the in-use figure above (the
    // GlobalPressure trigger's numerator, which releases decrement) and the
    // monotonic commit bump that acquireOldGenBlock tests against
    // nursery_offset (the hard alloc-failure wall). The M2 default-split
    // decision reads both.
    size_t getOldGenInUsePeakBytes() const { return old_gen_in_use_peak_; }
    size_t getOldGenCommitHighWaterBytes() const { return old_gen_committed; }

    // Returns committed bytes in the low / high nursery regions.
    size_t getNurseryLowCommittedBytes() const { return nursery_low_committed_; }
    size_t getNurseryHighCommittedBytes() const { return nursery_high_committed_; }

    // The old-gen address-space cap: where the nursery region begins
    // (HEAP_043). THE single source of truth — every consumer (the
    // GlobalPressure major-GC trigger, the post-major grow clamp, the
    // sweep-pressure ratio) must route through here rather than re-deriving
    // a cap from the config.
    //
    // min() with the config-derived cap so a reset() that shrinks
    // max_heap_size scales the cap down with it: the RESERVATION is
    // first-init-wins (nursery_offset never moves), but a test suite that
    // reconfigures to an 8 MiB heap expects its pressure ratios measured
    // against 8 MiB, not against the 24 GiB the process happened to reserve
    // first.
    size_t getOldGenMaxBytes() const {
        const size_t config_cap = config_.oldGenCapBytes();
        return config_cap < nursery_offset ? config_cap : nursery_offset;
    }

    // Diagnostics: dumps heap state (old-gen + nursery commit counters plus
    // per-thread allocated_bytes and block counts) to stderr. The body is a
    // compile-time no-op unless the build was configured with the CMake option
    // `-DECO_HEAP_TRACE=ON`; runtime emission is further gated by the
    // `ECO_HEAP_TRACE` env var so default release builds carry no trace cost.
    void dumpHeapState(const char* label, size_t pending_size = 0) const;

    // Returns true when traces are compiled in (CMake `ECO_HEAP_TRACE=ON`) and
    // the `ECO_HEAP_TRACE` env var is set to a non-zero / non-empty value at
    // process start. When the CMake option is OFF this is a compile-time
    // `false` so every `if (heapTraceEnabled())`-guarded block is DCE'd.
    static bool heapTraceEnabled();

#if ENABLE_GC_STATS
    // Returns combined statistics from all thread heaps.
    // Thread-safe: acquires mutex to iterate all thread heaps.
    GCStats getCombinedStats() const;
#endif

    // Default ctor/dtor are public so the namespace-scope `g_allocator_storage`
    // can construct the singleton. The trivial constructor only zero-initializes
    // pointers/counters; real setup runs in `initialize()`. Singleton discipline
    // is enforced by convention — every caller goes through `instance()`.
    Allocator();
    ~Allocator();

private:

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
    // Written only under thread_mutex_ (relaxed load + store), read
    // unlocked by the triggers (CR-012 hardening: relaxed atomic).
    std::atomic<size_t> old_gen_in_use_bytes_;
    void addOldGenInUse(size_t n) {
        old_gen_in_use_bytes_.store(old_gen_in_use_bytes_.load(std::memory_order_relaxed) + n,
                                    std::memory_order_relaxed);
    }
    void subOldGenInUse(size_t n) {
        old_gen_in_use_bytes_.store(old_gen_in_use_bytes_.load(std::memory_order_relaxed) - n,
                                    std::memory_order_relaxed);
    }
    // C0 census (TEMPORARY): running maximum of the field above, sampled at
    // every increment via noteOldGenInUsePeak(). Reset with it.
    size_t old_gen_in_use_peak_;
    size_t nursery_offset;        // Byte offset where the nursery region begins (== old-gen cap).
    size_t nursery_low_committed_;   // Committed bytes in first half of nursery region.
    size_t nursery_high_committed_;  // Committed bytes in second half of nursery region.
    // ---- Nursery slice slots (HEAP_042) ----
    //
    // The nursery region is carved into fixed-size slots; a heap owns the
    // low and high slice at ONE slot index, giving it two contiguous
    // semi-space extents. Geometry is derived from the config by
    // rebuildNurserySliceTable() at initialize()/reset(); the region itself
    // is first-init-wins.
    //
    // `retained_*` is the PHYSICAL high-water commit at the slot, kept
    // across release so a respawned heap reuses committed pages (the former
    // block free-lists' Issue-#40 role). It is tracked per side because a
    // partially-failed grow may raise one side only. It may exceed the
    // current owner's logical capacity — those pages are dormant. Retained
    // records are dropped wholesale by reset(), which also re-derives the
    // geometry: slot bases move when alloc_buffer_size or the block caps
    // change, so a stale record would skip committing pages that were never
    // mapped at the new base.
    struct NurserySliceSlot {
        bool   in_use        = false;
        size_t retained_low  = 0;
        size_t retained_high = 0;
    };
    std::vector<NurserySliceSlot> nursery_slots_;
    size_t nursery_slice_bytes_;     // per-side slice size (0 before init)
    // threaded-gc-07 (HEAP_069): the REGION layout, built instead of the pair
    // table when config_.nursery_regions = 1. A slot is n extents at a
    // power-of-two stride; retained commit is tracked per extent.
    struct NurseryRegionSlot {
        bool   in_use = false;
        size_t retained[8] = {};
    };
    std::vector<NurseryRegionSlot> region_slots_;
    size_t   region_stride_log2_ = 0;
    unsigned region_extents_ = 0;
    size_t   region_growth_bytes_ = 0;   // per-extent ceiling (<= stride)
    // Free list of previously-released old-gen blocks (pages or large blocks)
    // that have been returned by `releaseOldGenBlock`. The virtual mapping is
    // retained; physical RSS may have been dropped via `madvise(MADV_DONTNEED)`.
    // `acquireOldGenBlock` consults this list (first-fit by size) before
    // bumping `old_gen_committed`.
    std::vector<std::pair<char*, size_t>> old_gen_free_blocks_;
    bool initialized;             // True after initialize() has been called.
    // threaded-gc-03: ECO_GC_HELPER_JITTER_US (0 = none), read at initialize().
    uint32_t helper_jitter_us_ = 0;
    // threaded-gc-03: U1/U2 page work (modes 1/2 only; guarded by
    // thread_mutex_), the sync-point epoch, and the page-supply counters
    // (every mode; guarded by thread_mutex_).
    std::unique_ptr<gc::PageWork> page_work_;
    uint64_t sync_epoch_ = 0;
    uint64_t major_epoch_ = 0;       // majors completed (counted at sync points)
    PageSupplyStats page_supply_;
    // (Re)creates page_work_ from config_ (nullptr in mode 0) and configures
    // the helper pool (restarting it if idle and configured differently).
    void rebuildPageWork();
    // True when the calling thread's heap is inside a GC pause, or the caller
    // is a GCMarkGang member running a job (always inside a pause, CR-025).
    // The in_pause value of every helper-job wait (stall accounting only).
    bool callerInPause() const;
#if ECO_HEAP_VALIDATE
    void validatePageWork(const char* where) const;
#endif
    uint64_t heap_generation_ = 0; // Bumped on initialize()/reset(); see heapGeneration().

#if ENABLE_GC_STATS
    // Accumulated statistics from destroyed thread heaps.
    // Preserves stats across test runs when the allocator is reset.
    GCStats accumulated_stats_;
#endif

    // steady_clock anchor stamped at the end of initialize(); read by
    // getCombinedStats() to populate GCStats::wall_time_ns. Zero before
    // initialize() runs.
    uint64_t runtime_start_ns_ = 0;

    // ========== Thread-Local Heaps ==========

    mutable std::recursive_mutex thread_mutex_;  // Protects thread_heaps_ map and region allocation.
    std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> thread_heaps_;
    bool multi_mutator_opt_in_ = false;   // guarded by thread_mutex_; benchmark/test only (CR-012)
    // HEAP_007 / HEAP_075 (plans/threaded-gc-register-fixes.md §7.1): set by GCFork's
    // allocator layer in a forked child. Only heaps whose thread_heaps_ key equals
    // fork_owner_ (the forking thread: fork() keeps its pthread_t, so its
    // std::thread::id) are live in the child; the others are dead (never collected,
    // never torn down: ~Allocator leaks them, CR-031).
    bool fork_child_ = false;
    std::thread::id fork_owner_;
    // GCFork's allocator layer (kForkAllocator): prepare locks thread_mutex_ (after the
    // gangs, before the census and the pool); parent unlocks; child re-creates it in
    // place (never unlock the recursive mutex in the child: its owner TID differs).
    static void forkPrepare();
    static void forkParent();
    static void forkChild();
    void dropForkDeadHeapsLocked();   // CR-031: leak the heaps the forker does not own

    // Thread-local cache for fast access to current thread's heap (avoids map lookup).
    // constinit: guarantees static initialization, so cross-TU accesses skip
    // the C++ TLS dynamic-init guard (_ZTH wrapper + conditional call).
    // tls_model("initial-exec"): forces the call-free %fs-relative access
    // even under -fPIC (EcoRuntimeStatic compiles PIC without PIE, where
    // the default general-dynamic model emits a __tls_get_addr call).
    // Together these keep eco_bump_state's body call-free (Run L,
    // benchmarks/tier2-opt.md). initial-exec is fine for executables and
    // startup-loaded libs; the dlopen'd Node addon consumes one 8-byte
    // slot of glibc's static-TLS surplus.
    static constinit thread_local ThreadLocalHeap* tl_heap_
        __attribute__((tls_model("initial-exec")));

    // Sets `tl_heap_` AND the codegen-visible `eco_tl_bump_state` cache
    // (plans/inline-bump-state-tls.md). The SOLE writer of `tl_heap_` —
    // assign it directly and compiled code keeps bumping a stale nursery.
    static void setThreadHeap(ThreadLocalHeap* h);

    // ========== Internal Methods ==========

    // Returns the calling thread's heap, or nullptr if not initialized.
    ThreadLocalHeap* getThreadHeap() const { return tl_heap_; }

    // Resets the allocator to initial state (clears all heaps and stats).
    // If new_config is provided, reconfigures with new parameters. Used for testing.
    void reset(const HeapConfig* new_config = nullptr);

    // Returns the base address of the unified heap.
    char *getHeapBase() const { return heap_base; }

    // Size of the old-gen address range [heap_base, heap_base +
    // nursery_offset) that every heap's old-gen blocks lie in (HEAP_043).
    // First-init-wins, never changes. Sizes the threaded-gc-01 metadata
    // reservations (HEAP_048/049/050).
    size_t getOldGenReservationBytes() const { return nursery_offset; }

    // Returns the total reserved heap size.
    size_t getHeapReserved() const { return heap_reserved; }

    // C0 census (TEMPORARY): call after every increment of
    // old_gen_in_use_bytes_. Callers already hold thread_mutex_.
    void noteOldGenInUsePeak() {
        const size_t v = old_gen_in_use_bytes_.load(std::memory_order_relaxed);
        if (v > old_gen_in_use_peak_) {
            old_gen_in_use_peak_ = v;
        }
    }

    // ---- Nursery slice API (HEAP_042; replaces the per-block acquire /
    // release / free-list layer). All three are thread-safe. ----

    // Recomputes slice geometry from the CURRENT config against the
    // first-init region and rebuilds the slot table, dropping every
    // retained-commit record (see NurserySliceSlot). Called by initialize()
    // and reset(); must run after config_ and nursery_offset are settled.
    void rebuildNurserySliceTable();

    // Claims a free slot with capacity `initial` (clamped to the slice
    // size) and commits only the bytes not already retained at that slot,
    // on both sides. Aborts loudly if every slot is taken — the message
    // names the knobs that size the geometry. Returns a pair with
    // capacity 0 if the commit itself failed.
    NurserySlicePair acquireNurserySlicePair(size_t initial);

    // Raises the pair's capacity by `delta` on BOTH sides, committing only
    // the portion above the slot's retained commit. Returns false — leaving
    // `pair.capacity` untouched — if the request exceeds the slice or
    // either commit fails; a half-committed grow leaves the extra pages as
    // dormant retained commit, never as a leak.
    bool growNurserySlicePair(NurserySlicePair& pair, size_t delta);

    // Frees the slot for reuse, RETAINING its committed pages.
    void releaseNurserySlicePair(const NurserySlicePair& pair);

    // Per-side slice size for the live geometry (0 before initialize()).
    size_t getNurserySliceBytes() const { return nursery_slice_bytes_; }

    // ---- threaded-gc-07 region slice sets (HEAP_069). Thread-safe. ----
    // Claims a free region slot with every extent at capacity `initial`
    // (clamped to the per-extent ceiling); aborts loudly when every slot is
    // taken. capacity 0 = a commit failed.
    NurserySliceSet acquireNurserySliceSet(size_t initial);
    // Grows EVERY extent by `delta`, or none (capacity untouched on failure).
    bool growNurserySliceSet(NurserySliceSet& set, size_t delta);
    void releaseNurserySliceSet(const NurserySliceSet& set);
    // Region geometry of the live table (0 when the region table is empty).
    size_t getRegionStrideLog2() const { return region_stride_log2_; }
    unsigned getRegionExtents() const { return region_extents_; }
    size_t getRegionGrowthBytes() const { return region_growth_bytes_; }
    size_t getRegionSlotCount() const { return region_slots_.size(); }

    // Number of slice slots per side.
    size_t getNurserySliceSlotCount() const { return nursery_slots_.size(); }

    // Acquires a block of memory from the old gen region.
    // Thread-safe: acquires thread_mutex_.
    // Returns pointer to base of committed block.
    // First scans `old_gen_free_blocks_` for a previously-released block of
    // size >= requested. On hit, optionally `madvise(MADV_WILLNEED)` and
    // re-add the size to `old_gen_committed`. Otherwise bumps the committed
    // pointer, calling `mmap` to materialize the page.
    // CR-007: `w = AvoidUnderPromo` (a promo_mu_ holder with n > 1 workers)
    // selects the no-wait policy (AcquireWait, AllocatorCommon.hpp).
    using AcquireWait = ::Elm::AcquireWait;
    char* acquireOldGenBlock(size_t size, AcquireWait w = AcquireWait::Allowed);

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
        assert(ptr.ptr_ind == 0 && "Cannot convert an embedded constant HPointer to a pointer");
        // The word IS the raw absolute address (no heap_base, no shift): the ptr
        // field sits at bit 3, and constant/ptr_ind/null_cons_idx/padding are 0 for a
        // pointer, so masking the low 43 bits yields the 8-byte-aligned address.
        return hpToAddr(ptr);
    }

    // Converts a physical address to an HPointer without validation.
    // Internal use only - friends can access for performance-critical GC operations.
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

    // CR-025: the pause state a helper-job wait on this thread is charged with.
    static bool callerInPause(const Allocator& alloc) { return alloc.callerInPause(); }

    // CR-029: grows `space`'s bag toward `bytes` of capacity; with SIZE_MAX it
    // takes pages until acquireOldGenBlock refuses (the reservation is spent).
    static void ensureOldGenCapacityFor(Allocator& alloc, OldGenSpace& space, size_t bytes) {
        alloc.ensureOldGenCapacityFor(space, bytes);
    }

    // CR-007 / CR-012: the private block-supply calls (each takes thread_mutex_).
    static char* acquireOldGenBlock(Allocator& a, size_t n) { return a.acquireOldGenBlock(n); }
    static void releaseOldGenBlock(Allocator& a, char* p, size_t n) { a.releaseOldGenBlock(p, n); }
    // CR-007 / CR-012(b): the process-wide released-extent list (read with no mutator running).
    static const std::vector<std::pair<char*, size_t>>& freeBlocks(const Allocator& a) {
        return a.old_gen_free_blocks_;
    }
    // CR-007: true when ANOTHER thread holds thread_mutex_ (recursive: false on the holder).
    static bool threadMutexHeldElsewhere(Allocator& a) {
        if (!a.thread_mutex_.try_lock()) return true;
        a.thread_mutex_.unlock();
        return false;
    }
    // CR-013 (fork harness only): the calling thread, a host-forked child's only
    // thread, runs heap h, whose mutator does not exist in the child. OUTSIDE the
    // fork contract (HEAP_007); sound only when the mutator was parked outside any
    // pause and any RootSet update at the fork.
    // Validate builds: the adopting thread becomes the heap's owner (HEAP_007's check).
    static void adoptThreadHeap(Allocator&, ThreadLocalHeap* h);

    // threaded-gc-07: the region slice set API and geometry.
    static NurserySliceSet acquireSliceSet(Allocator& a, size_t initial) { return a.acquireNurserySliceSet(initial); }
    static bool growSliceSet(Allocator& a, NurserySliceSet& s, size_t d) { return a.growNurserySliceSet(s, d); }
    static void releaseSliceSet(Allocator& a, const NurserySliceSet& s) { a.releaseNurserySliceSet(s); }
    static size_t regionSlotCount(Allocator& a) { return a.getRegionSlotCount(); }
    static size_t sliceBytes(Allocator& a) { return a.getNurserySliceBytes(); }
    static size_t sliceSlotCount(Allocator& a) { return a.getNurserySliceSlotCount(); }
    static size_t liveNurseryRegionBytes(Allocator& a) { return a.heap_reserved - a.nursery_offset; }
    // The old-gen address range (first-init-wins; plans/large-body-gc-trigger.md tests).
    static size_t oldGenReservationBytes(Allocator& a) { return a.nursery_offset; }

    // Heap base address (start of the reserved region) — exposed for tests.
    static char* getHeapBase(Allocator& alloc) {
        return alloc.getHeapBase();
    }
};

} // namespace Elm

// `Allocator::getRootSet()` is defined out-of-line here because the body
// requires the full definition of `ThreadLocalHeap` (for `getRootSet()`),
// which is included after `Allocator.hpp` consumers typically pull in
// `ThreadLocalHeap.hpp`. The accessor compiles to a single TLS load + the
// already-inline `nursery_.getRootSet()` member access — no function call,
// no null check.
#include "ThreadLocalHeap.hpp"

namespace Elm {

inline RootSet &Allocator::getRootSet() noexcept {
    return tl_heap_->getRootSet();
}

// Same reason as getRootSet() above: the body needs `ThreadLocalHeap` to be
// complete. Keep the null check — cold callers run before initThread().
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
