// The serial semi-space minor collection, and the parts of `NurserySpace` both modes share: setup, the allocation
// limit and semi-space growth. The parallel copier, the region minor and the tenure job are in NurseryParallel.cpp,
// NurseryRegion.cpp and NurseryTenure.cpp.
//
// The serial minor is Cheney's algorithm. Copies are made by bumping `copy_ptr_` through to-space, and the copies
// between `scan_ptr_` and `copy_ptr_` are those not yet scanned, so to-space is its own queue of work. Two kinds of
// object a minor must also scan do not land in to-space: promoted copies, which are in the old generation, and young
// large objects, which never move. Each has its own queue (`promoted_buf_`, `young_large_scan_`). The drain takes
// from the three in turn until all are empty, because scanning an object of one kind can add to the others.
//
// The rest of the file is checks compiled only into validate builds, and the survivor-write census.

#include "NurserySpace.hpp"
#include "HeapChildWalk.hpp"
#if !defined(_WIN32)
#include <sys/resource.h>
#include <dlfcn.h>
#endif
#include "RuntimeExports.h"
#include <unordered_map>
#include <mutex>
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
// The validate-build diagnostics print a backtrace. Where <execinfo.h> is missing, as with musl, the three
// functions are no-ops.
#if defined(__has_include) && __has_include(<execinfo.h>)
#  include <execinfo.h>
#else
[[maybe_unused]] static inline int backtrace(void**, int) { return 0; }
[[maybe_unused]] static inline char** backtrace_symbols(void* const*, int) { return nullptr; }
[[maybe_unused]] static inline void backtrace_symbols_fd(void* const*, int, int) {}
#endif
#endif

#if ECO_HEAP_VALIDATE
// The object this thread is scanning, recorded so that the stale-pointer diagnostics can name the parent of a bad
// slot. Thread-local (HEAP_053) because each thread that scans records its own object.
thread_local void* g_scan_parent = nullptr;
thread_local int g_scan_tag = -1;
thread_local Elm::u32 g_scan_size = 0;
#endif

/// The word that a payload slot never written by its allocation site holds, once `ECO_NURSERY_POISON=1` has
/// filled free to-space with the byte 0xD8 (validate builds).
///
/// The byte is chosen so that the word is taken for a heap pointer. 0xD8 has bit 2, the `ptr_ind` bit of an
/// `HPointer`, clear, so `evacuate` follows the word and its check recognises it. A byte with bit 2 set, such as
/// 0xDD, would make the word an embedded constant, which `evacuate` skips, and the check would never fire.
static constexpr uint64_t ECO_POISON_WORD = 0xD8D8D8D8D8D8D8D8ull;

/// Returns whether `ECO_NURSERY_POISON` is set to a value starting with `1`. The environment is read on the first
/// call only.
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
}

NurserySpace::~NurserySpace() {
    // Freeing the slot lets another heap claim it and reuse its pages, which stay committed as the slot's retained
    // commit. Without this, every heap ever created would use up a slot for good.
    if (allocator_ && slice_.capacity != 0) {
        allocator_->releaseNurserySlicePair(slice_);
    }
    releaseRegions();   // the owner must already have run tenureTeardown
}

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

    size_t initial = config_->nurseryInitialPerSideBytes();
    if (initial > growth_ceiling_bytes_) initial = growth_ceiling_bytes_;

    if (config_->nursery_regions == 1) {
        // Region mode (HEAP_069): a slice set instead of the pair.
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
    filler_bytes_ = filler_bytes_to_ = 0;   // no survivor prefix yet
#if ENABLE_GC_STATS
    // Test switches read from the environment once per process, and applied to every nursery: ECO_TEST_PROMO_VIA_CTX=1
    // sets `test_serial_promo_via_ctx_`, and ECO_TEST_MINOR_ENGINE starting with `P` sets
    // `test_force_parallel_engine_`.
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
    thread_heap_ = nullptr;
    initializeFromConfig();
}

void NurserySpace::initialize(ThreadLocalHeap* heap, const HeapConfig* config) {
    config_ = config;
    thread_heap_ = heap;
    allocator_ = heap->getParent();
    initializeFromConfig();
}

void NurserySpace::reset(OldGenSpace &oldgen, const HeapConfig* new_config) {
    (void)oldgen;

    // Release the address space before `initializeFromConfig` acquires it again.
    if (slice_.capacity != 0) {
        allocator_->releaseNurserySlicePair(slice_);
        slice_ = NurserySlicePair{};
    }
    if (rg_) {
        tenureTeardown(oldgen);
        releaseRegions();
    }

    if (new_config) {
        config_ = new_config;
    }

    initializeFromConfig();

    root_set.reset();

    // The statistics are kept; `initializeFromConfig` refreshes only `nursery_size_bytes`.
}

void NurserySpace::updateBounds() {
    low_end_  = low_base_  ? low_base_  + slice_.capacity : nullptr;
    high_end_ = high_base_ ? high_base_ + slice_.capacity : nullptr;
}

void *NurserySpace::allocate(size_t size) {
    size = (size + 7) & ~7;

    // Only the slow path is timed (`allocateSlow`), so the fast path carries no clock reads.
    if (bump_.ptr + size <= bump_.end) {
        void* result = bump_.ptr;
        bump_.ptr += size;
        GC_STATS_MINOR_RECORD_ALLOC(stats, size);
        return result;
    }

    return allocateSlow(size);
}

void* NurserySpace::allocateSlow(size_t size) {
#if ENABLE_GC_STATS
    auto t0 = GC_STATS_TIMER_START();
#endif

    void* result = nullptr;

    // Reaching here means `ptr + size` passed `end`, which `computeAllocEnd` set either where a collection becomes
    // due or at the extent end. Either way only a collection can make room, so the answer is null.

#if ENABLE_GC_STATS
    if (!minor_gc_running_) {
        stats.total_nursery_alloc_in_mutator_ns +=
            GC_STATS_TIMER_ELAPSED_NS(t0);
    }
#endif

    (void)size;
    return result;
}

// Compared as integers: `end` below `ptr` is legal and means a collection is due, and `end - ptr` taken as a size
// would wrap round to a huge headroom.
bool NurserySpace::ensureHeadroom(size_t n) {
    const uintptr_t p = reinterpret_cast<uintptr_t>(bump_.ptr);
    const uintptr_t e = reinterpret_cast<uintptr_t>(bump_.end);
    return e >= p && e - p >= n;
}

void NurserySpace::failSoftUnclamp() {
    if (rg_) {   // eden may hold the capacity less S_m
        const size_t room = rg_->S_m < from_capacity_bytes_ ? from_capacity_bytes_ - rg_->S_m : 0;
        bump_.end = rg_->eden_base + room;
        if (bump_.end < bump_.ptr) bump_.end = bump_.ptr;
        return;
    }
    if (!fromBase()) return;
    bump_.end = fromBase() + from_capacity_bytes_;
}


size_t NurserySpace::bytesAllocated() const {
    if (!bump_.ptr) return 0;
    if (rg_) return rg_->S_m + static_cast<size_t>(bump_.ptr - rg_->eden_base);
    return static_cast<size_t>(bump_.ptr - fromBase());
}

void NurserySpace::refreshCapacityCaches() {
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
        // The survivors are counted as `S_m` object bytes. Eden gets what is left of the threshold, or of the
        // capacity once `S_m` has reached the threshold.
        const size_t sm = rg_->S_m;
        if (sm >= threshold_total_bytes_) {
            return rg_->eden_base + (sm < from_capacity_bytes_ ? from_capacity_bytes_ - sm : 0);
        }
        return rg_->eden_base + (threshold_total_bytes_ - sm);
    }
    char* base = fromBase();
    char* extent_end = base + from_capacity_bytes_;
    // Object bytes (HEAP_068): the fillers in the survivor prefix are not counted, so the limit lies
    // `filler_bytes_` further on.
    size_t already = static_cast<size_t>(bump_.ptr - base) - filler_bytes_;
    if (already >= threshold_total_bytes_) {
        return extent_end;
    }
    if (filler_bytes_ == 0) return base + threshold_total_bytes_;
    const size_t room = from_capacity_bytes_;
    if (threshold_total_bytes_ + filler_bytes_ > room) {
#if ENABLE_GC_STATS
        stats.pmin.alloc_end_capped++;   // the fillers pushed the limit past the extent end
#endif
        return extent_end;
    }
    return base + threshold_total_bytes_ + filler_bytes_;
}

void* NurserySpace::copyToSpace(size_t size) {
    if (copy_ptr_ + size <= copy_end_) {
        void* result = copy_ptr_;
        copy_ptr_ += size;
        return result;
    }

    assert(false && "To-space overflow - impossible with equal-sized extents");
    return nullptr;
}

bool NurserySpace::scanHasMore() const {
    return scan_ptr_ < copy_ptr_;
}

void NurserySpace::checkAndGrow() {
    if (rg_) { regionCheckAndGrow(); return; }
    // Occupancy in object bytes (HEAP_068): the fillers in to-space are excluded, so growth does not depend on how
    // many threads copied.
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

    // Grow by half, in whole multiples of alloc_buffer_size so that the block counts in the config keep their
    // meaning, and no further than the ceiling, so that the last step meets it exactly.
    const size_t quantum = config_->alloc_buffer_size;
    size_t delta = slice_.capacity / 2;
    delta -= delta % quantum;
    if (delta < quantum) delta = quantum;
    const size_t room = growth_ceiling_bytes_ - slice_.capacity;
    if (delta > room) delta = room;
    if (delta == 0) return;

    if (!allocator_->growNurserySlicePair(slice_, delta)) {
        // Commit refused: the capacity is unchanged and both extents stay equal.
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

// The order of a semi-space minor: the roots, the drain to a fixed point (see the file comment), growth, the swap of
// from-space and to-space, and the sweep of large bodies. When `chooseMinorWorkers` returns a thread count, the
// parallel copier runs the roots and the drain instead; what follows them is shared.
//
// A promoted object's children are normally old enough to be promoted with it, because Elm values are immutable.
// Kernel mutation and builders can break this. A release build then copies the young child into to-space, where the
// drain scans it. A validate build aborts: `in_phase3_` is set while a promoted object is scanned, and `evacuate`
// rejects a child too young to promote.
void NurserySpace::minorGC(OldGenSpace &oldgen, const StackMapRoots& stackmap_roots,
                           MinorGCRecord* rec) {
    ++minor_seq_;   // counted in both modes (HEAP_076)
    if (rg_) {   // region mode (HEAP_069)
        minorGCRegion(oldgen, stackmap_roots, rec);
        return;
    }
#if !ENABLE_GC_PHASE_TIMERS
    (void)rec;
#endif
    // Both flags stay set until the large-body sweep at the end is done.
    minor_gc_running_ = true;
    oldgen.setInMinorGC(true);

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
    // Checked before anything is copied, so that a corrupt header is reported where the mutator left it rather than
    // in a copy.
    preEvacuationFromSpaceWalk();
#endif
#if P1_CENSUS_COMPILED
    // The survivor-write census (see its section below): the survivors recorded at the end of the last minor are
    // hashed again before anything moves.
    // `onMinorStart` runs the old-generation detector (`P1Census.hpp`).
    if (censusEnabled()) censusCheck(oldgen);
    p1::onMinorStart(oldgen, ++census_minor_seq_);
#endif

#if ENABLE_GC_STATS
    size_t from_space_used = objectBytesAllocated();
    auto gc_start = GC_STATS_TIMER_START();
#endif

#if ENABLE_GC_PHASE_TIMERS
    // The phase timers read the clock only at phase boundaries, and nothing they measure feeds a collection
    // decision.
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
    filler_bytes_to_ = 0;   // only the parallel copier writes fillers

    // Kept across minors: `clear` keeps the capacity, so a minor that promotes many objects does not regrow the
    // buffer from nothing.
    promoted_buf_.clear();
    std::vector<void*>& promoted_objects = promoted_buf_;

    // The parallel copier (HEAP_067) when `chooseMinorWorkers` returns a thread count; otherwise the serial core
    // below.
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
    // `test_serial_promo_via_ctx_`: promote through worker 0 of a one-worker promotion context, which must place
    // every object where `OldGenSpace::allocate` would.
    promo_w0_ = nullptr;
    if (__builtin_expect(test_serial_promo_via_ctx_, 0) && oldgen.config_->old_gen_bitmap_alloc) {
        OldGenSpace::PromoCtx& ctx = oldgen.promoCtx();
        oldgen.beginParallelPromotion(ctx, 1);
        promo_w0_ = &ctx.w[0];
    }
#endif

    // The roots, in this order. Long-lived roots:
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1a: %zu long-lived roots\n", root_set.getRoots().size());
#endif
    for (HPointer *root: root_set.getRoots()) {
        evacuate(*root, oldgen, &promoted_objects);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_longlived_jit_ns += lap();
#endif

    // Roots found through the LLVM stack maps:
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

    // Compiled code's globals, which hold raw addresses rather than `HPointer`s:
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1c: %zu jit roots\n", root_set.getJitRoots().size());
#endif
    for (uint64_t *root: root_set.getJitRoots()) {
        evacuateJitPtr(*root, oldgen, &promoted_objects);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_longlived_jit_ns += lap();
#endif

    // Ranges of stack slots, of which the mask selects the roots:
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

    // Single stack slots:
#if ECO_GC_DEBUG
    std::fprintf(stderr, "[gc] phase 1e': %zu single stack roots\n", root_set.getSingleRoots().size());
#endif
    for (HPointer* slot : root_set.getSingleRoots()) {
        evacuate(*slot, oldgen, &promoted_objects);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_ranges_ns = lap();
#endif

    // External root scanners, last:
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

    // The drain: to-space, then the promoted queue, then the young large objects that stay young, and round again
    // while any of them has work.
    //
    // `in_phase3_` is set only while a promoted object is scanned. A young child of a to-space copy or of a young
    // large object is normal, so the check must be off for those.
    size_t promoted_idx = 0;
    size_t young_large_idx = 0;
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
            in_phase3_ = true;    // promoted parent: its children must be old enough to promote
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
    last_minor_promoted_ = promoted_objects.size();

    }   // ---- end of the serial core ----
#if ECO_HEAP_VALIDATE
    in_phase3_ = false;
    validatePromotedHaveNoYoungChildren(oldgen, promoted_buf_);   // V2
#endif
#if ENABLE_GC_PHASE_TIMERS
    // Promotion-path old-generation counters for this minor, read at drain exit, after the last promotion.
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

    // Growth first, so that the optional clearing of free to-space covers the grown extent.
    checkAndGrow();

    clearToSpaceFreeRegion();

#if ECO_HEAP_VALIDATE
    // Reports, without aborting, every boxed field of a to-space copy that still refers to a from-space object
    // whose header is not a forward word: a reference the minor failed to update.
    {
        {
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
                        validateExtKinds(c, "NurserySpace pre-walk");
                        for (u32 i = 0; i < h->size; i++) {   // tail slots: ext kind words
                            if (Elm::customSlotKind(c, i) == 0)
                                checkChild(c->values[i].p, "custom", i);
                        }
                        break;
                    }
                    case Tag_Record: {
                        Record* r = static_cast<Record*>(static_cast<void*>(scan));
                        validateExtKinds(r, "NurserySpace pre-walk");
                        for (u32 i = 0; i < h->size; i++) {
                            if (Elm::recordSlotKind(r, i) == 0)
                                checkChild(r->values[i].p, "record", i);
                        }
                        break;
                    }
                    case Tag_Closure: {
                        // n_values, matching the scan this is verifying.
                        Closure* cl = static_cast<Closure*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < cl->n_values; i++) {
                            if (Elm::closureSlotKind(cl, i) == 0)
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
                        // Only an array whose kind says boxed is walked. The kind-mismatch check in `scanObject`
                        // reports an unboxed array whose elements look like from-space objects.
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

    // Reports, without aborting, every boxed field of an old-generation object that still refers into from-space.
    {
        // The GC has not yet flipped from_is_low_, so from-space is still the
        // space we just evacuated FROM.  Objects there are garbage / stale.
        auto isInCurrentFromSpace = [this](void* p) -> bool {
            return isInFromSpace(p);
        };

        auto checkOGChild = [&](HPointer &hp, void* parent, const char* field, int idx) {
            if (hp.ptr_ind != 0 || hp.ptr == 0) return;
            // A young large object this minor did not reach is dead and is freed by the sweep at the end, so its
            // stale fields are not a defect.
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
            // Which cells hold objects. A raw LOS block holds header-less bodies and no references, so it is
            // skipped. In bitmap mode, and in an object LOS block, only the cells whose bit is set hold objects
            // (HEAP_024, HEAP_056): a dead cell keeps a stale header and a gap may have none.
            if (blk.los & kLosRaw) continue;
            const bool bitmap_walk =
                (oldgen.config_->old_gen_bitmap_alloc || blk.los != 0) && !blk.is_large;
            const bool uniform_bitmap = bitmap_walk && blk.size_class < oldgen.num_size_classes_;
            const size_t ucell = uniform_bitmap
                ? OldGenSpace::classToSize(blk.size_class) : 8;
            while (scan < end) {
                // Relaxed: background markers may be setting bits in the same words.
                if (bitmap_walk && !oldgen.isMarkedInBlockRelaxed(blk_id, scan)) {
                    scan += ucell;
                    continue;
                }
                char* const cell_start = scan;
                Header* h = getHeader(scan);
                // Only an all-zero word is an empty cell. `tag == 0` is not enough: that is `Tag_Int`, and stepping
                // over a boxed Int by 8 would land on its value word.
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
                    // Never a real object; step by 8 rather than loop for ever.
                    scan += 8;
                    continue;
                }
                switch (h->tag) {
                    case Tag_Closure: {
                        // n_values, matching the scan this is verifying.
                        Closure* cl = static_cast<Closure*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < cl->n_values; i++) {
                            if (Elm::closureSlotKind(cl, i) == 0)
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
                        for (u32 i = 0; i < h->size; i++) {   // tail slots: ext kind words
                            if (Elm::customSlotKind(c, i) == 0)
                                checkOGChild(c->values[i].p, scan, "custom", i);
                        }
                        break;
                    }
                    case Tag_Record: {
                        Record* r = static_cast<Record*>(static_cast<void*>(scan));
                        for (u32 i = 0; i < h->size; i++) {
                            if (Elm::recordSlotKind(r, i) == 0)
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

    // Paired with the assignment at the start of minorGC.
    in_minor_gc_ = false;

    // Done before the swap, while `fromBase` is still the space just emptied.
    poisonOldFromSpaceUsedRegion();
#endif

    // Swap from-space and to-space.
    from_is_low_ = !from_is_low_;

    // The caches derive from the from-space capacity, which `checkAndGrow` may just have changed.
    refreshCapacityCaches();

    // Resume allocation immediately after the survivors: the old to-space
    // (now from-space) holds them as one contiguous prefix (objects and, after
    // a parallel minor, Tag_Free fillers: HEAP_068).
    filler_bytes_ = filler_bytes_to_;
    bump_.ptr = copy_ptr_;
    bump_.end = computeAllocEnd();
    survivor_end_ = bump_.ptr;   // checked by forEachSurvivor (IM7)

    assert(bump_.ptr >= fromBase() && bump_.ptr <= bump_.end &&
           bump_.end <= fromBase() + from_capacity_bytes_ &&
           "post-swap bump state must lie inside the from-space extent");

#if P1_CENSUS_COMPILED
    // Detector N records this minor's survivors; the old-generation detector samples its promotions, whose contents
    // are now final.
    if (censusEnabled()) censusRecord(oldgen);
    p1::recordPromoted(&oldgen, promoted_buf_);
#endif

#if ENABLE_GC_STATS
    size_t to_space_used = objectBytesAllocated();
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

    // The recorded pause includes promotion allocation, which is not timed separately.
    GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
#endif

    // Frees the large bodies whose headers this minor did not reach; `OldGenSpace::sweepNurseryLargeBodies` decides
    // when to defer. It runs after the statistics' pause timer has stopped, so their minor pause excludes it; the
    // phase timers record it separately.
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

    // Cleared only now, after the large-body sweep, which is part of the minor.
    minor_gc_running_ = false;
    oldgen.setInMinorGC(false);
#if ECO_HEAP_VALIDATE
    // Old-generation metadata validators (HEAP_048 to HEAP_052).
    oldgen.validateEveryNthMinor();
#endif
}

#if ECO_HEAP_VALIDATE
// Asserts that `dst`, a minor's copy of an object whose header was `src`, kept every header field a copy must not
// change. A copy is a `memcpy`, after which a copier may edit only `age` and `color`; those two are not compared.
static inline void assertHeaderPreservedAcrossCopy(const Header &src, const Header *dst) {
    assert(dst->tag == src.tag && dst->pin == src.pin &&
           dst->unboxed == src.unboxed && dst->refcount == src.refcount &&
           dst->builder == src.builder && dst->size == src.size &&
           "HEAP: minor-GC copy/promotion must preserve header modulo age/color (U0.5/§16.2)");
}
#endif

void NurserySpace::evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
#if ECO_HEAP_VALIDATE
    // This boxed slot still holds the poison of free to-space, so the allocation site that made its parent never
    // wrote it.
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
            // ECO_POISON_NONFATAL=1 reports every such slot, sets it to null and carries on, so that one run lists
            // every parent left with an unwritten slot. The program's results are then meaningless.
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
    // Boxed, non-null slots are the common case, so both early returns are marked unlikely.
    if (__builtin_expect(ptr.ptr_ind != 0, 0))
        return;  // It's a constant.
    if (__builtin_expect(ptr.ptr == 0, 0))
        return;  // Null.

    void *obj = Allocator::fromPointerRaw(ptr);
    if (!obj)
        return;

#if ECO_HEAP_VALIDATE
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif

    // An address outside the heap is legal: a permanent-space object (HEAP_036) is never collected and needs no
    // evacuation. Validate builds abort on an address outside both.
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

    // The from-space test comes before the header load. It is arithmetic on an address already held, while the load
    // touches another object, and most references do not point into from-space. Skipping the load for them loses
    // nothing, because the semi-space copiers write forward words only over from-space objects.
    if (__builtin_expect(!isInFromSpace(obj), 1)) {
        // A young large object is outside from-space but young: it is reached in place and the reference stays.
        // `mayBeYoungLarge` is a range test.
        if (__builtin_expect(oldgen.mayBeYoungLarge(obj), 0))
            (void)reachYoungLarge(obj, oldgen, promoted_objects);
        return;
    }

    Header *hdr = getHeader(obj);

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
        // The target of a forward word must not be one itself: a chain means an object was evacuated twice.
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

    assert(isInFromSpace(obj) && "evacuate: reached the copy path off from-space");


    size_t size = getObjectSize(obj);
#if ECO_HEAP_VALIDATE
    // The source header, before the forward word overwrites it.
    const Header srcHdr = *hdr;
#endif
    void *new_obj = nullptr;

    // A builder is never promoted, so that kernel writes into it never make an old object refer to a young one
    // (HEAP_BUILDER_001/002). `pin` forbids moving an object, `builder` forbids promoting it.
    if (shouldPromote(hdr)) {
        new_obj = promoteAllocate(oldgen, size);
        assert(new_obj && "Failed to allocate in old gen during promotion");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        new_hdr->age = 0;
        // The source's colour should already be white; it is reset anyway so that the copy does not depend on
        // that.
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
        // `in_phase3_`: the parent is a promoted object, and its child is too young to promote.
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
                // From word 0, not -1: an old-generation object can start a block, and the word before it may not
                // be readable.
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
        new_obj = copyToSpace(size);
        assert(new_obj && "Failed to copy to to-space during evacuation!");

        std::memcpy(new_obj, obj, size);

        Header *new_hdr = getHeader(new_obj);
        // HEAP_BUILDER_002: a builder keeps age 0. Once its builder bit is cleared it ages like a fresh
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

    // Replace the original's header with a forward word, so that later references to it find the copy.
    Forward *fwd = static_cast<Forward *>(obj);
    fwd->header.tag = Tag_Forward;
    fwd->header.forward_ptr = encodeForwardPtr(new_obj, heap_base);
    fwd->header.unused = 0;

    ptr = Allocator::toPointerRaw(new_obj);
}


void NurserySpace::evacuateJitPtr(uint64_t &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects) {
    // Skip embedded constants (ptr_ind set); only real pointers are evacuated.
    if (isConstantBits(ptr)) {
        return;
    }

    void *obj = reinterpret_cast<void*>(ptr);
    if (!obj)
        return;

#if ECO_HEAP_VALIDATE
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif

    char *heap_base = heap_base_;

    // An address outside the heap is left as it is. Unlike `evacuate`, validate builds do not check it.
    if (static_cast<char*>(obj) < heap_base ||
        static_cast<char*>(obj) >= heap_base + heap_reserved_) {
        return;
    }

    Header *hdr = getHeader(obj);

    // Check for forwarding pointer.
    if (hdr->tag == Tag_Forward) {
        Forward *fwd = static_cast<Forward *>(obj);
        ptr = reinterpret_cast<uint64_t>(decodeForwardPtr(fwd->header.forward_ptr, heap_base));
        return;
    }

    // Only a from-space object is copied; a young large object is reached in place.
    if (!isInFromSpace(obj)) {
        if (oldgen.mayBeYoungLarge(obj))
            (void)reachYoungLarge(obj, oldgen, promoted_objects);
        return;
    }

    size_t size = getObjectSize(obj);
#if ECO_HEAP_VALIDATE
    const Header srcHdr = *hdr;
#endif
    void *new_obj = nullptr;

    // Promoted as `evacuate` promotes, except that this path neither resets the copy's colour nor transfers a large
    // body (`promoteLargeHeader`).
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
    // An embedded constant (`ptr_ind` set) is not a heap object.
    if (hp.ptr_ind != 0) {
        return;
    }
    evacuate(hp, oldgen, promoted_objects);
}

#if ECO_HEAP_VALIDATE
// Would check that a slot whose kind says unboxed does not hold a word that decodes to an object in the allocated
// part of from-space, which would mean the kind is wrong and the reference would not be updated. It is disabled and
// returns at once: an Int field's value can decode to such an address by chance, and filtering on the target's tag
// does not remove all of those false reports. `validateBitmapSlotKindStrict` is the check it would run.
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

// Aborts with a report if `slot`, field `idx` of `parent`, is unboxed but decodes to what looks like an object in the
// allocated part of from-space. Not called; `validateBitmapSlotKind` describes why.
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

    // Primitive boxes (Int, Float, Char) are dense in the nursery, so an Int field can land on one by chance and
    // those targets are ignored. Other tags have layouts a random Int is much less likely to hit.
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
        // Scanned as a promoted parent, or as a young one when the caller passes no promotion queue.
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
    switch (hdr->tag) {
        // Objects with several fields: each boxed field is evacuated in turn, so siblings are copied next to each
        // other.

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
            // Header-bitmap slots, then the tail (ext kind words, HEAP_019).
            Custom *c = static_cast<Custom *>(obj);
#if ECO_HEAP_VALIDATE
            validateExtKinds(obj, "NurserySpace::scanObject");
#endif
            auto slot = [&](u32 i, bool kib) {
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, c->values[i], kib, obj, hdr->tag, "Custom", i);
#endif
                evacuateUnboxable(c->values[i], kib, oldgen, promoted_objects);
            };
            const u32 n = hdr->size, h = n < Elm::CUSTOM_HDR_SLOTS ? n : Elm::CUSTOM_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) slot(i, Elm::kindInWord(c->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) slot(i, Elm::customSlotKind(c, i) == 0);
            break;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
#if ECO_HEAP_VALIDATE
            validateExtKinds(obj, "NurserySpace::scanObject");
#endif
            auto slot = [&](u32 i, bool kib) {
#if ECO_HEAP_VALIDATE
                validateBitmapSlotKind(this, hbase, hres, r->values[i], kib, obj, hdr->tag, "Record", i);
#endif
                evacuateUnboxable(r->values[i], kib, oldgen, promoted_objects);
            };
            const u32 n = hdr->size, h = n < Elm::RECORD_HDR_SLOTS ? n : Elm::RECORD_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) slot(i, Elm::kindInWord(r->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) slot(i, Elm::recordSlotKind(r, i) == 0);
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
            // Only the applied slots, below `n_values`, are traced. `hdr->size` also counts the unapplied capacity
            // and the extension kind words at the tail (HEAP_078), and the slots from `n_values` up may never have
            // been written. This relies on every writer of a closure keeping the slots below `n_values` written at
            // every safepoint (HEAP_034): too low a count loses a live capture, too high traces an unwritten slot.
            // `eco_store_field` and its variants assert rather than write into a closure.
            Closure *cl = static_cast<Closure *>(obj);
#if ECO_HEAP_VALIDATE
            if (!Elm::closureWellFormed(cl)) {
                std::fprintf(stderr, "[heap-validate] malformed closure %p: size=%u n_values=%u "
                                     "max_values=%u (needs size >= n + extWords(max, 20), "
                                     "no ext kind bits past max_values)\n",
                             obj, cl->header.size, unsigned(cl->n_values), unsigned(cl->max_values));
                std::fflush(stderr);
                std::abort();
            }
#endif
            for (u32 i = 0; i < cl->n_values; i++) {
                bool is_boxed = Elm::closureSlotKind(cl, i) == 0;
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
                                     obj, i, (unsigned long long)Elm::closureSlotKind(cl, i),
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

        // Lists. With `use_hybrid_dfs_` the tail spine is copied cell after cell (`evacuateListSpine`), so the copy
        // of a list is contiguous, and the heads after (`evacuateListHeads`).

        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            bool head_boxed = Elm::tupleFieldKind(hdr->unboxed, 0) == 0;
#if ECO_HEAP_VALIDATE
            validateBitmapSlotKind(this, hbase, hres, c->head, head_boxed, obj, hdr->tag, "Cons", 0);
#endif

            if (use_hybrid_dfs_) {

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
                        // Not in from-space: `evacuate` reaches a young large object and leaves anything else.
                        evacuate(c->tail, oldgen, promoted_objects);
                    }
                }
                // A constant tail (Nil) needs nothing.
            } else {
                // Standard BFS: evacuate head and tail normally
                evacuateUnboxable(c->head, head_boxed, oldgen, promoted_objects);
                evacuate(c->tail, oldgen, promoted_objects);
            }
            break;
        }

        // A chunk view refers to its backing and to the rest of the spine. A backing's elements are traced from
        // `hd` to its size, and only when their kind is boxed; the slots below `hd` may never have been written.
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
            evacuate(p->root, oldgen, promoted_objects);
            evacuate(p->stack, oldgen, promoted_objects);
            evacuate(p->mailbox, oldgen, promoted_objects);
            break;
        }

        case Tag_Array: {
            ElmArray *arr = static_cast<ElmArray *>(obj);
            bool is_boxed = (arr->header.unboxed & 0x3) == 0;
#if ECO_HEAP_VALIDATE
            // An array whose kind says unboxed but whose elements decode to plausible objects in the allocated part
            // of from-space has the wrong kind, and those references would not be updated. Aborts naming the
            // array.
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
        const Header srcHdr = *hdr;
#endif
        void* new_obj = nullptr;

        // HEAP_BUILDER_001/002: pin and builder are respected as for any object.
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

void NurserySpace::evacuateListHeads(void* first_cons, OldGenSpace &oldgen,
                                      std::vector<void*> *promoted_objects) {
    if (!first_cons) return;

    void* current = first_cons;

    while (current) {
        // Stop at anything that is not a list cell.
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
// Clearing free to-space
// ============================================================================

void NurserySpace::clearToSpaceFreeRegion() {
    // Off by default, because allocation sites are expected to write every word of what they allocate.
    // ECO_NURSERY_BULK_CLEAR=1 turns the clear on.
    static const bool bulk_clear =
        []{ const char* e = std::getenv("ECO_NURSERY_BULK_CLEAR");
            return e != nullptr && e[0] == '1'; }();

#if ECO_HEAP_VALIDATE
    // ECO_NURSERY_POISON=1 checks that expectation: the free part is filled with 0xD8 instead of zero, so a word an
    // allocation site leaves unwritten reads back as `ECO_POISON_WORD`, and `evacuate` aborts naming the parent. It
    // costs a fill of free to-space every minor.
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
// The byte 0xDD makes a stale reference fail loudly. As a header it has tag 29, past `Tag_Forward`, which the tag
// checks reject. As an `HPointer` it has bit 2 (`ptr_ind`) set, so a poisoned word is itself taken for an embedded
// constant and skipped. After the swap the poisoned space is to-space, which `debugAssertValidNurseryPointer`
// rejects outside a minor. The cost is a fill of what from-space held.
void NurserySpace::poisonOldFromSpaceUsedRegion() {
    constexpr uint8_t kPoisonByte = 0xDD;
    char* base = fromBase();
    if (!base || bump_.ptr <= base) return;
    std::memset(base, kPoisonByte, static_cast<size_t>(bump_.ptr - base));
}

// ============================================================================
// Validate-build checks of from-space and of nursery references
// ============================================================================
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
        // A nullary constructor is an embedded constant (HEAP_044), never a heap object.
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


bool NurserySpace::isInFromSpaceAllocatedRegion(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    if (rg_) return p >= rg_->eden_base && p < bump_.ptr;   // region mode: eden
    return p >= fromBase() && p < bump_.ptr;
}

bool NurserySpace::isInToSpaceAllocatedRegion(void* ptr) const {
    char* p = static_cast<char*>(ptr);
    if (rg_) return false;
    return p >= toBase() && p < copy_ptr_;
}

void NurserySpace::debugAssertValidNurseryPointer(void* ptr) const {
    assert(contains(ptr) && "debugAssertValidNurseryPointer called on non-nursery pointer");
    if (rg_) { regionAssertValidPointer(ptr); return; }   // TV7

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
        // The word offset from the heap base, for the report.
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
// The survivor-write census (detector N)
// ============================================================================
//
// At the end of each minor the survivors, apart from builders and free cells, are hashed, and at the start of the
// next each is hashed again; a changed hash is a write into an object that had already survived a minor. The hash
// leaves out the colour, age and builder bits of the header. The counts are kept for the whole process and, unless
// a test has forced the census on, printed at exit. In census mode 2, unless a test has forced the census on, the
// first change aborts.

namespace {

/// The census's process-wide counts and its table of changes by kind. Every field is guarded by `mu`.
struct SurvivorWriteCensus {
    std::mutex mu;
    uint64_t checked = 0;
    uint64_t mismatched = 0;
    uint64_t skipped_builder = 0;
    uint64_t base_mismatch = 0;     ///< Checks skipped because from-space had moved since the record.
    uint64_t minors = 0;
    uint64_t ylos_checked = 0;      ///< Of `checked`, the young large objects.
    uint64_t ylos_mismatched = 0;
    std::unordered_map<uint64_t, uint64_t> hits;          // packed key -> count
    std::unordered_map<uintptr_t, uint32_t> eval_id;      // EvaluatorDesc* -> id
    std::vector<uintptr_t> eval_fn;                       // id -> generic fn
    bool report_registered = false;
};

/// Returns the process's census, created on first use and never destroyed, so that it still exists for the exit
/// report.
SurvivorWriteCensus& survivorCensus() {
    static SurvivorWriteCensus* g = new SurvivorWriteCensus;
    return *g;
}

/// Packs `tag`, `sub` and `word` into one key of `hits`.
inline uint64_t censusKey(int tag, uint32_t sub, uint16_t word) {
    return (static_cast<uint64_t>(tag & 0xFF) << 48) |
           (static_cast<uint64_t>(sub) << 16) | word;
}

/// Returns the census hash of the object at `obj`: `p1::hashObject`, which ignores the header's colour, age and
/// builder bits.
inline uint64_t censusHash(const char* obj, size_t size) {
    return p1::hashObject(obj, size);
}

/// Prints the census's counts and its 50 most frequent changes to stderr. `g.mu` must be held.
void survivorCensusReportLocked(SurvivorWriteCensus& g);

/// Prints the census report, taking the lock. Registered with `atexit`.
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
#if defined(_WIN32)
            const char* sym = "?";   // no dladdr
#else
            Dl_info info{};
            const char* sym = (fn && dladdr(reinterpret_cast<void*>(fn), &info) && info.dli_sname)
                                  ? info.dli_sname : "?";
#endif
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
    return p1::mode() != 0;
}

void nurseryCensusForkPrepare() { survivorCensus().mu.lock(); }
void nurseryCensusForkParent() { survivorCensus().mu.unlock(); }
void nurseryCensusForkChild() { new (&survivorCensus().mu) std::mutex(); }

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
    // Young large objects that stay young are survivors too; they never move, so they are recorded by address.
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
        if (h->tag == Tag_Free) { scan += sz; continue; }   // a filler
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
    // Young large objects, unless a major collection has run since they were recorded.
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

// Records the survivor parts of the Young and Tenuring extents, the builder area of the age-1 Young extent, and the
// young large objects of each Young extent's generation that are still young.
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
    for (unsigned i = 0; i < R.n_surv; ++i) {
        region::Extent& X = R.x[i];
        if (X.state == region::XState::Young) {
            walk(X.base, X.surv_top);
            if (X.age == 1) walk(X.bld_lo, X.bld_hi);
            for (void* y : X.ylos_gen) {
                if (oldgen.youngLargeMember(y, X.gen_minor) != nullptr) rec(static_cast<char*>(y), getObjectSize(y));
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
