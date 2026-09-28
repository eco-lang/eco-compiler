#ifndef ECO_THREAD_LOCAL_HEAP_H
#define ECO_THREAD_LOCAL_HEAP_H

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <unordered_set>
#include "AllocatorCommon.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "StackMapRoots.hpp"
#include "GCStats.hpp"

namespace Elm {

class Allocator;

// Initializes a freshly-allocated object header for the given tag, applying
// the per-tag rule for hdr->size (variable-size types store an element
// count; fixed-size types store the byte size). Used by the slow path
// inside ThreadLocalHeap::allocate and by the generic
// eco_alloc_with_roots fast-path init in RuntimeExports.cpp.
void initHeaderForTag(Header* hdr, Tag tag, size_t size);

/// Zero a freshly allocated object. HEADER ONLY — the payload is left as
/// whatever the previous occupant of those bytes wrote.
///
/// That is safe because no collector loop ever reads a payload word the
/// mutator has not written (plans/nursery-per-site-zeroing.md):
///   - every fixed-shape class stores all of its fields via straight-line
///     code with no intervening safepoint (HEAP_034);
///   - the one variable class, Closure, is traced to `n_values`, not to its
///     capacity, and every writer of a value slot maintains
///     "slots below n_values are written".
///
/// The history is worth keeping, because two layers of zeroing were removed
/// and each looked load-bearing until it was measured:
///   1. `NurserySpace::clearToSpaceFreeRegion` memset the WHOLE semi-space
///      every minor GC (~246 GB per self-compile). Retired -> -14.54 s GC.
///   2. Per-site payload zeroing replaced it (inline codegen + 10 runtime
///      sites). Retired once the closure scan was bounded on n_values, which
///      is what made the over-scan — and therefore the zeroing — necessary.
///
/// ECO_PERSITE_ZERO=1 restores full-object zeroing in VALIDATOR builds only,
/// as the bisection switch if a missed write ever surfaces. Release builds
/// compile to an unconditional 8-byte memset with no branch.
inline void zeroNewObject(Header* hdr, size_t size) {
#if ECO_HEAP_VALIDATE
    static const bool full = []{
        const char* e = std::getenv("ECO_PERSITE_ZERO");
        return e != nullptr && e[0] == '1';
    }();
    if (full) { std::memset(hdr, 0, size); return; }
#endif
    (void)size;
    std::memset(hdr, 0, sizeof(Header));
}

/**
 * Thread-local heap space containing nursery, old gen, and GC stats.
 *
 * Each thread owns its own ThreadLocalHeap instance, allowing completely
 * independent garbage collection without any synchronization between threads.
 *
 * Memory regions are allocated from the global Allocator's unified address
 * space, but once assigned to a thread, they are owned exclusively by that
 * thread's ThreadLocalHeap.
 */
class ThreadLocalHeap {
public:
    /**
     * Constructs a thread-local heap with the given memory regions.
     *
     * @param parent       Parent allocator (for heap base access)
     * @param nursery_base Base address of nursery region
     * @param nursery_size Total size of nursery (split into from/to spaces)
     * @param old_gen_base Base address of old generation region
     * @param old_gen_initial_size Initial committed size for old gen
     * @param old_gen_max_size Maximum size old gen can grow to
     * @param config       Heap configuration parameters
     */
    ThreadLocalHeap(Allocator* parent,
                    char* nursery_base, size_t nursery_size,
                    char* old_gen_base, size_t old_gen_initial_size, size_t old_gen_max_size,
                    const HeapConfig* config);

    ~ThreadLocalHeap();

    // Non-copyable, non-movable (owns memory regions)
    ThreadLocalHeap(const ThreadLocalHeap&) = delete;
    ThreadLocalHeap& operator=(const ThreadLocalHeap&) = delete;
    ThreadLocalHeap(ThreadLocalHeap&&) = delete;
    ThreadLocalHeap& operator=(ThreadLocalHeap&&) = delete;

    // ========== Allocation ==========

    /**
     * Allocates an object in the nursery.
     * May trigger minor GC if nursery usage exceeds threshold.
     */
    void* allocate(size_t size, Tag tag);

    /**
     * Fast-path allocation: bump-pointer only, no GC.
     * Returns nullptr if nursery has insufficient space.
     * Caller is responsible for header initialization.
     */
    void* allocateFast(size_t size);

    /**
     * Slow-path allocation: may trigger GC, always succeeds or aborts.
     * Called when allocateFast returns nullptr.
     */
    void* allocateSlow(size_t size, Tag tag);

    /**
     * Slow path for the compiled-code inline nursery bump (HEAP_034):
     * minor GC + retry, NO header init (the caller stores the full header
     * word before its next safepoint). Size must be below the large-object
     * threshold. Always succeeds or aborts.
     */
    void* allocateSlowRaw(size_t size);

    /**
     * Capacity guarantee for a hoisted allocation check (HEAP_041,
     * plans/capacity-check-hoisting.md): establishes
     * `bump.end - bump.ptr >= n` for this thread WITHOUT allocating, so a
     * covered straight-line run can perform unchecked bumps totalling <= n.
     * Advances blocks on genuine exhaustion, then minor-GCs, then fail-soft
     * unclamps; aborts if still unsatisfiable. n must be 8-aligned, in
     * (0, 4096].
     */
    void ensureNursery(size_t n);

    /**
     * Slow-path region allocation: allocates a contiguous region of total bytes.
     * May trigger GC. Returns raw pointer to start of region.
     * Caller slices into per-object chunks and initializes headers inline.
     */
    void* allocateRegionSlow(size_t total);

    /**
     * Allocates an object directly in old generation (bypasses nursery).
     * Use for permanent objects like string literals.
     */
    void* allocatePermanent(size_t size, Tag tag);

    /**
     * Allocates a large string via the split-header path (HEAP_026): the
     * body (Tag_String, length UTF-16 chars) lives pinned in old gen, and
     * a small Tag_LargeStringHeader header lives in the nursery. Returns
     * the header's HPointer. Used internally by alloc::allocString when
     * the requested size meets or exceeds large_object_threshold.
     */
    HPointer allocLargeString(const u16* chars, size_t length);

    /**
     * Allocates a large byte buffer via the split-header path (HEAP_026):
     * the body (Tag_ByteBuffer) lives pinned in old gen and a small
     * Tag_LargeByteHeader header lives in the nursery. If `data` is
     * nullptr the body is zero-initialized.
     */
    HPointer allocLargeByteBuffer(const u8* data, size_t length);

private:
    /**
     * Allocates an object directly in old gen, bypassing the nursery, and
     * marks its header pinned (Header.pin = 1) so the old-gen compactor
     * leaves it in place. Used for objects whose aligned size meets or
     * exceeds config_->large_object_threshold.
     */
    void* allocateLargePinned(size_t size, Tag tag);

    // threaded-gc-04b: a large pointer-bearing object in the young
    // large-object space (the Ylos placement, and the fallback when a
    // Nursery-placed one does not fit after a minor).
    void* allocateYoungLarge(size_t size, Tag tag);

    // A large closure-group region that cannot fit the nursery: fatal.
    [[noreturn]] void regionTooLarge(size_t total);

public:

    // ========== Garbage Collection ==========

    /** Triggers a minor GC on the nursery. */
    void minorGC();

    /** Triggers a major GC (mark-sweep on old gen). */
    // `reason` is recorded in the GCStats per-major event log only; it does
    // not affect collection behaviour. Defaulted so the explicit/forced
    // callers (eco_entry teardown, RuntimeExports, main.cpp, Allocator) need
    // no change and land in the log as `forced`.
    void majorGC(GCStats::MajorReason reason = GCStats::MajorReason::Forced);

    // ========== Accessors ==========

    // threaded-gc-04b (plans/threaded-gc-04b-young-large-objects.md P§3.1):
    // where a large (>= large_object_threshold) allocation goes.
    enum class LargePlacement : uint8_t { Nursery, Ylos, Region, PointerFree };
    // Counts (stats builds) and traces (validate builds, ECO_LARGE_PTR_TRACE=1)
    // one large allocation.
    void noteLargeAlloc(LargePlacement where, size_t size, uint32_t tag);

    // The placement policy (P§3.1) for a large allocation: PointerFree for a
    // tag that cannot hold pointers (old gen, pinned), else Nursery when
    // size <= min(nursery_capacity / divisor, max size) and Ylos otherwise.
    // Pure, so tests can pass any nursery capacity.
    // threaded-gc-07 (P§3.13): `region_cap` is the region nursery's cap (the
    // largest old-gen size class); SIZE_MAX in legacy mode.
    static LargePlacement placeLargeFor(size_t size, uint32_t tag,
                                        size_t nursery_capacity,
                                        const HeapConfig& cfg,
                                        size_t region_cap = SIZE_MAX) {
        if (!tagMayHoldPointers(tag)) return LargePlacement::PointerFree;
        if (cfg.large_ptr_nursery_divisor == 0) return LargePlacement::Ylos;
        size_t cap = nursery_capacity / cfg.large_ptr_nursery_divisor;
        if (cfg.large_ptr_nursery_max_size != 0)
            cap = std::min(cap, cfg.large_ptr_nursery_max_size);
        cap = std::min(cap, region_cap);
        return size <= cap ? LargePlacement::Nursery : LargePlacement::Ylos;
    }
    LargePlacement placeLarge(size_t size, uint32_t tag) const {
        return placeLargeFor(size, tag, nursery_.capacityBytes(), *config_,
                             nursery_.regionLargeCap());
    }

    /** threaded-gc-05a: true while an incremental mark cycle runs (HEAP_063). */
    bool markCycleActive() const { return old_gen_.cycleActive(); }
    // Negative-control hooks (P§3.13; tests only): the t0 snapshot skips the
    // young walk / the external root scanners.
    bool test_snapshot_skip_young_walk_ = false;
    bool test_snapshot_skip_external_ = false;
    // Tests only: the next minor end behaves as if a major trigger fired
    // (starts a cycle with incremental_mark, else a STW major).
    bool test_force_major_trigger_ = false;

    /** threaded-gc-03: true while a minor/major GC of this heap is running. */
    bool inPause() const { return pause_depth_ > 0; }

    /** Returns the root set for this thread. */
    RootSet& getRootSet() { return nursery_.getRootSet(); }

    /** Returns the stackmap roots (GC-internal only). */
    StackMapRoots& getStackMapRoots() { return stack_map_roots_; }
    const StackMapRoots& getStackMapRoots() const { return stack_map_roots_; }

    /** Returns the nursery space. */
    NurserySpace& getNursery() { return nursery_; }

    /** Returns the old generation space. */
    OldGenSpace& getOldGen() { return old_gen_; }

    /** Returns the parent allocator. */
    Allocator* getParent() { return parent_; }

    /** Returns the heap configuration. */
    const HeapConfig* getConfig() const { return config_; }

    // ========== Diagnostics ==========

    /** Fast-path check: should GC run at this safepoint? */
    bool shouldCollectAtSafepoint() const;

    /** Slow-path: perform collection at safepoint. */
    void collectAtSafepoint();

    /** Returns true if the nursery is over the given threshold. */
    bool isNurseryNearFull(float threshold) const;

    /** Returns true if the pointer is in this thread's nursery. */
    bool isInNursery(void* ptr) const { return nursery_.contains(ptr); }

    /** Returns true if the pointer is in this thread's old gen. */
    bool isInOldGen(void* ptr) const { return old_gen_.contains(ptr); }

    /** Returns current bytes allocated in old gen. */
    size_t getOldGenAllocatedBytes() const { return old_gen_.getAllocatedBytes(); }

#if ECO_HEAP_VALIDATE
    /** Stale-pointer tripwire: aborts if `ptr` is in the nursery but not in
     *  any allocated region (i.e. points at post-swap to-space-free).
     *  Compiled in only under ECO_HEAP_VALIDATE. */
    void debugAssertValidNurseryPointer(void* ptr) {
        nursery_.debugAssertValidNurseryPointer(ptr);
    }
#endif

#if ENABLE_GC_STATS
    /** Returns GC statistics for this thread. */
    GCStats& getStats() { return stats_; }
    const GCStats& getStats() const { return stats_; }
#endif

private:
    Allocator* parent_;           // Parent allocator (for heap base, pointer conversion)
    const HeapConfig* config_;    // Heap configuration
    NurserySpace nursery_;        // Thread-local nursery
    OldGenSpace old_gen_;         // Thread-local old generation
    StackMapRoots stack_map_roots_; // Stackmap-derived roots (GC-internal)
    bool force_gc_ = false;       // Force GC at next safepoint (for test harness/debugger)
    // threaded-gc-03 (P§3.5): depth of nested minorGC/majorGC calls, always
    // on. The outermost exit is the helper sync point (Allocator::onGCPauseEnd).
    int pause_depth_ = 0;
    bool pause_had_major_ = false;   // a major ran in the current pause

    // threaded-gc-05a: the incremental mark cycle driver (HEAP_063).
    template <typename F> void forEachMajorRoot(RootSet& root_set, F&& f);
    // threaded-gc-05b: trigger majors run as cycles when marking is
    // incremental, or parallel (T = 0 then).
    bool useMarkCycle() const {
        return config_->incremental_mark || old_gen_.markThreads() > 1;
    }
    void startMarkCycle(GCStats::MajorReason reason);
    void stepMarkCycle();
    void finishMarkCycleNow(OldGenSpace::CycleFinish why);
    void completeMarkCycle(OldGenSpace::CycleFinish why);
    void notePauseCycleWork(int what);   // 0 t0, 1 slice, 2 handoff
    uint64_t cycle_t0_wall_ns_ = 0;
    uint64_t cycle_mark_ns_ = 0;
    uint64_t cycle_inpause_ns_ = 0;
#if ECO_HEAP_VALIDATE
    std::vector<void*> traceOldReachableForValidation(bool* complete);
#endif
    friend struct PauseEndHook;

#if ENABLE_GC_STATS
    GCStats stats_;               // Thread-local GC statistics

#if ENABLE_GC_PHASE_TIMERS
    // threaded-gc-00 pause bracket: depth of nested minorGC/majorGC calls,
    // start of the outermost one, and what it contained.
    int      gc_depth_ = 0;
    uint64_t pause_start_ns_ = 0;
    bool     pause_saw_minor_ = false;
    bool     pause_saw_major_ = false;
    bool     pause_saw_t0_ = false;       // threaded-gc-05a pause kinds 3/4/5
    bool     pause_saw_slice_ = false;
    bool     pause_saw_handoff_ = false;
    uint64_t pause_cpu_start_ns_ = 0;     // threaded-gc-05c: mutator CPU split
    friend struct GCPauseScope;

    /** Records one completed pause (outermost GC call). */
    void recordPause(uint64_t start_ns, uint64_t dur_ns, uint8_t kind);

    /** Records one minor GC's phase measurements into stats_ and the log. */
    void recordMinorPhases(MinorGCRecord& rec);
#endif
#endif

    /** Collects all roots from this thread's root set. */
    // Returns a reference into the RootSet, which outlives the call. Returning
    // by value copied the whole bucket array plus a node per root, once per
    // major GC (W0 item 39).
    const std::unordered_set<HPointer*>& collectRoots();

    /** Populate RootSet stack roots from __LLVM_StackMaps by walking
     *  the current thread's call stack frames. */
    struct StackWalkCounts {
        uint64_t frames_walked = 0;
        uint64_t frames_matched = 0;
        uint64_t slots = 0;
    };
    StackWalkCounts collectStackRootsFromStackMap();
};

} // namespace Elm

#endif // ECO_THREAD_LOCAL_HEAP_H
