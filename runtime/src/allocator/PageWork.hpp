#pragma once

// Returning old-generation memory to the operating system, and mapping it ahead of need, are page operations
// that can be slow, and this component lets them run on the GC helper pool (`GCHelperPool`) instead of on the
// caller. It is the bookkeeping that decides which pages to hand to a helper and when, and that keeps the caller
// from touching pages a helper is still working on.
//
// It serves two uses.
//
// Deferred decommit. A released extent (a run of old-generation pages returned to the free list) is first
// *Pending*: it stays resident in case it is reused soon. At each sync point the extents that have been Pending
// longer than the configured delay, or enough of the oldest to bring the Pending total to or under its cap, are
// handed to one Discard job, and become *Posted* until that job is reaped. Reusing a Pending extent *cancels* its
// discard, and the pages keep their contents. Reusing a Posted extent waits for the job first.
//
// Commit-ahead. At a sync point the caller commits (maps) the range just above the old-generation bump pointer, up
// to `ahead_bytes` beyond it rounded up to `kWindowGranule`, and a Populate job faults those pages in. This range,
// up to `windowEnd()`, is the *commit-ahead window*. A later fresh bump into the window must not commit it again.
// Commit-ahead is used only if a populate of a probe page succeeds when the `PageWork` is built.
//
// A *sync point* is a call to `syncPoint`, which passes the caller's count of sync points as `epoch`. Delays are
// counted in that count, and optionally in major collections.
//
// A `PageWork` is not thread-safe: the caller must serialise every call to it. Helper threads run only the job
// bodies, which call the `PageOps` functions on page ranges and touch no Elm value. `PageOps` supplies the page
// operations, so this header includes only `GCHelperPool.hpp` and the standard library.

#include <cstddef>
#include <cstdint>
#include <deque>
#include <unordered_map>
#include <utility>
#include <vector>

#include "GCHelperPool.hpp"

namespace Elm::gc {

/// The page operations a `PageWork` performs, each called with `ctx` and the range `[p, p+n)`.
///
/// Each returns whether it succeeded. `discard` releases the range's physical pages and `populate` faults the range
/// in as writable. Both run inside helper jobs, which `GCHelperPool` runs on a helper thread or inline; `drainAll`
/// also calls `discard`, and the constructor's probe `populate`, on the caller. `commit` maps the range readable and
/// writable and is called on the caller. `discard` must be set if decommit is on, and `commit` if `populate` is.
/// A null `populate` turns commit-ahead off.
///
/// The `PageWork` keeps a copy, so `ctx` must stay valid, and the functions callable from helper threads, for the
/// life of the `PageWork`.
struct PageOps {
    bool (*discard)(void* ctx, char* p, size_t n) = nullptr;
    bool (*populate)(void* ctx, char* p, size_t n) = nullptr;
    bool (*commit)(void* ctx, char* p, size_t n) = nullptr;
    void* ctx = nullptr;
};

/// Optional observers of a `PageWork`'s helper jobs, each passed `ctx`. A null function is not called.
///
/// Both are called on the caller's thread, inside the `PageWork` call that waited for or reaped the job.
/// `on_stall` reports a wait for a job that blocked, with the stall's start and duration in `GCHelperPool::nowNs`
/// nanoseconds, the job's client and whether the wait was counted as inside a pause. `on_job_reaped` is shown each
/// job just before its slot is cleared; the reference is valid only during the call. The `PageWork` keeps a copy,
/// so `ctx` must stay valid for its life.
struct PageWorkHooks {
    void (*on_stall)(void* ctx, uint64_t start_ns, uint64_t dur_ns,
                     HelperClient client, bool in_pause) = nullptr;
    void (*on_job_reaped)(void* ctx, const HelperJob& job) = nullptr;
    void* ctx = nullptr;
};

/// The settings of a `PageWork`, fixed when it is built.
///
/// An extent is aged, and so discarded at a sync point, once more than `delay` sync points or more than
/// `delay_majors` major collections have passed since its release, whichever comes first.
struct PageWorkConfig {
    bool     decommit = true;        ///< False: released extents are never tracked or discarded.
    uint32_t delay = 4;              ///< In sync points. `UINT32_MAX`: never aged by sync points.
    size_t   pending_cap = 0;        ///< Bytes that may stay Pending before the oldest are discarded early; 0: no cap.
    uint32_t delay_majors = 0;       ///< In major collections. 0: never aged by majors.
    size_t   ahead_bytes = 0;        ///< How far above the bump pointer to commit ahead; 0: commit-ahead off.
};

/// Statistics of a `PageWork`, in bytes and counts. They are observations only. Most accumulate; `pending_bytes`
/// is the current Pending total.
///
/// `reuse_waits`, `release_waits` and `slot_full_waits` count waits for a helper job that blocked: on a reuse of a
/// Posted extent, on a release overlapping a populate, and on a full set of job slots. The `nowait_*` counters
/// record the picks reported to `noteNoWait` and `noteNoWaitSkip`.
struct PageWorkCounters {
    uint64_t released_bytes = 0, released_extents = 0;
    uint64_t pending_bytes = 0, pending_peak_bytes = 0;
    uint64_t cancelled_bytes = 0, cancelled_extents = 0;
    /// Bytes and extents discarded, whether by a job or synchronously in `drainAll`; `discard_jobs` counts only jobs.
    uint64_t discard_posted_bytes = 0, discard_posted_extents = 0, discard_jobs = 0;
    uint64_t discard_failures = 0;
    uint64_t reuse_after_discard_bytes = 0;
    uint64_t reuse_never_discarded_bytes = 0;     ///< Reuses while decommit is off.
    uint64_t fresh_ahead_hit_bytes = 0, fresh_ahead_miss_bytes = 0;
    uint64_t populate_posted_bytes = 0, populate_jobs = 0, populate_failures = 0;
    uint64_t window_commit_failures = 0;
    uint64_t reuse_waits = 0, release_waits = 0, slot_full_waits = 0;
    uint64_t nowait_pending_reuse_bytes = 0;
    uint64_t nowait_skipped_extents = 0;
    uint64_t nowait_fresh_bytes = 0;
    uint64_t nowait_fallback_waits = 0;        ///< Counts Fallback picks, whether or not the reuse then waited.
    bool     populate_supported = false;       ///< Whether the constructor's probe populate succeeded.
};

/// The deferred-decommit and commit-ahead state of one old generation, and the helper jobs that serve it.
///
/// A `PageWork` holds up to `kJobSlots` helper jobs at once, which live inside it and which the pool refers to
/// while they run. It must therefore have no job in flight when it is destroyed: the owner calls `drainAll` first,
/// and the destructor aborts if a job is Posted or Running. It is neither copyable nor movable. It keeps a
/// reference to the pool it is given, which must outlive it.
///
/// An `in_pause` argument says whether the caller is inside a collection pause and decides how a blocking wait is
/// counted in the pool's statistics.
class PageWork {
public:
    /// The number of helper jobs that may be in flight at once. Posting with every slot busy waits for the oldest.
    static constexpr size_t kJobSlots = 8;
    /// The alignment, in bytes, to which the end of the commit-ahead window is rounded up: 2 MiB.
    static constexpr size_t kWindowGranule = size_t{2} << 20;

    /// Creates the bookkeeping for `cfg`, posting jobs to `pool` and performing page operations through `ops`.
    ///
    /// When `cfg.ahead_bytes` is not 0 and `ops.populate` is set, populates one probe page and turns commit-ahead
    /// on only if that succeeds.
    PageWork(PageOps ops, PageWorkConfig cfg, GCHelperPool& pool,
             PageWorkHooks hooks = {});
    ~PageWork();
    PageWork(const PageWork&) = delete;
    PageWork& operator=(const PageWork&) = delete;

    /// Records that the extent `[p, p+n)` was released to the free list, making it Pending when decommit is on.
    ///
    /// Waits first for any populate job still running over part of the range. With decommit on, aborts if `p` is
    /// already Pending or Posted.
    void onRelease(char* p, size_t n, bool in_pause);

    /// What a reused extent's pages may hold.
    ///
    /// `Cancelled`: the extent was Pending, its discard is cancelled, and its contents are as they were released.
    /// `NeverDiscarded`: decommit is off, so it was never discarded. `AfterDiscard`: decommit is on and it was not
    /// Pending; its contents are unspecified, and may be the old ones.
    enum class Reuse : uint8_t { Cancelled, NeverDiscarded, AfterDiscard };
    /// Takes the free-list extent `[p, p+n)` out of this bookkeeping before the caller touches it, and returns
    /// what its pages may hold.
    ///
    /// A Pending extent's discard is cancelled. For a Posted extent, waits for its discard job to finish.
    Reuse onReuse(char* p, size_t n, bool in_pause);

    /// Returns how many bytes of the freshly bumped range `[p, p+n)` the caller must still commit, and writes to
    /// `*commit_from` where they start.
    ///
    /// The part of the range below `windowEnd()` is already committed by commit-ahead and must not be committed
    /// again. When nothing remains, returns 0 and writes `p + n`.
    size_t onFreshBump(char* p, size_t n, char** commit_from);

    /// Runs a sync point: reaps finished jobs, posts the extents now aged or over the Pending cap together as one
    /// Discard job, and tops up the commit-ahead window.
    ///
    /// `epoch` and `major_epoch` are the caller's counts of sync points and of major collections, and must not
    /// decrease between calls. `bump` is the old-generation bump pointer, and the window is never extended past
    /// `cap_end`. A failure to commit the window is counted and leaves the window as it was.
    void syncPoint(uint64_t epoch, uint64_t major_epoch, char* bump, char* cap_end,
                   bool in_pause);
    /// Runs a sync point as the other overload does, with the major-collection count unchanged since the last one.
    void syncPoint(uint64_t epoch, char* bump, char* cap_end, bool in_pause) {
        syncPoint(epoch, major_epoch_, bump, cap_end, in_pause);
    }

    /// Waits for every job in flight and reaps it, so that no job remains. With `discard_pending`, also discards
    /// every Pending extent on the calling thread and forgets it. Any wait is counted as inside a pause.
    void drainAll(bool discard_pending);

    /// Returns the statistics so far. The reference is valid for the life of this `PageWork`.
    const PageWorkCounters& counters() const { return counters_; }
    /// Returns the end of the commit-ahead window, or null if no window has been committed.
    char* windowEnd() const { return window_end_; }

    // A caller choosing an extent without waiting for helpers.

    /// Returns whether the extent at `p` is Pending.
    ///
    /// Whether an extent is Pending changes only in `onRelease`, `onReuse`, `syncPoint`'s aging and `drainAll`,
    /// never with a helper's progress, so a choice keyed on it does not depend on helper timing. Whether an extent
    /// is Posted, and the state of a job, do depend on it.
    bool isPending(char* p) const { return pending_.count(p) != 0; }
    /// Returns whether decommit is on.
    bool decommitOn() const { return cfg_.decommit; }
    /// Which extent a caller choosing without waiting took: a Pending extent, whose reuse cancels its discard
    /// (`PendingReuse`); a fresh bump instead of a free-list extent (`Fresh`); or the ordinary first fit, which may
    /// wait (`Fallback`).
    enum class NoWaitPick : uint8_t { PendingReuse = 1, Fresh = 2, Fallback = 3 };
    /// Records that the caller picked `k` for the extent at `p` of `n` bytes, in the statistics and in trace
    /// builds' event log. It does not call `onReuse` or `onFreshBump`.
    void noteNoWait(NoWaitPick k, char* p, size_t n);
    /// Records that a caller choosing without waiting skipped a fitting extent because it was not Pending.
    void noteNoWaitSkip() { ++counters_.nowait_skipped_extents; }

    // Queries for validation and tests. Their answers depend on helper progress.

    /// The state an extent is reported in by `forEachTracked`.
    enum TrackState : int { kPending = 1, kPostedDiscard = 2 };
    /// Returns whether the extent at `p` is Pending or Posted.
    bool isPendingOrPosted(char* p) const;
    /// Returns the number of extents Pending or Posted.
    size_t trackedCount() const { return pending_.size() + posted_discard_.size(); }
    /// Calls `f(p, size, state)` for every Pending and then every Posted extent, `state` being a `TrackState`
    /// value as an `int`. `f` must not call into this `PageWork`.
    template <typename F> void forEachTracked(F&& f) const {
        for (const auto& kv : pending_) f(kv.first, kv.second.size, int(kPending));
        for (const auto& kv : posted_discard_) f(kv.first, kv.second.size, int(kPostedDiscard));
    }
    /// Calls `f(lo, hi)` for the range `[lo, hi)` of every populate job not yet reaped.
    template <typename F> void forEachPopulateInFlight(F&& f) const {
        for (const auto& s : slots_) {
            if (s.kind == Kind::Populate && !s.isIdle()) f(s.lo, s.hi);
        }
    }
    /// Returns whether every job slot is Idle, that is, holds no job posted and not yet reaped.
    bool allSlotsIdle() const;

private:
    /// What a job slot holds: nothing, a discard, or a populate.
    enum class Kind : uint8_t { None, Discard, Populate };
    /// A page range `[p, p+n)`.
    struct Extent { char* p; size_t n; };
    /// One job slot: a helper job together with the page work it carries.
    struct PageJob : HelperJob {
        Kind kind = Kind::None;
        std::vector<Extent> extents;     ///< The extents a Discard job discards.
        char* lo = nullptr;              ///< The range `[lo, hi)` a Populate job populates.
        char* hi = nullptr;
        const PageOps* ops = nullptr;    ///< The owning `PageWork`'s `ops_`; its constructor sets it.
        uint64_t failures = 0;           ///< Written by whoever runs the job; read only after the job is Done.
        uint64_t seq = 0;                ///< Post order, so that a full set of slots can wait for the oldest.
    };
    /// A Pending extent: its size, the sync-point and major counts at its release, and its release number.
    struct Pending { size_t size; uint64_t epoch; uint64_t major_epoch; uint64_t seq; };
    /// An entry in release order. It is stale if `pending_` has no entry for `p` with the same `seq`.
    struct OrderEntry { char* p; uint64_t seq; };
    /// A Posted extent: its size and the index of the slot whose job discards it.
    struct Posted { size_t size; uint8_t slot; };

    /// Runs job `j`, on a helper or inline: discards its extents or populates its range, counting failures.
    static void runJob(HelperJob* j);
    /// Reaps finished jobs and returns an Idle slot, waiting for and reaping the oldest job if none is Idle.
    PageJob& takeSlot(bool in_pause);
    /// Reaps the Done job in `s`: forgets the Posted extents it discarded, adds its failures to the statistics,
    /// reports it to `on_job_reaped`, and returns the slot to Idle.
    void reap(PageJob& s);
    /// Reaps every slot whose job is Done, without waiting.
    void reapDone();
    /// Waits for the job in `s` and reaps it, adding one to `wait_counter` if the wait blocked. Does nothing if
    /// `s` is Idle.
    void awaitSlot(PageJob& s, bool in_pause, uint64_t& wait_counter);
    /// Waits for and reaps every populate job whose range overlaps `[p, p+n)`.
    void awaitPopulateOverlapping(char* p, size_t n, bool in_pause);
    /// Posts the extents in `batch` as one Discard job, making them Posted, and empties `batch`. Does nothing if
    /// `batch` is empty.
    void postDiscardBatch(std::vector<Extent>& batch, bool in_pause);
    /// Commits the range from the window end, or `bump` if that is higher, up to the new target, and posts a
    /// Populate job for it. Does nothing when commit-ahead is off or the window already reaches the target. If the
    /// commit fails, counts the failure and posts nothing.
    void topUpWindow(char* bump, char* cap_end, bool in_pause);

    PageOps ops_;
    PageWorkConfig cfg_;
    GCHelperPool& pool_;                                  ///< The pool passed to the constructor; must outlive this.
    PageWorkHooks hooks_;
    PageJob slots_[kJobSlots];
    uint64_t next_seq_ = 1;                               ///< The next job post number (`PageJob::seq`).
    uint64_t epoch_ = 0;                                  ///< The `epoch` of the last sync point.
    uint64_t major_epoch_ = 0;                            ///< The `major_epoch` of the last sync point.
    std::unordered_map<char*, Pending> pending_;
    std::deque<OrderEntry> pending_order_;                ///< Pending extents in release order; may hold stale entries.
    uint64_t next_release_seq_ = 1;                       ///< The next release number (`Pending::seq`).
    std::unordered_map<char*, Posted> posted_discard_;
    char* window_end_ = nullptr;
    std::vector<Extent> batch_;                           ///< Scratch for the extents a sync point discards.
    PageWorkCounters counters_;
};

} // namespace Elm::gc
