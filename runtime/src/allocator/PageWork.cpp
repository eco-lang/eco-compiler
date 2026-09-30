// threaded-gc-03: deferred decommit (U1) and commit-ahead (U2). See
// PageWork.hpp and plans/threaded-gc-03-helper-threads.md P§3.6-3.7.

#include "PageWork.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include "TlaTrace.hpp"   // compiled-out hooks (trace builds only: M7's trace, test/tla/)

// M7's trace (test/tla/M7-pagework/TracePageWork.tla): every PageWork event is
// stamped from one process-wide seq_cst counter, so the merged log is one total
// order in which each stamp sits where its model step does (plan §8).
#if ECO_TLA_TRACE_ENABLED
#include <atomic>
namespace {
std::atomic<uint64_t> g_pw_tick{0};
}  // namespace
#define PW_TRACE(ev, ...) ECO_TLA_TRACE(ev, "clk", "pw", "tick", g_pw_tick.fetch_add(1) __VA_OPT__(, ) __VA_ARGS__)
#else
#define PW_TRACE(...) ((void)0)
#endif

namespace Elm::gc {

namespace {

[[noreturn]] void pageWorkAbort(const char* msg) {
    std::fprintf(stderr, "[page-work] %s\n", msg);
    std::fflush(stderr);
    std::abort();
}

// One private-writable page for the MADV_POPULATE_WRITE support probe.
alignas(65536) char g_probe_page[65536];

char* roundUp(char* p, size_t g) {
    const uintptr_t v = reinterpret_cast<uintptr_t>(p);
    return reinterpret_cast<char*>((v + g - 1) & ~(uintptr_t(g) - 1));
}

} // namespace

PageWork::PageWork(PageOps ops, PageWorkConfig cfg, GCHelperPool& pool,
                   PageWorkHooks hooks)
    : ops_(ops), cfg_(cfg), pool_(pool), hooks_(hooks) {
    for (auto& s : slots_) s.ops = &ops_;
    if (cfg_.ahead_bytes > 0 && ops_.populate != nullptr) {
        // Probe on a page of our own (P§3.7). A failure (EINVAL on kernels
        // older than 5.14, the Win64 stub) disables U2 for the process.
        counters_.populate_supported =
            ops_.populate(ops_.ctx, roundUp(g_probe_page, 4096), 4096);
    }
}

PageWork::~PageWork() {
    // The owner must have drained (Allocator::reset / ~Allocator); a job
    // still running would touch a PageWork that no longer exists.
    for (auto& s : slots_) {
        if (!s.isIdle() && !s.isDone()) pageWorkAbort("destroyed with a job in flight");
    }
}

void PageWork::runJob(HelperJob* j) {
    auto* s = static_cast<PageJob*>(j);
    PW_TRACE("start", "seq", s->seq, "kind", s->kind);
    const PageOps& ops = *s->ops;
    s->failures = 0;
    if (s->kind == Kind::Discard) {
        for (const Extent& e : s->extents) {
            if (!ops.discard(ops.ctx, e.p, e.n)) ++s->failures;
            PW_TRACE("body", "seq", s->seq, "x", ::Elm::tlatrace::obj(e.p));
        }
    } else if (s->kind == Kind::Populate) {
        if (!ops.populate(ops.ctx, s->lo, static_cast<size_t>(s->hi - s->lo))) {
            ++s->failures;
        }
    }
    PW_TRACE("jobdone", "seq", s->seq);
}

bool PageWork::allSlotsIdle() const {
    for (const auto& s : slots_) {
        if (!s.isIdle()) return false;
    }
    return true;
}

bool PageWork::isPendingOrPosted(char* p) const {
    return pending_.count(p) != 0 || posted_discard_.count(p) != 0;
}

void PageWork::reap(PageJob& s) {
    // Caller has observed Done (acquire): the runner's writes are visible.
    if (s.kind == Kind::Discard) {
        for (const Extent& e : s.extents) {
            auto it = posted_discard_.find(e.p);
            const uint8_t idx = static_cast<uint8_t>(&s - slots_);
            if (it != posted_discard_.end() && it->second.slot == idx) {
                posted_discard_.erase(it);
            }
        }
        counters_.discard_failures += s.failures;
    } else if (s.kind == Kind::Populate) {
        counters_.populate_failures += s.failures;
    }
    if (hooks_.on_job_reaped) hooks_.on_job_reaped(hooks_.ctx, s);
    s.extents.clear();
    s.kind = Kind::None;
    s.lo = s.hi = nullptr;
    s.resetForReuse();
}

void PageWork::reapDone() {
    ECO_TLA_TRACE_ONLY(uint32_t tla_mask = 0;)
    for (auto& s : slots_) {
        if (!s.isIdle() && s.isDone()) {
            ECO_TLA_TRACE_ONLY(tla_mask |= 1u << static_cast<unsigned>(&s - slots_);)
            reap(s);
        }
    }
    PW_TRACE("reaped", "mask", tla_mask);
}

void PageWork::awaitSlot(PageJob& s, bool in_pause, uint64_t& wait_counter) {
    if (s.isIdle()) return;
    const GCHelperPool::StallRecord r = pool_.wait(s, in_pause);
    if (r.stalled) {
        ++wait_counter;
        if (hooks_.on_stall) hooks_.on_stall(hooks_.ctx, r.start_ns, r.dur_ns, s.client, in_pause);
    }
    reap(s);
    PW_TRACE("await", "slot", &s - slots_);
}

PageWork::PageJob& PageWork::takeSlot(bool in_pause) {
    reapDone();
    for (auto& s : slots_) {
        if (s.isIdle()) return s;
    }
    // All in flight: wait for the oldest.
    PageJob* oldest = &slots_[0];
    for (auto& s : slots_) {
        if (s.seq < oldest->seq) oldest = &s;
    }
    awaitSlot(*oldest, in_pause, counters_.slot_full_waits);
    return *oldest;
}

void PageWork::awaitPopulateOverlapping(char* p, size_t n, bool in_pause) {
    char* e = p + n;
    for (auto& s : slots_) {
        if (s.kind != Kind::Populate || s.isIdle()) continue;
        if (s.lo < e && p < s.hi) awaitSlot(s, in_pause, counters_.release_waits);
    }
}

void PageWork::onRelease(char* p, size_t n, bool in_pause) {
    PW_TRACE("rel", "x", ::Elm::tlatrace::obj(p));
    awaitPopulateOverlapping(p, n, in_pause);
    counters_.released_bytes += n;
    counters_.released_extents += 1;
    if (!cfg_.decommit) return;
    if (pending_.count(p) != 0 || posted_discard_.count(p) != 0) {
        pageWorkAbort("onRelease: extent is already tracked (double release?)");
    }
    const uint64_t seq = next_release_seq_++;
    pending_.emplace(p, Pending{n, epoch_, major_epoch_, seq});
    pending_order_.push_back(OrderEntry{p, seq});
    counters_.pending_bytes += n;
    counters_.pending_peak_bytes =
        std::max(counters_.pending_peak_bytes, counters_.pending_bytes);
    PW_TRACE("pend", "x", ::Elm::tlatrace::obj(p));
}

PageWork::Reuse PageWork::onReuse(char* p, size_t n, bool in_pause) {
    PW_TRACE("acq", "x", ::Elm::tlatrace::obj(p),
             "st", pending_.count(p) != 0 ? 1 : (posted_discard_.count(p) != 0 ? 2 : 0),
             "slot", posted_discard_.count(p) != 0 ? int{posted_discard_.at(p).slot} : -1);
    if (auto it = pending_.find(p); it != pending_.end()) {
        // U1's win: the pages are still resident, no refault.
        counters_.pending_bytes -= it->second.size;
        counters_.cancelled_bytes += it->second.size;
        counters_.cancelled_extents += 1;
        pending_.erase(it);          // its pending_order_ entry goes stale
        PW_TRACE("reused", "x", ::Elm::tlatrace::obj(p), "r", "Cancelled");
        return Reuse::Cancelled;
    }
    if (auto it = posted_discard_.find(p); it != posted_discard_.end()) {
        awaitSlot(slots_[it->second.slot], in_pause, counters_.reuse_waits);
        // reap() erased the entry.
    } else if (!cfg_.decommit) {
        counters_.reuse_never_discarded_bytes += n;
        PW_TRACE("reused", "x", ::Elm::tlatrace::obj(p), "r", "NeverDiscarded");
        return Reuse::NeverDiscarded;
    }
    counters_.reuse_after_discard_bytes += n;
    PW_TRACE("reused", "x", ::Elm::tlatrace::obj(p), "r", "AfterDiscard");
    return Reuse::AfterDiscard;
}

size_t PageWork::onFreshBump(char* p, size_t n, char** commit_from) {
    PW_TRACE("fresh", "x", ::Elm::tlatrace::obj(p));
    char* end = p + n;
    if (window_end_ != nullptr && window_end_ > p) {
        if (window_end_ >= end) {
            counters_.fresh_ahead_hit_bytes += n;
            *commit_from = end;
            return 0;
        }
        counters_.fresh_ahead_hit_bytes += static_cast<size_t>(window_end_ - p);
        counters_.fresh_ahead_miss_bytes += static_cast<size_t>(end - window_end_);
        *commit_from = window_end_;
        return static_cast<size_t>(end - window_end_);
    }
    counters_.fresh_ahead_miss_bytes += n;
    *commit_from = p;
    return n;
}

void PageWork::postDiscardBatch(std::vector<Extent>& batch, bool in_pause) {
    if (batch.empty()) return;
    PageJob& s = takeSlot(in_pause);
    const uint8_t idx = static_cast<uint8_t>(&s - slots_);
    s.kind = Kind::Discard;
    s.client = HelperClient::Decommit;
    s.run = &PageWork::runJob;
    s.extents.assign(batch.begin(), batch.end());
    s.bytes = 0;
    for (const Extent& e : batch) {
        s.bytes += e.n;
        posted_discard_.emplace(e.p, Posted{e.n, idx});
    }
    s.seq = next_seq_++;
    counters_.discard_posted_bytes += s.bytes;
    counters_.discard_posted_extents += batch.size();
    counters_.discard_jobs += 1;
    batch.clear();
    PW_TRACE("post", "slot", idx, "seq", s.seq, "kind", s.kind);
    pool_.post(s);
}

void PageWork::topUpWindow(char* bump, char* cap_end, bool in_pause) {
    if (cfg_.ahead_bytes == 0 || !counters_.populate_supported) return;
    char* target = roundUp(bump + cfg_.ahead_bytes, kWindowGranule);
    if (target > cap_end) target = cap_end;
    char* lo = (window_end_ != nullptr && window_end_ > bump) ? window_end_ : bump;
    if (target <= lo) return;
    if (!ops_.commit(ops_.ctx, lo, static_cast<size_t>(target - lo))) {
        ++counters_.window_commit_failures;   // best effort; decides nothing
        return;
    }
    window_end_ = target;
    PW_TRACE("window", "lo", ::Elm::tlatrace::obj(lo), "hi", ::Elm::tlatrace::obj(target));
    PageJob& s = takeSlot(in_pause);
    s.kind = Kind::Populate;
    s.client = HelperClient::Populate;
    s.run = &PageWork::runJob;
    s.lo = lo;
    s.hi = target;
    s.bytes = static_cast<uint64_t>(target - lo);
    s.seq = next_seq_++;
    counters_.populate_posted_bytes += s.bytes;
    counters_.populate_jobs += 1;
    PW_TRACE("post", "slot", &s - slots_, "seq", s.seq, "kind", s.kind);
    pool_.post(s);
}

void PageWork::syncPoint(uint64_t epoch, uint64_t major_epoch, char* bump, char* cap_end,
                         bool in_pause) {
    // (a) Reap finished jobs: bookkeeping only, decides nothing.
    reapDone();
    epoch_ = epoch;
    major_epoch_ = major_epoch;
    // (b) Age: pending_order_ is in release (hence epoch) order.
    batch_.clear();
    while (!pending_order_.empty()) {
        const OrderEntry oe = pending_order_.front();
        auto it = pending_.find(oe.p);
        if (it == pending_.end() || it->second.seq != oe.seq) {
            pending_order_.pop_front();          // cancelled (or re-released later)
            continue;
        }
        const bool aged =
            (cfg_.delay != UINT32_MAX &&
             epoch - it->second.epoch > static_cast<uint64_t>(cfg_.delay)) ||
            (cfg_.delay_majors != 0 &&
             major_epoch - it->second.major_epoch > static_cast<uint64_t>(cfg_.delay_majors));
        const bool over_cap = cfg_.pending_cap != 0 &&
                              counters_.pending_bytes > cfg_.pending_cap;
        if (!aged && !over_cap) break;
        batch_.push_back(Extent{oe.p, it->second.size});
        PW_TRACE("age", "x", ::Elm::tlatrace::obj(oe.p));
        counters_.pending_bytes -= it->second.size;
        pending_.erase(it);
        pending_order_.pop_front();
    }
    PW_TRACE("sync", "size", batch_.size());
    // (c) Post the due discards as one job.
    postDiscardBatch(batch_, in_pause);
    // (d) U2: keep the commit-ahead window topped up.
    topUpWindow(bump, cap_end, in_pause);
}

void PageWork::drainAll(bool discard_pending) {
    for (auto& s : slots_) {
        uint64_t ignored = 0;
        awaitSlot(s, /*in_pause=*/true, ignored);
    }
    if (discard_pending) {
        for (const OrderEntry& oe : pending_order_) {
            auto it = pending_.find(oe.p);
            if (it == pending_.end() || it->second.seq != oe.seq) continue;
            if (!ops_.discard(ops_.ctx, oe.p, it->second.size)) ++counters_.discard_failures;
            counters_.discard_posted_bytes += it->second.size;
            counters_.discard_posted_extents += 1;
        }
        pending_.clear();
        pending_order_.clear();
        counters_.pending_bytes = 0;
    }
}

} // namespace Elm::gc
