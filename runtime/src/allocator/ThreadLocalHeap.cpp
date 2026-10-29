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
#include <execinfo.h>   // ECO_LARGE_PTR_TRACE backtraces
#include <fcntl.h>
#include <unistd.h>
#endif
// A C library without <execinfo.h>, such as musl, gets no-op stand-ins so that the backtrace calls below compile;
// they then print no frames.
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

// Returns whether ECO_GC_PHASE_PROFILE is set to anything other than empty or "0", read once per process. When it
// is, each stop-the-world major and each cycle handoff prints a "[gc-profile]" line to stderr.
inline bool gcPhaseProfileEnabled() {
    static const bool enabled = []{
        const char* e = std::getenv("ECO_GC_PHASE_PROFILE");
        if (e == nullptr || e[0] == '\0') return false;
        return !(e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

// Returns the nanoseconds from `a` to `b`.
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
// Adds one to the counter in `stats` for the major-collection trigger `reason`. Headroom shares the global-pressure
// counter, and LiveBudget the garbage counter; None counts nothing.
static inline void
recordMajorTriggerReason(GCStats& stats,
                         OldGenSpace::MajorGCTriggerReason reason) {
    switch (reason) {
        case OldGenSpace::MajorGCTriggerReason::Occupancy:
            stats.major_gc_occupancy_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::GlobalPressure:
        case OldGenSpace::MajorGCTriggerReason::Headroom:
            stats.major_gc_global_pressure_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::GarbageFraction:
        case OldGenSpace::MajorGCTriggerReason::LiveBudget:
            stats.major_gc_garbage_triggers++;
            break;
        case OldGenSpace::MajorGCTriggerReason::None:
            break;
    }
}
#endif

// Returns the event-log reason for the trigger `reason`, and Unknown for None. The two enumerations are separate
// because the log also names causes that are not triggers, such as an allocation failure or a forced collection.
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

[[noreturn]] void ecoFatalWideObject(const char* where, u32 n) {
    std::fprintf(stderr, "[eco] FATAL: %s: %u slots exceeds the wide-object limit (HEAP_019)\n",
                 where, n);
    std::fflush(stderr);
    std::abort();
}

void initHeaderForTag(Header* hdr, Tag tag, size_t size) {
    zeroNewObject(hdr, size);
    Header h{};
    h.tag = tag;

    switch (tag) {
        case Tag_String:
            h.size = (size - sizeof(ElmString)) / sizeof(u16);
            break;
        case Tag_StringSlice:
        case Tag_StringRope:
        case Tag_StringUtf8View:
            // The constructors set header.size to the logical UTF-16 length, which the byte size does not give.
            h.size = 0;
            break;
        case Tag_StringUtf8Leaf:
            // One unit per payload byte.
            h.size = static_cast<u32>(size - sizeof(ElmStringUtf8Leaf));
            break;
        case Tag_Custom:
        case Tag_Record: {
            // The byte size covers W = n + K words; split it into the field count n and the extension words K,
            // and zero those words, which zeroNewObject left.
            const bool isC = tag == Tag_Custom;
            const size_t base = isC ? sizeof(Custom) : sizeof(Record);
            const u32 cap  = isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS;
            const u32 maxN = isC ? CUSTOM_MAX_FIELDS : RECORD_MAX_FIELDS;
            const u32 W = static_cast<u32>((size - base) / sizeof(Unboxable));
            u32 n = 0, k = 0;
            if (!splitPhysicalSlots(W, cap, n, k) || n > maxN)
                ecoFatalWideObject(isC ? "initHeaderForTag(Custom)" : "initHeaderForTag(Record)", W);
            h.size = n;
            h.unboxed = k;
            if (k)
                std::memset(reinterpret_cast<char*>(hdr) + base + size_t(n) * sizeof(Unboxable), 0,
                            size_t(k) * sizeof(Unboxable));
            break;
        }
        case Tag_DynRecord:
            h.size = (size - sizeof(DynRecord)) / sizeof(HPointer);
            break;
        case Tag_FieldGroup:
            h.size = (size - sizeof(FieldGroup)) / sizeof(u32);
            break;
        case Tag_Closure:
            h.size = (size - sizeof(Closure)) / sizeof(Unboxable);
            break;
        default:
            h.size = static_cast<u32>(size);
            break;
    }
    std::memcpy(hdr, &h, sizeof(Header));

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
    old_gen_.initialize(parent_, config_);
    nursery_.initialize(this, config_);
    // Marking tells young from old by this heap's nursery, not the calling thread's (HEAP_053).
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
    // The file is opened for appending so that forked test children, which _exit without printing statistics,
    // can all write to it. A file that cannot be opened turns the trace off.
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
    // Trace builds only: tells the M6 fork model that a forked child's exit reached this destructor (CR-031).
    ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.tlh.dtor");)
    // The old generation is destroyed before the nursery, so the tenure job, which writes into it, is finished
    // while it still exists.
    nursery_.tenureTeardown(old_gen_);
    p1::forget(old_gen_);
}
// TLA-REGION(TLH.destructor) end

// ============================================================================
// Allocation.
// ============================================================================

void* ThreadLocalHeap::allocate(size_t size, Tag tag) {
    size = (size + 7) & ~static_cast<size_t>(7);

    if (size >= config_->large_object_threshold) {
        switch (placeLarge(size, tag)) {
            case LargePlacement::PointerFree: return allocateLargePinned(size, tag);
            case LargePlacement::Ylos:        return allocateYoungLarge(size, tag);
            default:
                noteLargeAlloc(LargePlacement::Nursery, size, tag);
                break;
        }
    }

    // The nursery's limit already accounts for its collection threshold, so one compare checks room and threshold.
    void* obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    minorGC();
    obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // The survivors left less room below the threshold than this object needs. Collecting again cannot help, as
    // nothing has been allocated since, so use the rest of the extent.
    nursery_.failSoftUnclamp();
    obj = nursery_.allocate(size);
    if (obj) {
        initHeaderForTag(getHeader(obj), tag, size);
        return obj;
    }

    // The nursery is full. An old-generation object is not an option: its fields, filled in afterwards, could
    // point at young objects (HEAP_062). The YLOS is young, so a large object can still go there.
    if (size >= config_->large_object_threshold) {
        return allocateYoungLarge(size, tag);
    }
    assert(false && "Failed to allocate to nursery, it is full.");
    return nullptr;
}

void* ThreadLocalHeap::allocateFast(size_t size) {
    size = (size + 7) & ~static_cast<size_t>(7);
    if (__builtin_expect(size > nursery_.regionLargeCap(), 0)) return nullptr;
    return nursery_.allocate(size);
}

void* ThreadLocalHeap::allocateSlow(size_t size, Tag tag) {
    size = (size + 7) & ~static_cast<size_t>(7);

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
    size = (size + 7) & ~static_cast<size_t>(7);
    assert(size < config_->large_object_threshold &&
           "allocateSlowRaw: inline-alloc size must be below the LOT threshold");

    minorGC();

    void* obj = nursery_.allocate(size);
    if (obj) {
        return obj;
    }

    nursery_.failSoftUnclamp();
    obj = nursery_.allocate(size);
    if (obj) {
        return obj;
    }

    assert(false && "Failed to allocate after GC in slow path (raw).");
    return nullptr;
}

void ThreadLocalHeap::ensureNursery(size_t n) {
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

    // A threshold below `n`, possible only in a very small nursery, would make every collection leave too little
    // room, so use the rest of the extent.
    nursery_.failSoftUnclamp();
    if (nursery_.ensureHeadroom(n)) {
        return;
    }

    assert(false && "ensureNursery: cannot satisfy after GC (HEAP_017)");
}

void* ThreadLocalHeap::allocateRegionSlow(size_t total) {
    total = (total + 7) & ~static_cast<size_t>(7);

    // A large region is bounded by the whole nursery, not by the cap placeLarge applies to a single object.
    const bool large = total >= config_->large_object_threshold;
    if (large) {
        noteLargeAlloc(LargePlacement::Region, total, Tag_Closure);
    }

    minorGC();

    void* obj = nursery_.allocate(total);
    if (obj) return obj;

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

size_t ThreadLocalHeap::directAllocBudget() const {
    const double f = config_->direct_alloc_minor_budget;
    if (!(f > 0.0)) return 0;
    size_t b = static_cast<size_t>(f * static_cast<double>(nursery_.minorThresholdBytes()));
    // The bound by the cap makes a minor, where a running mark cycle takes its next step, come due after about a
    // 32nd of the cap has been allocated directly, however large the nursery is.
    const size_t cap = parent_->getOldGenMaxBytes();
    if (cap != 0) b = std::min(b, cap / 32);
    return std::max<size_t>(b, 1);
}

void ThreadLocalHeap::noteDirectAlloc(size_t bytes) {
    const uint64_t seq = nursery_.minorSeq();
    if (seq != direct_debt_seq_) {   // a minor has run since the last note
        direct_debt_seq_ = seq;
        direct_debt_bytes_ = 0;
    }
    direct_debt_bytes_ += bytes;
#if ENABLE_GC_STATS
    stats_.direct_debt_bytes_total += bytes;
#endif
    const size_t budget = directAllocBudget();
    if (budget != 0 && direct_debt_bytes_ >= budget && nursery_.requestMinor()) {
#if ENABLE_GC_STATS
        stats_.minor_gc_debt_requests++;
#endif
    }
}

[[noreturn]] void ThreadLocalHeap::largeBodyExhausted(const char* kind, size_t body_size) {
    std::fprintf(stderr,
                 "eco: out of memory: cannot allocate a %zu-byte large %s body (old generation "
                 "%zu of %zu bytes in use after a minor and a major GC)\n",
                 body_size, kind, parent_->getOldGenCommittedBytes(),
                 parent_->getOldGenMaxBytes());
    std::abort();
}

void* ThreadLocalHeap::allocateYoungLarge(size_t size, Tag tag) {
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
    noteDirectAlloc(size);
    return obj;
}

void* ThreadLocalHeap::allocateLargePinned(size_t size, Tag tag) {
    assert(!tagMayHoldPointers(tag) &&
           "allocateLargePinned: pointer-bearing objects go to the nursery or YLOS");
    noteLargeAlloc(LargePlacement::PointerFree, size, tag);
    void* obj = old_gen_.allocateOldLarge(size, tag);
    if (!obj) {
#if ENABLE_GC_STATS
        stats_.major_gc_alloc_failure_triggers++;
#endif
        majorGC(GCStats::MajorReason::AllocFailure);
        obj = old_gen_.allocateOldLarge(size, tag);
    }
    if (!obj) {
        assert(false && "Failed to allocate large pinned object in old gen.");
        return nullptr;
    }
    noteDirectAlloc(size);
    return obj;
}

HPointer ThreadLocalHeap::allocLargeString(const u16* chars, size_t length) {
    // A body registered before a minor collection with no header pointing at it would carry the old minor
    // colour, and the large-body sweep at the end of that collection would free it. So the header comes first, and
    // nothing between registering the body and storing it in the header can collect. An abandoned header, with
    // its null body, is unreachable garbage that every collector path skips.
    const size_t body_size = (length * sizeof(u16) + 7) & ~static_cast<size_t>(7);
    for (int attempt = 0;; ++attempt) {
        const size_t header_size = sizeof(LargeStringHeader);
        void* header_obj = allocate(header_size, Tag_LargeStringHeader);
        assert(header_obj && "Failed to allocate large string header in nursery");
        LargeStringHeader* h = static_cast<LargeStringHeader*>(header_obj);
        h->header.size = static_cast<u32>(length);
        h->body = hpFromBits(0);  // null HPointer (all fields zero)
        HPointer header_hp = parent_->wrap(header_obj);

        // This cannot collect, so header_obj stays where it is.
        void* body =
            old_gen_.allocateLargeBody(body_size, length, Tag_String,
                                       nursery_.minor_color_);
        if (!body) {
            if (attempt == 0) {
#if ENABLE_GC_STATS
                stats_.large_body_recover_minors++;
#endif
                minorGC();
                continue;
            }
            if (attempt == 1) {
#if ENABLE_GC_STATS
                stats_.large_body_recover_majors++;
                stats_.major_gc_alloc_failure_triggers++;
#endif
                majorGC(GCStats::MajorReason::AllocFailure);
                continue;
            }
            largeBodyExhausted("string", body_size);
        }

        if (chars && length > 0) {
            std::memcpy(body, chars, length * sizeof(u16));
        }

        h->body = parent_->wrap(body);
        noteDirectAlloc(body_size);
        return header_hp;
    }
}

HPointer ThreadLocalHeap::allocLargeByteBuffer(const u8* data, size_t length) {
    // Ordered as allocLargeString is, for the same reason.
    const size_t body_size = (length + 7) & ~static_cast<size_t>(7);
    for (int attempt = 0;; ++attempt) {
        const size_t header_size = sizeof(LargeByteHeader);
        void* header_obj = allocate(header_size, Tag_LargeByteHeader);
        assert(header_obj && "Failed to allocate large byte buffer header in nursery");
        LargeByteHeader* h = static_cast<LargeByteHeader*>(header_obj);
        h->header.size = static_cast<u32>(length);
        h->body = hpFromBits(0);  // null HPointer (all fields zero)
        HPointer header_hp = parent_->wrap(header_obj);

        void* body =
            old_gen_.allocateLargeBody(body_size, length, Tag_ByteBuffer,
                                       nursery_.minor_color_);
        if (!body) {
            if (attempt == 0) {
#if ENABLE_GC_STATS
                stats_.large_body_recover_minors++;
#endif
                minorGC();
                continue;
            }
            if (attempt == 1) {
#if ENABLE_GC_STATS
                stats_.large_body_recover_majors++;
                stats_.major_gc_alloc_failure_triggers++;
#endif
                majorGC(GCStats::MajorReason::AllocFailure);
                continue;
            }
            largeBodyExhausted("byte buffer", body_size);
        }

        if (data && length > 0) {
            std::memcpy(body, data, length);
        } else if (length > 0) {
            std::memset(body, 0, length);
        }

        h->body = parent_->wrap(body);
        noteDirectAlloc(body_size);
        return header_hp;
    }
}

void* ThreadLocalHeap::allocatePermanent(size_t size, Tag tag) {
    size = (size + 7) & ~static_cast<size_t>(7);
    if (size >= config_->large_object_threshold) {
        void* big = old_gen_.allocateOldLarge(size, tag);
        assert(big && "Failed to allocate a large permanent object in old gen.");
        return big;
    }
    void* obj = old_gen_.allocate(size);
    if (obj) {
        GC_STATS_OLDGEN_DIRECT_RECORD_ALLOC(stats_, size);
        Header* hdr = getHeader(obj);
        u32 saved_color = hdr->color;
        initHeaderForTag(hdr, tag, size);
        // Restores the colour OldGenSpace::allocate gave the object, which initHeaderForTag cleared.
        Header h = loadHeaderRelaxed(hdr);
        h.color = saved_color;
        storeHeaderRelaxed(hdr, h);
        return obj;
    }

    assert(false && "Failed to allocate in old gen.");
    return nullptr;
}

// ============================================================================
// Collection.
// ============================================================================

bool ThreadLocalHeap::shouldCollectAtSafepoint() const {
    if (force_gc_)
        return true;
    if (isNurseryNearFull(config_->nursery_gc_threshold))
        return true;
    return old_gen_.shouldTriggerMajorGC();
}

void ThreadLocalHeap::collectAtSafepoint() {
    force_gc_ = false;
    // A minor collection evaluates the major triggers itself at its end, so the major is needed here only when
    // the nursery is not full.
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
// A scope that times a pause: constructed at the start of every minorGC/majorGC/majorGCAndShrink call, it records
// one pause when the outermost call ends, so a minor that runs a major is one pause. `h` must outlive it.
struct GCPauseScope {
    ThreadLocalHeap& h;
    // Starts timing if this is the outermost call, and notes whether this call is a major.
    GCPauseScope(ThreadLocalHeap& heap, bool is_major) : h(heap) {
        if (h.gc_depth_++ == 0) {
            h.pause_start_ns_ = GCStats::nowSinceProcessStartNs();
            h.pause_saw_minor_ = false;
            h.pause_saw_major_ = false;
            h.pause_saw_t0_ = h.pause_saw_slice_ = h.pause_saw_handoff_ = false;
            h.pause_cpu_start_ns_ = gc::GCHelperPool::threadCpuNs();
        }
        (is_major ? h.pause_saw_major_ : h.pause_saw_minor_) = true;
    }
    ~GCPauseScope() {
        if (--h.gc_depth_ == 0) {
            const uint64_t now = GCStats::nowSinceProcessStartNs();
            uint8_t kind = h.pause_saw_minor_ ? (h.pause_saw_major_ ? 1 : 0) : 2;
            // A minor pause that carried cycle work takes the kind of that work: handoff, then t0, then step.
            if (kind == 0) {
                if (h.pause_saw_handoff_) kind = 5;
                else if (h.pause_saw_t0_) kind = 3;
                else if (h.pause_saw_slice_) kind = 4;
            }
            h.recordPause(h.pause_start_ns_, now - h.pause_start_ns_, kind);
            // The mutator's CPU time, in pauses and in total.
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

// A scope that ends a pause: constructed in every minorGC/majorGC/majorGCAndShrink call, it reports the sync point
// (Allocator::onGCPauseEnd) when the outermost call ends. Declared after GCPauseScope in each function, so it is
// destroyed first and the sync point's own work is timed as part of the pause. `h` and `parent` must outlive it.
struct PauseEndHook {
    ThreadLocalHeap& h;
    Allocator* parent;
    // Enters one level of the pause.
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
// This function's PauseEndHook is the outermost, so the nested majorGC's is an inner one and the single sync point
// comes after the sweep and the shrink.
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
    PauseEndHook pause_end(*this, parent_);
    auto now = []() -> uint64_t {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    };
    ReleaseTimings t{};
    uint64_t s = now();
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
    // The previous tenure job is joined and merged before the minor touches the heap.
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
    // This minor's tenure job is launched on every return path below, after any cycle work or major in this pause.
    struct TenureLaunchScope {
        ThreadLocalHeap& h;
        ~TenureLaunchScope() {
            if (h.nursery_.regionMode()) h.nursery_.tenureLaunch(h.old_gen_);
        }
    } tenure_launch{*this};
    if (Allocator::heapTraceEnabled()) {
        parent_->dumpHeapState("minorGC end");
    }
    // Before the cycle step and the triggers, which read the estimate.
    old_gen_.notePacingMinorEnd();

    // A minor promotes into the old generation, so this is where its triggers come to hold. While a cycle runs,
    // the minor end is a step of it instead, and a pause that runs the handoff does not evaluate the triggers.
    if (old_gen_.cycleActive()) {
        stepMarkCycle();
        return;
    }
    if (__builtin_expect(test_force_major_trigger_, 0)) {
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
    // The tenure job is joined and merged first, so the mark sees its copies.
    if (nursery_.regionMode()) nursery_.tenureJoin(old_gen_, 1, nullptr);
    // A cycle frees only what was dead at its t0, and a major run for an allocation failure or on request must free
    // everything dead now, so a running cycle is finished first and the major then runs as well.
    if (old_gen_.cycleActive()) {
        finishMarkCycleNow(OldGenSpace::CycleFinish::Join);
    }
    const bool profile_phases = gcPhaseProfileEnabled();

    // Unlike minorGC's, this dump and the one at the end are not conditional on heapTraceEnabled(), so a build with
    // ECO_HEAP_TRACE prints them on every major.
    parent_->dumpHeapState("majorGC begin");

#if ENABLE_GC_STATS
    auto gc_start = GC_STATS_TIMER_START();
    // The old generation as the major found it.
    stats_.beginMajorGCEvent(reason,
                             old_gen_.getAllocatedBytes(),
                             old_gen_.getCommittedBytes());
#endif

    // The clock is read whether or not profiling is on; getrusage only when it is.
    auto t_enter = std::chrono::high_resolution_clock::now();
    long pf_enter_minor = 0, pf_enter_major = 0;
    long ctx_enter_vol = 0, ctx_enter_invol = 0;
#if defined(RUSAGE_THREAD)
    // Without RUSAGE_THREAD the fault and context-switch counts print as 0.
    struct rusage ru_enter;
    if (profile_phases && getrusage(RUSAGE_THREAD, &ru_enter) == 0) {
        pf_enter_minor = ru_enter.ru_minflt;
        pf_enter_major = ru_enter.ru_majflt;
        ctx_enter_vol  = ru_enter.ru_nvcsw;
        ctx_enter_invol = ru_enter.ru_nivcsw;
    }
#endif

    collectStackRootsFromStackMap();

    RootSet& root_set = nursery_.getRootSet();

    const std::unordered_set<HPointer*>& roots = collectRoots();
    const std::unordered_set<uint64_t*>& jit_roots = root_set.getJitRoots();

    auto t_after_root_collect = std::chrono::high_resolution_clock::now();

    p1::verifyOldGen(old_gen_, "major-start");

#if ENABLE_GC_STATS
    old_gen_.startMark(roots, jit_roots, *parent_, stats_);
#else
    old_gen_.startMark(roots, jit_roots, *parent_);
#endif

    size_t stackmap_roots_pushed = 0;
    size_t stackrange_roots_pushed = 0;
    size_t external_roots_pushed = 0;

    forEachMajorRoot(root_set, [&](HPointer& hp, int kind) {
        old_gen_.markHPointer(hp);
        if (kind == 0) ++stackmap_roots_pushed;
        else if (kind == 1) ++stackrange_roots_pushed;
        else ++external_roots_pushed;
    });

    auto t_after_root_push = std::chrono::high_resolution_clock::now();

    Elm::MajorGCPhaseProfile phase_profile;
#if ENABLE_GC_STATS
    // Statistics builds always take the phase times, which the per-major event log needs.
    (void)profile_phases;
    old_gen_.finishMarkAndSweep(stats_, phase_profile);
#else
    if (profile_phases) {
        old_gen_.finishMarkAndSweep(phase_profile);
    } else {
        old_gen_.finishMarkAndSweep();
    }
#endif

    // A survivor this major did not reach is dead, and the old objects it refers to may now be freed, so it is
    // turned into a filler (HEAP_074, CR-017).
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
        // The wall-clock time of finishMarkAndSweep, printed beside its own mark and sweep figures as a check.
        const uint64_t finish_ns     = nsBetween(t_after_root_push, t_done);
        const uint64_t accounted_ns  = root_scan_ns + root_push_ns
                                     + phase_profile.mark_ns
                                     + phase_profile.sweep_ns;
        const int64_t  unaccounted_ns =
            static_cast<int64_t>(total_ns) - static_cast<int64_t>(accounted_ns);

        // The major's sequence number exists only in statistics builds; 0 otherwise.
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
    // The current capacity, not the configured one, since the nursery grows. Object bytes exclude fillers
    // (HEAP_068).
    size_t total_capacity = nursery_.from_capacity_bytes_;
    size_t usage = nursery_.objectBytesAllocated();
    return usage >= static_cast<size_t>(total_capacity * threshold);
}

// The mark cycle driver (HEAP_063).

template <typename F>
void ThreadLocalHeap::forEachMajorRoot(RootSet& root_set, F&& f) {
    for (HPointer* slot : stack_map_roots_.get()) f(*slot, 0);
    for (const auto& range : root_set.getStackRootRanges()) {
        HPointer* base = range.base;
        uint64_t mask = range.hpointer_mask;
        for (size_t i = 0; i < range.count; ++i) {
            if (stackRangeSlotIsRoot(mask, i)) f(base[i], 1);
        }
    }
    for (HPointer* slot : root_set.getSingleRoots()) f(*slot, 1);
    // External scanners report words of stores outside the heap (HEAP_SNAPSHOT_002).
    for (auto& scanner : root_set.getExternalRootScanners()) {
        scanner([&f](uint64_t& ref) {
            HPointer hp;
            std::memcpy(&hp, &ref, sizeof(hp));
            f(hp, 2);
        });
    }
}

// ============================================================================
// The incremental mark cycle.
// ============================================================================

// Returns the steady clock's time in nanoseconds.
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
    // The list is rebuilt; the minor that just ran updated the slots in place, so they hold the new addresses.
    collectStackRootsFromStackMap();
    RootSet& root_set = nursery_.getRootSet();
    p1::verifyOldGen(old_gen_, "cycle-start");

    // With incremental marking off, the cycle exists only to mark on several threads, and has no steps.
    const uint32_t slices = config_->incremental_mark ? config_->incremental_mark_slices : 0;
    old_gen_.beginMarkCycle(*parent_, slices);
    ECO_TLA_TRACE("t0", "T", slices);   // M1 trace: P_T0 (the snapshot's greys follow)
    cycle_t0_wall_ns_ = t_start;
    cycle_mark_ns_ = 0;
    cycle_inpause_ns_ = 0;

    // The snapshot: the old objects every root refers to are greyed. Young targets are dropped in snapshot mode,
    // because the old objects every young object refers to are greyed below.
    old_gen_.setSnapshotMode(true);
    for (HPointer* root : root_set.getRoots()) old_gen_.markHPointer(*root);
    for (uint64_t* root : root_set.getJitRoots()) old_gen_.markJitRootRaw(*root, *parent_);
    forEachMajorRoot(root_set, [&](HPointer& hp, int kind) {
        if (kind == 2 && test_snapshot_skip_external_) return;
        old_gen_.markHPointer(hp);
    });
    old_gen_.snapshotYoungLarge();
    size_t surv_bytes = 0;
    size_t survivors = 0;
    if (!test_snapshot_skip_young_walk_) {
        // In region mode this includes the Tenuring extent, which is young at t0 and promoted after it.
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
    // IM1: every old object reachable at t0 must be marked at the handoff; record them now, unless there are too
    // many.
    {
        bool complete = false;
        old_gen_.cycle_t0_reach_ = traceOldReachableForValidation(&complete);
        if (!complete) old_gen_.cycle_t0_reach_.clear();
    }
#endif
    // Last of the t0 work, because background markers may start here and nothing else in this pause may run
    // beside them.
    ECO_TLA_TRACE("t0end", "greys", old_gen_.markStackSize());   // no marker is running yet (IM14)
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
    // No steps: the whole cycle runs in this pause.
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
    // IM6 reads every marker's totals, so only while no background marker runs.
    if (old_gen_.bgEpisode() != OldGenSpace::BgEpisode::Running) {
        old_gen_.validateCycleUniformLive("mark slice", /*exact=*/false);
    }
#endif
    // A concurrent step that did no marking in the pause leaves it a plain minor pause, and is not timed.
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
    // IM1 and IM2, checked before anything is freed: everything reachable at t0, and everything reachable now,
    // is marked.
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
    pause_had_major_ = true;   // the sync point counts a cycle as one major
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
        // The event log's row layout is fixed, so the cycle's progress and pacing go in its reason field as
        // key=value pairs.
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
// Independent of the mark: its own visited set, and visitHeapChildren rather than markChildren.
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
        if (old_gen_.isRawBody(o)) continue;   // HEAP_081: header-less, no children
        visitHeapChildren(o, [&](HPointer& c) { push(c); });
    }
    return old_out;
}
#endif

// ============================================================================
// Roots.
// ============================================================================

const std::unordered_set<HPointer*>& ThreadLocalHeap::collectRoots() {
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

    // What to add to a frame's IP to get the key the stack map records it under. For each caller frame the
    // unwinder gives the return address, which is that key.
    static constexpr int kIpToReturnAddressBias = 0;

    using namespace StackUnwind;
    Context ctx;
    Cursor cur(ctx);

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
            // An embedded constant is not a heap object, and resolve() asserts it is not given one.
            if (potential.ptr_ind != 0) {
                continue;
            }
            // A slot the stack map lists may hold null, and resolve() must not be given it.
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
    for (size_t ri = 0; ri < sm_roots.get().size(); ++ri) {
        HPointer* slot = sm_roots.get()[ri];
        HPointer val = *slot;
        uint64_t raw;
        memcpy(&raw, &val, sizeof(raw));
        fprintf(stderr, "[gc-stackmap-root] root[%zu] slot=%p val=0x%016lx (ptr=0x%lx const=%u)\n",
                ri, (void*)slot, raw, (unsigned long)val.ptr, (unsigned)val.constant);
    }
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
