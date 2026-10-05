/**
 * ThreadLocalHeap Implementation.
 *
 * Implements the per-thread heap containing nursery, old gen, and GC stats.
 * Each thread has its own independent GC with no synchronization required.
 */

#include "ThreadLocalHeap.hpp"
#include "P1Census.hpp"
#include "Allocator.hpp"
#include "StackMap.hpp"
#include "StackUnwind.hpp"
#include "HeapChildWalk.hpp"
#include "TlaTrace.hpp"   // compiled-out hooks (trace builds only)
#include <unordered_set>
#include <cassert>
#include <cstdio>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if ECO_HEAP_VALIDATE
#include <execinfo.h>   // threaded-gc-04b ECO_LARGE_PTR_TRACE
#include <fcntl.h>
#include <unistd.h>
#endif
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
ECO_TLA_TRACE_ONLY(namespace gc { extern bool tla_m6; })   // GCHelperPool.cpp: M6 probes log while set

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
        case OldGenSpace::MajorGCTriggerReason::Headroom:   // same counter (05c)
            stats.major_gc_global_pressure_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::GarbageFraction:
        case OldGenSpace::MajorGCTriggerReason::LiveBudget:  // same counter
            stats.major_gc_garbage_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::None:
            break;
    }
}
#endif

// Maps the trigger enum onto the event-log reason tag. Separate enums on
// purpose: the log also has to name causes that never pass through
// evaluateMajorGCTrigger (hard alloc failure, forced collections).
static inline GCStats::MajorReason
majorReasonTag(OldGenSpace::MajorGCTriggerReason reason) {
    switch (reason) {
        case OldGenSpace::MajorGCTriggerReason::Occupancy:
            return GCStats::MajorReason::Occupancy;
        case OldGenSpace::MajorGCTriggerReason::GlobalPressure:
            return GCStats::MajorReason::GlobalPressure;
        case OldGenSpace::MajorGCTriggerReason::GarbageFraction:
            return GCStats::MajorReason::GarbageFraction;
        case OldGenSpace::MajorGCTriggerReason::LiveBudget:
            return GCStats::MajorReason::LiveBudget;
        case OldGenSpace::MajorGCTriggerReason::Headroom:
            return GCStats::MajorReason::Headroom;
        case OldGenSpace::MajorGCTriggerReason::None:
            break;
    }
    return GCStats::MajorReason::Unknown;
}

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
    zeroNewObject(hdr, size);
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
            assertNarrowContainer(hdr->tag, hdr->size);
            break;
        case Tag_Record:
            hdr->size = (size - sizeof(Record)) / sizeof(Unboxable);
            assertNarrowContainer(hdr->tag, hdr->size);
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
    // on demand — the nursery claims a slice pair (HEAP_042) and the old gen
    // acquires buffers when they initialize.

    // Initialize old gen with reference to parent Allocator. The initialize
    // call now pre-commits `initial_old_gen_size` as one contiguous region
    // and slices it into pages stored in `unassigned_blocks_` (BBoP).
    old_gen_.initialize(parent_, config_);

    // Initialize nursery with reference to this heap for promotion.
    nursery_.initialize(this, config_);

    // HEAP_053: the old gen's mark path asks THIS heap's nursery, not the
    // calling thread's (Allocator::isInNursery via tl_heap_).
    old_gen_.bindNursery(&nursery_);
}

void ThreadLocalHeap::noteLargeAlloc(LargePlacement where, size_t size, uint32_t tag) {
#if ENABLE_GC_STATS
    LargePtrStats& lp = stats_.lp;
    switch (where) {
        case LargePlacement::Nursery:     lp.nursery_allocs++;     lp.nursery_bytes += size; break;
        case LargePlacement::Ylos:        lp.ylos_allocs++;        lp.ylos_bytes += size; break;
        case LargePlacement::Region:      lp.region_allocs++;      lp.region_bytes += size; break;
        case LargePlacement::PointerFree: lp.pointerfree_allocs++; lp.pointerfree_bytes += size; break;
    }
#endif
#if ECO_HEAP_VALIDATE
    // D6: a trace of large allocation sites (the tool for spotting a kernel
    // that builds big flat pointer arrays).
    // ECO_LARGE_PTR_TRACE=1 traces to stderr with a backtrace; any other
    // non-empty value is a FILE PATH that one line per allocation is appended
    // to (O_APPEND: forked test children can share it — the runners' children
    // _exit, so their stats banners never print).
    static const int trace_fd = [] {
        const char* e = std::getenv("ECO_LARGE_PTR_TRACE");
        if (e == nullptr || e[0] == '\0') return -1;
        if (e[0] == '1' && e[1] == '\0') return 2;
        return ::open(e, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }();
    if (trace_fd >= 0) {
        static const char* kNames[] = {"nursery", "ylos", "region", "pointer-free"};
        char line[128];
        const int len = std::snprintf(line, sizeof line, "[large-ptr] %s tag=%u size=%zu\n",
                                      kNames[static_cast<int>(where)], tag, size);
        if (len > 0) (void)!::write(trace_fd, line, static_cast<size_t>(len));
        if (trace_fd == 2) {
            void* frames[8];
            const int n = backtrace(frames, 8);
            backtrace_symbols_fd(frames, n, 2);
        }
    }
#else
    (void)size; (void)tag; (void)where;
#endif
}

// TLA-REGION(TLH.destructor) begin
ThreadLocalHeap::~ThreadLocalHeap() {
    // M6 fork harness (det-cr031): a child's exit() reached this heap's teardown (CR-031).
    ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.tlh.dtor");)
    // threaded-gc-07: stop / finish / stats-merge the last tenure job while
    // the old gen (destroyed before the nursery) still exists.
    nursery_.tenureTeardown(old_gen_);
    // threaded-gc-04: verify, then drop, this heap's P1 census table.
    p1::forget(old_gen_);
}
// TLA-REGION(TLH.destructor) end

void* ThreadLocalHeap::allocate(size_t size, Tag tag) {
    // Align to 8 bytes up front so the threshold comparison is meaningful
    // (matches the alignment performed inside nursery/oldgen allocators).
    size = (size + 7) & ~static_cast<size_t>(7);

    // Large-object path (threaded-gc-04b P§3.1): a pointer-free object goes
    // to the old gen, pinned; a pointer-bearing one to the nursery up to the
    // cap, else to the young large-object space. Never born old.
    if (size >= config_->large_object_threshold) {
        switch (placeLarge(size, tag)) {
            case LargePlacement::PointerFree: return allocateLargePinned(size, tag);
            case LargePlacement::Ylos:        return allocateYoungLarge(size, tag);
            default:
                noteLargeAlloc(LargePlacement::Nursery, size, tag);
                break;
        }
    }

    // Fast path. NurserySpace::allocate's bump-pointer compares against
    // bump_.end, which is pre-clamped to the earlier of (from-space extent
    // end, proactive-GC threshold trip point) by computeAllocEnd. So a
    // single compare enforces both space-fit and threshold-fit.
    void* obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // Slow path: nursery returned nullptr. This means either the threshold
    // tripped or the nursery is genuinely full. minorGC handles both —
    // after evacuation, the bump pointer resumes after the survivors and a
    // fresh clamped end is computed.
    minorGC();
    obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // Still nothing: the survivors left less room below the PROACTIVE
    // threshold than this object needs. Collecting again cannot help (no
    // allocation has happened since), so drop the clamp for the rest of
    // this cycle and use the extent — the same fail-soft computeAllocEnd
    // applies when survivors already sit past the threshold, and the same
    // rung ensureNursery has. (The block design masked this case with
    // block-quantized threshold arithmetic plus a block advance; a
    // byte-exact clamp over one extent needs it explicitly.)
    nursery_.failSoftUnclamp();
    obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // Nursery allocation still failed — genuinely out of space. Cannot fall
    // back to old-gen allocation: the object's fields would be filled in
    // afterwards, potentially creating old→young pointers that violate
    // the generational GC invariant. A large object can still go to the
    // young large-object space, which is young.
    if (size >= config_->large_object_threshold) {
        return allocateYoungLarge(size, tag);
    }
    assert(false && "Failed to allocate to nursery, it is full.");
    return nullptr;
}

void* ThreadLocalHeap::allocateFast(size_t size) {
    // Pure bump-pointer: no GC, no threshold check, no header init.
    // Returns nullptr when nursery has insufficient space.
    size = (size + 7) & ~static_cast<size_t>(7);
    // threaded-gc-07 (P§3.13): in region mode every nursery object has an
    // old-gen size class; a larger request takes the caller's slow path,
    // which places it (SIZE_MAX in legacy mode).
    if (__builtin_expect(size > nursery_.regionLargeCap(), 0)) return nullptr;
    return nursery_.allocate(size);
}

void* ThreadLocalHeap::allocateSlow(size_t size, Tag tag) {
    // Slow path: GC then allocate. Called after allocateFast returns nullptr.
    size = (size + 7) & ~static_cast<size_t>(7);

    // Large objects: same placement as allocate(). The Nursery placement
    // takes the GC-and-retry path below.
    if (size >= config_->large_object_threshold) {
        switch (placeLarge(size, tag)) {
            case LargePlacement::PointerFree: return allocateLargePinned(size, tag);
            case LargePlacement::Ylos:        return allocateYoungLarge(size, tag);
            default:
                noteLargeAlloc(LargePlacement::Nursery, size, tag);
                break;
        }
    }

    minorGC();

    void* obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // Post-GC threshold fail-soft — see ThreadLocalHeap::allocate.
    nursery_.failSoftUnclamp();
    obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    if (size >= config_->large_object_threshold) {
        return allocateYoungLarge(size, tag);
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

    // Post-GC threshold fail-soft — see ThreadLocalHeap::allocate.
    nursery_.failSoftUnclamp();
    obj = nursery_.allocate(size);
    if (obj) {
        return obj;
    }

    assert(false && "Failed to allocate after GC in slow path (raw).");
    return nullptr;
}

void ThreadLocalHeap::ensureNursery(size_t n) {
    // Cold edge of a hoisted capacity check (HEAP_041,
    // plans/capacity-check-hoisting.md). Establishes
    // `bump_.end - bump_.ptr >= n` and allocates NOTHING; the covered run's
    // unchecked bumps consume the guarantee afterwards.
    assert(n <= 4096 && (n & 7) == 0 &&
           "ensureNursery: budget out of inline-alloc bounds");
    GC_STATS_ENSURE_SLOW_CALL(stats_);

    if (nursery_.ensureHeadroom(n)) {
        return;
    }

    minorGC();
    if (nursery_.ensureHeadroom(n)) {
        return;
    }

    // Tiny-config corner: a CLAMPED end that sits below n
    // (threshold_total_bytes_ < n) would GC-loop here. Fail soft exactly
    // like computeAllocEnd's already-full clause — hand out the rest of the
    // from-space extent.
    nursery_.failSoftUnclamp();
    if (nursery_.ensureHeadroom(n)) {
        return;
    }

    assert(false && "ensureNursery: cannot satisfy after GC (HEAP_017)");
}

void* ThreadLocalHeap::allocateRegionSlow(size_t total) {
    // Slow path for contiguous region allocation. May GC.
    // Caller handles header init for each sub-object.
    total = (total + 7) & ~static_cast<size_t>(7);

    // A large closure-group region is several objects, so it cannot go to
    // the young large-object space (per object); it must fit the nursery
    // (threaded-gc-04b P§3.2). Bounded by the whole nursery, not the
    // placement cap: a region is not a large-object tuning decision.
    const bool large = total >= config_->large_object_threshold;
    if (large) {
        noteLargeAlloc(LargePlacement::Region, total, Tag_Closure);
    }

    minorGC();

    void* obj = nursery_.allocate(total);
    if (obj) return obj;

    // Post-GC threshold fail-soft — see ThreadLocalHeap::allocate.
    nursery_.failSoftUnclamp();
    obj = nursery_.allocate(total);
    if (obj) return obj;

    if (large) regionTooLarge(total);
    assert(false && "Failed to allocate region after GC.");
    return nullptr;
}

[[noreturn]] void ThreadLocalHeap::regionTooLarge(size_t total) {
    std::fprintf(stderr,
                 "eco: closure group region of %zu bytes exceeds the nursery cap "
                 "(%zu-byte nursery); split the group\n",
                 total, nursery_.capacityBytes());
    std::abort();
}

void* ThreadLocalHeap::allocateYoungLarge(size_t size, Tag tag) {
    // threaded-gc-04b HEAP_062: an old-gen cell that is YOUNG — registered
    // with the current minor color, so the next minor frees it unless it is
    // reached. No minor GC here: the caller's raw pointers stay valid unless
    // the old gen is full and a major runs first (before the cell exists).
    // Even then nothing moves, but in region mode that major zaps every
    // survivor it did not reach (HEAP_074): a pointer the caller stores into
    // the new object must be rooted across this call (HeapHelpers Pattern 1).
    noteLargeAlloc(LargePlacement::Ylos, size, tag);
    void* obj = old_gen_.allocateYoungLarge(size, tag, nursery_.minor_color_);
    if (!obj) {
#if ENABLE_GC_STATS
        stats_.major_gc_alloc_failure_triggers++;
#endif
        majorGC(GCStats::MajorReason::AllocFailure);
        obj = old_gen_.allocateYoungLarge(size, tag, nursery_.minor_color_);
    }
    assert(obj && "Failed to allocate young large object.");
    return obj;
}

void* ThreadLocalHeap::allocateLargePinned(size_t size, Tag tag) {
    // size is already 8-byte aligned by the caller. Pointer-free tags only
    // (threaded-gc-04b V4): a pointer-bearing object is never born old.
    assert(!tagMayHoldPointers(tag) &&
           "allocateLargePinned: pointer-bearing objects go to the nursery or YLOS");
    noteLargeAlloc(LargePlacement::PointerFree, size, tag);
    void* obj = old_gen_.allocate(size);
    if (!obj) {
        // Try once after a major GC to reclaim space.
#if ENABLE_GC_STATS
        stats_.major_gc_alloc_failure_triggers++;
#endif
        majorGC(GCStats::MajorReason::AllocFailure);
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
            majorGC(majorReasonTag(reason));
        }
    }
}

#if ENABLE_GC_PHASE_TIMERS
// threaded-gc-00: brackets the OUTERMOST minorGC/majorGC call on this thread,
// so a minor that triggers a major is recorded as one contiguous pause.
struct GCPauseScope {
    ThreadLocalHeap& h;
    GCPauseScope(ThreadLocalHeap& heap, bool is_major) : h(heap) {
        if (h.gc_depth_++ == 0) {
            h.pause_start_ns_ = GCStats::nowSinceProcessStartNs();
            h.pause_saw_minor_ = false;
            h.pause_saw_major_ = false;
            h.pause_saw_t0_ = h.pause_saw_slice_ = h.pause_saw_handoff_ = false;
            h.pause_cpu_start_ns_ = gc::GCHelperPool::threadCpuNs();   // 05c P§3.13
        }
        (is_major ? h.pause_saw_major_ : h.pause_saw_minor_) = true;
    }
    ~GCPauseScope() {
        if (--h.gc_depth_ == 0) {
            const uint64_t now = GCStats::nowSinceProcessStartNs();
            uint8_t kind = h.pause_saw_minor_ ? (h.pause_saw_major_ ? 1 : 0) : 2;
            // threaded-gc-05a: a minor pause that carried cycle work.
            // Precedence: major > handoff > t0 > slice.
            if (kind == 0) {
                if (h.pause_saw_handoff_) kind = 5;
                else if (h.pause_saw_t0_) kind = 3;
                else if (h.pause_saw_slice_) kind = 4;
            }
            h.recordPause(h.pause_start_ns_, now - h.pause_start_ns_, kind);
            // threaded-gc-05c (P§3.13): mutator CPU in and outside pauses, for
            // the interference figure (mode 2 vs mode 0).
            const uint64_t cpu = gc::GCHelperPool::threadCpuNs();
            ConcMarkStats& c = h.old_gen_.getStats().cm;
            c.mutator_pause_cpu_ns += cpu - h.pause_cpu_start_ns_;
            c.mutator_cpu_ns = cpu;
        }
    }
};

void ThreadLocalHeap::recordPause(uint64_t start_ns, uint64_t dur_ns, uint8_t kind) {
    stats_.tg.addPause(start_ns, dur_ns, kind);
    if (gcEventLogEnabled()) {
        gcEventLogPause(stats_.tg.pause_count, start_ns, dur_ns, kind);
    }
}

void ThreadLocalHeap::recordMinorPhases(MinorGCRecord& rec) {
    rec.pause_ns = GCStats::nowSinceProcessStartNs() - rec.start_ns;
    const auto& names = nursery_.getRootSet().getExternalRootScannerNames();
    stats_.tg.addMinor(rec, names.data(), names.size());
    if (gcEventLogEnabled()) {
        gcEventLogMinor(rec, nursery_.getStats().minor_gc_count, names.data(), names.size());
    }
}
#endif

// threaded-gc-03 (plans/threaded-gc-03-helper-threads.md P§3.5): the helper
// sync point at the end of the OUTERMOST pause. Declared after GCPauseScope so
// it destructs first: sync-mode helper work is inside the pause bracket.
struct PauseEndHook {
    ThreadLocalHeap& h;
    Allocator* parent;
    PauseEndHook(ThreadLocalHeap& heap, Allocator* p) : h(heap), parent(p) {
        ++h.pause_depth_;
    }
    ~PauseEndHook() {
        if (--h.pause_depth_ == 0) {
            const bool had_major = h.pause_had_major_;
            h.pause_had_major_ = false;
            parent->onGCPauseEnd(h, had_major);
        }
    }
};

// TLA-REGION(TLH.majorGCAndShrink) begin
// plans/frontend-heap-release.md §3.4 (HEAP_076): one pause, one sync point.
// The outermost PauseEndHook here makes the nested majorGC's hook an inner
// one, so its sync point (onGCPauseEnd, had_major = true) runs once, after
// the sweep and the forced shrink, and the shrink's releases are Pending
// before it. The caller discards them after the pause (AL.releaseDiscard).
ThreadLocalHeap::ReleaseTimings ThreadLocalHeap::majorGCAndShrink() {
#if ECO_HEAP_VALIDATE
    assertOwner("majorGCAndShrink");
#endif
    if (pause_depth_ != 0) {
        std::fprintf(stderr, "[gc] FATAL: explicit release inside a GC pause (HEAP_076)\n");
        std::fflush(stderr);
        std::abort();
    }
#if ENABLE_GC_PHASE_TIMERS
    GCPauseScope pause_scope(*this, /*is_major=*/true);
#endif
    PauseEndHook pause_end(*this, parent_);   // outermost: ONE onGCPauseEnd, had_major = true
    auto now = []() -> uint64_t {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    };
    ReleaseTimings t{};
    uint64_t s = now();
    // Nested (depth 2): joins the tenure job and finishes a live cycle by Join.
    majorGC(GCStats::MajorReason::Explicit);
    t.gc_ns = now() - s;
    s = now();
    old_gen_.finishSweepForRelease();
    t.sweep_ns = now() - s;
    s = now();
    const size_t u0 = parent_->getOldGenCommittedBytes();
    old_gen_.shrinkToFloorForRelease();
    const size_t u1 = parent_->getOldGenCommittedBytes();
    t.shrink_released = u0 > u1 ? u0 - u1 : 0;
    t.shrink_ns = now() - s;
    return t;
}
// TLA-REGION(TLH.majorGCAndShrink) end

#if ECO_HEAP_VALIDATE
void ThreadLocalHeap::assertOwner(const char* where) const {
    if (owner_ != std::thread::id() && owner_ != std::this_thread::get_id()) {
        std::fprintf(stderr, "[heap-validate] HEAP_007: heap used by a non-owner (%s; CR-031)\n", where);
        std::fflush(stderr);
        std::abort();
    }
}
#endif

// TLA-REGION(TLH.minorGC) begin
void ThreadLocalHeap::minorGC() {
#if ECO_HEAP_VALIDATE
    assertOwner("minorGC");
#endif
#if ENABLE_GC_PHASE_TIMERS
    GCPauseScope pause_scope(*this, /*is_major=*/false);
    MinorGCRecord rec;
    rec.start_ns = GCStats::nowSinceProcessStartNs();
#endif
    PauseEndHook pause_end(*this, parent_);
    ECO_TLA_TRACE("minor", "cyc", old_gen_.cycleActive());   // M1 trace: P_Minor
    if (Allocator::heapTraceEnabled()) {
        parent_->dumpHeapState("minorGC begin");
    }
    StackWalkCounts sw = collectStackRootsFromStackMap();
#if ENABLE_GC_PHASE_TIMERS
    rec.stack_walk_ns = GCStats::nowSinceProcessStartNs() - rec.start_ns;
    rec.frames_walked = sw.frames_walked;
    rec.frames_matched = sw.frames_matched;
    rec.stack_slots = sw.slots;
    // threaded-gc-07 (P§3.15): join and MERGE the previous tenure job
    // before anything else touches the heap.
    if (nursery_.regionMode()) {
        rec.rg_region = 1;
        nursery_.tenureJoin(old_gen_, 0, &rec);
    }
    nursery_.minorGC(old_gen_, stack_map_roots_, &rec);
    recordMinorPhases(rec);
#else
    (void)sw;
    if (nursery_.regionMode()) nursery_.tenureJoin(old_gen_, 0, nullptr);
    nursery_.minorGC(old_gen_, stack_map_roots_, nullptr);
#endif
    // threaded-gc-07 (trap 2 / trap 6): the tenure job of this minor is built
    // and launched on EVERY return path below, after any cycle start, cycle
    // step, handoff or STW major of this pause.
    struct TenureLaunchScope {
        ThreadLocalHeap& h;
        ~TenureLaunchScope() {
            if (h.nursery_.regionMode()) h.nursery_.tenureLaunch(h.old_gen_);
        }
    } tenure_launch{*this};
    if (Allocator::heapTraceEnabled()) {
        parent_->dumpHeapState("minorGC end");
    }
    // threaded-gc-05c Part B (P§3.11): the promotion-rate estimate, at every
    // minor end, before the cycle step or the trigger.
    old_gen_.notePacingMinorEnd();

    // 75% occupancy trigger: minor GC promotes into old gen, so allocated
    // bytes can cross the initiating threshold here. Safepoint polling is
    // not dense in MLIR-generated code, so we also check at the end of
    // every minor GC to avoid filling the old gen before the next
    // safepoint fires.
    //
    // threaded-gc-05a (HEAP_063): while an incremental cycle runs, this minor
    // end is one of its steps instead (triggers are suppressed; a pause that
    // runs a handoff does not evaluate them again).
    if (old_gen_.cycleActive()) {
        stepMarkCycle();
        return;
    }
    if (__builtin_expect(test_force_major_trigger_, 0)) {   // tests only
        test_force_major_trigger_ = false;
        if (useMarkCycle()) startMarkCycle(GCStats::MajorReason::Forced);
        else majorGC(GCStats::MajorReason::Forced);
        return;
    }
    const auto reason = old_gen_.evaluateMajorGCTrigger();
    if (reason != OldGenSpace::MajorGCTriggerReason::None) {
#if ENABLE_GC_STATS
        recordMajorTriggerReason(stats_, reason);
#endif
        if (useMarkCycle()) {
            startMarkCycle(majorReasonTag(reason));
        } else {
            majorGC(majorReasonTag(reason));
        }
    }
}
// TLA-REGION(TLH.minorGC) end

// TLA-REGION(TLH.majorGC) begin
void ThreadLocalHeap::majorGC(GCStats::MajorReason reason) {
#if ECO_HEAP_VALIDATE
    assertOwner("majorGC");
#endif
#if ENABLE_GC_PHASE_TIMERS
    GCPauseScope pause_scope(*this, /*is_major=*/true);
#endif
    PauseEndHook pause_end(*this, parent_);
    ECO_TLA_TRACE("major", "cyc", old_gen_.cycleActive());   // M1 trace: J_Join
    pause_had_major_ = true;
    // threaded-gc-07 (P§3.16): a STW major joins and merges the tenure job
    // first; its mark then greys the copy of every forwarded tenuring object.
    if (nursery_.regionMode()) nursery_.tenureJoin(old_gen_, 1, nullptr);
    // threaded-gc-05a (P§3.8): a join. A running incremental cycle frees only
    // what was dead at its t0; an allocation failure or an explicit major
    // needs everything dead now. Finish the cycle, then run the requested STW
    // major as usual (two majors: an emergency path).
    if (old_gen_.cycleActive()) {
        finishMarkCycleNow(OldGenSpace::CycleFinish::Join);
    }
    const bool profile_phases = gcPhaseProfileEnabled();

    // Dump sizes at major GC so the reproduction log makes it easy to see
    // whether a major GC actually ran before the old-gen assert fired. The
    // dump is a compile-time no-op unless the build was configured with
    // `-DECO_HEAP_TRACE=ON` (the trace must then still be enabled at runtime
    // via the `ECO_HEAP_TRACE` env var).
    parent_->dumpHeapState("majorGC begin");

#if ENABLE_GC_STATS
    auto gc_start = GC_STATS_TIMER_START();
    // Snapshot the old-gen state BEFORE the pause so the event log can show
    // what each collection walked into, not just what it left behind.
    stats_.beginMajorGCEvent(reason,
                             old_gen_.getAllocatedBytes(),
                             old_gen_.getCommittedBytes());
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
    const std::unordered_set<HPointer*>& roots = collectRoots();
    const std::unordered_set<uint64_t*>& jit_roots = root_set.getJitRoots();

    auto t_after_root_collect = std::chrono::high_resolution_clock::now();

    // threaded-gc-04: verify the P1 census's old-gen table before marking.
    p1::verifyOldGen(old_gen_, "major-start");

    // Start marking phase with long-lived and JIT roots.
#if ENABLE_GC_STATS
    old_gen_.startMark(roots, jit_roots, *parent_, stats_);
#else
    old_gen_.startMark(roots, jit_roots, *parent_);
#endif

    size_t stackmap_roots_pushed = 0;
    size_t stackrange_roots_pushed = 0;
    size_t external_roots_pushed = 0;

    // Mark stackmap-derived roots, stack root ranges, single-slot stack roots
    // and external roots (Scheduler run queue, PlatformRuntime state, MVar
    // slots, Eco kernel Runtime state) — threaded-gc-05a D1: one enumeration
    // shared with the incremental cycle's t0 snapshot.
    forEachMajorRoot(root_set, [&](HPointer& hp, int kind) {
        old_gen_.markHPointer(hp);
        if (kind == 0) ++stackmap_roots_pushed;
        else if (kind == 1) ++stackrange_roots_pushed;
        else ++external_roots_pushed;
    });

    auto t_after_root_push = std::chrono::high_resolution_clock::now();

    // Continue with marking and sweep.
    Elm::MajorGCPhaseProfile phase_profile;
#if ENABLE_GC_STATS
    // Always take the profiling overload in stats builds: the per-major event
    // log needs the mark/sweep split, and the extra cost is a handful of clock
    // reads against a pause measured in tens of milliseconds.
    (void)profile_phases;
    old_gen_.finishMarkAndSweep(stats_, phase_profile);
#else
    if (profile_phases) {
        old_gen_.finishMarkAndSweep(phase_profile);
    } else {
        old_gen_.finishMarkAndSweep();
    }
#endif

    // CR-017 / HEAP_074: nursery_visited_ is exactly the young objects this major reached;
    // every other survivor of a Young extent is dead and its old children may now be free.
    if (nursery_.regionMode()) nursery_.zapDeadAfterMajor(old_gen_);

    auto t_done = std::chrono::high_resolution_clock::now();

#if ENABLE_GC_STATS
    uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
    GC_STATS_MAJOR_RECORD_GC_END(stats_, elapsed_ns);
    stats_.recordMajorGCEvent(
        nsBetween(t_enter, t_done),
        nsBetween(t_enter, t_after_root_collect),
        nsBetween(t_after_root_collect, t_after_root_push),
        phase_profile.mark_ns,
        phase_profile.sweep_ns,
        phase_profile.capacity_ns,
        old_gen_.getAllocatedBytes(),
        phase_profile.live_bytes_after,
        phase_profile.garbage_bytes,
        phase_profile.alldead_bytes_released,
        phase_profile.shrink_bytes_released,
        phase_profile.mark_units_done,
        phase_profile.mark_stack_peak,
        phase_profile.blocks_scanned,
        nursery_.getStats().minor_gc_count,
        nursery_.getStats().objects_promoted);
#if ENABLE_GC_PHASE_TIMERS
    if (gcEventLogEnabled() && stats_.major_gc_events_used > 0) {
        const GCStats::MajorGCEvent& ev =
            stats_.major_gc_events[stats_.major_gc_events_used - 1];
        gcEventLogMajor(ev.seq, ev.start_ns, ev.total_ns, ev.mark_ns, ev.sweep_ns,
                        ev.root_scan_ns + ev.root_push_ns, gcMajorReasonName(ev.reason));
    }
#endif
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
// TLA-REGION(TLH.majorGC) end

bool ThreadLocalHeap::isNurseryNearFull(float threshold) const {
    // LIVE per-side capacity, not the CONFIGURED one: the nursery grows
    // adaptively, and measuring a grown nursery against its initial size
    // reported "near full" from ~20% occupancy onward. Callers: the
    // safepoint gating in collectAtSafepoint (reachable only via
    // __eco_safepoint_poll, which compiled code does not emit today) and
    // the synthetic benchmark driver's pacing loop (main.cpp).
    size_t total_capacity = nursery_.from_capacity_bytes_;  // friend access
    size_t usage = nursery_.objectBytesAllocated();   // threaded-gc-06 HEAP_068
    return usage >= static_cast<size_t>(total_capacity * threshold);
}

// ===========================================================================
// threaded-gc-05a: the incremental mark cycle driver (HEAP_063,
// plans/threaded-gc-05a-incremental-marking.md P§3.1-P§3.8).
// ===========================================================================

template <typename F>
void ThreadLocalHeap::forEachMajorRoot(RootSet& root_set, F&& f) {
    // kind 0: stack-map slots.
    for (HPointer* slot : stack_map_roots_.get()) f(*slot, 0);
    // kind 1: stack root ranges (masked), then single-slot stack roots.
    for (const auto& range : root_set.getStackRootRanges()) {
        HPointer* base = range.base;
        uint64_t mask = range.hpointer_mask;
        for (size_t i = 0; i < range.count; ++i) {
            if (stackRangeSlotIsRoot(mask, i)) f(base[i], 1);
        }
    }
    for (HPointer* slot : root_set.getSingleRoots()) f(*slot, 1);
    // kind 2: external root scanners (off-heap stores; HEAP_SNAPSHOT_002).
    for (auto& scanner : root_set.getExternalRootScanners()) {
        scanner([&f](uint64_t& ref) {
            HPointer hp;
            std::memcpy(&hp, &ref, sizeof(hp));
            f(hp, 2);
        });
    }
}

static inline uint64_t cycleNowNs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

void ThreadLocalHeap::notePauseCycleWork(int what) {
#if ENABLE_GC_PHASE_TIMERS
    if (what == 0) pause_saw_t0_ = true;
    else if (what == 1) pause_saw_slice_ = true;
    else pause_saw_handoff_ = true;
#else
    (void)what;
#endif
}

// TLA-REGION(TLH.startMarkCycle) begin
void ThreadLocalHeap::startMarkCycle(GCStats::MajorReason reason) {
    const uint64_t t_start = cycleNowNs();
#if ENABLE_GC_STATS
    stats_.beginMajorGCEvent(reason, old_gen_.getAllocatedBytes(),
                             old_gen_.getCommittedBytes());
#else
    (void)reason;
#endif
    // Fresh stack roots: the minor just updated every slot in place.
    collectStackRootsFromStackMap();
    RootSet& root_set = nursery_.getRootSet();
    p1::verifyOldGen(old_gen_, "cycle-start");

    // threaded-gc-05b P§3.8: with incremental_mark off, a cycle exists only to
    // run the mark on N markers -- T = 0, the whole cycle in this pause.
    const uint32_t slices = config_->incremental_mark ? config_->incremental_mark_slices : 0;
    old_gen_.beginMarkCycle(*parent_, slices);
    ECO_TLA_TRACE("t0", "T", slices);   // M1 trace: P_T0 (the snapshot's greys follow)
    cycle_t0_wall_ns_ = t_start;
    cycle_mark_ns_ = 0;
    cycle_inpause_ns_ = 0;

    // P§3.2: the snapshot. Old-gen targets of every root and off-heap store
    // are greyed; young targets are dropped (snapshot mode) because every
    // young object is walked below.
    old_gen_.setSnapshotMode(true);
    for (HPointer* root : root_set.getRoots()) old_gen_.markHPointer(*root);
    for (uint64_t* root : root_set.getJitRoots()) old_gen_.markJitRootRaw(*root, *parent_);
    forEachMajorRoot(root_set, [&](HPointer& hp, int kind) {
        if (kind == 2 && test_snapshot_skip_external_) return;   // negative control
        old_gen_.markHPointer(hp);
    });
    old_gen_.snapshotYoungLarge();
    size_t surv_bytes = 0;
    size_t survivors = 0;
    if (!test_snapshot_skip_young_walk_) {                        // negative control
        // threaded-gc-07 (P§3.16, trap 7): region mode walks Fresh AND
        // Tenuring (young at t0, promoted after it by the next job).
        survivors = nursery_.forEachYoung(
            [&](void* obj) { old_gen_.markChildren(obj); }, &surv_bytes);
    }
    old_gen_.setSnapshotMode(false);
#if ENABLE_GC_STATS
    old_gen_.getStats().im.t0_survivors += survivors;
    old_gen_.getStats().im.t0_survivor_bytes += surv_bytes;
#else
    (void)survivors;
#endif
#if ECO_HEAP_VALIDATE
    // IM1 (record half): every old-gen object reachable at t0, found by an
    // independent tracer, must be marked at the handoff.
    {
        bool complete = false;
        old_gen_.cycle_t0_reach_ = traceOldReachableForValidation(&complete);
        if (!complete) old_gen_.cycle_t0_reach_.clear();
    }
#endif
    // threaded-gc-05c (P§3.5): hand the grey set to the background markers
    // (conc_mark 2) or mark it all now (conc_mark 1). After every other t0
    // action, IM1's record half included: nothing the mutator does in this
    // pause may race with a marker.
    ECO_TLA_TRACE("t0end", "greys", old_gen_.markStackSize());   // no marker runs yet (IM14)
    old_gen_.afterSnapshot();
    notePauseCycleWork(0);
    const uint64_t dur = cycleNowNs() - t_start;
    cycle_mark_ns_ += dur;
    cycle_inpause_ns_ += dur;
#if ENABLE_GC_STATS
    {
        IncrMarkStats& im = old_gen_.getStats().im;
        im.t0_ns_total += dur;
        if (dur > im.t0_ns_max) im.t0_ns_max = dur;
    }
#endif
    // T = 0: the whole cycle inside the t0 pause (the E0 equivalence arm).
    if (slices == 0) {
        finishMarkCycleNow(OldGenSpace::CycleFinish::Schedule);
    }
}
// TLA-REGION(TLH.startMarkCycle) end

// TLA-REGION(TLH.stepMarkCycle) begin
void ThreadLocalHeap::stepMarkCycle() {
    old_gen_.noteCycleMinorEnd();
    if (old_gen_.cycleState() == OldGenSpace::CycleState::HandoffDue) {
        completeMarkCycle(OldGenSpace::CycleFinish::Schedule);
        return;
    }
    if (old_gen_.cyclePressureFinishDue()) {
        finishMarkCycleNow(OldGenSpace::CycleFinish::Pressure);
        return;
    }
    const uint64_t t_start = cycleNowNs();
    const bool conc = old_gen_.concurrentCycle();
    (void)old_gen_.cycleStep();
#if ECO_HEAP_VALIDATE
    // IM6 reads every accumulator: only when no background member runs (05c trap 7).
    if (old_gen_.bgEpisode() != OldGenSpace::BgEpisode::Running) {
        old_gen_.validateCycleUniformLive("mark slice", /*exact=*/false);
    }
#endif
    // threaded-gc-05c: a concurrent step with no in-pause mark work is a plain
    // minor pause (kind 0), and its time is not a slice.
    if (conc && !old_gen_.lastStepHadPauseWork()) return;
    notePauseCycleWork(1);
    const uint64_t dur = cycleNowNs() - t_start;
    cycle_mark_ns_ += dur;
    cycle_inpause_ns_ += dur;
#if ENABLE_GC_STATS
    {
        IncrMarkStats& im = old_gen_.getStats().im;
        im.slice_ns_total += dur;
        if (dur > im.slice_ns_max) im.slice_ns_max = dur;
    }
#endif
}
// TLA-REGION(TLH.stepMarkCycle) end

// TLA-REGION(TLH.finishMarkCycleNow) begin
void ThreadLocalHeap::finishMarkCycleNow(OldGenSpace::CycleFinish why) {
    assert(old_gen_.cycleActive());
    assert(!old_gen_.in_slice_ && "IM9: a join inside a mark slice");
    ECO_TLA_TRACE(why == OldGenSpace::CycleFinish::Pressure ? "pressure"
                  : why == OldGenSpace::CycleFinish::Join ? "join" : "finish",
                  "marking", old_gen_.cycleState() == OldGenSpace::CycleState::Marking);
    if (old_gen_.cycleState() == OldGenSpace::CycleState::Marking) {
        const uint64_t t_start = cycleNowNs();
        old_gen_.drainCycleMark();
        const uint64_t dur = cycleNowNs() - t_start;
        cycle_mark_ns_ += dur;
        cycle_inpause_ns_ += dur;
    }
    completeMarkCycle(why);
}
// TLA-REGION(TLH.finishMarkCycleNow) end

// TLA-REGION(TLH.completeMarkCycle) begin
void ThreadLocalHeap::completeMarkCycle(OldGenSpace::CycleFinish why) {
#if ECO_HEAP_VALIDATE
    // IM1 (check half) and IM2, before anything is freed.
    old_gen_.assertAllMarked(old_gen_.cycle_t0_reach_, "IM1 reachable at t0");
    old_gen_.cycle_t0_reach_.clear();
    {
        bool complete = false;
        std::vector<void*> now = traceOldReachableForValidation(&complete);
        if (complete) old_gen_.assertAllMarked(now, "IM2 reachable at handoff");
    }
#endif
#if ENABLE_GC_STATS
    {
        IncrMarkStats& im = old_gen_.getStats().im;
        if (why == OldGenSpace::CycleFinish::Schedule) im.finish_schedule++;
        else if (why == OldGenSpace::CycleFinish::Pressure) im.finish_pressure++;
        else im.finish_join++;
    }
#else
    (void)why;
#endif
    const uint64_t units = old_gen_.cycleUnitsDone();
    const uint32_t span_minors = old_gen_.cycleMinorsSinceT0();
    const uint64_t t_start = cycleNowNs();
    MajorGCPhaseProfile prof;
#if ENABLE_GC_STATS
    old_gen_.handoffMarkCycle(&stats_, &prof);
#else
    old_gen_.handoffMarkCycle(nullptr, &prof);
#endif
    // M1 trace: H_Free (logged after the tail, whose "tail" probe records the marks it frees by)
    ECO_TLA_TRACE("handoff", "k", span_minors,
                  "why", why == OldGenSpace::CycleFinish::Pressure ? "pressure"
                         : why == OldGenSpace::CycleFinish::Join ? "join" : "schedule");
    pause_had_major_ = true;   // one major per cycle for the decommit clock
    notePauseCycleWork(2);
    const uint64_t dur = cycleNowNs() - t_start;
    if (gcPhaseProfileEnabled()) {
        std::fprintf(stderr,
            "[gc-profile] cycle handoff units=%llu span_minors=%u handoff=%.3fms"
            " tail_sweep=%.3fms live=%zu garbage=%zu alldead=%zu/%zub demoted=%zu/%zub"
            " sweep_pending=%zu\n",
            (unsigned long long)units, span_minors, dur / 1e6, prof.sweep_ns / 1e6,
            prof.live_bytes_after, prof.garbage_bytes, prof.alldead_blocks_released,
            prof.alldead_bytes_released, prof.demoted_blocks, prof.demoted_bytes,
            prof.sweep_pending_blocks);
        std::fflush(stderr);
    }
    cycle_inpause_ns_ += dur;
#if ENABLE_GC_STATS
    {
        IncrMarkStats& im = old_gen_.getStats().im;
        im.handoff_ns_total += dur;
        if (dur > im.handoff_ns_max) im.handoff_ns_max = dur;
    }
    GC_STATS_MAJOR_RECORD_GC_END(stats_, cycle_inpause_ns_);
    stats_.recordMajorGCEvent(
        cycle_inpause_ns_,
        /*root_scan_ns=*/0,
        /*root_push_ns=*/0,
        cycle_mark_ns_,
        prof.sweep_ns,
        prof.capacity_ns,
        old_gen_.getAllocatedBytes(),
        prof.live_bytes_after,
        prof.garbage_bytes,
        prof.alldead_bytes_released,
        prof.shrink_bytes_released,
        units,
        /*mark_stack_peak=*/0,
        prof.blocks_scanned,
        nursery_.getStats().minor_gc_count,
        nursery_.getStats().objects_promoted);
#if ENABLE_GC_PHASE_TIMERS
    if (gcEventLogEnabled() && stats_.major_gc_events_used > 0) {
        const GCStats::MajorGCEvent& ev =
            stats_.major_gc_events[stats_.major_gc_events_used - 1];
        gcEventLogMajor(ev.seq, ev.start_ns, ev.total_ns, ev.mark_ns, ev.sweep_ns,
                        ev.root_scan_ns + ev.root_push_ns, gcMajorReasonName(ev.reason));
        // threaded-gc-05c (P§3.13): progress and pacing columns ride in the
        // reason field as key=value pairs (the row layout is fixed).
        const OldGenSpace::CycleProgress cp = old_gen_.cycleProgress();
        char reason[256];
        std::snprintf(reason, sizeof reason,
            "%s;done_k=%u;bg_units=%llu;assists=%llu;assist_units=%llu;closing_units=%llu;%s",
            why == OldGenSpace::CycleFinish::Schedule ? "schedule"
            : why == OldGenSpace::CycleFinish::Pressure ? "pressure" : "join",
            cp.done_k, (unsigned long long)cp.bg_units, (unsigned long long)cp.assists,
            (unsigned long long)cp.assist_units, (unsigned long long)cp.closing_units,
            old_gen_.pacingSnapshot().c_str());
        gcEventLogCycle(ev.seq, ev.start_ns, cycleNowNs() - cycle_t0_wall_ns_,
                        span_minors, units, reason);
    }
#endif
#endif
    (void)span_minors;
    (void)units;
}
// TLA-REGION(TLH.completeMarkCycle) end

#if ECO_HEAP_VALIDATE
// IM1/IM2: an INDEPENDENT tracer (its own visited set, visitHeapChildren
// rather than markChildren) from every root, through young and old objects.
// Returns the old-gen objects reached; `complete` is false when the walk hit
// the 5 M-object cap (the caller then skips the check).
std::vector<void*> ThreadLocalHeap::traceOldReachableForValidation(bool* complete) {
    constexpr size_t kCap = 5'000'000;
    std::unordered_set<void*> seen;
    std::vector<void*> stack;
    std::vector<void*> old_out;
    auto push = [&](HPointer& hp) {
        if (hp.ptr_ind != 0) return;
        void* o = Allocator::fromPointerRaw(hp);
        if (!o || !parent_->isInHeap(o)) return;
        if (seen.insert(o).second) stack.push_back(o);
    };
    RootSet& root_set = nursery_.getRootSet();
    for (HPointer* root : root_set.getRoots()) push(*root);
    for (uint64_t* root : root_set.getJitRoots()) {
        const uint64_t val = *root;
        if (isConstantBits(val)) continue;
        void* o = reinterpret_cast<void*>(val);
        if (o && parent_->isInHeap(o) && seen.insert(o).second) stack.push_back(o);
    }
    forEachMajorRoot(root_set, [&](HPointer& hp, int) { push(hp); });
    *complete = true;
    while (!stack.empty()) {
        if (seen.size() > kCap) { *complete = false; break; }
        void* o = stack.back();
        stack.pop_back();
        if (old_gen_.contains(o)) old_out.push_back(o);
        visitHeapChildren(o, [&](HPointer& c) { push(c); });
    }
    return old_out;
}
#endif

const std::unordered_set<HPointer*>& ThreadLocalHeap::collectRoots() {
    // Returns only long-lived roots. Stackmap roots and stack root ranges
    // are marked via explicit loops in majorGC().
    return nursery_.getRootSet().getRoots();
}

ThreadLocalHeap::StackWalkCounts ThreadLocalHeap::collectStackRootsFromStackMap() {
    StackWalkCounts counts;
    StackMap& sm = globalStackMap();
    if (!sm.hasRecords()) {
#if ECO_GC_DEBUG
        static bool warned = false;
        if (!warned) {
            fprintf(stderr, "[gc-stackmap] WARNING: no stack map records found! Stack roots will NOT be tracked.\n");
            warned = true;
        }
#endif
        return counts;
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
        ++counts.frames_walked;
        uintptr_t ip = cur.ip();
        const StackMapRecord* rec = sm.findRecord(ip + kIpToReturnAddressBias);
        if (!rec) {
            continue;
        }
        ++counts.frames_matched;

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
    counts.slots = sm_roots.get().size();

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
    return counts;
}

} // namespace Elm
