/**
 * NurserySpace Implementation.
 *
 * Contiguous-extent nursery using Cheney's semi-space copying algorithm
 * (HEAP_042, plans/contiguous-nursery-space.md).
 *
 * The nursery is a mirrored pair of contiguous extents carved from two
 * separate address-space regions:
 *   - the low extent:  a slice of the low half of the nursery region
 *   - the high extent: the same-index slice of the high half
 *
 * This split guarantees all low addresses < all high addresses, which makes
 * membership an O(1) range comparison. Both extents always have the same
 * length (one `slice_.capacity`), so the semi-spaces are equal by
 * construction.
 *
 * One extent is the "from-space" (allocation), the other the "to-space"
 * (copy target during GC). After GC, the roles swap.
 *
 * Allocation: one bump pointer against a limit spanning the WHOLE from-space
 * (O(1)). No block advance exists: a miss means the proactive-GC threshold
 * tripped, or the space is exhausted — either way, minor GC.
 *
 * Minor GC algorithm:
 *   1. Evacuate roots into to-space (or promote to old gen if aged).
 *   2. Cheney scan: `scan_ptr_ < copy_ptr_` over one contiguous region.
 *   3. Process promoted objects (they may point back to nursery).
 *   4. Check occupancy and grow if needed (both extents or neither).
 *   5. Swap from/to roles by flipping from_is_low_.
 *
 * Key optimization: Elm's immutability means no old->young pointers exist,
 * so no write barrier or remembered set is needed.
 */

#include "NurserySpace.hpp"
#include "HeapChildWalk.hpp"
#include <sys/resource.h>
#include "RuntimeExports.h"
#include <unordered_map>
#include <mutex>
#include <dlfcn.h>
#include "Allocator.hpp"
#include "PermanentSpace.hpp"
#include "ThreadLocalHeap.hpp"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <atomic>
#include <cstdlib>
#if ECO_HEAP_VALIDATE
// Used by debugAssertValidNurseryPointer's diagnostic (prints a backtrace).
// musl (Stage B static build) ships no <execinfo.h>; stub as no-ops there.
#if defined(__has_include) && __has_include(<execinfo.h>)
#  include <execinfo.h>
#else
[[maybe_unused]] static inline int backtrace(void**, int) { return 0; }
[[maybe_unused]] static inline char** backtrace_symbols(void* const*, int) { return nullptr; }
[[maybe_unused]] static inline void backtrace_symbols_fd(void* const*, int, int) {}
#endif
#endif

#if ECO_HEAP_VALIDATE
// Track which heap object is currently being scanned during Cheney scan,
// so stale-pointer diagnostics can identify the parent object.
// Deliberately thread_local (HEAP_053): it describes what THIS worker is
// scanning, which is the right meaning once several threads scan one heap.
thread_local void* g_scan_parent = nullptr;
thread_local int g_scan_tag = -1;
thread_local Elm::u32 g_scan_size = 0;
#endif

// ---------------------------------------------------------------------------
// Phase-1 per-site-zeroing tripwire (plans/nursery-per-site-zeroing.md gate 4)
// ---------------------------------------------------------------------------
//
// ECO_NURSERY_POISON=1 makes the post-GC free-region fill write 0xD8 bytes
// instead of zeroes. Any payload word an allocation site failed to zero then
// reads back as ECO_POISON_WORD.
//
// 0xD8 is NOT arbitrary. An HPointer's bit 2 is `ptr_ind`, and 0xD8 has that
// bit CLEAR, so a poisoned word is classified as a heap POINTER and is
// followed into evacuate(), where the check below catches it by name. The
// obvious choice, 0xDD, has bit 2 SET: every poisoned word would decode as an
// embedded constant, be skipped, and the tripwire would report nothing
// however broken the zeroing was. That is the trap this gate exists to avoid.
static constexpr uint64_t ECO_POISON_WORD = 0xD8D8D8D8D8D8D8D8ull;

bool nursery_poison_enabled() {
    static const bool on =
        []{ const char* e = std::getenv("ECO_NURSERY_POISON");
            return e != nullptr && e[0] == '1'; }();
    return on;
}

namespace Elm {

NurserySpace::NurserySpace() :
    config_(nullptr), allocator_(nullptr), from_is_low_(true),
    growth_ceiling_bytes_(0),
    low_base_(nullptr), low_end_(nullptr), high_base_(nullptr), high_end_(nullptr),
    bump_{nullptr, nullptr},
    copy_ptr_(nullptr), copy_end_(nullptr), scan_ptr_(nullptr),
    growth_threshold_(NURSERY_GROWTH_THRESHOLD),
    gc_threshold_(0.0f), from_capacity_bytes_(0), threshold_total_bytes_(0),
    thread_heap_(nullptr) {
    // Initialization happens in initialize() method.
}

NurserySpace::~NurserySpace() {
    // Release the slice slot so a subsequent ThreadLocalHeap (e.g. a freshly
    // spawned task) can claim it and reuse its committed pages. Without this,
    // every spawn would consume a slot permanently and the region would
    // exhaust under spawn-heavy workloads (Issue #40). The pages themselves
    // stay committed and are recorded as the slot's retained commit.
    if (allocator_ && slice_.capacity != 0) {
        allocator_->releaseNurserySlicePair(slice_);
    }
    releaseRegions();   // threaded-gc-07: the owner ran tenureTeardown first
}

// Shared body of the two initialize() overloads. `allocator_`, `config_` and
// `thread_heap_` are already set by the caller.
void NurserySpace::initializeFromConfig() {
    growth_threshold_ = config_->nursery_growth_threshold;
    gc_threshold_     = config_->nursery_gc_threshold;

    // The per-heap growth ceiling is the smaller of what the allocator's
    // slice geometry can offer and what this config asks for, so a clamped
    // slice never RAISES a config's cap.
    const size_t config_max_per_side =
        (config_->nursery_max_block_count / 2) * config_->alloc_buffer_size;
    const size_t slice_bytes = allocator_->getNurserySliceBytes();
    growth_ceiling_bytes_ =
        config_max_per_side < slice_bytes ? config_max_per_side : slice_bytes;

    // Initial per-side capacity: half the configured nursery, exactly as the
    // block design's `nursery_block_count / 2` blocks.
    size_t initial = config_->nurseryInitialPerSideBytes();
    if (initial > growth_ceiling_bytes_) initial = growth_ceiling_bytes_;

    if (config_->nursery_regions == 1) {
        // threaded-gc-07 (HEAP_069): the region nursery instead of the pair.
        initRegions();
        return;
    }

    slice_ = allocator_->acquireNurserySlicePair(initial);
    assert(slice_.capacity != 0 && "Failed to acquire nursery slice pair");

    low_base_  = slice_.low_base;
    high_base_ = slice_.high_base;

    // Start with low as from-space.
    from_is_low_ = true;
    updateBounds();
    refreshCapacityCaches();
    bump_.ptr = fromBase();
    filler_bytes_ = filler_bytes_to_ = 0;   // threaded-gc-06: an empty prefix
#if ENABLE_GC_STATS
    // threaded-gc-06 Step 4 gate: ECO_TEST_PROMO_VIA_CTX=1 turns the identity
    // switch on for a whole run (stats builds only; never a shipped setting).
    {
        static const bool via_ctx = [] {
            const char* e = std::getenv("ECO_TEST_PROMO_VIA_CTX");
            return e != nullptr && e[0] == '1';
        }();
        test_serial_promo_via_ctx_ = via_ctx;
        static const bool engine = [] {
            const char* e = std::getenv("ECO_TEST_MINOR_ENGINE");
            return e != nullptr && e[0] == 'P';
        }();
        test_force_parallel_engine_ = engine;
    }
#endif
    bump_.end = computeAllocEnd();

#if ENABLE_GC_STATS
    stats.nursery_size_bytes = 2 * slice_.capacity;
#endif
}

void NurserySpace::initialize(Allocator* allocator, const HeapConfig* config) {
    config_ = config;
    allocator_ = allocator;
    thread_heap_ = nullptr;  // Legacy single-threaded mode (not using ThreadLocalHeap).
    initializeFromConfig();
}

void NurserySpace::initialize(ThreadLocalHeap* heap, const HeapConfig* config) {
    config_ = config;
    thread_heap_ = heap;
    allocator_ = heap->getParent();  // Reference to Allocator for slice acquisition.
    initializeFromConfig();
}

void NurserySpace::reset(OldGenSpace &oldgen, const HeapConfig* new_config) {
    (void)oldgen;

    // Release the current slice before re-acquiring: the block design leaked
    // its blocks here (vectors cleared without release), which the slice
    // layer fixes for free.
    if (slice_.capacity != 0) {
        allocator_->releaseNurserySlicePair(slice_);
        slice_ = NurserySlicePair{};
    }
    if (rg_) {
        tenureTeardown(oldgen);
        releaseRegions();
    }

    // Update config if provided.
    if (new_config) {
        config_ = new_config;
    }

    initializeFromConfig();

    // Reset the root set.
    root_set.reset();

    // Note: GC stats are not reset here - they accumulate across multiple runs.
    // (initializeFromConfig refreshes the live nursery_size_bytes snapshot.)
}

void NurserySpace::updateBounds() {
    // Exact, gap-free bounds: base .. base + capacity, both sides equal.
    low_end_  = low_base_  ? low_base_  + slice_.capacity : nullptr;
    high_end_ = high_base_ ? high_base_ + slice_.capacity : nullptr;
}

void *NurserySpace::allocate(size_t size) {
    // Align to 8 bytes.
    size = (size + 7) & ~7;

    // Fast path: fits before the clamped limit. No wall-clock timing here —
    // the bump-pointer body is too short for `clock_gettime` brackets to be
    // anything but pure overhead (~25% of total CPU on the Stage 7 profile).
    // Slow-path timing is done inside `allocateSlow` below.
    if (bump_.ptr + size <= bump_.end) {
        void* result = bump_.ptr;
        bump_.ptr += size;
        GC_STATS_MINOR_RECORD_ALLOC(stats, size);
        return result;
    }

    // Slow path: signal GC (or take the already-full fail-soft). Wall-clock
    // the body so its cost lands in total_nursery_alloc_in_mutator_ns rather
    // than leaking into mutator time. The mutator-only check is correct
    // because nursery_.allocate is never invoked from inside minorGC
    // (promotions go to oldgen.allocate).
    return allocateSlow(size);
}

void* NurserySpace::allocateSlow(size_t size) {
#if ENABLE_GC_STATS
    auto t0 = GC_STATS_TIMER_START();
#endif

    void* result = nullptr;

    // The fast path fell through (bump_.ptr + size > bump_.end). With a
    // contiguous from-space there is no block to advance to, so this has
    // exactly one meaning — the clamped limit was reached — and one
    // response: signal a minor GC by returning null.
    //
    // The single exception is the already-full fail-soft (see
    // computeAllocEnd): if the previous GC left survivors at or past the
    // threshold, `bump_.end` is the extent end and a GC cannot free
    // anything new, so re-clamping would GC-loop. That case is already
    // encoded in `bump_.end`, so nothing to do here — the null return
    // drives the GC and the post-GC recompute re-applies the fail-soft.

#if ENABLE_GC_STATS
    if (!minor_gc_running_) {
        stats.total_nursery_alloc_in_mutator_ns +=
            GC_STATS_TIMER_ELAPSED_NS(t0);
    }
#endif

    (void)size;
    return result;
}

// Capacity guarantee for hoisted allocation checks (HEAP_041,
// plans/capacity-check-hoisting.md). Establishes `bump_.end - bump_.ptr >= n`
// WITHOUT allocating anything; returns false when only a minor GC can satisfy
// the request. Contiguity collapses the block design's advance loop (and its
// clamp-vs-exhaustion disambiguator) to a single comparison.
//
// `end < ptr` is a legal state meaning "must collect" (e.g. a future remote
// clamp that lands below the bump pointer, design_docs/parallel-gc.md §3.2).
// The old `size_t(end - ptr) >= n` form underflowed to "plenty of room" there,
// letting a covered region bump unchecked past the extent. Compare in integer
// space, ordered, so no out-of-range pointer is ever formed.
bool NurserySpace::ensureHeadroom(size_t n) {
    const uintptr_t p = reinterpret_cast<uintptr_t>(bump_.ptr);
    const uintptr_t e = reinterpret_cast<uintptr_t>(bump_.end);
    return e >= p && e - p >= n;
}

void NurserySpace::failSoftUnclamp() {
    // Same fail-soft shape as computeAllocEnd's already-full clause: give the
    // caller the whole remaining extent. Reachable only in tiny test configs
    // where threshold_total_bytes_ < n (see ThreadLocalHeap::ensureNursery).
    if (rg_) {   // threaded-gc-07 P§3.8: eden may hold capacity - S_m bytes
        const size_t room = rg_->S_m < from_capacity_bytes_ ? from_capacity_bytes_ - rg_->S_m : 0;
        bump_.end = rg_->eden_base + room;
        if (bump_.end < bump_.ptr) bump_.end = bump_.ptr;
        return;
    }
    if (!fromBase()) return;
    bump_.end = fromBase() + from_capacity_bytes_;
}

// contains(), isInFromSpace(), isInToSpace() are now inline in the header.

size_t NurserySpace::bytesAllocated() const {
    if (!bump_.ptr) return 0;
    // threaded-gc-07 P§3.8: survived object bytes of the last minor plus eden.
    if (rg_) return rg_->S_m + static_cast<size_t>(bump_.ptr - rg_->eden_base);
    return static_cast<size_t>(bump_.ptr - fromBase());
}

void NurserySpace::refreshCapacityCaches() {
    // W2 items 16/18/19/22: GC-invariant values hoisted off the per-object
    // and per-slot paths. This function already runs at init / reset / grow,
    // which is exactly when any of them can change.
    if (config_ != nullptr) {
        promotion_age_ = config_->promotion_age;
        use_hybrid_dfs_ = config_->use_hybrid_dfs;
    }
    if (allocator_ != nullptr) {
        heap_base_ = allocator_->getHeapBase();
        heap_reserved_ = allocator_->getHeapReserved();
    }

    from_capacity_bytes_ = rg_ ? rg_->set.capacity : slice_.capacity;
    threshold_total_bytes_ =
        static_cast<size_t>(static_cast<double>(from_capacity_bytes_) * gc_threshold_);
}

char* NurserySpace::computeAllocEnd() {
    if (rg_) {
        // threaded-gc-07 P§3.8: eden gets threshold - S_m (legacy's survivor
        // prefix is the same object bytes); fail-soft: capacity - S_m.
        const size_t sm = rg_->S_m;
        if (sm >= threshold_total_bytes_) {
            return rg_->eden_base + (sm < from_capacity_bytes_ ? from_capacity_bytes_ - sm : 0);
        }
        return rg_->eden_base + (threshold_total_bytes_ - sm);
    }
    char* base = fromBase();
    char* extent_end = base + from_capacity_bytes_;
    // threaded-gc-06 HEAP_068: OBJECT bytes. The survivor prefix may hold
    // filler_bytes_ of LAB-tail fillers; counting them would make the next
    // trigger depend on the copy schedule. At N = 1 filler_bytes_ is 0.
    size_t already = static_cast<size_t>(bump_.ptr - base) - filler_bytes_;
    if (already >= threshold_total_bytes_) {
        // The threshold has already been crossed by survivors of a prior
        // GC. Tripping the threshold again before the space fills cannot
        // free any new space (no allocations have happened since the GC
        // that produced these survivors), so re-engaging it would only
        // GC-loop. Fail soft: use the full extent, and let genuine
        // exhaustion drive the GC.
        return extent_end;
    }
    if (filler_bytes_ == 0) return base + threshold_total_bytes_;
    const size_t room = from_capacity_bytes_;
    if (threshold_total_bytes_ + filler_bytes_ > room) {
#if ENABLE_GC_STATS
        stats.pmin.alloc_end_capped++;   // must stay 0 on gate runs (P§3.5)
#endif
        return extent_end;
    }
    return base + threshold_total_bytes_ + filler_bytes_;
}

void* NurserySpace::copyToSpace(size_t size) {
    // To-space is one contiguous extent, so this is a pure bump. Overflow is
    // impossible: both semi-spaces share one `slice_.capacity`, so everything
    // that fit in from-space fits here.
    if (copy_ptr_ + size <= copy_end_) {
        void* result = copy_ptr_;
        copy_ptr_ += size;
        return result;
    }

    assert(false && "To-space overflow - impossible with equal-sized extents");
    return nullptr;
}

bool NurserySpace::scanHasMore() const {
    // One contiguous to-space extent: the textbook Cheney test.
    return scan_ptr_ < copy_ptr_;
}

void NurserySpace::checkAndGrow() {
    if (rg_) { regionCheckAndGrow(); return; }   // threaded-gc-07 P§3.8
    // To-space occupancy after copying. Contiguous, so this is pure survivor
    // bytes with no block-quantization waste in the numerator.
    // threaded-gc-06 HEAP_068: object bytes (the to-space prefix's fillers
    // excluded), so growth is identical at every worker count.
    const size_t bytes_used = static_cast<size_t>(copy_ptr_ - toBase()) - filler_bytes_to_;
    const size_t total_to_capacity = slice_.capacity;
    if (total_to_capacity == 0) return;

    const float occupancy =
        static_cast<float>(bytes_used) / static_cast<float>(total_to_capacity);
    if (occupancy <= growth_threshold_) {
        return;  // No growth needed.
    }

    if (slice_.capacity >= growth_ceiling_bytes_) {
        return;  // Already at the configured / geometric ceiling.
    }

    // Default policy: grow by 50%, quantized to alloc_buffer_size so
    // nursery_block_count / nursery_max_block_count keep their exact config
    // meaning (capacity in block-sized units). Truncate against the
    // remaining room so the last step fills the ceiling exactly rather than
    // overshooting.
    const size_t quantum = config_->alloc_buffer_size;
    size_t delta = slice_.capacity / 2;
    delta -= delta % quantum;
    if (delta < quantum) delta = quantum;
    const size_t room = growth_ceiling_bytes_ - slice_.capacity;
    if (delta > room) delta = room;
    if (delta == 0) return;

    if (!allocator_->growNurserySlicePair(slice_, delta)) {
        // Commit refused: skip growth this cycle. Nothing was half-applied —
        // capacity is unchanged and both extents stay equal (the block design
        // leaked the blocks it had already acquired here).
        if (Allocator::heapTraceEnabled()) {
            std::fprintf(stderr,
                "[heap-trace] nursery grow declined: +%zu KB refused "
                "(capacity %zu KB/side)\n",
                delta / 1024, slice_.capacity / 1024);
        }
        return;
    }

    // Both extents are longer now: re-derive the membership bounds BEFORE
    // anything can consult them, then the capacity-derived caches. Stale
    // bounds would make the next minor GC treat objects in the grown region
    // as non-nursery and skip evacuating them.
    updateBounds();
    refreshCapacityCaches();

#if ENABLE_GC_STATS
    stats.nursery_grow_events++;
    stats.nursery_size_bytes = 2 * slice_.capacity;
#endif

    if (Allocator::heapTraceEnabled()) {
        std::fprintf(stderr,
            "[heap-trace] nursery grew: +%zu KB/side (now %.2f MB/side, "
            "%.2f MB total)\n",
            delta / 1024,
            slice_.capacity / (1024.0 * 1024.0),
            (2 * slice_.capacity) / (1024.0 * 1024.0));
    }
}

/**
 * Performs a minor garbage collection using Cheney's algorithm.
 *
 * Algorithm phases:
 *   1. Evacuate all roots (from root set) to to-space or old gen (if aged).
 *   2. Cheney scan: walk to-space objects breadth-first, evacuating children.
 *      When use_hybrid_dfs is enabled, list spines are copied contiguously.
 *   3. Process promoted objects (scan their children, may add more promoted objects).
 *   4. Check occupancy and grow nursery if needed.
 *   5. Swap from-space and to-space.
 *
 * Note on old→young pointers: Elm's immutability guarantees no old→nursery
 * pointers can exist. An object can only reference values that already existed
 * when it was created, so any object's children are always at least as old as
 * the object itself. When a nursery object reaches promotion_age, all of its
 * transitively-reachable children must also have reached promotion_age and are
 * promoted together in the same phase-3 scan. The assertion in evacuate() enforces
 * this: if phase 3 ever encounters a from-space child whose age < promotion_age,
 * that is a bug (heap corruption), not a case to handle gracefully.
 */
void NurserySpace::minorGC(OldGenSpace &oldgen, const StackMapRoots& stackmap_roots,
                           MinorGCRecord* rec) {
    if (rg_) {   // threaded-gc-07 (HEAP_069): the region minor
        minorGCRegion(oldgen, stackmap_roots, rec);
        return;
    }
#if !ENABLE_GC_PHASE_TIMERS
    (void)rec;
#endif
    // Set the cross-allocator in-minor-GC flag (always on, used by the
    // OldGenSpace::allocate inline-helper attribution counter).
    minor_gc_running_ = true;
    oldgen.setInMinorGC(true);

    // Flip the split-header body color for this cycle. Every live header
    // scanned in to-space gets recorded with this color via markLargeBodySeen;
    // bodies whose recorded color doesn't match at the end are freed.
    minor_color_ = !minor_color_;
    young_large_scan_.clear();

#if ECO_HEAP_VALIDATE
    // Used by stale-pointer detection in `debugAssertValidNurseryPointer`.
    in_minor_gc_ = true;
#endif
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] minorGC start from_is_low=%d\n", (int)from_is_low_);
#endif

#if ECO_HEAP_VALIDATE
    // Class 3: walk every header in from-space's allocated prefix and
    // assert tag/size sanity before evacuation begins. Catches mutator-side
    // header corruption that would otherwise propagate via memcpy.
    preEvacuationFromSpaceWalk();
#endif
#if P1_CENSUS_COMPILED
    // threaded-gc-04 P1 census: detector N compares the survivors recorded at
    // the end of the previous minor GC before anything is evacuated; detector
    // O verifies the old-gen table every ECO_P1_CENSUS_EVERY minors.
    if (censusEnabled()) censusCheck(oldgen);
    p1::onMinorStart(oldgen, ++census_minor_seq_);
#endif

#if ENABLE_GC_STATS
    // Capture state before GC.
    size_t from_space_used = objectBytesAllocated();   // threaded-gc-06: object bytes
    auto gc_start = GC_STATS_TIMER_START();
#endif

#if ENABLE_GC_PHASE_TIMERS
    // threaded-gc-00 phase timers. Clock reads at phase boundaries only
    // (never per object); nothing here feeds a GC decision.
    const bool T = rec != nullptr;
    uint64_t tp = T ? GCStats::nowSinceProcessStartNs() : 0;
    auto lap = [&]() -> uint64_t {
        const uint64_t now = GCStats::nowSinceProcessStartNs();
        const uint64_t d = now - tp;
        tp = now;
        return d;
    };
    const uint64_t surv0 = stats.objects_survived, prom0 = stats.objects_promoted;
    uint64_t survb0 = 0, promb0 = 0;
    if (T) {
        for (int i = 0; i < GCStats::NUM_ALLOC_TAGS; ++i) {
            survb0 += stats.survived_bytes_by_tag[i];
            promb0 += stats.promoted_bytes_by_tag[i];
        }
    }
    const OldGenSpace::PromoInstr promo0 = oldgen.promoInstr();
    long flt_minor0 = 0, flt_major0 = 0;
#if defined(RUSAGE_THREAD)
    if (T) {
        struct rusage ru;
        if (getrusage(RUSAGE_THREAD, &ru) == 0) {
            flt_minor0 = ru.ru_minflt;
            flt_major0 = ru.ru_majflt;
        }
    }
#endif
#endif

    // Reset to-space allocation and the Cheney scan: one contiguous extent,
    // so both cursors start at its base and the copy limit is its end.
    copy_ptr_ = toBase();
    copy_end_ = toBase() + slice_.capacity;
    scan_ptr_ = toBase();
    filler_bytes_to_ = 0;   // threaded-gc-06: only a parallel minor writes fillers

    // Buffer for promoted objects that need scanning.
    // W5 item 35: reuse the buffer across cycles. Declared locally it mallocs
    // and doubles from zero inside every pause — this workload promotes ~350K
    // objects per minor GC, i.e. ~19 reallocs each copying up to 2.8 MB of
    // pointers, 1,924 times per run. clear() keeps the capacity; deliberately
    // NOT shrink_to_fit.
    promoted_buf_.clear();
    std::vector<void*>& promoted_objects = promoted_buf_;

    // threaded-gc-06 (HEAP_067): with gc_minor_threads > 1 (or the forced
    // one-worker engine) the root phase and the drain run in parallel
    // (NurseryParallel.cpp). The serial core below is unchanged; it is the
    // gc_minor_threads = 1 reference and every fallback minor (P§3.2).
    const unsigned par_n = chooseMinorWorkers(oldgen);
    if (par_n != 0) {
#if ENABLE_GC_STATS
        const uint64_t tpar0 = GCStats::nowSinceProcessStartNs();
#endif
        minorGCParallel(oldgen, stackmap_roots, rec, par_n);
#if ENABLE_GC_STATS
        stats.pmin.drain_ns_sum += GCStats::nowSinceProcessStartNs() - tpar0;
#endif
    } else {   // ---- the serial core: roots, then the alternating drain ----
#if ENABLE_GC_STATS
    // threaded-gc-06 Step 4: the one-worker identity switch -- the serial
    // copiers promote through worker 0 of a promotion context (P§3.8), which
    // must reproduce allocate() bit for bit.
    promo_w0_ = nullptr;
    if (__builtin_expect(test_serial_promo_via_ctx_, 0) && oldgen.config_->old_gen_bitmap_alloc) {
        OldGenSpace::PromoCtx& ctx = oldgen.promoCtx();
        oldgen.beginParallelPromotion(ctx, 1);
        promo_w0_ = &ctx.w[0];
    }
#endif

    // Phase 1a: Evacuate long-lived roots (may add to promoted_objects).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1a: %zu long-lived roots\n", root_set.getRoots().size());
#endif
    for (HPointer *root: root_set.getRoots()) {
        evacuate(*root, oldgen, &promoted_objects);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_longlived_jit_ns += lap();
#endif

    // Phase 1b: Evacuate stackmap-derived roots (discovered from LLVM StackMaps).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1b: %zu stackmap roots\n", stackmap_roots.get().size());
#endif
    for (HPointer *root: stackmap_roots.get()) {
#if ECO_GC_DEBUG
        uint64_t rv; memcpy(&rv, root, sizeof(rv));
        if (rv == 0x20039995ULL)
            std::fprintf(stderr, "[gc-debug] phase1b: FOUND target 0x20039995 in stackmap root %p\n", (void*)root);
#endif
        evacuate(*root, oldgen, &promoted_objects);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_stackmap_ns = lap();
#endif

    // Phase 1c: Evacuate JIT roots (raw 64-bit pointers from JIT-compiled globals).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1c: %zu jit roots\n", root_set.getJitRoots().size());
#endif
    for (uint64_t *root: root_set.getJitRoots()) {
        evacuateJitPtr(*root, oldgen, &promoted_objects);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_longlived_jit_ns += lap();
#endif

    // Phase 1e: Stack root ranges (alloca-backed args arrays from compiled code).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1e: %zu stack root ranges\n", root_set.getStackRootRanges().size());
#endif
    for (const auto &range : root_set.getStackRootRanges()) {
        HPointer *base = range.base;
        uint64_t mask  = range.hpointer_mask;
        for (size_t i = 0; i < range.count; ++i) {
            if (stackRangeSlotIsRoot(mask, i)) {
#if ECO_GC_DEBUG
                uint64_t rv; memcpy(&rv, &base[i], sizeof(rv));
                if (rv == 0x20039995ULL)
                    std::fprintf(stderr, "[gc-debug] phase1e: FOUND target 0x20039995 in stack range %p idx %zu\n",
                                 (void*)base, i);
#endif
                evacuate(base[i], oldgen, &promoted_objects);
            }
        }
    }

    // Phase 1e': single-slot stack roots (plan §3.3). Same status as the ranges
    // above — one HPointer slot each, count and mask implicit.
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1e': %zu single stack roots\n", root_set.getSingleRoots().size());
#endif
    for (HPointer* slot : root_set.getSingleRoots()) {
        evacuate(*slot, oldgen, &promoted_objects);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_ranges_ns = lap();
#endif

    // Phase 1d: External root scanners (Scheduler run queue, PlatformRuntime state, etc.).
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1d: %zu external scanners\n", root_set.getExternalRootScanners().size());
#endif
#if ENABLE_GC_PHASE_TIMERS
    if (T) {
        // Same scanners, same order; each timed and its slots counted.
        const auto& scanners = root_set.getExternalRootScanners();
        for (size_t i = 0; i < scanners.size(); ++i) {
            uint64_t slots = 0;
            const uint64_t ts = GCStats::nowSinceProcessStartNs();
            scanners[i]([this, &oldgen, &promoted_objects, &slots](uint64_t& ref) {
                ++slots;
                evacuateValueSlot(ref, oldgen, &promoted_objects);
            });
            const uint64_t dt = GCStats::nowSinceProcessStartNs() - ts;
            const size_t k = i < static_cast<size_t>(GC_EXT_SCANNER_CAP)
                                 ? i : static_cast<size_t>(GC_EXT_SCANNER_CAP - 1);
            rec->ext_ns[k] += dt;
            rec->ext_slots[k] += slots;
        }
        rec->ext_count = static_cast<int>(std::min(scanners.size(),
                                          static_cast<size_t>(GC_EXT_SCANNER_CAP)));
        rec->roots_external_ns = lap();
    } else
#endif
    for (auto& scanner : root_set.getExternalRootScanners()) {
        scanner([this, &oldgen, &promoted_objects](uint64_t& ref) {
            evacuateValueSlot(ref, oldgen, &promoted_objects);
        });
    }

#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 2: Cheney scan starts\n");
#endif
    // Phase 2: Cheney's algorithm - scan to-space objects breadth-first.
    // When use_hybrid_dfs is enabled, list spine copying provides locality optimization
    // within scanObject() without requiring a separate DFS stack.
    // W5 item 33: the Cheney drain that stood here was REDUNDANT — phase 3's
    // outer loop below opens with an identical inner `while (scanHasMore())`
    // and runs unconditionally immediately after, so this loop only ever did
    // work that the next one would have done anyway.

    // Phase 3: Process promoted objects until buffer is empty.
    // By Elm's immutability invariant, every child of a promoted object must be
    // at least as old as the parent and therefore also qualify for promotion.
    // in_phase3_ arms the assertion in evacuate() that catches any violation.
    // Use index-based loop since vector may grow during iteration.
    //
    // The flag is toggled PER INNER LOOP, not once around the whole
    // alternation. The assertion is about the children of a PROMOTED parent;
    // a to-space parent's child being younger than promotion_age is the
    // ordinary case, and arming the assertion across the Cheney drain made
    // it fire on that — reporting a to-space parent as "parent(old-gen)".
    // W5 item 33 removed the preliminary drain that used to empty to-space
    // before the flag was raised, which is what made a latent mislabel start
    // aborting the heap-validate build.
    // Drain alternately between to-space and the promoted-objects queue
    // until both are empty. Scanning a promoted object can copy YOUNG
    // children into to-space (when the child's age < promotion_age) —
    // Elm's immutability invariant is supposed to forbid this (children of
    // a promoted object should be at least as old as the parent), but
    // kernel-side mutation paths can violate it. Without re-draining,
    // those new to-space objects would never be scanned and their boxed
    // slots would remain pointing at from-space, surfacing as stale refs
    // at the next mutator read. Conversely, scanning a fresh to-space
    // object can promote an aged child, growing the queue further; hence
    // the alternation runs to mutual fixed point.
    size_t promoted_idx = 0;
    size_t young_large_idx = 0;   // threaded-gc-04b: YLOS objects staying young
    while (scanHasMore() || promoted_idx < promoted_objects.size() ||
           young_large_idx < young_large_scan_.size()) {
#if ENABLE_GC_PHASE_TIMERS
        if (T) { ++rec->drain_rounds; lap(); }
#endif
        while (scanHasMore()) {
            void *obj = scan_ptr_;
#if ECO_HEAP_VALIDATE
            in_phase3_ = false;   // to-space parent: young children are normal
#endif
            scanObject(obj, oldgen, &promoted_objects);
            scan_ptr_ += getObjectSize(obj);
        }
#if ENABLE_GC_PHASE_TIMERS
        if (T) rec->drain_tospace_ns += lap();
#endif
        while (promoted_idx < promoted_objects.size()) {
#if ECO_HEAP_VALIDATE
            in_phase3_ = true;    // promoted parent: the invariant applies
#endif
            scanObject(promoted_objects[promoted_idx++], oldgen, &promoted_objects);
        }
#if ENABLE_GC_PHASE_TIMERS
        if (T) rec->drain_promoted_ns += lap();
#endif
        // A young parent, scanned in place: its young children are normal.
        while (young_large_idx < young_large_scan_.size()) {
#if ECO_HEAP_VALIDATE
            in_phase3_ = false;
#endif
            scanObject(young_large_scan_[young_large_idx++], oldgen, &promoted_objects);
#if ENABLE_GC_STATS
            stats.lp.ylos_scans++;
#endif
        }
    }
#if ENABLE_GC_STATS
    if (promo_w0_ != nullptr) {
        oldgen.endParallelPromotion(oldgen.promoCtx());
        promo_w0_ = nullptr;
    }
#endif
    last_minor_promoted_ = promoted_objects.size();   // sizes the next pre-drain sweep

    }   // ---- end of the serial core ----
#if ECO_HEAP_VALIDATE
    in_phase3_ = false;
    validatePromotedHaveNoYoungChildren(oldgen, promoted_buf_);   // V2
#endif
#if ENABLE_GC_PHASE_TIMERS
    // Promotion-path old-gen counters for this cycle (Step 7). Taken at drain
    // exit: every promotion happens inside the root phases or the drain.
    if (T) {
        const OldGenSpace::PromoInstr& p1 = oldgen.promoInstr();
        rec->lazy_sweep_calls = p1.sweep.calls - promo0.sweep.calls;
        rec->lazy_sweep_bytes = p1.sweep_bytes - promo0.sweep_bytes;
        rec->lazy_sweep_est_ns = sampledEstimateNs(
            p1.sweep.sampled_ns - promo0.sweep.sampled_ns, rec->lazy_sweep_calls,
            p1.sweep.sampled_calls - promo0.sweep.sampled_calls);
        rec->promo_alloc_calls = p1.alloc.calls - promo0.alloc.calls;
        rec->promo_alloc_est_ns = sampledEstimateNs(
            p1.alloc.sampled_ns - promo0.alloc.sampled_ns, rec->promo_alloc_calls,
            p1.alloc.sampled_calls - promo0.alloc.sampled_calls);
    }
    auto t_loop_exit = GC_STATS_TIMER_START();
#endif

    // Phase 4: Check occupancy and grow if needed.
    checkAndGrow();

    // Safety net: zero free to-space region to prevent ghost headers from
    // surviving into the next GC cycle. Load-bearing — disabling this
    // produces "Pointer above heap end!" aborts in evacuate when stale
    // bytes in the free tail decode as out-of-range raw pointers. Called
    // after checkAndGrow() so newly added blocks are also zeroed.
    clearToSpaceFreeRegion();

#if ECO_HEAP_VALIDATE
    // Post-GC heap integrity check: walk all surviving objects in to-space
    // and verify every boxed child pointer points outside from-space. A
    // child still in from-space at this point (without a Tag_Forward
    // header) means GC failed to forward it — diagnostic for stale-pointer
    // corruption that would surface as a poisoned-region read at the next
    // mutator phase.
    {
        {   // One contiguous to-space extent: a single linear walk of the
            // whole evacuated prefix (the block design needed a per-block
            // loop with a tail-gap-aware end).
            char* scan = toBase();
            char* end  = copy_ptr_;
            while (scan < end) {
                Header* h = getHeader(scan);
                auto checkChild = [&](HPointer &hp, const char* desc, int idx) {
                    if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                    void* child = Allocator::fromPointerRaw(hp);
                    if (child && isInFromSpace(child)) {
                        Header* ch = getHeader(child);
                        if (ch->tag != Tag_Forward) {
                            uint64_t raw = 0;
                            memcpy(&raw, &hp, sizeof(raw));
                            std::fprintf(stderr,
                                "[gc-heap-check] STALE CHILD in to-space obj=%p tag=%u size=%u %s[%d] -> raw=0x%lx child=%p child_tag=%u\n",
                                (void*)scan, (unsigned)h->tag, (unsigned)h->size, desc, idx,
                                (unsigned long)raw, child, (unsigned)ch->tag);
                        }
                    }
                };
                switch (h->tag) {
                    case Tag_Cons: {
                        Cons* c = static_cast<Cons*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkChild(c->head.p, "head", 0);
                        checkChild(c->tail, "tail", 0);
                        break;
                    }
                    case Tag_ConsChunk: {
                        ConsChunk* cv = static_cast<ConsChunk*>(static_cast<void*>(scan));
                        checkChild(cv->backing, "backing", 0);
                        checkChild(cv->next, "next", 1);
                        break;
                    }
                    case Tag_ListBacking: {
                        ListBacking* lb = static_cast<ListBacking*>(static_cast<void*>(scan));
                        if ((h->unboxed & 0x3) == 0) {
                            for (u32 i = lb->hd; i < h->size; i++)
                                checkChild(lb->elems[i].p, "elem", static_cast<int>(i));
                        }
                        break;
                    }
                    case Tag_Tuple2: {
                        Tuple2* t = static_cast<Tuple2*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkChild(t->a.p, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkChild(t->b.p, "b", 1);
                        break;
                    }
                    case Tag_Tuple3: {
                        Tuple3* t = static_cast<Tuple3*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkChild(t->a.p, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkChild(t->b.p, "b", 1);
                        if (Elm::tupleFieldKind(h->unboxed, 2) == 0) checkChild(t->c.p, "c", 2);
                        break;
                    }
                    case Tag_Custom: {
                        Custom* c = static_cast<Custom*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 24; i++) {
                            if (Elm::fieldKind(c->unboxed, i) == 0)
                                checkChild(c->values[i].p, "custom", i);
                        }
                        break;
                    }
                    case Tag_Record: {
                        Record* r = static_cast<Record*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 32; i++) {
                            if (Elm::fieldKind(r->unboxed, i) == 0)
                                checkChild(r->values[i].p, "record", i);
                        }
                        break;
                    }
                    case Tag_Closure: {
                        // n_values, matching the scan this is verifying.
                        Closure* cl = static_cast<Closure*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < cl->n_values; i++) {
                            if (Elm::fieldKind(cl->unboxed, i) == 0)
                                checkChild(cl->values[i].p, "closure", i);
                        }
                        break;
                    }
                    case Tag_DynRecord: {
                        DynRecord* dr = static_cast<DynRecord*>(static_cast<void*>(scan));
                        checkChild(dr->fieldgroup, "fieldgroup", 0);
                        for (u32 i = 0; i < h->size; i++)
                            checkChild(dr->values[i], "dynrec", i);
                        break;
                    }
                    case Tag_StringSlice: {
                        ElmStringSlice* slc = static_cast<ElmStringSlice*>(static_cast<void*>(scan));
                        checkChild(slc->base, "slice-base", 0);
                        break;
                    }
                    case Tag_StringUtf8View: {
                        ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(static_cast<void*>(scan));
                        checkChild(v->base, "utf8view-base", 0);
                        break;
                    }
                    case Tag_ByteBufferSlice: {
                        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(static_cast<void*>(scan));
                        checkChild(slc->base, "byte-slice-base", 0);
                        break;
                    }
                    case Tag_StringRope: {
                        ElmStringRope* r = static_cast<ElmStringRope*>(static_cast<void*>(scan));
                        checkChild(r->left, "rope-left", 0);
                        checkChild(r->right, "rope-right", 0);
                        break;
                    }
                    case Tag_Array: {
                        ElmArray* a = static_cast<ElmArray*>(static_cast<void*>(scan));
                        // Only walk when the array claims boxed elements.
                        // For an unboxed-tagged array we have no good way to
                        // tell whether random-looking element bits are real
                        // pointers (false positives), so we trust the kind
                        // tag here and rely on the GC-time kind-mismatch
                        // tripwire (case Tag_Array in evacuate) to flag
                        // arrays whose tag is lying.
                        if ((a->header.unboxed & 0x3) == 0) {
                            for (u32 i = 0; i < a->length; i++)
                                checkChild(a->elements[i].p, "array", static_cast<int>(i));
                        }
                        break;
                    }
                    default: break;
                }
                scan += getObjectSize(scan);
            }
        }
    }

    // Post-GC old-gen integrity check: scan every old-gen object and report
    // any boxed field that still points into (old) from-space.
    {
        // The GC has not yet flipped from_is_low_, so from-space is still the
        // space we just evacuated FROM.  Objects there are garbage / stale.
        auto isInCurrentFromSpace = [this](void* p) -> bool {
            return isInFromSpace(p);
        };

        auto checkOGChild = [&](HPointer &hp, void* parent, const char* field, int idx) {
            if (hp.ptr_ind != 0 || hp.ptr == 0) return;
            // threaded-gc-04b: an unreached young large object is dead (the
            // minor-end sweep frees it); its stale slots are not a defect.
            if (const auto* m = oldgen.youngLargeMeta(parent); m && m->color != minor_color_)
                return;
            void* child = Allocator::fromPointerRaw(hp);
            if (!child) return;
            if (!isInCurrentFromSpace(child)) return;
            // child still points into old from-space — dangling old→nursery pointer
            uint64_t raw = 0;
            memcpy(&raw, &hp, sizeof(raw));
            std::fprintf(stderr,
                "[gc-old-check] OLD-GEN→NURSERY(stale): parent=%p %s[%d] raw=0x%016lx child=%p\n",
                parent, field, idx, (unsigned long)raw, child);
            Header* ph = getHeader(parent);
            Header* ch = getHeader(child);
            std::fprintf(stderr,
                "  parent tag=%u size=%u age=%u  child tag=%u size=%u age=%u\n",
                (unsigned)ph->tag, (unsigned)ph->size, (unsigned)ph->age,
                (unsigned)ch->tag, (unsigned)ch->size, (unsigned)ch->age);
            std::fflush(stderr);
        };

        for (size_t pos = 0; pos < oldgen.blocks_.size(); ++pos) {
            const BlockId blk_id = oldgen.blocks_.idAt(pos);
            const BlockInfo& blk = oldgen.blocks_.info(blk_id);
            char* scan = blk.start;
            char* end  = blk.end_of_objects;
            // threaded-gc-02 (HEAP_024 reworded): in bitmap mode a uniform
            // block is NOT header-parsable — only cells whose start bit is set
            // hold objects (dead cells keep stale headers, virgin cells none).
            // A MIXED block is not header-parsable over dead space either
            // (HEAP_056): the bitmap cursor fills a gap between set bits and
            // leaves the gap's tail as stale bytes with no header, so the walk
            // visits set start bits only and steps a granule otherwise.
            const bool bitmap_walk = oldgen.config_->old_gen_bitmap_alloc && !blk.is_large;
            const bool uniform_bitmap = bitmap_walk && blk.size_class < oldgen.num_size_classes_;
            const size_t ucell = uniform_bitmap
                ? OldGenSpace::classToSize(blk.size_class) : 8;
            while (scan < end) {
                // threaded-gc-05c (H2): background markers may write these bytes.
                if (bitmap_walk && !oldgen.isMarkedInBlockRelaxed(blk_id, scan)) {
                    scan += ucell;
                    continue;
                }
                char* const cell_start = scan;
                Header* h = getHeader(scan);
                // Only a FULLY-ZERO word is uninitialized/swept filler.
                // Testing `tag == 0` alone is wrong: Tag_Int == 0, so a
                // promoted boxed Int (header word 16<<32 — every alloc
                // path writes size = sizeof(ElmInt)) would be skipped by
                // 8 and the walk would land on its VALUE word; a value of
                // 25 decodes as Tag_Free with size 0 = zero stride = hang.
                uint64_t raw_header;
                memcpy(&raw_header, h, sizeof(raw_header));
                if (raw_header == 0 || h->tag > Tag_Forward) {
                    scan += 8;
                    continue;
                }
                if (h->tag == Tag_Forward) {
                    scan += 8;
                    continue;
                }
                size_t obj_size = getObjectSize(scan);
                if (obj_size == 0) {
                    // Degenerate decode (e.g. Tag_Free size 0) — never a
                    // real object; resync by 8 rather than loop forever.
                    scan += 8;
                    continue;
                }
                switch (h->tag) {
                    case Tag_Closure: {
                        // n_values, matching the scan this is verifying.
                        Closure* cl = static_cast<Closure*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < cl->n_values; i++) {
                            if (Elm::fieldKind(cl->unboxed, i) == 0)
                                checkOGChild(cl->values[i].p, scan, "capture", i);
                        }
                        break;
                    }
                    case Tag_Tuple2: {
                        Tuple2* t = static_cast<Tuple2*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkOGChild(t->a.p, scan, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkOGChild(t->b.p, scan, "b", 1);
                        break;
                    }
                    case Tag_Tuple3: {
                        Tuple3* t = static_cast<Tuple3*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkOGChild(t->a.p, scan, "a", 0);
                        if (Elm::tupleFieldKind(h->unboxed, 1) == 0) checkOGChild(t->b.p, scan, "b", 1);
                        if (Elm::tupleFieldKind(h->unboxed, 2) == 0) checkOGChild(t->c.p, scan, "c", 2);
                        break;
                    }
                    case Tag_Custom: {
                        Custom* c = static_cast<Custom*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 24; i++) {
                            if (Elm::fieldKind(c->unboxed, i) == 0)
                                checkOGChild(c->values[i].p, scan, "custom", i);
                        }
                        break;
                    }
                    case Tag_Record: {
                        Record* r = static_cast<Record*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size && i < 32; i++) {
                            if (Elm::fieldKind(r->unboxed, i) == 0)
                                checkOGChild(r->values[i].p, scan, "record", i);
                        }
                        break;
                    }
                    case Tag_Cons: {
                        Cons* c = static_cast<Cons*>(static_cast<void*>(scan));
                        if (Elm::tupleFieldKind(h->unboxed, 0) == 0) checkOGChild(c->head.p, scan, "head", 0);
                        checkOGChild(c->tail, scan, "tail", 0);
                        break;
                    }
                    case Tag_ConsChunk: {
                        ConsChunk* cv = static_cast<ConsChunk*>(static_cast<void*>(scan));
                        checkOGChild(cv->backing, scan, "backing", 0);
                        checkOGChild(cv->next, scan, "next", 1);
                        break;
                    }
                    case Tag_ListBacking: {
                        ListBacking* lb = static_cast<ListBacking*>(static_cast<void*>(scan));
                        if ((h->unboxed & 0x3) == 0) {
                            for (u32 i = lb->hd; i < h->size; i++)
                                checkOGChild(lb->elems[i].p, scan, "elem", static_cast<int>(i));
                        }
                        break;
                    }
                    case Tag_DynRecord: {
                        DynRecord* dr = static_cast<DynRecord*>(static_cast<void*>(scan));
                        checkOGChild(dr->fieldgroup, scan, "fieldgroup", 0);
                        for (u32 i = 0; i < h->size; i++)
                            checkOGChild(dr->values[i], scan, "dynrec", i);
                        break;
                    }
                    case Tag_StringSlice: {
                        ElmStringSlice* slc = static_cast<ElmStringSlice*>(static_cast<void*>(scan));
                        checkOGChild(slc->base, scan, "slice-base", 0);
                        break;
                    }
                    case Tag_StringUtf8View: {
                        ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(static_cast<void*>(scan));
                        checkOGChild(v->base, scan, "utf8view-base", 0);
                        break;
                    }
                    case Tag_ByteBufferSlice: {
                        ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(static_cast<void*>(scan));
                        checkOGChild(slc->base, scan, "byte-slice-base", 0);
                        break;
                    }
                    case Tag_StringRope: {
                        ElmStringRope* r = static_cast<ElmStringRope*>(static_cast<void*>(scan));
                        checkOGChild(r->left, scan, "rope-left", 0);
                        checkOGChild(r->right, scan, "rope-right", 0);
                        break;
                    }
                    default: break;
                }
                scan += obj_size;
                if (uniform_bitmap) scan = cell_start + ucell;
            }
        }
    }
#endif

#if ECO_HEAP_VALIDATE
    // (The block design audited block_end_of_objects_ here. Contiguous
    // to-space has no tail gaps to track, so there is nothing to audit.)

    // Paired with the assignment at the start of minorGC.
    in_minor_gc_ = false;

    // Stale-pointer diagnostic aid: poison the just-evacuated from-space's
    // allocated bytes BEFORE the swap, so any stale mutator HPointer that
    // still references those bytes lands on recognisable poison (or trips
    // the detector). See poisonOldFromSpaceUsedRegion for details.
    poisonOldFromSpaceUsedRegion();
#endif

    // Phase 5: Swap spaces by flipping which is from/to.
    from_is_low_ = !from_is_low_;

    // The from-space changed; refresh capacity-derived caches before deriving
    // the new bump_.end. (Both extents share one slice_.capacity, so this is
    // only load-bearing when checkAndGrow just changed it.)
    refreshCapacityCaches();

    // Resume allocation immediately after the survivors: the old to-space
    // (now from-space) holds them as one contiguous prefix (objects and, after
    // a parallel minor, Tag_Free fillers: HEAP_068).
    filler_bytes_ = filler_bytes_to_;
    bump_.ptr = copy_ptr_;
    bump_.end = computeAllocEnd();
    survivor_end_ = bump_.ptr;   // threaded-gc-05a IM7

    assert(bump_.ptr >= fromBase() && bump_.ptr <= bump_.end &&
           bump_.end <= fromBase() + from_capacity_bytes_ &&
           "post-swap bump state must lie inside the from-space extent");

#if P1_CENSUS_COMPILED
    // threaded-gc-04 P1 census: record this cycle's survivors (N) and a sample
    // of its promotions, now final after the drain (O).
    if (censusEnabled()) censusRecord(oldgen);
    p1::recordPromoted(&oldgen, promoted_buf_);
#endif

#if ENABLE_GC_STATS
    // Calculate what happened during this GC.
    size_t to_space_used = objectBytesAllocated();   // threaded-gc-06: object bytes
    size_t bytes_freed = from_space_used > to_space_used ? from_space_used - to_space_used : 0;
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
#if ENABLE_GC_PHASE_TIMERS
    if (T) {
        rec->tail_ns = static_cast<uint64_t>(GC_STATS_TIMER_ELAPSED_NS(t_loop_exit));
        rec->nursery_pause_ns = elapsed_ns;
        rec->survived = stats.objects_survived - surv0;
        rec->promoted = stats.objects_promoted - prom0;
        uint64_t survb1 = 0, promb1 = 0;
        for (int i = 0; i < GCStats::NUM_ALLOC_TAGS; ++i) {
            survb1 += stats.survived_bytes_by_tag[i];
            promb1 += stats.promoted_bytes_by_tag[i];
        }
        rec->survived_bytes = survb1 - survb0;
        rec->promoted_bytes = promb1 - promb0;
    }
#endif

    // The recorded pause is the WHOLE minor cycle, promotion allocation
    // included. Promotions are no longer timed individually (OldGenSpace
    // ::allocate skips the clock when g_in_minor_gc), so there is nothing
    // to subtract: the old "pure nursery-copy" figure was this pause minus
    // a quantity that was mostly the timer overhead itself.
    GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
#endif

    // Reclaim split-header bodies whose nursery header did not survive this
    // cycle. Skipped only while old-gen COMPACTION is in flight (deferred
    // until it completes); it runs normally during major-GC mark/sweep. See
    // OldGenSpace::sweepNurseryLargeBodies. NOTE: this runs after the minor
    // pause timer stops, so "Minor GC Timing" excludes it (threaded-gc-00
    // reports it in the pause and phase blocks).
#if ENABLE_GC_PHASE_TIMERS
    const uint64_t t_lb = T ? GCStats::nowSinceProcessStartNs() : 0;
#endif
    oldgen.sweepNurseryLargeBodies(minor_color_);
#if ECO_HEAP_VALIDATE
    validateYoungLarge(oldgen);   // V1
#endif
#if ENABLE_GC_PHASE_TIMERS
    if (T) {
        rec->large_body_sweep_ns = GCStats::nowSinceProcessStartNs() - t_lb;
#if defined(RUSAGE_THREAD)
        struct rusage ru;
        if (getrusage(RUSAGE_THREAD, &ru) == 0) {
            rec->minflt = static_cast<uint64_t>(ru.ru_minflt - flt_minor0);
            rec->majflt = static_cast<uint64_t>(ru.ru_majflt - flt_major0);
        }
#endif
    }
#endif

    // Clear the cross-allocator in-minor-GC flag last, after the timer
    // has captured the full minor pause but before control returns to
    // ThreadLocalHeap::minorGC (which may then fire majorGC).
    minor_gc_running_ = false;
    oldgen.setInMinorGC(false);
#if ECO_HEAP_VALIDATE
    // threaded-gc-01 Step 9: old-gen metadata validators (HEAP_048..052).
    oldgen.validateEveryNthMinor();
#endif
}

/**
 * Evacuates an object from from-space to to-space or old gen.
 *
 * Behavior:
 *   - If already forwarded: updates ptr to forwarding target and returns.
 *   - If not in from-space: returns (already evacuated or in old gen).
 *   - Otherwise: copies object to to-space (or promotes to old gen if aged),
 *     leaves forwarding pointer, and updates ptr to new location.
 *
 * Promotion: Objects with age >= promotion_age are copied to old gen and
 * added to promoted_objects for later scanning. Otherwise, they are copied
 * to to-space with age incremented.
 *
 * The original object is replaced with a forwarding pointer (Tag_Forward)
 * to prevent redundant copying if multiple pointers reference it.
 */
#if ECO_HEAP_VALIDATE
// U0.5 (borrow-inference Phase 0, plans/borrow-inference-phase0-measurement.md):
// the §16.2 header-preservation obligation. A minor-GC copy/promotion must carry
// the header word — INCLUDING `refcount` [16,30] — verbatim, editing ONLY `color`
// and `age` (D0.4: `pin` is memcpy-preserved, never GC-edited). If a future
// refactor replaces the `std::memcpy` with a field-wise header construction and
// forgets `refcount`, promoted survivors silently reset to refcount 0 =
// "untracked" and RC-1 dies for them. This assertion is that regression tripwire.
// Load-bearing once alloc-site count-init lands (B4); until then `refcount` is
// always 0 (unused) so it is trivially true.
static inline void assertHeaderPreservedAcrossCopy(const Header &src, const Header *dst) {
    assert(dst->tag == src.tag && dst->pin == src.pin &&
           dst->unboxed == src.unboxed && dst->refcount == src.refcount &&
           dst->builder == src.builder && dst->size == src.size &&
           "HEAP: minor-GC copy/promotion must preserve header modulo age/color (U0.5/§16.2)");
    // `color` and `age` are the ONLY fields GC legitimately edits on a copy (D0.4).
}
#endif

void NurserySpace::evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
#if ECO_HEAP_VALIDATE
    // Gate 4 tripwire: this boxed slot still holds free-region poison, so the
    // allocation site that produced the parent never zeroed it.
    if (nursery_poison_enabled()) {
        uint64_t raw_slot;
        memcpy(&raw_slot, &ptr, sizeof(raw_slot));
        if (raw_slot == ECO_POISON_WORD) {
            std::fprintf(stderr,
                "[gc-debug] POISON READ AS A BOXED SLOT: an allocation site "
                "left a payload word unzeroed.\n  slot raw=0x%016lx\n",
                (unsigned long)raw_slot);
            if (g_scan_parent) {
                std::fprintf(stderr,
                    "  parent obj=%p tag=%d size=%u\n",
                    g_scan_parent, g_scan_tag, (unsigned)g_scan_size);
            }
            std::fflush(stderr);
            // ECO_POISON_NONFATAL=1: census mode. Report each distinct
            // (parent tag, size) once, NULL the slot so the collector stays
            // sane, and carry on — one run then yields the full distribution
            // of classes that need their payload zeroed, instead of stopping
            // at the first one. Answers are meaningless in this mode; only
            // the census is.
            static const bool nonfatal =
                []{ const char* e = std::getenv("ECO_POISON_NONFATAL");
                    return e != nullptr && e[0] == '1'; }();
            if (nonfatal) {
                ptr.ptr = 0;
                ptr.ptr_ind = 0;
                return;
            }
            void* bt[40];
            int n = backtrace(bt, 40);
            backtrace_symbols_fd(bt, n, fileno(stderr));
            assert(false && "per-site zeroing missed a payload slot");
        }
    }
#endif
    // W2 item 20: boxed, non-null slots dominate the traced population, so
    // both early-outs are the unlikely side.
    if (__builtin_expect(ptr.ptr_ind != 0, 0))
        return;  // It's a constant.
    if (__builtin_expect(ptr.ptr == 0, 0))
        return;  // Null/zero HPointer (e.g. unfilled closure capture slot).

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

#if ECO_HEAP_VALIDATE
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif

    // Use cached allocator reference instead of repeated singleton lookup.
    // Non-heap addresses are legal since HEAP_036: permanent-space objects
    // (immortal, closed, GC-invisible) may be referenced from anywhere and
    // need no evacuation. The former hard bounds asserts survive as a
    // permanent-aware tripwire in validator builds (out-of-range garbage
    // still aborts there).
    char *heap_base = heap_base_;
    if (static_cast<char*>(obj) < heap_base ||
        static_cast<char*>(obj) >= heap_base + heap_reserved_) {
#if ECO_HEAP_VALIDATE
        if (!PermanentSpace::instance().contains(obj)) {
            std::fprintf(stderr,
                "[gc-debug] evacuate: pointer outside heap AND permanent "
                "space: %p\n", obj);
            std::abort();
        }
#endif
        return;
    }

    // W2 item 17: the from-space test comes FIRST, before the child header is
    // touched. It is pure arithmetic on a pointer we already hold, whereas the
    // header load is a cache-line miss on a different object — and in steady
    // state most edges point at to-space, old gen or permanent space, so most
    // of those loads were pure waste.
    //
    // The old ordering existed so old-gen -> from-space pointers get forwarded.
    // That still works: such a pointer IS in from-space, so it passes this test
    // and reaches the header load exactly as before. What changes is only that
    // pointers NOT in from-space skip the load, and those need no forwarding by
    // construction — a Tag_Forward is only ever installed on a from-space copy
    // (the three install sites all write into the object being evacuated OUT of
    // from-space). The assertion below pins that claim.
    if (__builtin_expect(!isInFromSpace(obj), 1)) {
        // threaded-gc-04b: a young large object is not in from-space but is
        // young; reach it (the pointer stays). A pure compare when empty.
        if (__builtin_expect(oldgen.mayBeYoungLarge(obj), 0))
            (void)reachYoungLarge(obj, oldgen, promoted_objects);
        return;
    }

    Header *hdr = getHeader(obj);

    // Assert tag is valid.
#if ECO_HEAP_VALIDATE
    if (hdr->tag > Tag_Forward) {
        uint64_t raw_hptr;
        memcpy(&raw_hptr, &ptr, sizeof(raw_hptr));
        std::fprintf(stderr,
            "[gc-debug] INVALID TAG in evacuate: obj=%p tag=%u (max=%u)\n"
            "  hptr raw=0x%016lx constant=%u\n"
            "  header raw=0x%016lx\n"
            "  obj in from-space=%d obj in nursery=%d\n",
            obj, (unsigned)hdr->tag, (unsigned)Tag_Forward,
            (unsigned long)raw_hptr, (unsigned)ptr.constant,
            (unsigned long)*(uint64_t*)((char*)obj - 8),
            (int)isInFromSpace(obj), (int)contains(obj));
        uint64_t* w = reinterpret_cast<uint64_t*>(obj);
        for (int i = -2; i < 6; i++) {
            std::fprintf(stderr, "  obj[%d] = 0x%016lx\n", i, w[i]);
        }
        std::fflush(stderr);
        void* bt[40];
        int n = backtrace(bt, 40);
        backtrace_symbols_fd(bt, n, fileno(stderr));
        if (g_scan_parent) {
            std::fprintf(stderr, "  SCAN PARENT: obj=%p tag=%d size=%u\n",
                         g_scan_parent, g_scan_tag, (unsigned)g_scan_size);
            uint64_t* pw = reinterpret_cast<uint64_t*>(g_scan_parent);
            for (int x = 0; x < (int)g_scan_size + 3 && x < 12; x++) {
                std::fprintf(stderr, "  parent[%d] = 0x%016lx\n", x, pw[x]);
            }
        }
    }
#endif
    assert(hdr->tag <= Tag_Forward && "Invalid tag value!");
    if (hdr->tag == Tag_Forward) {
        // Follow forward pointer and update ptr.
        Forward *fwd = static_cast<Forward *>(obj);
        char* tgt = decodeForwardPtr(fwd->header.forward_ptr, heap_base);
#if ECO_HEAP_VALIDATE
        // Class 3: forward-chain depth must be exactly 1. The target of a
        // Tag_Forward must itself be a real (not Tag_Forward) object —
        // otherwise we have a chain that indicates double evacuation or
        // corrupted forwarding.
        {
            assert(tgt >= heap_base &&
                   tgt < heap_base + heap_reserved_ &&
                   "forward target outside heap");
            Header* tgthdr = getHeader(tgt);
            if (tgthdr->tag == Tag_Forward) {
                std::fprintf(stderr,
                    "[gc-debug] FORWARD CHAIN DEPTH > 1: obj=%p -> %p (tag=%u)\n",
                    obj, (void*)tgt, (unsigned)tgthdr->tag);
                std::fflush(stderr);
                std::abort();
            }
        }
#endif
        ptr = Allocator::toPointerRaw(tgt);
        return;
    }

    // Second priority: Only evacuate if in from-space (not to-space!).
    // This prevents creating forwarding chains by re-evacuating already-moved objects.
    // W2 item 17: membership was already established above.
    assert(isInFromSpace(obj) && "evacuate: reached the copy path off from-space");

    // Now proceed with evacuation (object is in from-space and not yet forwarded).

    size_t size = getObjectSize(obj);
#if ECO_HEAP_VALIDATE
    // U0.5: snapshot the source header before any copy/mutation, so each copy
    // path can assert §16.2 header preservation at its tail.
    const Header srcHdr = *hdr;
#endif
    void *new_obj = nullptr;

    // Promote to old gen iff age has reached promotion_age AND neither pin
    // nor builder forbids it. `builder == 1` keeps in-construction objects
    // (e.g. JsArray result arrays under indexedMap/initialize) pinned to
    // the nursery so kernel slot writes never produce old-gen→young edges
    // (HEAP_BUILDER_001/002). `pin` is orthogonal: pin forbids relocation,
    // builder forbids promotion.
    if (shouldPromote(hdr)) {
        // Direct allocation to old gen (simplified - no TLAB buffering).
        new_obj = promoteAllocate(oldgen, size);
        assert(new_obj && "Failed to allocate in old gen during promotion");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        new_hdr->age = 0;
        // Defensive: major GC must not write into nursery headers (see
        // OldGenSpace::pushMarkRoot / incrementalMark), so the source cell's
        // color should already be White. Reset anyway to keep the promotion
        // path independent of that invariant.
        new_hdr->color = static_cast<u32>(Color::White);
#if ECO_HEAP_VALIDATE
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        // Split-header forms transfer body ownership from nursery_owned to
        // major-GC-managed on promotion (HEAP_026).
        if (new_hdr->tag == Tag_LargeStringHeader) {
            LargeStringHeader* h = static_cast<LargeStringHeader*>(new_obj);
            oldgen.promoteLargeHeader(h->body);
        } else if (new_hdr->tag == Tag_LargeByteHeader) {
            LargeByteHeader* h = static_cast<LargeByteHeader*>(new_obj);
            oldgen.promoteLargeHeader(h->body);
        }

        if (promoted_objects) {
            promoted_objects->push_back(new_obj);
        }

        GC_STATS_MINOR_INC_PROMOTED(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Copy to to_space if not promoted.
    if (!new_obj) {
#if ECO_HEAP_VALIDATE
        // Elm's immutability invariant: every child of a promoted object must be
        // at least as old as the parent, so it must also qualify for promotion.
        // If we reach here during phase 3 it means the invariant is violated.
        if (in_phase3_) {
            std::fprintf(stderr,
                "[gc-debug] INVARIANT VIOLATION: phase 3 child not old enough to promote!\n"
                "  child obj=%p tag=%u age=%u builder=%u promotion_age=%u\n",
                obj, (unsigned)hdr->tag, (unsigned)hdr->age,
                (unsigned)hdr->builder, (unsigned)promotion_age_);
            uint64_t raw_hptr;
            memcpy(&raw_hptr, &ptr, sizeof(raw_hptr));
            std::fprintf(stderr, "  child hptr raw=0x%016lx\n", (unsigned long)raw_hptr);
            if (g_scan_parent) {
                Header *phdr = getHeader(g_scan_parent);
                std::fprintf(stderr,
                    "  parent(old-gen) obj=%p tag=%u size=%u age=%u\n",
                    g_scan_parent, g_scan_tag, (unsigned)g_scan_size,
                    (unsigned)phdr->age);
                // Start at 0, NOT -1: an old-gen object can sit at the very
                // first address of a block, and reading the word before it
                // faults -- which is how this diagnostic used to kill the
                // process before printing the backtrace it exists to print.
                uint64_t *pw = reinterpret_cast<uint64_t*>(g_scan_parent);
                for (int x = 0; x < (int)g_scan_size + 2 && x < 10; x++) {
                    std::fprintf(stderr, "  parent[%d] = 0x%016lx\n", x, pw[x]);
                }
            }
            std::fflush(stderr);
            void *bt[40];
            int n = backtrace(bt, 40);
            backtrace_symbols_fd(bt, n, fileno(stderr));
            // A builder bit reaching this point means a kernel published a
            // builder object into a parent that was already old enough to
            // promote — HEAP_BUILDER_003 was violated.
            assert(!hdr->builder && "Elm invariant: builder object reached as child of promoted parent (HEAP_BUILDER_003)");
            assert(false && "Elm invariant: child of promoted object has age < promotion_age");
        }
#endif
        // Allocate in to_space.
        new_obj = copyToSpace(size);
        assert(new_obj && "Failed to copy to to-space during evacuation!");

        // Copy the object with its padding to maintain alignment.
        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        // HEAP_BUILDER_002: while builder == 1, age must remain 0. Skip the
        // increment so the invariant holds across minor cycles. Once the
        // kernel calls clear_builder, the cell ages from 0 like a fresh
        // allocation.
        if (!new_hdr->builder) {
            new_hdr->age++;
        }
        // Defensive (see promotion path above).
        new_hdr->color = static_cast<u32>(Color::White);
#if ECO_HEAP_VALIDATE
        assert(!(new_hdr->builder && new_hdr->age != 0) &&
               "HEAP_BUILDER_002: builder objects must have age == 0");
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        GC_STATS_MINOR_INC_SURVIVORS(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Leave forwarding pointer (as logical offset).
    // IMPORTANT: Set this BEFORE evacuating children to prevent infinite recursion.
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    fwd->header.forward_ptr = encodeForwardPtr(new_obj, heap_base);
    fwd->header.unused = 0;

    ptr = Allocator::toPointerRaw(new_obj);
}

// W2 item 21: evacuateUnboxable is now inline in NurserySpace.hpp.

/**
 * Evacuates a JIT root containing a raw 64-bit heap pointer.
 *
 * In JIT mode, globals store full 64-bit heap pointers rather than
 * HPointer-encoded values. This function handles evacuation for such roots.
 *
 * Embedded constants are identified by having zero in the lower 40 bits
 * and a value 1-7 in bits 40-43.
 */
void NurserySpace::evacuateJitPtr(uint64_t &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    // Skip embedded constants (ptr_ind set); only real pointers are evacuated.
    if (isConstantBits(ptr)) {
        return;
    }

    // Treat as raw pointer.
    void *obj = reinterpret_cast<void*>(ptr);
    if (!obj)
        return;

#if ECO_HEAP_VALIDATE
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif

    char *heap_base = heap_base_;

    // Validate pointer is within heap bounds.
    if (static_cast<char*>(obj) < heap_base ||
        static_cast<char*>(obj) >= heap_base + heap_reserved_) {
        // Pointer is outside the heap - could be a foreign pointer or error.
        // For now, skip it to avoid crashes.
        return;
    }

    Header *hdr = getHeader(obj);

    // Check for forwarding pointer.
    if (hdr->tag == Tag_Forward) {
        Forward *fwd = static_cast<Forward *>(obj);
        ptr = reinterpret_cast<uint64_t>(decodeForwardPtr(fwd->header.forward_ptr, heap_base));
        return;
    }

    // Only evacuate if in from-space; a young large object is reached in
    // place (threaded-gc-04b).
    if (!isInFromSpace(obj)) {
        if (oldgen.mayBeYoungLarge(obj))
            (void)reachYoungLarge(obj, oldgen, promoted_objects);
        return;
    }

    size_t size = getObjectSize(obj);
#if ECO_HEAP_VALIDATE
    // U0.5: header-preservation tripwire also covers this JIT-root copier.
    const Header srcHdr = *hdr;
#endif
    void *new_obj = nullptr;

    // Promote to old gen iff aged AND not pinned/builder (HEAP_BUILDER_001).
    if (shouldPromote(hdr)) {
        new_obj = promoteAllocate(oldgen, size);
        assert(new_obj && "Failed to allocate in old gen during promotion");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        new_hdr->age = 0;
#if ECO_HEAP_VALIDATE
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        if (promoted_objects) {
            promoted_objects->push_back(new_obj);
        }

        GC_STATS_MINOR_INC_PROMOTED(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Copy to to_space if not promoted.
    if (!new_obj) {
        new_obj = copyToSpace(size);
        assert(new_obj && "Failed to copy to to-space during evacuation!");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        // HEAP_BUILDER_002: don't age builders.
        if (!new_hdr->builder) {
            new_hdr->age++;
        }
#if ECO_HEAP_VALIDATE
        assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

        GC_STATS_MINOR_INC_SURVIVORS(stats, new_hdr->tag, size, new_hdr->size);
    }

    // Leave forwarding pointer.
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    fwd->header.forward_ptr = encodeForwardPtr(new_obj, heap_base);
    fwd->header.unused = 0;

    // Update the root with the new raw pointer.
    ptr = reinterpret_cast<uint64_t>(new_obj);
}

void NurserySpace::evacuateValueSlot(uint64_t &encoded, OldGenSpace &oldgen,
                                     std::vector<void*> *promoted_objects) {
    HPointer &hp = reinterpret_cast<HPointer&>(encoded);
    // Constants (constant != 0) are non-heap per HEAP_010/014.
    if (hp.ptr_ind != 0) {
        return;
    }
    evacuate(hp, oldgen, promoted_objects);
    // evacuate updates hp in place; encoded now holds relocated HPointer bits.
}

/**
 * Scans a heap object and evacuates all its children.
 *
 * Uses standard Cheney's BFS with a locality optimization for lists:
 *   - When use_hybrid_dfs is enabled and a Cons cell's tail is in from-space,
 *     the entire list spine is copied contiguously using two-pass copying.
 *   - Pass 1 (evacuateListSpine): Copies Cons cells by following tail pointers
 *   - Pass 2 (evacuateListHeads): Evacuates heads if any were boxed pointers
 *   - This creates contiguous list spines for better cache locality.
 *
 * All other types use standard BFS evacuation.
 */
#if ECO_HEAP_VALIDATE
// Class 2 bitmap-mismatch tripwire. Called per slot during scanObject for
// every bitmap-bearing container (Cons, Tuple2/3, Custom, Record, Closure,
// DynRecord). When the bitmap claims a slot is unboxed, the slot's bits
// must NOT decode to a live in-from-space-allocated address — that would
// mean the kind tag is lying and the GC will leave a real boxed pointer
// un-forwarded. Trip immediately with a backtrace naming the parent
// container so the mutator path that mis-tagged it can be identified.
//
// **Currently disabled.** Audit found a fundamental false-positive class:
// for any slot legitimately holding an Int (e.g. record field `c : Int`),
// random int32 values often have low-40-bit patterns that decode to
// addresses inside the live nursery. Filtering by target-header tag
// (must be > Tag_Char) reduces but does not eliminate the rate. Keeping
// the helper in source for future re-enable behind a stricter check
// (e.g. requiring the target object to also have plausible body bytes).
static inline void validateBitmapSlotKind(NurserySpace* /*self*/,
                                          char* /*heap_base*/,
                                          uintptr_t /*heap_reserved*/,
                                          Unboxable /*slot*/,
                                          bool /*is_boxed*/,
                                          void* /*parent*/,
                                          uint32_t /*parent_tag*/,
                                          const char* /*container*/,
                                          uint32_t /*idx*/) {
    return;  // disabled — see comment above
}

// Reference implementation, kept for documentation. Not invoked.
[[maybe_unused]] static inline void validateBitmapSlotKindStrict(
    NurserySpace* self,
    char* heap_base,
    uintptr_t heap_reserved,
    Unboxable slot,
    bool is_boxed,
    void* parent,
    uint32_t parent_tag,
    const char* container,
    uint32_t idx) {
    if (is_boxed) return;
    HPointer hp = slot.p;
    if (hp.ptr_ind != 0 || hp.ptr == 0) return;
    char* tgt = static_cast<char*>(hpToAddr(hp));
    if (tgt < heap_base || tgt >= heap_base + heap_reserved) return;
    if (!self->isInFromSpaceAllocatedRegion(tgt)) return;

    // Target-header sanity check: real HPointers point at an object whose
    // header has a plausible tag and non-zero size. We exclude Tag_Int /
    // Tag_Float / Tag_Char because primitive boxes are dense in the
    // nursery and an unboxed Int slot can easily land coincidentally on a
    // Tag_Int header — a confirmed false-positive case
    // (BytesRoundtripMixedRecord.elm Record[2] = `c: Int`). The remaining
    // tags (Cons, Tuple, Custom, Record, DynRecord, FieldGroup, Closure,
    // Process, Task, ByteBuffer, Array, StringRope/Slice, etc.) have
    // distinctive layouts that are much less likely to be hit by random
    // Int bit patterns, so a trip there is strong evidence of a real
    // wrong-bitmap bug.
    Header* tgt_hdr = getHeader(tgt);
    if (tgt_hdr->tag <= Tag_Char) return;          // primitive coincidence
    if (tgt_hdr->tag > Tag_Forward) return;
    if (tgt_hdr->size == 0) return;
    if (tgt_hdr->size > 0x10000) return;

    std::fprintf(stderr,
        "[gc-debug] %s KIND-MISMATCH at parent=%p tag=%u %s[%u]: "
        "slot tagged unboxed but bits decode to a live from-space "
        "target %p (tgt tag=%u size=%u) — element will not be "
        "forwarded.\n",
        container, parent, parent_tag, container, idx, tgt,
        (unsigned)tgt_hdr->tag, (unsigned)tgt_hdr->size);
    std::fflush(stderr);
    std::abort();
}
#endif

bool NurserySpace::reachYoungLarge(void* obj, OldGenSpace& oldgen,
                                   std::vector<void*>* promoted_objects) {
    OldGenSpace::LargeBodyMeta* m = oldgen.youngLargeMeta(obj);
    if (m == nullptr) return false;   // an old object inside the bounding box
#if ENABLE_GC_STATS
    stats.lp.ylos_reach_calls++;
#endif
    if (m->color == minor_color_) return true;   // already reached this minor
    m->color = minor_color_;
    Header* h = getHeader(obj);
    // shouldPromote minus pin: YLOS objects are pinned (never moved) but age.
    if (!h->builder && h->age >= promotion_age_) {
        oldgen.promoteYoungLarge(obj);   // invalidates m
        // Scanned as a promoted parent: by immutability its children are at
        // least as old, so they promote in this minor too (phase-3 rule).
        (promoted_objects ? *promoted_objects : young_large_scan_).push_back(obj);
        return true;
    }
#if ECO_HEAP_VALIDATE
    if (in_phase3_) {
        std::fprintf(stderr,
            "[gc-debug] INVARIANT VIOLATION: phase 3 child (young large object) "
            "not old enough to promote!\n  child obj=%p tag=%u age=%u builder=%u "
            "promotion_age=%u\n  parent(old-gen) obj=%p tag=%d\n",
            obj, (unsigned)h->tag, (unsigned)h->age, (unsigned)h->builder,
            (unsigned)promotion_age_, g_scan_parent, g_scan_tag);
        std::fflush(stderr);
        std::abort();
    }
#endif
    if (!h->builder) h->age++;
    young_large_scan_.push_back(obj);
    return true;
}

#if ECO_HEAP_VALIDATE
void NurserySpace::validateYoungLarge(OldGenSpace& oldgen) const {
    oldgen.forEachYoungLarge([&](void* obj, OldGenSpace::LargeBodyMeta&) {
        const Header* h = getHeader(obj);
        const char* p = static_cast<const char*>(obj);
        if (h->pin != 1 || (h->builder && h->age != 0) ||
            !oldgen.mayBeYoungLarge(p) || !oldgen.mayBeYoungLarge(p + getObjectSize(obj) - 1)) {
            std::fprintf(stderr, "[heap-validate] V1: YLOS object %p tag=%u pin=%u "
                         "builder=%u age=%u (or outside the bounding box)\n",
                         obj, (unsigned)h->tag, (unsigned)h->pin,
                         (unsigned)h->builder, (unsigned)h->age);
            std::fflush(stderr);
            std::abort();
        }
    });
}

void NurserySpace::validatePromotedHaveNoYoungChildren(
        OldGenSpace& oldgen, const std::vector<void*>& promoted) const {
    // HEAP_005 strict: after the drain, no object promoted this minor points
    // into the nursery or at a young large object.
    for (void* parent : promoted) {
        visitHeapChildren(parent, [&](HPointer& hp) {
            if (hp.ptr_ind != 0 || hp.ptr == 0) return;
            void* child = Allocator::fromPointerRaw(hp);
            if (child == nullptr) return;
            if (contains(child) || oldgen.isYoungLarge(child)) {
                std::fprintf(stderr, "[heap-validate] V2: promoted %p (tag=%u) has a "
                             "young child %p (%s)\n", parent,
                             (unsigned)getHeader(parent)->tag, child,
                             contains(child) ? "nursery" : "YLOS");
                std::fflush(stderr);
                std::abort();
            }
        });
    }
}
#endif

void NurserySpace::scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    Header *hdr = getHeader(obj);
#if ECO_HEAP_VALIDATE
    g_scan_parent = obj;
    g_scan_tag = hdr->tag;
    g_scan_size = hdr->size;
    char* hbase = Allocator::instance().getHeapBase();
    uintptr_t hres = Allocator::instance().getHeapReserved();
#endif
    // Process children based on tag.
    switch (hdr->tag) {
        // ====== Wide structures: BFS (inline evacuation) ======
        // These have multiple fields accessed together; keep siblings contiguous.

        case Tag_Tuple2: {
            Tuple2 *t = static_cast<Tuple2 *>(obj);
            bool ka = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
            bool kb = Elm::tupleFieldKind(hdr->unboxed, 1) == 0;
#if ECO_HEAP_VALIDATE
            validateBitmapSlotKind(this, hbase, hres, t->a, ka, obj, hdr->tag, "Tuple2", 0);
            validateBitmapSlotKind(this, hbase, hres, t->b, kb, obj, hdr->tag, "Tuple2", 1);
#endif
            evacuateUnboxable(t->a, ka, oldgen, promoted_objects);
            evacuateUnboxable(t->b, kb, oldgen, promoted_objects);
            break;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            bool ka = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
            bool kb = Elm::tupleFieldKind(hdr->unboxed, 1) == 0;
            bool kc = Elm::tupleFieldKind(hdr->unboxed, 2) == 0;
#if ECO_HEAP_VALIDATE
            validateBitmapSlotKind(this, hbase, hres, t->a, ka, obj, hdr->tag, "Tuple3", 0);
            validateBitmapSlotKind(this, hbase, hres, t->b, kb, obj, hdr->tag, "Tuple3", 1);
            validateBitmapSlotKind(this, hbase, hres, t->c, kc, obj, hdr->tag, "Tuple3", 2);
#endif
            evacuateUnboxable(t->a, ka, oldgen, promoted_objects);
            evacuateUnboxable(t->b, kb, oldgen, promoted_objects);
            evacuateUnboxable(t->c, kc, oldgen, promoted_objects);
            break;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 24; i++) {
                bool kib = Elm::fieldKind(c->unboxed, i) == 0;
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, c->values[i], kib, obj, hdr->tag, "Custom", i);
#endif
                evacuateUnboxable(c->values[i], kib, oldgen, promoted_objects);
            }
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 32; i++) {
                bool kib = Elm::fieldKind(r->unboxed, i) == 0;
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, r->values[i], kib, obj, hdr->tag, "Record", i);
#endif
                evacuateUnboxable(r->values[i], kib, oldgen, promoted_objects);
            }
            break;
        }
        case Tag_DynRecord: {
            DynRecord *dr = static_cast<DynRecord *>(obj);
            evacuate(dr->fieldgroup, oldgen, promoted_objects);
            for (u32 i = 0; i < hdr->size; i++) {
                evacuate(dr->values[i], oldgen, promoted_objects);
            }
            break;
        }
        case Tag_Closure: {
            // GC scans APPLIED slots only: `n_values`, not `hdr->size`
            // (== max_values, the capacity). Slots [n_values, max_values) are
            // unapplied argument space that no code reads, so tracing them
            // only exposed uninitialised memory — the reason the closure
            // payload had to be zeroed at all
            // (plans/nursery-per-site-zeroing.md).
            //
            // INVARIANT every writer of a value slot must keep: at any
            // safepoint, slots below n_values are written. closureCapture
            // stores then increments; papCreate codegen and eco_pap_extend
            // publish the count first and fill after, with no safepoint in
            // between (HEAP_034). eco_store_field* does NOT maintain it and
            // must never be used on a Closure — its Tag_Closure arm asserts.
            //
            // Getting this wrong is silent either way: too low drops a live
            // capture (use-after-free), too high traces an unwritten slot.
            // GCPressureTest's "eco_alloc_closure captures stay valid across
            // minor and major GCs" pins it.
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < cl->n_values; i++) {
                bool is_boxed = Elm::fieldKind(cl->unboxed, i) == 0;
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, cl->values[i], is_boxed, obj, hdr->tag, "Closure", i);
#endif
#if ECO_GC_DEBUG
                if (!is_boxed) {
                    // Warn if a "unboxed" slot has a value that looks like a nursery HPointer
                    uint64_t raw; memcpy(&raw, &cl->values[i], sizeof(raw));
                    HPointer hp; memcpy(&hp, &raw, sizeof(hp));
                    if (hp.ptr_ind == 0 && hp.ptr != 0 && raw == 0x20039995ULL)
                        std::fprintf(stderr, "[gc-debug] closure scan: FOUND 0x20039995 in UNBOXED slot! closure=%p idx=%u kind=%llu unboxed=0x%llx\n",
                                     obj, i, (unsigned long long)Elm::fieldKind(cl->unboxed, i),
                                     (unsigned long long)cl->unboxed);
                } else {
                    uint64_t raw; memcpy(&raw, &cl->values[i], sizeof(raw));
                    if (raw == 0x20039995ULL)
                        std::fprintf(stderr, "[gc-debug] closure scan: FOUND 0x20039995 in BOXED slot (should be evacuated): closure=%p idx=%u\n",
                                     obj, i);
                }
#endif
                evacuateUnboxable(cl->values[i], is_boxed, oldgen, promoted_objects);
            }
            break;
        }

        // ====== Deep structures: Two-pass spine copying for locality ======
        // Lists form chains; copying spine first keeps cells contiguous.

        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            bool head_boxed = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
#if ECO_HEAP_VALIDATE
            validateBitmapSlotKind(this, hbase, hres, c->head, head_boxed, obj, hdr->tag, "Cons", 0);
#endif

            if (use_hybrid_dfs_) {
                // Two-pass list copying for optimal locality:
                // Pass 1: Copy the tail spine contiguously
                // Pass 2: Copy heads (only if needed)

                // First evacuate this cell's head
                evacuateUnboxable(c->head, head_boxed, oldgen, promoted_objects);

                // Then copy the tail spine if it's in from-space
                if (c->tail.ptr_ind == 0) {
                    void* tail_obj = Allocator::fromPointerRaw(c->tail);
                    if (tail_obj && isInFromSpace(tail_obj)) {
                        bool needs_head_pass = false;
                        void* spine_start = evacuateListSpine(c->tail, oldgen, promoted_objects, needs_head_pass);

                        if (needs_head_pass && spine_start) {
                            evacuateListHeads(spine_start, oldgen, promoted_objects);
                        }
                    } else {
                        // Tail not in from-space - just update the pointer if forwarded
                        evacuate(c->tail, oldgen, promoted_objects);
                    }
                }
                // If tail is Nil constant, nothing to do
            } else {
                // Standard BFS: evacuate head and tail normally
                evacuateUnboxable(c->head, head_boxed, oldgen, promoted_objects);
                evacuate(c->tail, oldgen, promoted_objects);
            }
            break;
        }

        // Chunked-list forms (plans/chunked-list-representation.md §6):
        // a view traces its backing + spine continuation; a backing traces
        // its live element range [hd, capacity) only when the uniform kind
        // is boxed (scalar backings are pointer-free). Slots below hd are
        // uninitialized and must never be traced (v1: hd == 0 always).
        case Tag_ConsChunk: {
            ConsChunk *cv = static_cast<ConsChunk *>(obj);
            evacuate(cv->backing, oldgen, promoted_objects);
            evacuate(cv->next, oldgen, promoted_objects);
            break;
        }
        case Tag_ListBacking: {
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking *lb = static_cast<ListBacking *>(obj);
                for (u32 i = lb->hd; i < hdr->size; i++) {
                    evacuateUnboxable(lb->elems[i], /*is_boxed=*/true, oldgen,
                                      promoted_objects);
                }
            }
            break;
        }

        case Tag_Task: {
            Task *t = static_cast<Task *>(obj);
            // Skip t->value when it carries an unboxed primitive (slot 0 of
            // header.unboxed != 0); only the boxed-payload case has a child.
            if ((t->header.unboxed & 0x3) == 0) {
                evacuate(t->value.p, oldgen, promoted_objects);
            }
            evacuate(t->callback, oldgen, promoted_objects);
            evacuate(t->kill, oldgen, promoted_objects);
            evacuate(t->task, oldgen, promoted_objects);
            break;
        }

        case Tag_Process: {
            Process *p = static_cast<Process *>(obj);
            // Evacuate all children - no special handling needed.
            // Process subgraphs will be processed via Cheney's BFS.
            evacuate(p->root, oldgen, promoted_objects);
            evacuate(p->stack, oldgen, promoted_objects);
            evacuate(p->mailbox, oldgen, promoted_objects);
            break;
        }

        case Tag_Array: {
            ElmArray *arr = static_cast<ElmArray *>(obj);
            bool is_boxed = (arr->header.unboxed & 0x3) == 0;
#if ECO_HEAP_VALIDATE
            // Kind-mismatch tripwire: if the array claims unboxed but its
            // element bit-patterns decode to in-from-space-allocated
            // addresses (real live objects we're about to evacuate), the
            // kind tag is lying — those elements are real boxed pointers
            // that we're about to leave un-forwarded, which is exactly
            // the bug pattern that produces stale-pointer reads after the
            // GC swap. Trip immediately so the GC's caller-frame backtrace
            // names the mutator path that mis-tagged this array.
            if (!is_boxed) {
                char* hbase = Allocator::instance().getHeapBase();
                uintptr_t hres = Allocator::instance().getHeapReserved();
                for (u32 i = 0; i < arr->length; i++) {
                    HPointer hp = arr->elements[i].p;
                    if (hp.ptr_ind != 0 || hp.ptr == 0) continue;
                    char* tgt = static_cast<char*>(hpToAddr(hp));
                    if (tgt < hbase || tgt >= hbase + hres) continue;
                    if (!isInFromSpaceAllocatedRegion(tgt)) continue;
                    // Target-header sanity check (see validateBitmapSlotKind).
                    Header* tgt_hdr = getHeader(tgt);
                    if (tgt_hdr->tag <= Tag_Char) continue;
                    if (tgt_hdr->tag > Tag_Forward) continue;
                    if (tgt_hdr->size == 0 || tgt_hdr->size > 0x10000) continue;
                    fprintf(stderr,
                        "[gc-debug] ARRAY KIND-MISMATCH at arr=%p "
                        "elements[%u]: header.unboxed=%u (claims "
                        "unboxed) but element bits decode to a live "
                        "from-space target %p (tgt tag=%u size=%u) — "
                        "element will not be forwarded.\n",
                        (void*)arr, i,
                        (unsigned)arr->header.unboxed, tgt,
                        (unsigned)tgt_hdr->tag, (unsigned)tgt_hdr->size);
                    std::abort();
                }
            }
#endif
            for (u32 i = 0; i < arr->length; i++) {
                evacuateUnboxable(arr->elements[i], is_boxed, oldgen, promoted_objects);
            }
            break;
        }

        case Tag_StringSlice: {
            ElmStringSlice *slc = static_cast<ElmStringSlice *>(obj);
            evacuate(slc->base, oldgen, promoted_objects);
            break;
        }

        case Tag_StringUtf8View: {
            // Same shape as Tag_StringSlice: the only boxed field is `base`.
            ElmStringUtf8View *v = static_cast<ElmStringUtf8View *>(obj);
            evacuate(v->base, oldgen, promoted_objects);
            break;
        }

        case Tag_ByteBufferSlice: {
            ElmByteBufferSlice *slc = static_cast<ElmByteBufferSlice *>(obj);
            evacuate(slc->base, oldgen, promoted_objects);
            break;
        }

        case Tag_StringRope: {
            ElmStringRope *r = static_cast<ElmStringRope *>(obj);
            evacuate(r->left, oldgen, promoted_objects);
            evacuate(r->right, oldgen, promoted_objects);
            break;
        }

        case Tag_LargeStringHeader: {
            // Body lives in old gen and is never copied. Record that the
            // header is still live for this minor cycle, then return without
            // touching the body HPointer (it stays as-is).
            LargeStringHeader *h = static_cast<LargeStringHeader *>(obj);
            oldgen.markLargeBodySeen(h->body, minor_color_);
            break;
        }

        case Tag_LargeByteHeader: {
            LargeByteHeader *h = static_cast<LargeByteHeader *>(obj);
            oldgen.markLargeBodySeen(h->body, minor_color_);
            break;
        }

        // Tag_ByteBuffer: No pointers to scan (raw bytes only).
        // Tag_FieldGroup: No pointers to scan (field IDs only).
        // Tag_Int, Tag_Float, Tag_Char, Tag_String: No children.
        default:
            break;
    }
}

// ============================================================================
// List Locality Optimization - Two-Pass Spine Copying
// ============================================================================

/**
 * Copies a list spine (Cons cells only) contiguously in to-space.
 *
 * This function iterates through a linked list via tail pointers, copying
 * each Cons cell to create a contiguous spine in to-space. This provides
 * excellent cache locality when traversing the list later.
 *
 * The function handles:
 *   - Already-forwarded cells (follows the forward, stops copying)
 *   - Promotion to old gen (aged cells go to old gen)
 *   - Non-Cons tails (delegates to regular evacuate)
 *   - Nil terminator (stops iteration)
 *
 * @return Pointer to first copied Cons in to-space, or nullptr if list was empty
 */
void* NurserySpace::evacuateListSpine(HPointer &ptr, OldGenSpace &oldgen,
                                       std::vector<void*> *promoted_objects,
                                       bool &needs_head_pass) {
    needs_head_pass = false;

    if (ptr.ptr_ind != 0) {
        return nullptr;  // Nil or other constant - nothing to copy
    }

    void* first_copied = nullptr;
    void* prev_copied = nullptr;
    HPointer current = ptr;
    char* heap_base = heap_base_;

    while (current.ptr_ind == 0) {
        void* obj = Allocator::fromPointerRaw(current);
        if (!obj) break;

        Header* hdr = getHeader(obj);

        // Already forwarded? Update pointer and stop - rest of list already copied
        if (hdr->tag == Tag_Forward) {
            Forward* fwd = static_cast<Forward*>(obj);
            HPointer forwarded = Allocator::toPointerRaw(decodeForwardPtr(fwd->header.forward_ptr, heap_base));

            if (prev_copied) {
                // Link previous copied cell to the forwarded location
                Cons* prev_cons = static_cast<Cons*>(prev_copied);
                prev_cons->tail = forwarded;
            } else {
                // First cell was already forwarded
                ptr = forwarded;
            }
            break;
        }

        // Not in from-space? Stop spine copying
        if (!isInFromSpace(obj)) {
            break;
        }

        // Not a Cons? Delegate to regular evacuate and stop
        if (hdr->tag != Tag_Cons) {
            if (prev_copied) {
                Cons* prev_cons = static_cast<Cons*>(prev_copied);
                evacuate(prev_cons->tail, oldgen, promoted_objects);
            } else {
                evacuate(ptr, oldgen, promoted_objects);
            }
            break;
        }

        Cons* cons = static_cast<Cons*>(obj);

        // Check if head needs evacuation (boxed pointer, not a constant)
        bool head_is_boxed = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
        if (head_is_boxed && cons->head.p.ptr_ind == 0) {
            needs_head_pass = true;
        }

        // Save tail before we overwrite the object with forwarding pointer
        HPointer next_tail = cons->tail;

        // Copy this Cons cell (may go to old gen if aged)
        size_t size = sizeof(Cons);
#if ECO_HEAP_VALIDATE
        // U0.5: header-preservation tripwire also covers the list-spine copier.
        const Header srcHdr = *hdr;
#endif
        void* new_obj = nullptr;

        // HEAP_BUILDER_001/002: defensively respect pin/builder on Cons,
        // even though no current kernel marks Cons cells as builders.
        if (shouldPromote(hdr)) {
            // Promote to old gen
            new_obj = promoteAllocate(oldgen, size);
            assert(new_obj && "Failed to allocate in old gen during list spine copy");
            std::memcpy(new_obj, obj, size);

            Header* new_hdr = getHeader(new_obj);
            new_hdr->age = 0;
#if ECO_HEAP_VALIDATE
            assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif

            if (promoted_objects) {
                promoted_objects->push_back(new_obj);
            }
            GC_STATS_MINOR_INC_PROMOTED(stats, new_hdr->tag, size, new_hdr->size);
        } else {
            // Copy to to-space
            new_obj = copyToSpace(size);
            assert(new_obj && "Failed to copy Cons to to-space during spine copy");
            std::memcpy(new_obj, obj, size);

            Header* new_hdr = getHeader(new_obj);
            if (!new_hdr->builder) {
                new_hdr->age++;
            }
#if ECO_HEAP_VALIDATE
            assertHeaderPreservedAcrossCopy(srcHdr, new_hdr);
#endif
            GC_STATS_MINOR_INC_SURVIVORS(stats, new_hdr->tag, size, new_hdr->size);
        }

        // Leave forwarding pointer at original location
        Forward* fwd = static_cast<Forward*>(obj);
        fwd->header.tag = Tag_Forward;
        fwd->header.forward_ptr = encodeForwardPtr(new_obj, heap_base);
        fwd->header.unused = 0;

        // Link previous cell to this new cell
        if (prev_copied) {
            Cons* prev_cons = static_cast<Cons*>(prev_copied);
            prev_cons->tail = Allocator::toPointerRaw(new_obj);
        } else {
            // This is the first cell - update the original pointer
            first_copied = new_obj;
            ptr = Allocator::toPointerRaw(new_obj);
        }

        prev_copied = new_obj;
        current = next_tail;
    }

    // Handle Nil terminator or end of list - update last cell's tail
    if (prev_copied && current.ptr_ind != 0) {
        Cons* prev_cons = static_cast<Cons*>(prev_copied);
        prev_cons->tail = current;  // Keep the Nil constant
    }

    return first_copied;
}

/**
 * Evacuates heads of a previously-copied list spine.
 *
 * This is Pass 2 of the two-pass list copying algorithm. It iterates through
 * the already-copied spine in to-space and evacuates each head that contains
 * a boxed pointer (not unboxed, not a constant).
 *
 * This function should only be called if evacuateListSpine() set needs_head_pass
 * to true, indicating that at least one head requires evacuation.
 */
void NurserySpace::evacuateListHeads(void* first_cons, OldGenSpace &oldgen,
                                      std::vector<void*> *promoted_objects) {
    if (!first_cons) return;

    void* current = first_cons;

    while (current) {
        // Verify we're still looking at a Cons cell in to-space or old gen
        Header* hdr = getHeader(current);
        if (hdr->tag != Tag_Cons) break;

        Cons* cons = static_cast<Cons*>(current);

        // Evacuate head if it's boxed
        bool head_is_boxed = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
        if (head_is_boxed) {
            evacuate(cons->head.p, oldgen, promoted_objects);
        }

        // Move to next cell in spine
        if (cons->tail.ptr_ind != 0) {
            break;  // Reached Nil or other constant
        }

        void* next = Allocator::fromPointerRaw(cons->tail);

        // Stop if we've left the contiguous region we just copied
        // (tail might point to something copied earlier or in old gen)
        if (!next || (!isInToSpace(next) && !oldgen.contains(next))) {
            break;
        }

        current = next;
    }
}

// ============================================================================
// Ghost-data safety net: clear free to-space after minor GC
// ============================================================================

void NurserySpace::clearToSpaceFreeRegion() {
    // One contiguous extent: a single memset of everything past the last
    // survivor. Load-bearing (not debug-gated) — without it, stale bytes in
    // the free tail decode as out-of-range raw pointers at the next cycle
    // and abort in evacuate with "Pointer above heap end!".
    // PER-SITE ZEROING Phase 1 (plans/nursery-per-site-zeroing.md): the bulk
    // clear is OFF by default now that every allocation site zeroes its own
    // payload. Set ECO_NURSERY_BULK_CLEAR=1 to restore the old behaviour —
    // that is the bisection switch if Phase 1 turns out to be unsound.
    static const bool bulk_clear =
        []{ const char* e = std::getenv("ECO_NURSERY_BULK_CLEAR");
            return e != nullptr && e[0] == '1'; }();

#if ECO_HEAP_VALIDATE
    // ECO_NURSERY_POISON=1 is the zeroing TRIPWIRE
    // (plans/nursery-per-site-zeroing.md gate 4): it fills the free region
    // with 0xD8 instead of zero, so any payload word an allocation site
    // fails to write reads back as ECO_POISON_WORD and the boxed-slot check
    // in evacuate() aborts naming the parent. It costs a full bulk memset
    // per cycle, so it is a gate configuration and never a measured one.
    // Validator builds only — the check it feeds lives there too.
    const bool poison = nursery_poison_enabled();
    if (!bulk_clear && !poison) return;
#else
    if (!bulk_clear) return;
#endif

    char* base = toBase();
    if (!base) return;
    char* end = base + slice_.capacity;
    if (copy_ptr_ < end) {
#if ECO_HEAP_VALIDATE
        std::memset(copy_ptr_, poison ? 0xD8 : 0,
                    static_cast<size_t>(end - copy_ptr_));
#else
        std::memset(copy_ptr_, 0, static_cast<size_t>(end - copy_ptr_));
#endif
    }
}

#if ECO_HEAP_VALIDATE
// Stale-pointer diagnostic aid: fill the just-evacuated from-space's
// allocated region with a recognisable poison byte so that any stale
// HPointer the mutator still holds either:
//   (a) trips the per-resolve detector in `debugAssertValidNurseryPointer`
//       (which classifies post-swap to-space as "free"), OR
//   (b) on a path that bypasses Allocator::resolve, dereferences as an
//       obviously-bogus header (tag = 29, > Tag_Forward) and trips the
//       `assert(hdr->tag <= Tag_Forward)` in evacuate.
//
// The 0xDD byte was picked so the resulting HPointer has constant=13
// (out of range for valid embedded constants 0-7) which makes
// NurserySpace::evacuate treat it as a constant and bail early — i.e.
// the poison itself never trips the GC walker on its own, only the
// stale references TO it produce useful diagnostics.
//
// Cost: O(bytes used by the previous mutator phase) per minor GC. Run
// only on the from-space *allocated* prefix, not the entire nursery.
// Compiled in only under ECO_HEAP_VALIDATE — see HeapHelpers.hpp for why.
void NurserySpace::poisonOldFromSpaceUsedRegion() {
    constexpr uint8_t kPoisonByte = 0xDD;
    char* base = fromBase();
    if (!base || bump_.ptr <= base) return;
    std::memset(base, kPoisonByte, static_cast<size_t>(bump_.ptr - base));
}

// ============================================================================
// Class 3 — From-space pre-evacuation walk
// ============================================================================
//
// Walks every header in from-space's allocated prefix at the start of
// minorGC. For each cell, asserts:
//   - tag <= Tag_Forward
//   - obj + getObjectSize(obj) does not overshoot the allocated end
// Catches mutator-side header corruption that would otherwise propagate
// into to-space via memcpy in evacuate.
//
// Under the contiguous design this covers the ENTIRE allocated prefix. The
// block design could only walk the CURRENT block, because earlier blocks
// carried untracked tail gaps left by slow-path transitions — those gaps no
// longer exist, so this is a strictly stronger check (and a proportionally
// more expensive one: O(bytes allocated this cycle) per minor GC).
void NurserySpace::preEvacuationFromSpaceWalk() {
    char* base = fromBase();
    if (!base) return;

    char* end = bump_.ptr;
    char* scan = base;
    while (scan < end) {
        Header* h = getHeader(scan);
        if (h->tag > Tag_Forward) {
            std::fprintf(stderr,
                "[heap-validate] from-space pre-walk: invalid tag %u at "
                "obj=%p extent in [%p,%p), header_raw=0x%016lx\n",
                (unsigned)h->tag, (void*)scan,
                (void*)base, (void*)end,
                (unsigned long)*(uint64_t*)scan);
            std::fflush(stderr);
            std::abort();
        }
        size_t sz = getObjectSize(scan);
        if (sz == 0 || scan + sz > end) {
            std::fprintf(stderr,
                "[heap-validate] from-space pre-walk: bogus object size "
                "%zu at obj=%p tag=%u extent in [%p,%p)\n",
                sz, (void*)scan, (unsigned)h->tag,
                (void*)base, (void*)end);
            std::fflush(stderr);
            std::abort();
        }
        // Single-representation tripwire (HEAP_044,
        // plans/null-cons-hpointer-embedding.md §2.3): nullary ctors are
        // embedded null-cons constants; a heap Tag_Custom with 0 fields
        // means some construction path missed the embedding.
        if (h->tag == Tag_Custom && h->size == 0) {
            std::fprintf(stderr,
                "[heap-validate] from-space pre-walk: 0-field Tag_Custom at "
                "obj=%p (ctor=%u) — nullary ctors must be embedded null-cons "
                "constants (HEAP_044 §2.3)\n",
                (void*)scan,
                (unsigned)static_cast<Custom*>(static_cast<void*>(scan))->ctor);
            std::fflush(stderr);
            std::abort();
        }
        scan += sz;
    }
}

// ============================================================================
// Stale nursery pointer detection (validator-only)
// ============================================================================

bool NurserySpace::isInFromSpaceAllocatedRegion(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    if (rg_) return p >= rg_->eden_base && p < bump_.ptr;   // threaded-gc-07: eden
    return p >= fromBase() && p < bump_.ptr;
}

bool NurserySpace::isInToSpaceAllocatedRegion(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    if (rg_) return false;
    return p >= toBase() && p < copy_ptr_;
}

void NurserySpace::debugAssertValidNurseryPointer(void* ptr) const {
    assert(contains(ptr) && "debugAssertValidNurseryPointer called on non-nursery pointer");
    if (rg_) { regionAssertValidPointer(ptr); return; }   // threaded-gc-07 TV7

    bool ok = false;
    if (!in_minor_gc_) {
        // Mutator phase: all live nursery objects must be in the allocated
        // prefix of from-space.
        ok = isInFromSpaceAllocatedRegion(ptr);
    } else {
        // GC phase: pointers may refer to from-space (not yet evacuated)
        // or to-space (already evacuated), but never to free regions.
        ok = isInFromSpaceAllocatedRegion(ptr) || isInToSpaceAllocatedRegion(ptr);
    }

    if (!ok) {
        // Compute the HPointer value from the physical address
        char* heap_base = heap_base_;
        uint64_t hptr_val = (reinterpret_cast<char*>(ptr) - heap_base) / 8;
        std::fprintf(stderr, "[gc-debug] STALE hptr value=0x%lx (physical %p, heap_base=%p)\n",
                     (unsigned long)hptr_val, ptr, (void*)heap_base);

        char* fb = fromBase();
        char* tb = toBase();
        std::fprintf(stderr,
            "[gc-debug] STALE nursery pointer: ptr=%p in_minor_gc=%d from_is_low=%d\n"
            "  from_space: [%p,%p) alloc_ptr=%p%s\n"
            "  to_space:   [%p,%p) copy_ptr=%p%s\n"
            "  capacity=%zu KB/side slot=%zu\n",
            ptr, (int)in_minor_gc_, (int)from_is_low_,
            (void*)fb, (void*)(fb + from_capacity_bytes_), (void*)bump_.ptr,
            ((char*)ptr >= fb && (char*)ptr < fb + from_capacity_bytes_)
                ? "  <-- PTR IN FROM-SPACE" : "",
            (void*)tb, (void*)(tb + from_capacity_bytes_), (void*)copy_ptr_,
            ((char*)ptr >= tb && (char*)ptr < tb + from_capacity_bytes_)
                ? "  <-- PTR IN TO-SPACE" : "",
            from_capacity_bytes_ / 1024, slice_.slot);
        uint64_t* w = reinterpret_cast<uint64_t*>(ptr);
        std::fprintf(stderr, "  *ptr   = 0x%016lx\n", w[0]);
        std::fprintf(stderr, "  ptr[1] = 0x%016lx\n", w[1]);
        std::fprintf(stderr, "  ptr[2] = 0x%016lx\n", w[2]);
        std::fprintf(stderr, "  ptr[3] = 0x%016lx\n", w[3]);
        std::fflush(stderr);
        void* bt[40];
        int n = backtrace(bt, 40);
        backtrace_symbols_fd(bt, n, fileno(stderr));

        // Scan parent tracking: if we crashed during scanObject, show
        // which heap object was being scanned.
        if (g_scan_parent) {
            std::fprintf(stderr, "  SCAN PARENT: obj=%p tag=%d size=%u\n",
                         g_scan_parent, g_scan_tag, (unsigned)g_scan_size);
            uint64_t* pw = reinterpret_cast<uint64_t*>(g_scan_parent);
            for (int x = 0; x < (int)g_scan_size + 3 && x < 12; x++) {
                std::fprintf(stderr, "  parent[%d] = 0x%016lx\n", x, pw[x]);
            }
        }
    }
    assert(ok && "HPointer into nursery free region (stale pointer into unallocated space)");
}
#endif // ECO_HEAP_VALIDATE


#if P1_CENSUS_COMPILED
// ============================================================================
// threaded-gc-00 Step 11: survivor-write census
// ============================================================================
//
// Measures P1 (design_docs/parallel-gc.md §7.4.3): does anything write into
// an object after it has survived a minor GC? The in_phase3_ assertion only
// sees writes of YOUNGER values; a concurrent promoter would also lose writes
// of older ones, so this compares whole-object hashes instead. Aggregated
// process-wide and printed to stderr at exit. Never aborts, never repairs.

namespace {

struct SurvivorWriteCensus {
    std::mutex mu;
    uint64_t checked = 0;
    uint64_t mismatched = 0;
    uint64_t skipped_builder = 0;
    uint64_t base_mismatch = 0;
    uint64_t minors = 0;
    uint64_t ylos_checked = 0;      // threaded-gc-04b: young large objects
    uint64_t ylos_mismatched = 0;
    std::unordered_map<uint64_t, uint64_t> hits;          // packed key -> count
    std::unordered_map<uintptr_t, uint32_t> eval_id;      // EvaluatorDesc* -> id
    std::vector<uintptr_t> eval_fn;                       // id -> generic fn
    bool report_registered = false;
};

SurvivorWriteCensus& survivorCensus() {
    // Leaked on purpose: must outlive every nursery and still exist at atexit.
    static SurvivorWriteCensus* g = new SurvivorWriteCensus;
    return *g;
}

inline uint64_t censusKey(int tag, uint32_t sub, uint16_t word) {
    return (static_cast<uint64_t>(tag & 0xFF) << 48) |
           (static_cast<uint64_t>(sub) << 16) | word;
}

// threaded-gc-04: the header's GC-owned bits (color, age, builder) are masked.
inline uint64_t censusHash(const char* obj, size_t size) {
    return p1::hashObject(obj, size);
}

void survivorCensusReportLocked(SurvivorWriteCensus& g);

void survivorCensusReport() {
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    survivorCensusReportLocked(g);
}

void survivorCensusReportLocked(SurvivorWriteCensus& g) {
    std::fprintf(stderr,
        "[survivor-write-census] minors=%llu checked=%llu mismatched=%llu "
        "skipped_builder=%llu base_mismatch=%llu ylos_checked=%llu ylos_mismatched=%llu\n",
        (unsigned long long)g.minors, (unsigned long long)g.checked,
        (unsigned long long)g.mismatched, (unsigned long long)g.skipped_builder,
        (unsigned long long)g.base_mismatch, (unsigned long long)g.ylos_checked,
        (unsigned long long)g.ylos_mismatched);
    std::vector<std::pair<uint64_t, uint64_t>> rows(g.hits.begin(), g.hits.end());
    std::sort(rows.begin(), rows.end(),
              [](const auto& a, const auto& b) { return a.second > b.second; });
    const size_t n = std::min<size_t>(rows.size(), 50);
    for (size_t i = 0; i < n; ++i) {
        const uint64_t key = rows[i].first;
        const int tag = static_cast<int>(key >> 48);
        const uint32_t sub = static_cast<uint32_t>((key >> 16) & 0xFFFFFFFFu);
        const uint16_t word = static_cast<uint16_t>(key & 0xFFFF);
        char wbuf[16];
        if (word == 0xFFFF) std::snprintf(wbuf, sizeof wbuf, "?");
        else std::snprintf(wbuf, sizeof wbuf, "%u", (unsigned)word);
        if (tag == Tag_Closure && sub < g.eval_fn.size()) {
            const uintptr_t fn = g.eval_fn[sub];
            Dl_info info{};
            const char* sym = (fn && dladdr(reinterpret_cast<void*>(fn), &info) && info.dli_sname)
                                  ? info.dli_sname : "?";
            std::fprintf(stderr,
                "[survivor-write-census]   tag=%s evaluator-fn=0x%lx (%s) word=%s count=%llu\n",
                gcTagName(tag), (unsigned long)fn, sym, wbuf,
                (unsigned long long)rows[i].second);
        } else {
            std::fprintf(stderr,
                "[survivor-write-census]   tag=%s sub=%u word=%s count=%llu\n",
                gcTagName(tag), (unsigned)sub, wbuf, (unsigned long long)rows[i].second);
        }
    }
    std::fprintf(stderr, "[survivor-write-census] anchor eco_alloc_custom=0x%lx\n",
                 (unsigned long)reinterpret_cast<uintptr_t>(&eco_alloc_custom));
}

}  // namespace

bool NurserySpace::censusEnabled() const {
    if (census_forced_ >= 0) return census_forced_ == 1;
    return p1::mode() != 0;   // ECO_P1_CENSUS (ECO_SURVIVOR_WRITE_CENSUS alias)
}

void nurseryCensusReport(bool from_signal) {
    SurvivorWriteCensus& g = survivorCensus();
    if (from_signal) {
        if (!g.mu.try_lock()) return;
        survivorCensusReportLocked(g);
        g.mu.unlock();
        return;
    }
    std::lock_guard<std::mutex> lock(g.mu);
    survivorCensusReportLocked(g);
}

void NurserySpace::censusRecord(OldGenSpace& oldgen) {
    // threaded-gc-04b: YLOS objects that stay young are survivors too.
    census_ylos_.clear();
    census_ylos_epoch_ = oldgen.majorEpoch();
    for (void* obj : young_large_scan_) {
        if (getHeader(obj)->builder) continue;
        const size_t sz = getObjectSize(obj);
        census_ylos_.push_back(CensusYlosEntry{obj, static_cast<uint32_t>(sz),
                                               censusHash(static_cast<char*>(obj), sz)});
    }
    census_.clear();
    census_copy_.clear();
    char* base = fromBase();
    census_base_ = base;
    if (!base) return;
    char* end = bump_.ptr;
    for (char* scan = base; scan < end;) {
        const size_t sz = getObjectSize(scan);
        if (sz == 0 || scan + sz > end) break;   // pre-walk would have aborted
        const Header* h = getHeader(scan);
        if (h->tag == Tag_Free) { scan += sz; continue; }   // threaded-gc-06 filler
        CensusEntry e;
        e.offset_q = static_cast<uint32_t>((scan - base) >> 3);
        e.size = static_cast<uint32_t>(sz);
        e.hash = censusHash(scan, sz);
        e.builder = static_cast<uint8_t>(h->builder);
        e.copy_off = UINT32_MAX;
        if (sz <= 128 && !e.builder) {
            e.copy_off = static_cast<uint32_t>(census_copy_.size());
            for (size_t i = 0; i < sz / 8; ++i) {
                uint64_t w;
                std::memcpy(&w, scan + 8 * i, 8);
                census_copy_.push_back(w);
            }
        }
        census_.push_back(e);
        scan += sz;
    }
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    if (!g.report_registered && census_forced_ < 0) {
        g.report_registered = true;
        std::atexit(survivorCensusReport);
    }
}

void NurserySpace::censusCheck(OldGenSpace& oldgen) {
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    g.minors++;
    // threaded-gc-04b: YLOS survivors (still young, no major since).
    if (!census_ylos_.empty() && oldgen.majorEpoch() == census_ylos_epoch_) {
        for (const CensusYlosEntry& e : census_ylos_) {
            if (!oldgen.isYoungLarge(e.obj)) continue;
            g.checked++;
            g.ylos_checked++;
            if (censusHash(static_cast<char*>(e.obj), e.size) == e.hash) continue;
            g.mismatched++;
            g.ylos_mismatched++;
            const Header* vh = getHeader(e.obj);
            if (census_forced_ < 0 && p1::mode() == 2) {
                std::fprintf(stderr,
                    "[p1-census] VIOLATION (young large object): object %p tag=%s size=%u "
                    "was written after surviving a minor GC (HEAP_SNAPSHOT_001)\n",
                    e.obj, gcTagName(static_cast<int>(vh->tag)), e.size);
                std::fflush(stderr);
                std::abort();
            }
            g.hits[censusKey(static_cast<int>(vh->tag), 0, 0xFFFF)]++;
        }
    }
    census_ylos_.clear();
    if (census_.empty()) return;
    char* base = fromBase();
    if (census_base_ != base) {
        if (g.base_mismatch++ == 0) {
            std::fprintf(stderr, "[survivor-write-census] WARNING: from-space base moved "
                                 "between record and check; cycle skipped\n");
        }
        census_.clear();
        return;
    }
    for (const CensusEntry& e : census_) {
        char* obj = base + (static_cast<size_t>(e.offset_q) << 3);
        if (e.builder) { g.skipped_builder++; continue; }
        g.checked++;
        if (censusHash(obj, e.size) == e.hash) continue;
        g.mismatched++;
        if (census_forced_ < 0 && p1::mode() == 2) {
            const Header* vh = getHeader(obj);
            std::fprintf(stderr,
                "[p1-census] VIOLATION (nursery survivor): object %p tag=%s size=%u was "
                "written after surviving a minor GC (HEAP_SNAPSHOT_001)\n",
                static_cast<void*>(obj), gcTagName(static_cast<int>(vh->tag)), e.size);
            std::fflush(stderr);
            std::abort();
        }
        uint16_t word = 0xFFFF;
        if (e.copy_off != UINT32_MAX) {
            for (size_t i = 0; i < e.size / 8; ++i) {
                uint64_t w;
                std::memcpy(&w, obj + 8 * i, 8);
                if (w != census_copy_[e.copy_off + i]) { word = static_cast<uint16_t>(i); break; }
            }
        }
        const Header* h = getHeader(obj);
        const int tag = static_cast<int>(h->tag);
        uint32_t sub = 0;
        if (tag == Tag_Custom) {
            sub = static_cast<uint32_t>(static_cast<Custom*>(static_cast<void*>(obj))->ctor);
        } else if (tag == Tag_Closure) {
            const Closure* c = static_cast<const Closure*>(static_cast<void*>(obj));
            const uintptr_t desc = reinterpret_cast<uintptr_t>(c->evaluator);
            auto it = g.eval_id.find(desc);
            if (it == g.eval_id.end()) {
                const uint32_t id = static_cast<uint32_t>(g.eval_fn.size());
                g.eval_fn.push_back(c->evaluator
                    ? reinterpret_cast<uintptr_t>(c->evaluator->generic) : 0);
                it = g.eval_id.emplace(desc, id).first;
            }
            sub = it->second;
        }
        g.hits[censusKey(tag, sub, word)]++;
    }
    census_.clear();
}

// threaded-gc-07 TV11: detector N in region form. At minor end every object
// of the Fresh extent (survivor part and builder area), of the Tenuring
// extent's survivor part and of the Fresh generation's YLOS objects is
// hashed; tenureJoin re-hashes them BEFORE the heal (trap 9).
void NurserySpace::censusRecordRegion(OldGenSpace& oldgen) {
    RegionState& R = *rg_;
    R.census.clear();
    R.census_epoch = oldgen.majorEpoch();
    auto rec = [&](char* p, size_t sz) {
        const Header* h = getHeader(p);
        if (h->tag == Tag_Free) return;
        R.census.push_back(RegionState::CensusObj{p, static_cast<uint32_t>(sz),
                                                  censusHash(p, sz), static_cast<uint8_t>(h->builder)});
    };
    auto walk = [&](char* lo, char* hi) {
        for (char* p = lo; p < hi;) {
            const size_t sz = getObjectSize(p);
            if (sz == 0 || p + sz > hi) break;
            rec(p, sz);
            p += sz;
        }
    };
    for (int i = 0; i < 3; ++i) {
        region::Extent& X = R.x[i];
        if (X.state == region::XState::Fresh) {
            walk(X.base, X.surv_top);
            walk(X.bld_lo, X.bld_hi);
            for (void* y : X.ylos_gen) {
                if (oldgen.isYoungLarge(y)) rec(static_cast<char*>(y), getObjectSize(y));
            }
        } else if (X.state == region::XState::Tenuring) {
            walk(X.base, X.surv_top);
        }
    }
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    if (!g.report_registered && census_forced_ < 0) {
        g.report_registered = true;
        std::atexit(survivorCensusReport);
    }
}

void NurserySpace::censusCheckRegion(OldGenSpace& oldgen) {
    RegionState& R = *rg_;
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    g.minors++;
    const bool ylos_valid = oldgen.majorEpoch() == R.census_epoch;
    for (const RegionState::CensusObj& e : R.census) {
        if (e.builder) { g.skipped_builder++; continue; }
        if (!R.contains(e.obj)) {
            if (!ylos_valid || !oldgen.isYoungLarge(e.obj)) continue;   // a YLOS object freed / retired
            g.ylos_checked++;
        }
        g.checked++;
        if (censusHash(e.obj, e.size) == e.hash) continue;
        g.mismatched++;
        const Header* vh = getHeader(e.obj);
        if (census_forced_ < 0 && p1::mode() == 2) {
            std::fprintf(stderr,
                "[p1-census] VIOLATION (region survivor): object %p tag=%s size=%u was written "
                "after surviving a minor GC (HEAP_SNAPSHOT_001)\n",
                static_cast<void*>(e.obj), gcTagName(static_cast<int>(vh->tag)), e.size);
            std::fflush(stderr);
            std::abort();
        }
        g.hits[censusKey(static_cast<int>(vh->tag), 0, 0xFFFF)]++;
    }
    R.census.clear();
}

NurserySpaceTestAccess::CensusCounts NurserySpaceTestAccess::survivorWriteCensusCounts() {
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    return CensusCounts{g.checked, g.mismatched, g.skipped_builder, g.ylos_checked};
}

uint64_t NurserySpaceTestAccess::survivorWriteCensusHits(int tag, uint32_t sub, uint16_t word) {
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    auto it = g.hits.find(censusKey(tag, sub, word));
    return it == g.hits.end() ? 0 : it->second;
}

void NurserySpaceTestAccess::resetSurvivorWriteCensus() {
    SurvivorWriteCensus& g = survivorCensus();
    std::lock_guard<std::mutex> lock(g.mu);
    g.checked = g.mismatched = g.skipped_builder = g.base_mismatch = g.minors = 0;
    g.ylos_checked = g.ylos_mismatched = 0;
    g.hits.clear();
    g.eval_id.clear();
    g.eval_fn.clear();
}
#endif  // P1_CENSUS_COMPILED

} // namespace Elm
