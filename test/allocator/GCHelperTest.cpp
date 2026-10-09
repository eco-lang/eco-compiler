/**
 * threaded-gc-03 (plans/threaded-gc-03-helper-threads.md): the GC helper
 * pool, the PageWork state machine (deferred decommit U1, commit-ahead U2)
 * over fake page ops, and the allocator-level mode equivalence
 * (GC_DET_001: modes 0/1/2 and 2+jitter make identical GC decisions).
 *
 * Configs are built programmatically; unit tests never see ECO_HEAP_CONFIG
 * in the old gen (initAllocator -> reset installs the raw config).
 */

#include "GCHelperTest.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <algorithm>
#include <functional>
#include <cstring>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <sys/mman.h>
#include <sys/wait.h>
#include <csignal>
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "GCHelperPool.hpp"
#include "HeapConfigJson.hpp"
#include "HeapHelpers.hpp"
#include "PageWork.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;
using Elm::gc::GCHelperPool;
using Elm::gc::HelperClient;
using Elm::gc::HelperJob;
using Elm::gc::HelperMode;
using Elm::gc::PageWork;

namespace {

HeapConfig modeConfig(uint32_t mode, size_t ahead = 0);

// Quiesce the allocator's own page work (default configs run mode 2) so the
// pool can be restarted underneath it.
void quiesceAllocator() {
    initAllocator(modeConfig(0));
}

// A fresh, unconfigured pool configured to `mode`.
GCHelperPool& freshPool(HelperMode mode, unsigned threads = 1, unsigned jitter = 0) {
    quiesceAllocator();
    auto& pool = GCHelperPool::instance();
    if (pool.configured()) pool.shutdownForTesting();
    pool.configure(mode, threads, -1, jitter);
    return pool;
}

void closePool() {
    quiesceAllocator();
    auto& pool = GCHelperPool::instance();
    if (pool.configured()) {
        pool.drain();
        pool.shutdownForTesting();
    }
}

struct FnJob : HelperJob {
    std::function<void()> fn;
    static void call(HelperJob* j) { static_cast<FnJob*>(j)->fn(); }
    explicit FnJob(std::function<void()> f) : fn(std::move(f)) {
        run = &FnJob::call;
        client = HelperClient::Test;
    }
};

#if !defined(_WIN32)
// Runs `body` in a forked child; returns true iff the child died abnormally
// (abort / signal) or exited non-zero.
bool childAborts(const std::function<void()>& body) {
    std::fflush(stdout);
    std::fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        // Silence the expected abort message.
        FILE* devnull = std::freopen("/dev/null", "w", stderr);
        (void)devnull;
        body();
        _exit(0);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return !(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
#endif

// ---------------------------------------------------------------------------
// Fake page ops: a log of (op, p, n) plus a gate that can hold any op.
// ---------------------------------------------------------------------------
struct FakeOps {
    enum Op { Discard, Populate, Commit };
    struct Entry { Op op; char* p; size_t n; };
    std::mutex m;
    std::vector<Entry> log;
    std::condition_variable gate_cv;
    bool block_discard = false, block_populate = false;
    bool gate_open = true;
    bool populate_ok = true;
    std::atomic<int> entered{0};

    void hold(Op op) {
        std::unique_lock<std::mutex> lk(m);
        const bool blocked = (op == Discard && block_discard) ||
                             (op == Populate && block_populate);
        entered.fetch_add(1);
        if (blocked) gate_cv.wait(lk, [&] { return gate_open; });
    }
    void open() {
        std::lock_guard<std::mutex> lk(m);
        gate_open = true;
        gate_cv.notify_all();
    }
    void record(Op op, char* p, size_t n) {
        hold(op);
        std::lock_guard<std::mutex> lk(m);
        log.push_back({op, p, n});
    }
    size_t count(Op op, char* p = nullptr) {
        std::lock_guard<std::mutex> lk(m);
        size_t c = 0;
        for (auto& e : log) if (e.op == op && (p == nullptr || e.p == p)) ++c;
        return c;
    }
    static bool discard(void* ctx, char* p, size_t n) {
        static_cast<FakeOps*>(ctx)->record(Discard, p, n);
        return true;
    }
    static bool populate(void* ctx, char* p, size_t n) {
        auto* f = static_cast<FakeOps*>(ctx);
        f->record(Populate, p, n);
        return f->populate_ok;
    }
    static bool commit(void* ctx, char* p, size_t n) {
        static_cast<FakeOps*>(ctx)->record(Commit, p, n);
        return true;
    }
    gc::PageOps ops() {
        gc::PageOps o;
        o.discard = &discard;
        o.populate = &populate;
        o.commit = &commit;
        o.ctx = this;
        return o;
    }
};

// Fake addresses: nothing is ever dereferenced.
char* X(size_t k) { return reinterpret_cast<char*>(uintptr_t{0x100000000000ull} + k * (512 * 1024)); }
constexpr size_t kExt = 512 * 1024;

gc::PageWorkConfig pwConfig(uint32_t delay, size_t cap = 0, size_t ahead = 0) {
    gc::PageWorkConfig c;
    c.decommit = true;
    c.delay = delay;
    c.pending_cap = cap;
    c.ahead_bytes = ahead;
    return c;
}

template <typename F>
void inBothModes(F&& f) {
    for (HelperMode m : {HelperMode::Sync, HelperMode::Concurrent}) {
        auto& pool = freshPool(m);
        f(pool, m);
        closePool();
    }
}

}  // namespace

// ============================================================================
// Step 1 — configuration
// ============================================================================

Testing::TestCase testHelperConfigValidation(
    "threaded-gc-03: HeapConfig helper keys parse, validate, and ECO_GC_THREAD overrides",
    []() {
        HeapConfig cfg;
        TEST_ASSERT(cfg.gc_thread_mode == GC_THREAD_MODE);
        cfg.validate();
        auto bad = [](auto mutate) {
            HeapConfig c;
            mutate(c);
            try { c.validate(); } catch (const std::invalid_argument&) { return true; }
            return false;
        };
        TEST_ASSERT(bad([](HeapConfig& c) { c.gc_thread_mode = 3; }));
        TEST_ASSERT(bad([](HeapConfig& c) { c.gc_helper_threads = 0; }));
        TEST_ASSERT(bad([](HeapConfig& c) { c.gc_helper_threads = 65; }));
        TEST_ASSERT(bad([](HeapConfig& c) { c.gc_helper_cpu = -2; }));
        TEST_ASSERT(bad([](HeapConfig& c) { c.commit_ahead_bytes = 1000; }));

        uint32_t jitter = 99;
        HeapConfig e;
        applyGcThreadEnv(e, jitter, "2", "0500");
        TEST_ASSERT(e.gc_thread_mode == 2);
        TEST_ASSERT(jitter == 500);
        applyGcThreadEnv(e, jitter, nullptr, nullptr);
        TEST_ASSERT(e.gc_thread_mode == 2);   // unset leaves the value
        TEST_ASSERT(jitter == 0);
        auto envBad = [](const char* m, const char* j) {
            HeapConfig c;
            uint32_t jj = 0;
            try { applyGcThreadEnv(c, jj, m, j); } catch (const std::invalid_argument&) { return true; }
            return false;
        };
        TEST_ASSERT(envBad("3", nullptr));
        TEST_ASSERT(envBad("conc", nullptr));
        TEST_ASSERT(envBad("11", nullptr));
        TEST_ASSERT(envBad(nullptr, "12x"));
        TEST_ASSERT(envBad(nullptr, "100001"));

#if !defined(_WIN32)
        // JSON round trip of all six keys.
        char path[] = "/tmp/eco-gc03-cfg-XXXXXX";
        int fd = mkstemp(path);
        TEST_ASSERT(fd >= 0);
        const char* json =
            "{\"gc_thread_mode\": 1, \"gc_helper_threads\": 3, \"gc_helper_cpu\": 5,"
            " \"decommit_delay_syncs\": 7, \"decommit_pending_max_bytes\": \"64M\","
            " \"commit_ahead_bytes\": \"2M\"}";
        TEST_ASSERT(write(fd, json, std::strlen(json)) == static_cast<ssize_t>(std::strlen(json)));
        close(fd);
        HeapConfig j;
        applyHeapConfigJsonFile(j, path);
        unlink(path);
        TEST_ASSERT(j.gc_thread_mode == 1);
        TEST_ASSERT(j.gc_helper_threads == 3);
        TEST_ASSERT(j.gc_helper_cpu == 5);
        TEST_ASSERT(j.decommit_delay_syncs == 7);
        TEST_ASSERT(j.decommit_pending_max_bytes == 64ull * 1024 * 1024);
        TEST_ASSERT(j.commit_ahead_bytes == 2ull * 1024 * 1024);
        j.validate();
#endif
    });

// ============================================================================
// Step 2 — GCHelperPool
// ============================================================================

Testing::TestCase testHelperPoolSyncRunsInline(
    "threaded-gc-03: Sync mode runs a posted job inline on the caller",
    []() {
        freshPool(HelperMode::Sync);
        std::thread::id ran_on;
        FnJob j([&] { ran_on = std::this_thread::get_id(); });
        GCHelperPool::instance().post(j);
        TEST_ASSERT(j.isDone());
        TEST_ASSERT(ran_on == std::this_thread::get_id());
        auto r = GCHelperPool::instance().wait(j, true);
        TEST_ASSERT(!r.stalled);
        TEST_ASSERT(GCHelperPool::instance().stats().client[2].jobs.load() == 1);
        closePool();
    });

Testing::TestCase testHelperPoolConcurrentRunsOnWorker(
    "threaded-gc-03: Concurrent mode runs a posted job on a worker",
    []() {
        auto& pool = freshPool(HelperMode::Concurrent);
        std::thread::id ran_on;
        FnJob j([&] { ran_on = std::this_thread::get_id(); });
        pool.post(j);
        pool.wait(j, true);
        TEST_ASSERT(j.isDone());
        TEST_ASSERT(ran_on != std::this_thread::get_id());
        TEST_ASSERT(pool.stats().client[2].jobs.load() == 1);
        j.resetForReuse();
        pool.post(j);            // a Done-then-reset job can be re-posted
        pool.wait(j, true);
        TEST_ASSERT(pool.stats().client[2].jobs.load() == 2);
        closePool();
    });

Testing::TestCase testHelperPoolFifoAndDrain(
    "threaded-gc-03: jobs run FIFO on one worker; drain waits for all (1 and 4 workers)",
    []() {
        for (unsigned threads : {1u, 4u}) {
            auto& pool = freshPool(HelperMode::Concurrent, threads);
            std::mutex m;
            std::vector<int> order;
            std::deque<FnJob> jobs;
            for (int i = 0; i < 1000; ++i) {
                jobs.emplace_back([&, i] { std::lock_guard<std::mutex> lk(m); order.push_back(i); });
            }
            for (auto& j : jobs) pool.post(j);
            pool.drain();
            for (auto& j : jobs) TEST_ASSERT(j.isDone());
            TEST_ASSERT(order.size() == 1000);
            std::vector<int> sorted = order;
            std::sort(sorted.begin(), sorted.end());
            for (int i = 0; i < 1000; ++i) TEST_ASSERT(sorted[i] == i);
            if (threads == 1) {
                for (int i = 0; i < 1000; ++i) TEST_ASSERT(order[i] == i);
            }
            closePool();
        }
    });

Testing::TestCase testHelperPoolStallAccounting(
    "threaded-gc-03: a wait that blocks is a stall; a wait on a Done job is not",
    []() {
        auto& pool = freshPool(HelperMode::Concurrent);
        FnJob slow([] { std::this_thread::sleep_for(std::chrono::milliseconds(20)); });
        pool.post(slow);
        auto r = pool.wait(slow, /*in_pause=*/false);
        TEST_ASSERT(r.stalled);
        TEST_ASSERT(r.dur_ns >= 10ull * 1000 * 1000);
        TEST_ASSERT(pool.stats().stall_count.load() == 1);
        TEST_ASSERT(pool.stats().stall_outside_pause.load() == 1);
        TEST_ASSERT(pool.stats().stall_ns.load() >= 10ull * 1000 * 1000);
        auto r2 = pool.wait(slow, true);
        TEST_ASSERT(!r2.stalled);
        TEST_ASSERT(pool.stats().stall_count.load() == 1);
        closePool();
    });

Testing::TestCase testHelperPoolJitterKeepsFifo(
    "threaded-gc-03: jitter delays jobs but one worker still runs them FIFO",
    []() {
        auto& pool = freshPool(HelperMode::Concurrent, 1, 500);
        std::vector<int> order;
        std::deque<FnJob> jobs;
        for (int i = 0; i < 200; ++i) jobs.emplace_back([&, i] { order.push_back(i); });
        for (auto& j : jobs) pool.post(j);
        pool.drain();
        TEST_ASSERT(order.size() == 200);
        for (int i = 0; i < 200; ++i) TEST_ASSERT(order[i] == i);
        closePool();
    });

Testing::TestCase testHelperPoolStateMachineAsserts(
    "threaded-gc-03: posting a job that is not Idle aborts",
    []() {
#if !defined(_WIN32)
        TEST_ASSERT(childAborts([] {
            freshPool(HelperMode::Sync);
            FnJob j([] {});
            GCHelperPool::instance().post(j);
            GCHelperPool::instance().post(j);   // Done, not Idle
        }));
        TEST_ASSERT(childAborts([] {
            freshPool(HelperMode::Sync);
            GCHelperPool::instance().configure(HelperMode::Concurrent, 1, -1, 0);
        }));
#endif
    });

// ============================================================================
// Step 4 — PageWork over fake ops
// ============================================================================

Testing::TestCase testPageWorkReleaseThenCancel(
    "HEAP_059: a reuse before the discard is posted cancels it (no discard, pages resident)",
    []() {
        inBothModes([](GCHelperPool& pool, HelperMode) {
            FakeOps f;
            PageWork pw(f.ops(), pwConfig(1), pool);
            pw.onRelease(X(0), kExt, true);
            pw.onRelease(X(1), kExt, true);
            TEST_ASSERT(pw.onReuse(X(0), kExt, true) == PageWork::Reuse::Cancelled);
            TEST_ASSERT(!pw.isPendingOrPosted(X(0)));
            TEST_ASSERT(pw.isPendingOrPosted(X(1)));
            for (uint64_t e = 1; e <= 4; ++e) pw.syncPoint(e, X(100), X(1000), true);
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Discard, X(0)) == 0);
            TEST_ASSERT(f.count(FakeOps::Discard, X(1)) == 1);
            TEST_ASSERT(pw.counters().cancelled_bytes == kExt);
            TEST_ASSERT(pw.onReuse(X(1), kExt, true) == PageWork::Reuse::AfterDiscard);
        });
    });

Testing::TestCase testPageWorkDelaySemantics(
    "HEAP_059: an extent released at epoch e is posted at sync point e + D + 1",
    []() {
        inBothModes([](GCHelperPool& pool, HelperMode m) {
            for (uint32_t d : {0u, 1u, 4u}) {
                FakeOps f;
                PageWork pw(f.ops(), pwConfig(d), pool);
                const uint64_t e = 10;
                pw.syncPoint(e, X(100), X(1000), true);        // epoch_ = e
                pw.onRelease(X(3), kExt, true);                // released at epoch e
                for (uint64_t s = e + 1; s <= e + 6; ++s) {
                    pw.syncPoint(s, X(100), X(1000), true);
                    const bool posted = !pw.isPendingOrPosted(X(3)) ||
                                        pw.counters().discard_posted_extents == 1;
                    if (s < e + d + 1) {
                        TEST_ASSERT(pw.counters().discard_posted_extents == 0);
                    } else {
                        TEST_ASSERT(posted);
                        TEST_ASSERT(pw.counters().discard_posted_extents == 1);
                    }
                    if (m == HelperMode::Sync && s == e + d + 1) {
                        TEST_ASSERT(f.count(FakeOps::Discard, X(3)) == 1);   // ran in syncPoint
                    }
                }
                pw.drainAll(false);
                TEST_ASSERT(f.count(FakeOps::Discard, X(3)) == 1);
            }
        });
    });

Testing::TestCase testPageWorkDelayMajors(
    "HEAP_059: with decommit_delay_majors = 1 an extent survives one major cycle unused, then is posted",
    []() {
        inBothModes([](GCHelperPool& pool, HelperMode) {
            FakeOps f;
            gc::PageWorkConfig c = pwConfig(UINT32_MAX);
            c.delay_majors = 1;
            PageWork pw(f.ops(), c, pool);
            pw.syncPoint(1, /*majors*/ 0, X(100), X(1000), true);
            pw.onRelease(X(7), kExt, true);                  // released during major #1's pause
            pw.onRelease(X(8), kExt, true);
            pw.syncPoint(2, 1, X(100), X(1000), true);        // end of the pause containing major #1
            for (uint64_t e = 3; e < 40; ++e) pw.syncPoint(e, 1, X(100), X(1000), true);
            TEST_ASSERT(pw.counters().discard_posted_extents == 0);
            pw.onReuse(X(8), kExt, true);                     // reused within the cycle
            pw.syncPoint(40, 2, X(100), X(1000), true);       // major #2 ends
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Discard, X(7)) == 1);
            TEST_ASSERT(f.count(FakeOps::Discard, X(8)) == 0);
        });
    });

Testing::TestCase testPageWorkReuseWaitsForPostedDiscard(
    "HEAP_059: reusing an extent whose discard is in flight waits for the job",
    []() {
        auto& pool = freshPool(HelperMode::Concurrent);
        FakeOps f;
        f.block_discard = true;
        f.gate_open = false;
        {
            PageWork pw(f.ops(), pwConfig(0), pool);
            pw.onRelease(X(5), kExt, true);
            pw.syncPoint(1, X(100), X(1000), true);   // posts the discard; it blocks
            while (f.entered.load() == 0) std::this_thread::yield();
            std::atomic<bool> returned{false};
            PageWork::Reuse got = PageWork::Reuse::Cancelled;
            std::thread t([&] {
                got = pw.onReuse(X(5), kExt, /*in_pause=*/false);
                returned = true;
            });
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            TEST_ASSERT(!returned.load());
            f.open();
            t.join();
            TEST_ASSERT(returned.load());
            TEST_ASSERT(got == PageWork::Reuse::AfterDiscard);
            TEST_ASSERT(f.count(FakeOps::Discard, X(5)) == 1);
            TEST_ASSERT(pw.counters().reuse_waits == 1);
            TEST_ASSERT(pool.stats().stall_count.load() == 1);
            TEST_ASSERT(!pw.isPendingOrPosted(X(5)));
            pw.drainAll(false);
        }
        closePool();
    });

Testing::TestCase testPageWorkPendingCap(
    "HEAP_059: pending bytes over the cap are posted oldest-first regardless of age",
    []() {
        inBothModes([](GCHelperPool& pool, HelperMode) {
            FakeOps f;
            PageWork pw(f.ops(), pwConfig(UINT32_MAX, 1024 * 1024), pool);
            pw.onRelease(X(0), kExt, true);
            pw.onRelease(X(1), kExt, true);
            pw.onRelease(X(2), kExt, true);
            TEST_ASSERT(pw.counters().pending_bytes == 3 * kExt);
            pw.syncPoint(1, X(100), X(1000), true);
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Discard, X(0)) == 1);
            TEST_ASSERT(f.count(FakeOps::Discard, X(1)) == 0);
            TEST_ASSERT(pw.counters().pending_bytes == 2 * kExt);
            for (uint64_t e = 2; e < 50; ++e) pw.syncPoint(e, X(100), X(1000), true);
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Discard) == 1);   // D = never: no aging
        });
    });

Testing::TestCase testPageWorkReleaseWaitsForOverlappingPopulate(
    "HEAP_060: a release overlapping an in-flight populate waits; others do not",
    []() {
        auto& pool = freshPool(HelperMode::Concurrent);
        FakeOps f;
        f.block_populate = true;
        {
            PageWork pw(f.ops(), pwConfig(4, 0, 4 * 1024 * 1024), pool);
            TEST_ASSERT(pw.counters().populate_supported);   // probe ran (not gated yet)
            {
                std::lock_guard<std::mutex> lk(f.m);
                f.gate_open = false;
            }
            const int before = f.entered.load();
            char* bump = X(64);   // 2 MiB-aligned fake address
            pw.syncPoint(1, bump, X(4096), true);     // commit + populate [bump, bump+4M)
            while (f.entered.load() < before + 2) std::this_thread::yield();
            TEST_ASSERT(pw.windowEnd() == bump + 4 * 1024 * 1024);
            // Outside the window: no wait.
            pw.onRelease(X(10), kExt, true);
            TEST_ASSERT(pw.counters().release_waits == 0);
            std::atomic<bool> returned{false};
            std::thread t([&] { pw.onRelease(bump + kExt, kExt, true); returned = true; });
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            TEST_ASSERT(!returned.load());
            f.open();
            t.join();
            TEST_ASSERT(pw.counters().release_waits == 1);
            pw.drainAll(false);
        }
        closePool();
    });

Testing::TestCase testPageWorkFreshBumpWindow(
    "HEAP_060: bumps inside the commit-ahead window commit nothing; a straddle commits the rest",
    []() {
        inBothModes([](GCHelperPool& pool, HelperMode) {
            FakeOps f;
            const size_t ahead = 2 * 1024 * 1024;
            PageWork pw(f.ops(), pwConfig(4, 0, ahead), pool);
            char* bump = X(64);
            pw.syncPoint(1, bump, X(4096), true);
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Commit, bump) == 1);
            TEST_ASSERT(f.count(FakeOps::Populate, bump) == 1);
            TEST_ASSERT(pw.windowEnd() == bump + ahead);
            char* from = nullptr;
            TEST_ASSERT(pw.onFreshBump(bump, kExt, &from) == 0);
            TEST_ASSERT(pw.onFreshBump(bump + ahead - kExt, kExt, &from) == 0);
            // A 1 MiB request straddling the window end.
            const size_t n = pw.onFreshBump(bump + ahead - kExt, 2 * kExt, &from);
            TEST_ASSERT(n == kExt);
            TEST_ASSERT(from == bump + ahead);
            // Entirely above the window.
            TEST_ASSERT(pw.onFreshBump(bump + 2 * ahead, kExt, &from) == kExt);
            TEST_ASSERT(from == bump + 2 * ahead);
            // Next sync point with the bump inside the window tops up from
            // the old window end, never re-committing below it.
            pw.syncPoint(2, bump + kExt, X(4096), true);
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Commit, bump + ahead) == 1);
            TEST_ASSERT(f.count(FakeOps::Commit) == 2);
        });
    });

Testing::TestCase testPageWorkSlotFullWaits(
    "threaded-gc-03: a ninth in-flight job waits for the oldest slot",
    []() {
        auto& pool = freshPool(HelperMode::Concurrent);
        FakeOps f;
        f.block_discard = true;
        f.gate_open = false;
        {
            PageWork pw(f.ops(), pwConfig(0), pool);
            for (size_t k = 0; k < PageWork::kJobSlots; ++k) {
                pw.onRelease(X(k), kExt, true);
                pw.syncPoint(k + 1, X(100), X(1000), true);
            }
            TEST_ASSERT(pw.counters().discard_jobs == PageWork::kJobSlots);
            pw.onRelease(X(50), kExt, true);
            std::atomic<bool> returned{false};
            std::thread t([&] { pw.syncPoint(100, X(100), X(1000), true); returned = true; });
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            TEST_ASSERT(!returned.load());
            f.open();
            t.join();
            TEST_ASSERT(pw.counters().slot_full_waits == 1);
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Discard) == PageWork::kJobSlots + 1);
        }
        closePool();
    });

Testing::TestCase testPageWorkDrainAllDiscardsPending(
    "HEAP_059: drainAll(true) discards every pending extent and leaves nothing tracked",
    []() {
        inBothModes([](GCHelperPool& pool, HelperMode) {
            FakeOps f;
            PageWork pw(f.ops(), pwConfig(UINT32_MAX), pool);
            for (size_t k = 0; k < 5; ++k) pw.onRelease(X(k), kExt, true);
            pw.onReuse(X(2), kExt, true);   // cancelled: must not be discarded
            pw.drainAll(true);
            TEST_ASSERT(pw.trackedCount() == 0);
            TEST_ASSERT(pw.allSlotsIdle());
            TEST_ASSERT(f.count(FakeOps::Discard) == 4);
            TEST_ASSERT(f.count(FakeOps::Discard, X(2)) == 0);
            TEST_ASSERT(pw.counters().pending_bytes == 0);
        });
    });

Testing::TestCase testPageWorkPopulateUnsupported(
    "HEAP_060: without MADV_POPULATE_WRITE no window is ever opened",
    []() {
        inBothModes([](GCHelperPool& pool, HelperMode) {
            FakeOps f;
            f.populate_ok = false;
            PageWork pw(f.ops(), pwConfig(4, 0, 2 * 1024 * 1024), pool);
            TEST_ASSERT(!pw.counters().populate_supported);
            pw.syncPoint(1, X(64), X(4096), true);
            pw.drainAll(false);
            TEST_ASSERT(f.count(FakeOps::Commit) == 0);
            TEST_ASSERT(pw.windowEnd() == nullptr);
            char* from = nullptr;
            TEST_ASSERT(pw.onFreshBump(X(64), kExt, &from) == kExt);
        });
    });

// ============================================================================
// Step 5 / 7 — allocator level
// ============================================================================

namespace {

HeapConfig modeConfig(uint32_t mode, size_t ahead) {
    HeapConfig cfg;
    cfg.alloc_buffer_size       = 32 * 1024;
    cfg.nursery_block_count     = 8;
    cfg.nursery_max_block_count = cfg.nursery_block_count;   // a region heap slot fits (plans/region-nursery-everywhere.md)
    cfg.initial_old_gen_size    = 64 * 1024;
    cfg.max_heap_size           = 256ULL * 1024 * 1024;
    cfg.large_object_threshold  = 8 * 1024;
    cfg.decommit_on_oldgen_release = true;
    cfg.gc_thread_mode          = mode;
    cfg.decommit_delay_syncs    = 2;
    cfg.commit_ahead_bytes      = ahead;
    cfg.validate();
    return cfg;
}

struct ModeRun {
    uint64_t minors, majors, promoted, allocated, bytes_alloc, inuse_peak, hiwater;
    uint64_t released, fresh, reuse_total, cancelled;
    uint64_t checksum;
    // CR-007: the no-wait acquire's decisions (modes 1/2 with decommit on, in
    // a parallel promotion with n > 1): Pending reuses + fresh bumps +
    // fallbacks. Zero in mode 0 and at n = 1.
    uint64_t nowait = 0;
    // HEAP_076 (explicit_every > 0): the explicit releases' reports, summed.
    uint64_t x_calls = 0, x_live = 0, x_inuse_after = 0, x_released = 0;
    uint64_t x_pending_nonzero = 0;   // calls that left pending bytes behind (must be 0)
    // Object-level quantities only (GC_DET_001 at N > 1: placement counters
    // -- hiwater, fresh, reuse -- may differ from mode 0, which has no
    // PageWork and so no no-wait policy).
    bool sameObjects(const ModeRun& o) const {
        return minors == o.minors && majors == o.majors && promoted == o.promoted &&
               allocated == o.allocated && bytes_alloc == o.bytes_alloc &&
               released == o.released && checksum == o.checksum &&
               x_calls == o.x_calls && x_live == o.x_live && x_released == o.x_released;
    }
    bool operator==(const ModeRun& o) const {
        return minors == o.minors && majors == o.majors && promoted == o.promoted &&
               allocated == o.allocated && bytes_alloc == o.bytes_alloc &&
               inuse_peak == o.inuse_peak && hiwater == o.hiwater &&
               released == o.released && fresh == o.fresh &&
               reuse_total == o.reuse_total && checksum == o.checksum &&
               x_calls == o.x_calls && x_live == o.x_live &&
               x_inuse_after == o.x_inuse_after && x_released == o.x_released;
    }
};

// Deterministic churn: cohorts of rooted Ints live for two rounds, so every
// major releases whole all-dead blocks that the following minors reacquire.
// explicit_every = k > 0 (HEAP_076): at r % k == k - 1, after the round's
// minors, collectMinor() then collectMajorAndRelease() in place of the
// round's major.
ModeRun runModeWorkload(uint32_t mode, uint32_t jitter, size_t ahead = 0,
                        int explicit_every = 0) {
    HeapConfig cfg = modeConfig(mode, ahead);
    auto& pool = GCHelperPool::instance();
    if (pool.configured()) {
        initAllocator(modeConfig(0));   // drain + destroy the previous PageWork
        pool.shutdownForTesting();
    }
    if (mode != 0) pool.configure(static_cast<HelperMode>(mode), 1, -1, jitter);
    auto& alloc = initAllocator(cfg);
    // getCombinedStats accumulates across resets: measure deltas.
    const GCStats base = alloc.getCombinedStats();
    constexpr int kRounds = 24;
    constexpr int kPerRound = 12000;
    std::deque<std::vector<HPointer>> cohorts;
    uint64_t checksum = 0;
    ModeRun m{};
    for (int r = 0; r < kRounds; ++r) {
        cohorts.emplace_back();
        auto& c = cohorts.back();
        c.reserve(kPerRound / 2);
        for (int i = 0; i < kPerRound; ++i) {
            void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
            static_cast<ElmInt*>(obj)->value = r * 100000 + i;
            if (i % 2 == 0) {
                c.push_back(AllocatorTestAccess::toPointer(obj));
                alloc.getRootSet().addRoot(&c.back());
            }
        }
        if (cohorts.size() > 2) {
            for (auto& h : cohorts.front()) {
                checksum += static_cast<uint64_t>(
                    static_cast<ElmInt*>(readBarrier(h))->value);
                alloc.getRootSet().removeRoot(&h);
            }
            cohorts.pop_front();
        }
        alloc.minorGC();
        alloc.minorGC();
        const bool explicit_round =
            explicit_every > 0 && r % explicit_every == explicit_every - 1;
        // An explicit round replaces the round's own major (r % 6 == 5 is
        // always an r % 3 == 2 round): otherwise that major has released
        // everything and the explicit call measures nothing.
        if (r % 3 == 2 && !explicit_round) alloc.majorGC();
        if (explicit_round) {
            const GCReport mi = alloc.collectMinor();
            TEST_ASSERT(mi.kind == GCReport::Kind::Minor);
            const GCReport x = alloc.collectMajorAndRelease();
            TEST_ASSERT(x.kind == GCReport::Kind::Major);
            TEST_ASSERT(x.majors_run >= 1);
            ++m.x_calls;
            m.x_live += x.live_after_mark;
            m.x_inuse_after += x.old_in_use_after;
            m.x_released += x.released_bytes;
            const gc::PageWork* pw = alloc.pageWork();
            if (x.old_pending_after != 0 || (pw && pw->counters().pending_bytes != 0)) {
                ++m.x_pending_nonzero;
            }
        }
    }
    for (auto& c : cohorts) {
        for (auto& h : c) {
            checksum += static_cast<uint64_t>(static_cast<ElmInt*>(readBarrier(h))->value);
            alloc.getRootSet().removeRoot(&h);
        }
    }
    GCStats s = alloc.getCombinedStats();
    m.minors = s.minor_gc_count - base.minor_gc_count;
    m.majors = s.major_gc_count - base.major_gc_count;
    m.promoted = s.objects_promoted - base.objects_promoted;
    m.allocated = s.objects_allocated - base.objects_allocated;
    m.bytes_alloc = s.bytes_allocated - base.bytes_allocated;
    m.inuse_peak = s.oldgen_inuse_peak_bytes;
    m.hiwater = s.oldgen_hiwater_bytes;
    m.released = s.page_supply.released_bytes;
    m.fresh = s.page_supply.fresh_bytes;
    m.reuse_total = s.page_supply.reuse_resident_bytes + s.page_supply.reuse_after_discard_bytes;
    m.cancelled = s.helper.cancelled_bytes;
    m.checksum = checksum;
    if (const gc::PageWork* pw = alloc.pageWork()) {
        const gc::PageWorkCounters& c = pw->counters();
        m.nowait = c.nowait_pending_reuse_bytes + c.nowait_fresh_bytes + c.nowait_fallback_waits;
    }
    return m;
}

}  // namespace

Testing::TestCase testDecommitModesAgreeOnCounters(
    "GC_DET_001: modes 0, 1, 2 and 2+jitter make identical GC decisions",
    []() {
#if ENABLE_GC_STATS
        const ModeRun m0 = runModeWorkload(0, 0);
        const ModeRun m1 = runModeWorkload(1, 0);
        const ModeRun m2 = runModeWorkload(2, 0);
        const ModeRun m2j = runModeWorkload(2, 200);
        const ModeRun m2a = runModeWorkload(2, 0, 2 * 1024 * 1024);
        TEST_ASSERT(m0.majors >= 5);
        TEST_ASSERT(m0.released > 0);
        TEST_ASSERT(m0.reuse_total > 0);
        auto dump = [](const char* n, const ModeRun& m) {
            std::fprintf(stderr, "  %s: minors %llu majors %llu promoted %llu alloc %llu bytes %llu peak %llu hw %llu rel %llu fresh %llu reuse %llu canc %llu sum %llu\n",
                n, (unsigned long long)m.minors, (unsigned long long)m.majors,
                (unsigned long long)m.promoted, (unsigned long long)m.allocated,
                (unsigned long long)m.bytes_alloc, (unsigned long long)m.inuse_peak,
                (unsigned long long)m.hiwater, (unsigned long long)m.released,
                (unsigned long long)m.fresh, (unsigned long long)m.reuse_total,
                (unsigned long long)m.cancelled, (unsigned long long)m.checksum);
        };
        // CR-007 (register-fixes 6.3): with parallel minors (ECO_TEST_MINOR_THREADS
        // > 1) modes 1/2 apply the no-wait acquire policy and mode 0 does not, so
        // mode 0 is compared on object-level quantities only; modes 1, 2, 2+jitter
        // and 2+ahead must stay identical in every counter, the policy's included
        // (it reads pending_ membership only: job-blind).
        const bool nowait_ran = m1.nowait != 0;
        if (!((nowait_ran ? m0.sameObjects(m1) : m0 == m1) && m1 == m2 && m2 == m2j && m2 == m2a) ||
            nowait_ran) {
            dump("m0", m0); dump("m1", m1); dump("m2", m2); dump("m2j", m2j); dump("m2a", m2a);
            std::fprintf(stderr, "  no-wait decisions: m1 %llu m2 %llu m2j %llu m2a %llu\n",
                         (unsigned long long)m1.nowait, (unsigned long long)m2.nowait,
                         (unsigned long long)m2j.nowait, (unsigned long long)m2a.nowait);
        }
        if (nowait_ran) TEST_ASSERT(m0.sameObjects(m1));
        else TEST_ASSERT(m0 == m1);
        TEST_ASSERT(m0.nowait == 0);
        TEST_ASSERT(m1.nowait == m2.nowait && m2.nowait == m2j.nowait && m2.nowait == m2a.nowait);
        TEST_ASSERT(m1 == m2);
        TEST_ASSERT(m2 == m2j);
        TEST_ASSERT(m2 == m2a);
        TEST_ASSERT(m0.cancelled == 0);
        TEST_ASSERT(m1.cancelled > 0);
        TEST_ASSERT(m1.cancelled == m2.cancelled);
        TEST_ASSERT(m2.cancelled == m2j.cancelled);
        initAllocator(modeConfig(0));
        closePool();
#endif
    });

Testing::TestCase testExplicitReleaseModesAgree(
    "GC_DET_001: collectMajorAndRelease makes identical decisions in modes 0, 1, 2 and 2+jitter",
    []() {
#if ENABLE_GC_STATS
        const ModeRun m0 = runModeWorkload(0, 0, 0, 6);
        const ModeRun m1 = runModeWorkload(1, 0, 0, 6);
        const ModeRun m2 = runModeWorkload(2, 0, 0, 6);
        const ModeRun m2j = runModeWorkload(2, 200, 0, 6);
        auto dump = [](const char* n, const ModeRun& m) {
            std::fprintf(stderr, "  %s: minors %llu majors %llu promoted %llu peak %llu hw %llu rel %llu fresh %llu reuse %llu"
                         " | x %llu live %llu inuse %llu released %llu pend!=0 %llu\n",
                n, (unsigned long long)m.minors, (unsigned long long)m.majors,
                (unsigned long long)m.promoted, (unsigned long long)m.inuse_peak,
                (unsigned long long)m.hiwater, (unsigned long long)m.released,
                (unsigned long long)m.fresh, (unsigned long long)m.reuse_total,
                (unsigned long long)m.x_calls, (unsigned long long)m.x_live,
                (unsigned long long)m.x_inuse_after, (unsigned long long)m.x_released,
                (unsigned long long)m.x_pending_nonzero);
        };
        const bool nowait_ran = m1.nowait != 0;
        const bool agree = (nowait_ran ? m0.sameObjects(m1) : m0 == m1) && m1 == m2 && m2 == m2j;
        if (!agree) { dump("m0", m0); dump("m1", m1); dump("m2", m2); dump("m2j", m2j); }
        TEST_ASSERT(m0.x_calls == 4);
        TEST_ASSERT(m0.x_released > 0);
        TEST_ASSERT(m0.x_live > 0);
        // pending bytes are 0 immediately after every call, in every mode
        TEST_ASSERT(m0.x_pending_nonzero == 0 && m1.x_pending_nonzero == 0 &&
                    m2.x_pending_nonzero == 0 && m2j.x_pending_nonzero == 0);
        // every decision (and the majors after each call) agrees across modes
        if (nowait_ran) TEST_ASSERT(m0.sameObjects(m1));
        else TEST_ASSERT(m0 == m1);
        TEST_ASSERT(m1 == m2);
        TEST_ASSERT(m2 == m2j);
        TEST_ASSERT(m1.nowait == m2.nowait && m2.nowait == m2j.nowait);
        initAllocator(modeConfig(0));
        closePool();
#endif
    });

Testing::TestCase testExplicitReleaseReturnsMemory(
    "HEAP_076: collectMajorAndRelease returns a dead 256 MB old gen to the OS (statm)",
    []() {
#if defined(__linux__)
        auto statmResident = []() -> size_t {
            FILE* f = std::fopen("/proc/self/statm", "r");
            if (!f) return 0;
            unsigned long long sz = 0, res = 0;
            const int n = std::fscanf(f, "%llu %llu", &sz, &res);
            std::fclose(f);
            return n == 2 ? static_cast<size_t>(res) * static_cast<size_t>(sysconf(_SC_PAGESIZE)) : 0;
        };
        constexpr size_t kMiB = 1024 * 1024;
        // 256 x 1 MiB, rooted, then dropped; the drop must be >= half of it.
        // The old-gen cap is first-init-wins for the test process (the
        // reservation), so a filtered run that first initialised a small heap
        // scales the heap down to half the cap.
        // Mode 0 (inline discard) and mode 2 with the production decommit
        // schedule (delay one MAJOR, never by syncs): without the explicit
        // drain the shrink's releases would stay resident until the next major.
        for (uint32_t mode : {0u, 2u}) {
            HeapConfig cfg = modeConfig(mode);
            cfg.max_heap_size = 1024ULL * kMiB;
            cfg.decommit_delay_syncs = UINT32_MAX;
            cfg.decommit_delay_majors = 1;
            cfg.validate();
            auto& pool = GCHelperPool::instance();
            if (pool.configured()) {
                initAllocator(modeConfig(0));
                pool.shutdownForTesting();
            }
            if (mode != 0) pool.configure(static_cast<HelperMode>(mode), 1, -1, 0);
            auto& alloc = initAllocator(cfg);
            const size_t cap_mib = alloc.getOldGenMaxBytes() / kMiB;
            const size_t kBuffers = std::min<size_t>(256, cap_mib > 64 ? cap_mib / 2 - 16 : 0);
            if (kBuffers < 32) {
                std::fprintf(stderr, "  SKIP: old-gen cap %zu MiB too small for the release test\n", cap_mib);
                break;
            }
            const size_t kMinDrop = kBuffers / 2 * kMiB;
            std::vector<HPointer> keep;
            keep.reserve(kBuffers);   // stable root addresses
            for (size_t i = 0; i < kBuffers; ++i) {
                const size_t payload = kMiB;
                void* obj = alloc.allocate(sizeof(ByteBuffer) + payload, Tag_ByteBuffer);
                TEST_ASSERT(obj != nullptr);
                ByteBuffer* buf = static_cast<ByteBuffer*>(obj);
                buf->header.size = static_cast<u32>(payload);
                std::memset(buf->bytes, 0xAB, payload);   // resident
                keep.push_back(AllocatorTestAccess::toPointer(obj));
                alloc.getRootSet().addRoot(&keep.back());
            }
            alloc.minorGC();
            for (auto& h : keep) alloc.getRootSet().removeRoot(&h);
            const size_t before = statmResident();
            const GCReport r = alloc.collectMajorAndRelease();
            const size_t after = statmResident();
            const bool ok = before > after && before - after >= kMinDrop &&
                            r.rss_after_discard < r.rss_before && r.old_pending_after == 0;
            if (!ok) {
                std::fprintf(stderr, "  mode %u: statm %zu -> %zu MiB; report rss %llu > %llu > %llu MiB,"
                             " released %llu MiB, discarded %llu MiB, shrink %llu MiB, pending %llu\n",
                             mode, before / kMiB, after / kMiB,
                             (unsigned long long)(r.rss_before / kMiB),
                             (unsigned long long)(r.rss_after_discard / kMiB),
                             (unsigned long long)(r.rss_after / kMiB),
                             (unsigned long long)(r.released_bytes / kMiB),
                             (unsigned long long)(r.discarded_bytes / kMiB),
                             (unsigned long long)(r.shrink_released_bytes / kMiB),
                             (unsigned long long)r.old_pending_after);
            }
            TEST_ASSERT(before > after && before - after >= kMinDrop);
            TEST_ASSERT(r.rss_after_discard < r.rss_before);
            TEST_ASSERT(r.old_pending_after == 0);
            TEST_ASSERT(r.released_bytes >= kMinDrop);
            TEST_ASSERT(r.discarded_bytes >= kMinDrop);
            TEST_ASSERT(r.majors_run >= 1);
        }
        initAllocator(modeConfig(0));
        closePool();
#endif
    });

namespace {
std::vector<std::pair<char*, size_t>> g_commits;
void recordCommit(char* p, size_t n) { g_commits.emplace_back(p, n); }
}  // namespace

Testing::TestCase testCommitAheadNeverRemapsWindow(
    "HEAP_060: with commit-ahead on, no commitAt range overlaps an earlier one",
    []() {
#if defined(__linux__) && ENABLE_GC_STATS
        initAllocator(modeConfig(0));   // settle: no pool, nothing in flight
        closePool();
        g_commits.clear();
        Allocator::commit_observer_for_testing = &recordCommit;
        runModeWorkload(1, 0, 2 * 1024 * 1024);
        Allocator::commit_observer_for_testing = nullptr;
        GCStats s = Allocator::instance().getCombinedStats();
        TEST_ASSERT(!g_commits.empty());
        auto sorted = g_commits;
        std::sort(sorted.begin(), sorted.end());
        for (size_t i = 1; i < sorted.size(); ++i) {
            TEST_ASSERT(sorted[i - 1].first + sorted[i - 1].second <= sorted[i].first);
        }
        if (s.helper.populate_supported) {
            TEST_ASSERT(s.page_supply.fresh_ahead_hit_bytes > 0);
        }
        initAllocator(modeConfig(0));
        closePool();
#endif
    });

Testing::TestCase testPageWorkValidatorCatchesOwnedTrackedExtent(
    "HEAP_059 V2: a tracked (pending) extent that a heap owns aborts at the next sync point",
    []() {
#if ECO_HEAP_VALIDATE && !defined(_WIN32) && ENABLE_GC_STATS
        // Clean run first: the validator stays quiet on a correct workload.
        runModeWorkload(1, 0);
        TEST_ASSERT(childAborts([] {
            HeapConfig cfg = modeConfig(1);
            cfg.decommit_delay_syncs = UINT32_MAX;   // keep extents pending
            auto& pool = GCHelperPool::instance();
            if (pool.configured()) pool.shutdownForTesting();
            auto& alloc = initAllocator(cfg);
            // Grow the old gen, then free it all so a major releases blocks.
            std::vector<HPointer> keep;
            keep.reserve(40000);
            for (int i = 0; i < 40000; ++i) {
                void* o = alloc.allocate(sizeof(ElmInt), Tag_Int);
                keep.push_back(AllocatorTestAccess::toPointer(o));
                alloc.getRootSet().addRoot(&keep.back());
            }
            alloc.minorGC();
            alloc.minorGC();
            for (auto& h : keep) alloc.getRootSet().removeRoot(&h);
            alloc.majorGC();
            char* victim = nullptr;
            alloc.pageWork()->forEachTracked([&](char* p, size_t, int) { if (!victim) victim = p; });
            if (victim == nullptr) _exit(0);   // nothing released: the test proves nothing
            auto* og = AllocatorTestAccess::getOldGen(alloc);
            OldGenSpaceTestAccess::pushUnassignedForTesting(*og, victim, victim + 32 * 1024);
            alloc.minorGC();                 // sync point -> V2 must abort
            _exit(0);
        }));
        initAllocator(modeConfig(0));
        closePool();
#endif
    });

Testing::TestCase testMmuIncludesHelperStalls(
    "threaded-gc-03: the MMU over pauses + outside-pause stalls matches a hand computation",
    []() {
#if ENABLE_GC_STATS
        const uint64_t ms = 1000000;
        GCPhaseTotals t;
        t.addPause(0, 10 * ms, 0);        // [0, 10) ms
        t.addStall(20 * ms, 10 * ms);     // [20, 30) ms
        TEST_ASSERT(t.stall_events.size() == 1);
        std::vector<PauseEvent> pauses = t.pause_events;
        std::vector<PauseEvent> both = pauses;
        both.insert(both.end(), t.stall_events.begin(), t.stall_events.end());
        const double u_pause = GCPhaseTotals::mmu(pauses, 100 * ms, 30 * ms);
        const double u_both = GCPhaseTotals::mmu(both, 100 * ms, 30 * ms);
        TEST_ASSERT(std::abs(u_pause - 2.0 / 3.0) < 1e-9);   // worst 30 ms window holds 10 ms
        TEST_ASSERT(std::abs(u_both - 1.0 / 3.0) < 1e-9);    // [0, 30) holds 20 ms
        GCPhaseTotals m;
        m.merge(t);
        TEST_ASSERT(m.stall_events.size() == 1);
#endif
    });

Testing::TestCase testHelperPoolSurvivesFork(
    "threaded-gc-03: after fork() the child restarts its helper workers (no lost jobs)",
    []() {
#if !defined(_WIN32)
        auto& pool = freshPool(HelperMode::Concurrent, 2);
        FnJob warm([] {});
        pool.post(warm);             // workers now running in the parent
        pool.wait(warm, true);
        std::fflush(stdout);
        pid_t pid = fork();
        if (pid == 0) {
            std::atomic<int> ran{0};
            std::deque<FnJob> jobs;
            for (int i = 0; i < 50; ++i) jobs.emplace_back([&] { ran.fetch_add(1); });
            for (auto& j : jobs) GCHelperPool::instance().post(j);
            GCHelperPool::instance().drain();
            _exit(ran.load() == 50 ? 0 : 3);
        }
        int status = 0;
        // A lost-worker bug hangs the child: bound the wait.
        for (int i = 0; i < 200; ++i) {
            if (waitpid(pid, &status, WNOHANG) == pid) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            if (i == 199) { kill(pid, SIGKILL); waitpid(pid, &status, 0); TEST_FAIL("child hung after fork"); }
        }
        TEST_ASSERT(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        FnJob after([] {});
        pool.post(after);            // the parent's workers are still alive
        pool.wait(after, true);
        closePool();
#endif
    });
