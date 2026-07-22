/**
 * ThreadLocalHeap Implementation.
 *
 * Implements the per-thread heap containing nursery, old gen, and GC stats.
 * Each thread has its own independent GC with no synchronization required.
 */

#include "ThreadLocalHeap.hpp"
#include "Allocator.hpp"
#include "StackMap.hpp"
#include "StackUnwind.hpp"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
// musl (Stage B static build) ships no <execinfo.h>/backtrace; stub them as
// no-ops so the debug paths compile. glibc keeps its real backtrace. See
// plans/static-link-eco-binary.md.
#if defined(__has_include) && __has_include(<execinfo.h>)
#  include <execinfo.h>
#else
[[maybe_unused]] static inline int backtrace(void**, int) { return 0; }
[[maybe_unused]] static inline char** backtrace_symbols(void* const*, int) { return nullptr; }
[[maybe_unused]] static inline void backtrace_symbols_fd(void* const*, int, int) {}
#endif
#if !defined(_WIN32)
#include <sys/resource.h>
#endif

namespace {

// Latched once per process. Reads ECO_GC_PHASE_PROFILE.
//   "0" / unset / empty -> disabled
//   any other value     -> enabled
inline bool gcPhaseProfileEnabled() {
    static const bool enabled = []{
        const char* e = std::getenv("ECO_GC_PHASE_PROFILE");
        if (e == nullptr || e[0] == '\0') return false;
        return !(e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

inline uint64_t nsBetween(
        const std::chrono::high_resolution_clock::time_point& a,
        const std::chrono::high_resolution_clock::time_point& b) {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(b - a).count());
}

}  // namespace

namespace Elm {

#if ENABLE_GC_STATS
// Bumps the per-thread counter that matches the trigger reason returned by
// OldGenSpace::evaluateMajorGCTrigger, so the printed GC summary attributes
// each major GC to a specific cause.
static inline void
recordMajorTriggerReason(GCStats& stats,
                         OldGenSpace::MajorGCTriggerReason reason) {
    switch (reason) {
        case OldGenSpace::MajorGCTriggerReason::Occupancy:
            stats.major_gc_occupancy_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::GlobalPressure:
            stats.major_gc_global_pressure_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::GarbageFraction:
            stats.major_gc_garbage_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::None:
            break;
    }
}
#endif

// Initializes a freshly-allocated object header for the given tag.
// `size` is the total aligned byte size returned by the allocator. For
// variable-size types, hdr->size is overwritten with the per-type element
// count; for fixed-size types it stores the byte size.
//
// The header is zeroed first; callers may set additional fields (e.g. pin,
// color) after this returns.
//
// Exposed (non-static) so the generic eco_alloc_with_roots helper in
// RuntimeExports.cpp can apply the same header-init policy on its fast
// path (allocateFast does not touch the header; only allocateSlow does
// via this function).
void initHeaderForTag(Header* hdr, Tag tag, size_t size) {
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = tag;

    switch (tag) {
        case Tag_String:
            hdr->size = (size - sizeof(ElmString)) / sizeof(u16);
            break;
        case Tag_StringSlice:
        case Tag_StringRope:
        case Tag_StringUtf8View:
            // Constructors (StringOps::makeSlice / makeRope / makeUtf8View) set
            // header.size explicitly to the logical UTF-16 length; nothing to
            // derive from byte size.
            hdr->size = 0;
            break;
        case Tag_StringUtf8Leaf:
            // Inline ASCII bytes: 1 unit per byte, so the logical length is the
            // payload byte count (mirrors Tag_String's u16 derivation).
            hdr->size = static_cast<u32>(size - sizeof(ElmStringUtf8Leaf));
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
            hdr->size = static_cast<u32>(size);
            break;
    }

    // Per-kind mutator allocation accounting. No-op when ENABLE_GC_STATS=0;
    // does a thread-local lookup + two array bumps when stats are on.
    GC_STATS_TLH_RECORD_ALLOC(size, tag);
}

ThreadLocalHeap::ThreadLocalHeap(Allocator* parent,
                                 char* nursery_base, size_t nursery_size,
                                 char* old_gen_base, size_t old_gen_initial_size,
                                 size_t old_gen_max_size,
                                 const HeapConfig* config)
    : parent_(parent)
    , config_(config)
    , nursery_()
    , old_gen_()
{
    assert(parent && "Parent allocator must not be null");
    assert(config && "Config must not be null");
    // Note: nursery_base and old_gen_base may be null if memory is allocated
    // on demand via acquireNurseryBlock/acquireAllocBuffer.

    // Initialize old gen with reference to parent Allocator. The initialize
    // call now pre-commits `initial_old_gen_size` as one contiguous region
    // and slices it into pages stored in `unassigned_blocks_` (BBoP).
    old_gen_.initialize(parent_, config_);

    // Initialize nursery with reference to this heap for promotion.
    nursery_.initialize(this, config_);
}

void* ThreadLocalHeap::allocate(size_t size, Tag tag) {
    // Align to 8 bytes up front so the threshold comparison is meaningful
    // (matches the alignment performed inside nursery/oldgen allocators).
    size = (size + 7) & ~static_cast<size_t>(7);

    // Large-object path: bypass the nursery and allocate directly in old
    // gen, marking the object pinned so the compactor will not move it.
    if (size >= config_->large_object_threshold) {
        return allocateLargePinned(size, tag);
    }

    // Fast path. NurserySpace::allocate's bump-pointer compares against
    // alloc_end_, which is pre-clamped at block-acquisition time to the
    // earlier of (block end, proactive-GC threshold trip point) by
    // computeAllocEndForBlock. So a single compare enforces both
    // block-fit and threshold-fit; no separate wouldExceedThreshold call
    // is needed on the hot path.
    void* obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // Slow path: nursery returned nullptr. This means either the threshold
    // tripped or the nursery is genuinely full. minorGC handles both —
    // after evacuation, the from-space allocation pointer resets and a
    // fresh alloc_end_ is computed.
    minorGC();
    obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // Nursery allocation still failed after a GC — fatal. Cannot fall back
    // to old-gen allocation: the object's fields would be filled in
    // afterwards, potentially creating old→young pointers that violate
    // the generational GC invariant.
    assert(false && "Failed to allocate to nursery, it is full.");
    return nullptr;
}

void* ThreadLocalHeap::allocateFast(size_t size) {
    // Pure bump-pointer: no GC, no threshold check, no header init.
    // Returns nullptr when nursery has insufficient space.
    size = (size + 7) & ~static_cast<size_t>(7);
    return nursery_.allocate(size);
}

void* ThreadLocalHeap::allocateSlow(size_t size, Tag tag) {
    // Slow path: GC then allocate. Called after allocateFast returns nullptr.
    size = (size + 7) & ~static_cast<size_t>(7);

    if (size >= config_->large_object_threshold) {
        return allocateLargePinned(size, tag);
    }

    minorGC();

    void* obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    assert(false && "Failed to allocate after GC in slow path.");
    return nullptr;
}

void* ThreadLocalHeap::allocateSlowRaw(size_t size) {
    // Slow path for the compiled-code inline nursery bump
    // (eco_alloc_inline_slow, HEAP_034): minor GC + retry, but NO header
    // init — the caller composes and stores the full header word itself
    // before its next safepoint. Inline-alloc sizes are compile-time
    // constants far below the large-object threshold, so assert rather than
    // route to old gen (the caller's fresh-object stores assume a nursery
    // placement; old-gen placement would create unremembered old→young
    // edges).
    size = (size + 7) & ~static_cast<size_t>(7);
    assert(size < config_->large_object_threshold &&
           "allocateSlowRaw: inline-alloc size must be below the LOT threshold");

    minorGC();

    void* obj = nursery_.allocate(size);
    if (obj) {
        return obj;
    }

    assert(false && "Failed to allocate after GC in slow path (raw).");
    return nullptr;
}

void* ThreadLocalHeap::allocateRegionSlow(size_t total) {
    // Slow path for contiguous region allocation. May GC.
    // Caller handles header init for each sub-object.
    total = (total + 7) & ~static_cast<size_t>(7);

    if (total >= config_->large_object_threshold) {
        // Large regions go to old gen directly.
        void* obj = old_gen_.allocate(total);
        if (!obj) {
            assert(false && "Failed to allocate large region in old gen.");
            return nullptr;
        }
        GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats_, total);
        return obj;
    }

    if (total >= config_->large_object_threshold) {
        // Large regions go to old gen directly.
        void* obj = old_gen_.allocate(total);
        if (!obj) {
#if ENABLE_GC_STATS
            stats_.major_gc_alloc_failure_triggers++;
#endif
            majorGC();
            obj = old_gen_.allocate(total);
        }
        if (!obj) {
            assert(false && "Failed to allocate large region in old gen.");
            return nullptr;
        }
        GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats_, total);
        return obj;
    }

    minorGC();

    void* obj = nursery_.allocate(total);
    if (obj) return obj;

    assert(false && "Failed to allocate region after GC.");
    return nullptr;
}

void* ThreadLocalHeap::allocateLargePinned(size_t size, Tag tag) {
    // size is already 8-byte aligned by the caller.
    void* obj = old_gen_.allocate(size);
    if (!obj) {
        // Try once after a major GC to reclaim space.
#if ENABLE_GC_STATS
        stats_.major_gc_alloc_failure_triggers++;
#endif
        majorGC();
        obj = old_gen_.allocate(size);
    }
    if (!obj) {
        assert(false && "Failed to allocate large pinned object in old gen.");
        return nullptr;
    }
    GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats_, size);

    Header* hdr = getHeader(obj);
    // OldGenSpace::allocate already memset/colored the header. Re-init for
    // tag (this preserves the zero color and overwrites tag/size fields),
    // then set pin LAST so it survives any prior writes. Color was set by
    // OldGenSpace::allocate based on GC phase; preserve it.
    u32 saved_color = hdr->color;
    initHeaderForTag(hdr, tag, size);
    hdr->color = saved_color;
    hdr->pin = 1;
    return obj;
}

HPointer ThreadLocalHeap::allocLargeString(const u16* chars, size_t length) {
    // The caller (HeapHelpers::allocString) guarantees length > 0 and that
    // the total payload meets the split threshold; this function never
    // returns the empty-string constant.
    //
    // Ordering note (HEAP_026): allocate the nursery header FIRST, then the
    // old-gen body. The nursery allocate() may trigger a minor GC; if we
    // reversed this order, the body would be registered in
    // nursery_owned_bodies_ with no header pointing at it, and the
    // sweepNurseryLargeBodies at the end of that minor GC would free the
    // body before we could wire it in (the body's color would be the
    // pre-flip minor color; the header that would have refreshed it via
    // markLargeBodySeen does not yet exist).
    const size_t header_size = sizeof(LargeStringHeader);
    void* header_obj = allocate(header_size, Tag_LargeStringHeader);
    assert(header_obj && "Failed to allocate large string header in nursery");
    LargeStringHeader* h = static_cast<LargeStringHeader*>(header_obj);
    h->header.size = static_cast<u32>(length);
    // Body field is null until step 4. A GC that visits the header here
    // would see hp.ptr == 0 and skip the body slot via the markHPointer /
    // markLargeBodySeen null guards.
    h->body = hpFromBits(0);  // null HPointer (all fields zero)
    HPointer header_hp = parent_->wrap(header_obj);

    // Step 3: allocate body in old gen. old_gen_.allocate does NOT trigger a
    // minor GC (only the nursery allocate above does), so header_obj stays
    // put through this call. registerLargeBody runs with the post-step-1
    // minor_color_, which matches the value the next minor GC's sweep will
    // compare against.
    const size_t body_size =
        (sizeof(ElmString) + length * sizeof(u16) + 7) & ~static_cast<size_t>(7);
    void* body =
        old_gen_.allocateLargeBody(body_size, length, Tag_String,
                                   nursery_.minor_color_);
    assert(body && "Failed to allocate large string body in old gen");

    if (chars && length > 0) {
        ElmString* leaf = static_cast<ElmString*>(body);
        std::memcpy(leaf->chars, chars, length * sizeof(u16));
    }

    // Step 4: wire body into header. No GC fires between body registration
    // and this assignment, so the next minor GC scans an already-complete
    // header → body link.
    h->body = parent_->wrap(body);
    return header_hp;
}

HPointer ThreadLocalHeap::allocLargeByteBuffer(const u8* data, size_t length) {
    // Same ordering rationale as allocLargeString — see comment there.
    const size_t header_size = sizeof(LargeByteHeader);
    void* header_obj = allocate(header_size, Tag_LargeByteHeader);
    assert(header_obj && "Failed to allocate large byte buffer header in nursery");
    LargeByteHeader* h = static_cast<LargeByteHeader*>(header_obj);
    h->header.size = static_cast<u32>(length);
    h->body = hpFromBits(0);  // null HPointer (all fields zero)
    HPointer header_hp = parent_->wrap(header_obj);

    const size_t body_size =
        (sizeof(ByteBuffer) + length + 7) & ~static_cast<size_t>(7);
    void* body =
        old_gen_.allocateLargeBody(body_size, length, Tag_ByteBuffer,
                                   nursery_.minor_color_);
    assert(body && "Failed to allocate large byte buffer body in old gen");

    ByteBuffer* buf = static_cast<ByteBuffer*>(body);
    if (data && length > 0) {
        std::memcpy(buf->bytes, data, length);
    } else if (length > 0) {
        std::memset(buf->bytes, 0, length);
    }

    h->body = parent_->wrap(body);
    return header_hp;
}

void* ThreadLocalHeap::allocatePermanent(size_t size, Tag tag) {
    // Allocate directly in old generation - for permanent objects like string literals.
    size = (size + 7) & ~static_cast<size_t>(7);
    void* obj = old_gen_.allocate(size);
    if (obj) {
        GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats_, size);
        Header* hdr = getHeader(obj);
        u32 saved_color = hdr->color;
        initHeaderForTag(hdr, tag, size);
        hdr->color = saved_color;
        return obj;
    }

    assert(false && "Failed to allocate in old gen.");
    return nullptr;
}

bool ThreadLocalHeap::shouldCollectAtSafepoint() const {
    if (force_gc_)
        return true;
    if (isNurseryNearFull(config_->nursery_gc_threshold))
        return true;
    // 75% old-gen occupancy trigger: stop at the next safepoint so we can
    // run a major GC before this thread's old gen is exhausted.
    return old_gen_.shouldTriggerMajorGC();
}

void ThreadLocalHeap::collectAtSafepoint() {
    force_gc_ = false;
    // Minor GC is now threshold-gated: without this, a forced safepoint
    // (e.g. from a single `force_gc_ = true`) could run a minor GC when
    // the nursery is near-empty, which is wasted work. `minorGC()` itself
    // chains into a major GC when the 75% old-gen trigger is live, so
    // covering the non-nursery-full case is enough here.
    if (isNurseryNearFull(config_->nursery_gc_threshold)) {
        minorGC();
    } else {
        const auto reason = old_gen_.evaluateMajorGCTrigger();
        if (reason != OldGenSpace::MajorGCTriggerReason::None) {
#if ENABLE_GC_STATS
            recordMajorTriggerReason(stats_, reason);
#endif
            majorGC();
        }
    }
}

void ThreadLocalHeap::minorGC() {
    if (Allocator::heapTraceEnabled()) {
        parent_->dumpHeapState("minorGC begin");
    }
    collectStackRootsFromStackMap();
    nursery_.minorGC(old_gen_, stack_map_roots_);
    if (Allocator::heapTraceEnabled()) {
        parent_->dumpHeapState("minorGC end");
    }

    // 75% occupancy trigger: minor GC promotes into old gen, so allocated
    // bytes can cross the initiating threshold here. Safepoint polling is
    // not dense in MLIR-generated code, so we also check at the end of
    // every minor GC to avoid filling the old gen before the next
    // safepoint fires.
    const auto reason = old_gen_.evaluateMajorGCTrigger();
    if (reason != OldGenSpace::MajorGCTriggerReason::None) {
#if ENABLE_GC_STATS
        recordMajorTriggerReason(stats_, reason);
#endif
        majorGC();
    }
}

void ThreadLocalHeap::majorGC() {
    const bool profile_phases = gcPhaseProfileEnabled();

    // Dump sizes at major GC so the reproduction log makes it easy to see
    // whether a major GC actually ran before the old-gen assert fired. The
    // dump is a compile-time no-op unless the build was configured with
    // `-DECO_HEAP_TRACE=ON` (the trace must then still be enabled at runtime
    // via the `ECO_HEAP_TRACE` env var).
    parent_->dumpHeapState("majorGC begin");

#if ENABLE_GC_STATS
    auto gc_start = GC_STATS_TIMER_START();
#endif

    // Per-phase profiling state (zero-cost when profile_phases is false —
    // the rusage calls and clock reads still happen but their cost is
    // negligible compared to the GC pause itself).
    auto t_enter = std::chrono::high_resolution_clock::now();
    long pf_enter_minor = 0, pf_enter_major = 0;
    long ctx_enter_vol = 0, ctx_enter_invol = 0;
#if defined(RUSAGE_THREAD)
    // RUSAGE_THREAD is Linux-only; on Darwin the per-thread fault/context-
    // switch counters simply read as 0 in the phase profile.
    struct rusage ru_enter;
    if (profile_phases && getrusage(RUSAGE_THREAD, &ru_enter) == 0) {
        pf_enter_minor = ru_enter.ru_minflt;
        pf_enter_major = ru_enter.ru_majflt;
        ctx_enter_vol  = ru_enter.ru_nvcsw;
        ctx_enter_invol = ru_enter.ru_nivcsw;
    }
#endif

    collectStackRootsFromStackMap();

    // Hoist nursery_.getRootSet() to a single resolution per major GC. The
    // accessor itself is cheap, but the previous code re-fetched it four
    // times (once for jit_roots, once for stack root ranges, once for
    // external scanners, plus the implicit hits in collectRoots) — visible
    // in profiles when major GC fires often.
    RootSet& root_set = nursery_.getRootSet();

    // Collect long-lived roots from this thread.
    std::unordered_set<HPointer*> roots = collectRoots();
    const std::unordered_set<uint64_t*>& jit_roots = root_set.getJitRoots();

    auto t_after_root_collect = std::chrono::high_resolution_clock::now();

    // Start marking phase with long-lived and JIT roots.
#if ENABLE_GC_STATS
    old_gen_.startMark(roots, jit_roots, *parent_, stats_);
#else
    old_gen_.startMark(roots, jit_roots, *parent_);
#endif

    size_t stackmap_roots_pushed = 0;
    size_t stackrange_roots_pushed = 0;
    size_t external_roots_pushed = 0;

    // Mark stackmap-derived roots.
    for (HPointer* slot : stack_map_roots_.get()) {
        old_gen_.markHPointer(*slot);
        ++stackmap_roots_pushed;
    }

    // Mark stack root ranges.
    for (const auto& range : root_set.getStackRootRanges()) {
        HPointer* base = range.base;
        uint64_t mask = range.hpointer_mask;
        for (size_t i = 0; i < range.count; ++i) {
            if (mask & (1ULL << i)) {
                old_gen_.markHPointer(base[i]);
                ++stackrange_roots_pushed;
            }
        }
    }

    // Mark external roots (Scheduler run queue, PlatformRuntime state,
    // MVar slots, Eco kernel Runtime state).
    for (auto& scanner : root_set.getExternalRootScanners()) {
        scanner([this, &external_roots_pushed](uint64_t& ref) {
            HPointer hp;
            std::memcpy(&hp, &ref, sizeof(hp));
            old_gen_.markHPointer(hp);
            ++external_roots_pushed;
        });
    }

    auto t_after_root_push = std::chrono::high_resolution_clock::now();

    // Continue with marking and sweep.
    Elm::MajorGCPhaseProfile phase_profile;
#if ENABLE_GC_STATS
    if (profile_phases) {
        old_gen_.finishMarkAndSweep(stats_, phase_profile);
    } else {
        old_gen_.finishMarkAndSweep(stats_);
    }
#else
    if (profile_phases) {
        old_gen_.finishMarkAndSweep(phase_profile);
    } else {
        old_gen_.finishMarkAndSweep();
    }
#endif

    auto t_done = std::chrono::high_resolution_clock::now();

#if ENABLE_GC_STATS
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
    GC_STATS_MAJOR_RECORD_GC_END(stats_, elapsed_ns);
#endif

    if (profile_phases) {
        long pf_minor_delta = 0, pf_major_delta = 0;
        long ctx_vol_delta = 0, ctx_invol_delta = 0;
#if defined(RUSAGE_THREAD)
        struct rusage ru_done;
        if (getrusage(RUSAGE_THREAD, &ru_done) == 0) {
            pf_minor_delta = ru_done.ru_minflt - pf_enter_minor;
            pf_major_delta = ru_done.ru_majflt - pf_enter_major;
            ctx_vol_delta  = ru_done.ru_nvcsw - ctx_enter_vol;
            ctx_invol_delta = ru_done.ru_nivcsw - ctx_enter_invol;
        }
#else
        (void)pf_enter_minor; (void)pf_enter_major;
        (void)ctx_enter_vol;  (void)ctx_enter_invol;
#endif

        const uint64_t total_ns      = nsBetween(t_enter, t_done);
        const uint64_t root_scan_ns  = nsBetween(t_enter, t_after_root_collect);
        const uint64_t root_push_ns  = nsBetween(t_after_root_collect, t_after_root_push);
        // Time inside finishMarkAndSweep that wasn't accounted for as mark or
        // sweep (e.g. computeFragmentationStats + adjustCapacityAfterMajorGC,
        // both invoked inside sweep()). The phase_profile.sweep_ns covers the
        // entire sweep() call including those, but we also report the
        // measured wall-clock for the finishMarkAndSweep block as a sanity check.
        const uint64_t finish_ns     = nsBetween(t_after_root_push, t_done);
        const uint64_t accounted_ns  = root_scan_ns + root_push_ns
                                     + phase_profile.mark_ns
                                     + phase_profile.sweep_ns;
        const int64_t  unaccounted_ns =
            static_cast<int64_t>(total_ns) - static_cast<int64_t>(accounted_ns);

        // Phase profiling (gcPhaseProfileEnabled) is independent of
        // ENABLE_GC_STATS, but the major-GC sequence counter lives in stats_,
        // which only exists in stats-enabled builds. Fall back to 0 otherwise.
#if ENABLE_GC_STATS
        const unsigned long long major_gc_seq = (unsigned long long)stats_.major_gc_count;
#else
        const unsigned long long major_gc_seq = 0;
#endif

        std::fprintf(stderr,
            "[gc-profile] major #%llu total=%.3fms"
            " root_scan=%.3fms (long=%zu jit=%zu)"
            " root_push=%.3fms (stackmap=%zu range=%zu external=%zu)"
            " mark=%.3fms (iters=%llu peak_stack=%zu)"
            " sweep=%.3fms (blocks=%zu live=%zu garbage=%zu)"
            " alldead=%zu/%zub demoted=%zu/%zub"
            " initial_sweep=%zub sweep_pending=%zub"
            " finish_block=%.3fms"
            " unaccounted=%.3fms"
            " minor_pf=%ld major_pf=%ld vol_csw=%ld invol_csw=%ld\n",
            major_gc_seq,
            total_ns / 1.0e6,
            root_scan_ns / 1.0e6,
            roots.size(),
            jit_roots.size(),
            root_push_ns / 1.0e6,
            stackmap_roots_pushed,
            stackrange_roots_pushed,
            external_roots_pushed,
            phase_profile.mark_ns / 1.0e6,
            (unsigned long long)phase_profile.mark_iterations,
            phase_profile.mark_stack_peak,
            phase_profile.sweep_ns / 1.0e6,
            phase_profile.blocks_scanned,
            phase_profile.live_bytes_after,
            phase_profile.garbage_bytes,
            phase_profile.alldead_blocks_released,
            phase_profile.alldead_bytes_released,
            phase_profile.demoted_blocks,
            phase_profile.demoted_bytes,
            phase_profile.initial_sweep_budget_bytes,
            phase_profile.sweep_pending_blocks,
            finish_ns / 1.0e6,
            unaccounted_ns / 1.0e6,
            pf_minor_delta,
            pf_major_delta,
            ctx_vol_delta,
            ctx_invol_delta);
        std::fflush(stderr);
    }

    parent_->dumpHeapState("majorGC end");
}

bool ThreadLocalHeap::isNurseryNearFull(float threshold) const {
    size_t total_capacity = config_->nurserySize() / 2;
    size_t usage = nursery_.bytesAllocated();
    return usage >= static_cast<size_t>(total_capacity * threshold);
}

std::unordered_set<HPointer*> ThreadLocalHeap::collectRoots() {
    // Returns only long-lived roots. Stackmap roots and stack root ranges
    // are marked via explicit loops in majorGC().
    return nursery_.getRootSet().getRoots();
}

void ThreadLocalHeap::collectStackRootsFromStackMap() {
    StackMap& sm = globalStackMap();
    if (!sm.hasRecords()) {
#if ECO_GC_DEBUG
        static bool warned = false;
        if (!warned) {
            fprintf(stderr, "[gc-stackmap] WARNING: no stack map records found! Stack roots will NOT be tracked.\n");
            warned = true;
        }
#endif
        return;
    }

    StackMapRoots& sm_roots = stack_map_roots_;
    sm_roots.clear();

    // Walk the call stack using libunwind.
    // For each frame, look up the IP in the stack map and process
    // Indirect locations (GC roots spilled to the stack).
    //
    // The unwinder's IP for a non-top frame is the return address,
    // which matches the key used by StackMap::findRecord().
    // Bias is 0 on x86-64 Linux (verified empirically).
    static constexpr int kIpToReturnAddressBias = 0;

    using namespace StackUnwind;
    Context ctx;
    Cursor cur(ctx);

    // Hoist Allocator::instance() above the unwind loop. The original code
    // re-resolved TLS once per stackmap location processed; on stack-walk-
    // heavy paths (many roots per frame) this showed up in profiles.
    Allocator& alloc = Allocator::instance();

    do {
        uintptr_t ip = cur.ip();
        const StackMapRecord* rec = sm.findRecord(ip + kIpToReturnAddressBias);
        if (!rec) {
            continue;
        }

        for (const StackMapLocation& loc : rec->locations) {
            if (loc.kind != StackMapLocation::Indirect) {
                continue;
            }
            uintptr_t base = 0;
            if (!cur.getRegister(loc.dwarfRegNum, base)) {
                continue;
            }
            uintptr_t addr = base + static_cast<int32_t>(loc.offset);
            auto* slot = reinterpret_cast<HPointer*>(addr);

            HPointer potential = *slot;
            // Embedded-constant HPointers (False/True/Empty) are not
            // heap-allocated and do not need GC. Skip them (ptr_ind set) before
            // calling resolve(), which asserts ptr_ind == 0.
            if (potential.ptr_ind != 0) {
                continue;
            }
            // Null HPointers are legitimately tracked by RS4GC (e.g.
            // unfilled closure capture slots, statically-null derived
            // pointers). resolve(null) would dereference heap_base, which
            // is part of the reserved-but-not-committed address range.
            if (potential.ptr == 0) {
                continue;
            }
            void* phys = alloc.resolve(potential);
            if (phys != nullptr && alloc.isInHeap(phys)) {
                sm_roots.push(slot);
            }
        }
    } while (cur.step());

#if ECO_GC_DEBUG
    fprintf(stderr, "[gc-stackmap-summary] stack roots pushed: %zu\n",
            sm_roots.get().size());
    // Print all stackmap roots with their values
    for (size_t ri = 0; ri < sm_roots.get().size(); ++ri) {
        HPointer* slot = sm_roots.get()[ri];
        HPointer val = *slot;
        uint64_t raw;
        memcpy(&raw, &val, sizeof(raw));
        fprintf(stderr, "[gc-stackmap-root] root[%zu] slot=%p val=0x%016lx (ptr=0x%lx const=%u)\n",
                ri, (void*)slot, raw, (unsigned long)val.ptr, (unsigned)val.constant);
    }
    // Print all stack root ranges with their values
    RootSet& roots = nursery_.getRootSet();
    for (size_t ri = 0; ri < roots.getStackRootRanges().size(); ++ri) {
        auto& range = roots.getStackRootRanges()[ri];
        fprintf(stderr, "[gc-stackrange] range[%zu] base=%p count=%zu mask=0x%lx\n",
                ri, (void*)range.base, range.count, (unsigned long)range.hpointer_mask);
        for (size_t j = 0; j < range.count; ++j) {
            uint64_t raw;
            memcpy(&raw, &range.base[j], sizeof(raw));
            fprintf(stderr, "[gc-stackrange]   [%zu] val=0x%016lx %s\n",
                    j, raw, (range.hpointer_mask & (1ULL << j)) ? "(HPTR)" : "(skip)");
        }
    }
#endif
}

} // namespace Elm
