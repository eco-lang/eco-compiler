#pragma once

// threaded-gc-03 (plans/threaded-gc-03-helper-threads.md P§3.6-3.7,
// HEAP_059/HEAP_060, GC_DET_001): page-level housekeeping of old-gen memory
// done through the GC helper pool. Two users:
//
//   U1 deferred decommit. A released extent stays Pending (resident) until it
//      has gone unused past `delay` sync points (or the pending-byte cap forces
//      it); then a Discard job MADV_DONTNEEDs it. A reuse of a Pending extent
//      cancels its discard; a reuse of a Posted one WAITS for the job. Posted
//      extents stay in the caller's free list, so which extent an allocation
//      gets never depends on helper progress.
//   U2 commit-ahead. At each sync point the range just above the old-gen bump
//      pointer is committed by the caller (mutator) and a Populate job
//      MADV_POPULATE_WRITEs it; the bump path then never re-maps that range.
//      A release overlapping an in-flight populate waits for it.
//
// Standalone: includes only GCHelperPool.hpp and std, so it compiles under
// the TSan harness with fake PageOps. NOT thread-safe: the caller serialises
// every call (Allocator::thread_mutex_). Helper threads only ever run the job
// bodies, which touch pages, never an HPointer.

#include <cstddef>
#include <cstdint>
#include <deque>
#include <unordered_map>
#include <utility>
#include <vector>

#include "GCHelperPool.hpp"

namespace Elm::gc {

struct PageOps {
    bool (*discard)(void* ctx, char* p, size_t n) = nullptr;    // MADV_DONTNEED
    bool (*populate)(void* ctx, char* p, size_t n) = nullptr;   // MADV_POPULATE_WRITE
    bool (*commit)(void* ctx, char* p, size_t n) = nullptr;     // map RW (commitAt)
    void* ctx = nullptr;
};

// Optional observers (event log, MMU stall list). Called on the caller's
// thread, with the caller's lock held.
struct PageWorkHooks {
    void (*on_stall)(void* ctx, uint64_t start_ns, uint64_t dur_ns,
                     HelperClient client, bool in_pause) = nullptr;
    void (*on_job_reaped)(void* ctx, const HelperJob& job) = nullptr;
    void* ctx = nullptr;
};

struct PageWorkConfig {
    bool     decommit = true;        // HeapConfig::decommit_on_oldgen_release
    uint32_t delay = 4;              // decommit_delay_syncs (UINT32_MAX = never)
    size_t   pending_cap = 0;        // decommit_pending_max_bytes (0 = none)
    uint32_t delay_majors = 0;       // decommit_delay_majors (0 = off)
    size_t   ahead_bytes = 0;        // commit_ahead_bytes (0 = off)
};

struct PageWorkCounters {
    uint64_t released_bytes = 0, released_extents = 0;
    uint64_t pending_bytes = 0, pending_peak_bytes = 0;
    uint64_t cancelled_bytes = 0, cancelled_extents = 0;       // reuse before discard
    uint64_t discard_posted_bytes = 0, discard_posted_extents = 0, discard_jobs = 0;
    uint64_t discard_failures = 0;
    uint64_t reuse_after_discard_bytes = 0;
    uint64_t reuse_never_discarded_bytes = 0;     // decommit off
    uint64_t fresh_ahead_hit_bytes = 0, fresh_ahead_miss_bytes = 0;
    uint64_t populate_posted_bytes = 0, populate_jobs = 0, populate_failures = 0;
    uint64_t window_commit_failures = 0;
    uint64_t reuse_waits = 0, release_waits = 0, slot_full_waits = 0;
    // CR-007 (HEAP_059): the no-wait acquire of a promotion holder with n > 1
    // workers (Allocator::acquireOldGenBlock, AcquireWait::AvoidUnderPromo).
    uint64_t nowait_pending_reuse_bytes = 0;   // Pending extents taken (cancelled, no wait)
    uint64_t nowait_skipped_extents = 0;       // fitting extents skipped: not Pending
    uint64_t nowait_fresh_bytes = 0;           // fresh bumps taken instead
    uint64_t nowait_fallback_waits = 0;        // cap fallbacks to first fit (may wait)
    bool     populate_supported = false;
};

class PageWork {
public:
    static constexpr size_t kJobSlots = 8;
    static constexpr size_t kWindowGranule = size_t{2} << 20;   // 2 MiB (THP)

    PageWork(PageOps ops, PageWorkConfig cfg, GCHelperPool& pool,
             PageWorkHooks hooks = {});
    ~PageWork();
    PageWork(const PageWork&) = delete;
    PageWork& operator=(const PageWork&) = delete;

    // An extent [p, p+n) was released to the free list (replaces the inline
    // MADV_DONTNEED). Waits for any in-flight populate overlapping it first.
    void onRelease(char* p, size_t n, bool in_pause);

    // The free-list extent at p is being reused (called BEFORE the caller
    // touches it). Cancels a pending discard, or waits for a posted one.
    // Returns what the caller gets: resident old contents, or discarded
    // (zero-fill-on-touch) pages.
    enum class Reuse : uint8_t { Cancelled, NeverDiscarded, AfterDiscard };
    Reuse onReuse(char* p, size_t n, bool in_pause);

    // A fresh bump acquire of [p, p+n). Returns the number of bytes the
    // caller must still commit, starting at *commit_from; the part inside
    // the commit-ahead window is already mapped and must NOT be re-mapped.
    size_t onFreshBump(char* p, size_t n, char** commit_from);

    // The pause-end sync point. `epoch` increases by one per call;
    // `major_epoch` counts completed major GCs (it increases at the sync
    // point that ends a pause containing a major). `bump` is the old-gen bump
    // pointer, `cap_end` the end of old-gen address space.
    void syncPoint(uint64_t epoch, uint64_t major_epoch, char* bump, char* cap_end,
                   bool in_pause);
    void syncPoint(uint64_t epoch, char* bump, char* cap_end, bool in_pause) {
        syncPoint(epoch, major_epoch_, bump, cap_end, in_pause);
    }

    // Waits for every posted job and reaps it. With discard_pending, also
    // discards every still-Pending extent synchronously (Allocator::reset).
    void drainAll(bool discard_pending);

    const PageWorkCounters& counters() const { return counters_; }
    char* windowEnd() const { return window_end_; }

    // ---- CR-007's no-wait acquire policy (Allocator::acquireOldGenBlock under
    // AcquireWait::AvoidUnderPromo; the caller holds thread_mutex_) ----
    // Membership in pending_ is JOB-BLIND (it changes only in onRelease,
    // onReuse and the sync point's aging), so a choice keyed on it keeps
    // GC_DET_001; never key a choice on posted_discard_ or a job's state.
    bool isPending(char* p) const { return pending_.count(p) != 0; }
    bool decommitOn() const { return cfg_.decommit; }
    enum class NoWaitPick : uint8_t { PendingReuse = 1, Fresh = 2, Fallback = 3 };
    // Records the policy's pick (counters; M7 trace event "nw" before the
    // onReuse / onFreshBump it precedes).
    void noteNoWait(NoWaitPick k, char* p, size_t n);
    void noteNoWaitSkip() { ++counters_.nowait_skipped_extents; }

    // ---- Validation / test queries (never used by policy code) ----
    enum TrackState : int { kPending = 1, kPostedDiscard = 2 };
    bool isPendingOrPosted(char* p) const;
    size_t trackedCount() const { return pending_.size() + posted_discard_.size(); }
    template <typename F> void forEachTracked(F&& f) const {
        for (const auto& kv : pending_) f(kv.first, kv.second.size, int(kPending));
        for (const auto& kv : posted_discard_) f(kv.first, kv.second.size, int(kPostedDiscard));
    }
    template <typename F> void forEachPopulateInFlight(F&& f) const {
        for (const auto& s : slots_) {
            if (s.kind == Kind::Populate && !s.isIdle()) f(s.lo, s.hi);
        }
    }
    bool allSlotsIdle() const;

private:
    enum class Kind : uint8_t { None, Discard, Populate };
    struct Extent { char* p; size_t n; };
    struct PageJob : HelperJob {
        Kind kind = Kind::None;
        std::vector<Extent> extents;     // Discard
        char* lo = nullptr;              // Populate range [lo, hi)
        char* hi = nullptr;
        const PageOps* ops = nullptr;
        uint64_t failures = 0;           // written by the runner, read after Done
        uint64_t seq = 0;                // post order, for "oldest slot"
    };
    struct Pending { size_t size; uint64_t epoch; uint64_t major_epoch; uint64_t seq; };
    struct OrderEntry { char* p; uint64_t seq; };
    struct Posted { size_t size; uint8_t slot; };

    static void runJob(HelperJob* j);
    PageJob& takeSlot(bool in_pause);
    void reap(PageJob& s);
    void reapDone();
    void awaitSlot(PageJob& s, bool in_pause, uint64_t& wait_counter);
    void awaitPopulateOverlapping(char* p, size_t n, bool in_pause);
    void postDiscardBatch(std::vector<Extent>& batch, bool in_pause);
    void topUpWindow(char* bump, char* cap_end, bool in_pause);

    PageOps ops_;
    PageWorkConfig cfg_;
    GCHelperPool& pool_;
    PageWorkHooks hooks_;
    PageJob slots_[kJobSlots];
    uint64_t next_seq_ = 1;
    uint64_t epoch_ = 0;                                  // last sync point seen
    uint64_t major_epoch_ = 0;                            // majors seen at it
    std::unordered_map<char*, Pending> pending_;
    std::deque<OrderEntry> pending_order_;                // release order; stale if seq differs
    uint64_t next_release_seq_ = 1;
    std::unordered_map<char*, Posted> posted_discard_;
    char* window_end_ = nullptr;
    std::vector<Extent> batch_;                           // scratch
    PageWorkCounters counters_;
};

} // namespace Elm::gc
